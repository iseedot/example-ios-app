//
//  TapRecorder.swift
//  MyCallRec — record a private audio tap into a CAF file.
//
//  The private AudioToolbox classes are reached through the Objective-C runtime, so the
//  target builds against the public SDK only. The call sequence follows the upstream
//  GPL reference implementation (cli/call-recorder.mm, cli/dtmf-decoder.mm) exactly,
//  because the order and the flag matter:
//
//    1. ATAudioTapDescription initTapInternalWithFormat:PIDs:   (iOS 16+)
//       fallback initProcessTapInternalWithFormat:PID:          (older, PID is an int)
//    2. [[ATAudioTap alloc] initWithTapDescription:]
//    3. AudioQueueNewInput(..., 0x800, &queue)                  <- tap flag, not 0
//    4. AudioQueueSetProperty(queue, 'qtob', tapPointer, 8)
//    5. allocate AND enqueue every buffer, then AudioQueueStart
//    6. read the queue's actual StreamDescription back and use it for writing
//

import Foundation
import AudioToolbox
import AVFAudio
import ObjectiveC

/// Well-known process sentinels accepted by the private tap description API.
public enum TapTarget: Equatable {
    case systemAudio   // -1
    case speaker       // -2
    case microphone    // -3
    case process(Int32)

    var rawValue: Int32 {
        switch self {
        case .systemAudio: return -1
        case .speaker: return -2
        case .microphone: return -3
        case .process(let pid): return pid
        }
    }

    public static func parse(_ text: String) -> TapTarget? {
        switch text.lowercased() {
        case "mic", "microphone": return .microphone
        case "speaker": return .speaker
        case "system": return .systemAudio
        default: return Int32(text).map(TapTarget.process)
        }
    }

    public var label: String {
        switch self {
        case .microphone: return "microphone"
        case .speaker: return "speaker"
        case .systemAudio: return "system-audio"
        case .process(let pid): return "pid:\(pid)"
        }
    }
}

/// AudioQueue property that redirects the queue input from the microphone to a tap object.
/// Documented by upstream's GPL header as four-char code 'qtob'.
let kTapOutputBypassProperty = AudioQueuePropertyID(0x71746F62)

/// Reserved flag the tap queues are created with upstream. A plain microphone queue is
/// created with 0, so this is what makes the queue a tap queue.
private let kTapQueueFlags: UInt32 = 0x800

/// Upstream's buffer bounds (cli/call-recorder.mm).
private let kMinimumBufferSize: UInt32 = 0x4000
private let kMaximumBufferSize: UInt32 = 0x50000

public enum TapRecorderError: Error, CustomStringConvertible {
    case privateClassesUnavailable
    case formatRejected
    case tapCreationFailed
    case queueSetupFailed(OSStatus)
    case fileCreationFailed(OSStatus)

    public var description: String {
        switch self {
        case .privateClassesUnavailable: return "private ATAudioTap classes are not present on this OS build"
        case .formatRejected: return "AVAudioFormat rejected the requested sample rate / channel count"
        case .tapCreationFailed: return "the private tap description or tap object could not be created"
        case .queueSetupFailed(let status):
            return "AudioQueue setup failed (OSStatus \(status) \(TapRecorder.fourCC(status)))"
        case .fileCreationFailed(let status):
            return "AudioFile creation failed (OSStatus \(status) \(TapRecorder.fourCC(status)))"
        }
    }
}

// The two init selectors take different argument kinds: the modern one takes an array of
// NSNumber, the legacy one takes a plain int. Casting the legacy one as an object pointer
// would put the low 32 bits of a pointer where the pid is expected.
private typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
private typealias InitOneObjectFn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> AnyObject?
private typealias InitObjectAndIntFn = @convention(c) (AnyObject, Selector, AnyObject?, Int32) -> AnyObject?

private func tr_implementation(of cls: AnyClass, _ name: String, classMethod: Bool = false) -> IMP? {
    let selector = NSSelectorFromString(name)
    let method = classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector)
    return method.map(method_getImplementation)
}

/// Receives audio from a private tap and writes it to a CAF file.
public final class TapRecorder {
    private var queue: AudioQueueRef?
    /// ExtAudioFile owns the file writer and converts the queue's PCM to AAC for m4a.
    private var extFile: ExtAudioFileRef?
    /// True when the destination is m4a/AAC; false keeps the lossless CAF/PCM output.
    private let compress: Bool
    private var buffers: [AudioQueueBufferRef] = []
    private var format = AudioStreamBasicDescription()
    /// The AVAudioFormat-derived description. Fully populated, unlike what the queue
    /// may hand back, so it is what the file is created with.
    private var requestedFormat = AudioStreamBasicDescription()
    private var packetIndex: Int64 = 0
    private let lock = NSLock()
    private var storedPackets: UInt64 = 0
    /// Held for the whole recording: the queue keeps an unretained reference.
    private var tap: AnyObject?
    private var destination: URL

    /// Human-readable target ("system-audio", "pid:123", …) for the log and the sidecar.
    public let targetLabel: String
    /// A plain microphone recording: the AudioQueue reads the default input device and the
    /// private ATAudioTap / 'qtob' path is skipped entirely.
    private let bypassTap: Bool
    /// When the recorder was created, for the metadata sidecar.
    public let startedAt = Date()
    /// Where the recording is written.
    public var fileURL: URL { destination }

    public private(set) var isRunning = false

    /// Highest sample magnitude in the most recent buffer (0...1). A non-zero value
    /// proves the tap is delivering audio rather than silence.
    public private(set) var peakAmplitude: Float = 0
    /// Highest magnitude observed since the recording started.
    public private(set) var maxPeakAmplitude: Float = 0
    /// Set once the first non-empty buffer arrives; distinguishes "entitlement missing"
    /// from "target produced nothing".
    public private(set) var receivedFirstBuffer = false

    public var packetsWritten: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return storedPackets
    }

    public var secondsRecorded: Double {
        format.mSampleRate > 0 ? Double(packetsWritten) / format.mSampleRate : 0
    }

    private static let callback: AudioQueueInputCallback = { userData, queue, buffer, _, _, _ in
        guard let userData else { return }
        let recorder = Unmanaged<TapRecorder>.fromOpaque(userData).takeUnretainedValue()
        recorder.handle(buffer: buffer, queue: queue)
    }

    /// Upstream watches kAudioQueueProperty_IsRunning: a tap queue can start in a
    /// "waiting for device" state and only begin delivering once the route is ready. A
    /// queue that stays at IsRunning=0 never calls back, which is exactly the 0-packet
    /// case, so the state is logged.
    private static let runningListener: AudioQueuePropertyListenerProc = { userData, queue, _ in
        guard let userData else { return }
        let recorder = Unmanaged<TapRecorder>.fromOpaque(userData).takeUnretainedValue()
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size)
        recorder.reportRunning(status == noErr ? running : 0, status: status)
    }

    fileprivate func reportRunning(_ running: UInt32, status: OSStatus) {
        trlog(.info, "TAP", "AudioQueue IsRunning=\(running)（status=\(status)）")
    }

    /// Renders an OSStatus four-character result so a failure is readable in the log.
    static func fourCC(_ status: OSStatus) -> String {
        let raw = UInt32(bitPattern: status)
        guard raw >= 0x2020_2020, raw <= 0x7E7E_7E7E else { return "" }
        let bytes = [UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF),
                     UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
        guard let text = String(bytes: bytes, encoding: .ascii) else { return "" }
        return "('\(text)')"
    }

    public init(target: TapTarget, sampleRate: Double, channels: UInt32,
                fileURL: URL, bypassTap: Bool = false, compress: Bool = true) throws {
        destination = fileURL
        targetLabel = target.label
        self.bypassTap = bypassTap
        self.compress = compress

        guard let requested = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sampleRate,
                                            channels: AVAudioChannelCount(channels),
                                            interleaved: true) else {
            throw TapRecorderError.formatRejected
        }
        self.format = requested.streamDescription.pointee
        self.requestedFormat = Self.normalized(self.format)
        trlog(.info, "TAP", "请求格式：\(Self.describe(self.format))")

        // A plain microphone recording does not need the private tap. Skipping it avoids
        // the tap queue entirely, which is what never delivers buffers here (notably with a
        // Bluetooth HFP headset connected).
        if bypassTap {
            trlog(.info, "TAP", "麦克风直录模式：不使用私有 tap，AudioQueue 直接用默认输入设备")
            return
        }

        guard let descriptionClass = NSClassFromString("ATAudioTapDescription"),
              let tapClass = NSClassFromString("ATAudioTap") else {
            throw TapRecorderError.privateClassesUnavailable
        }

        guard let allocIMP = tr_implementation(of: descriptionClass, "alloc", classMethod: true) else {
            throw TapRecorderError.tapCreationFailed
        }
        let allocate = unsafeBitCast(allocIMP, to: AllocFn.self)
        guard let allocated = allocate(descriptionClass, NSSelectorFromString("alloc")) else {
            throw TapRecorderError.tapCreationFailed
        }

        var description: AnyObject?
        if let imp = tr_implementation(of: descriptionClass, "initTapInternalWithFormat:PIDs:") {
            // The argument is an NSArray of NSNumber, so an object-typed call is correct.
            let initialize = unsafeBitCast(imp, to: InitOneObjectFn.self)
            description = initialize(allocated, NSSelectorFromString("initTapInternalWithFormat:PIDs:"),
                                     requested, [NSNumber(value: target.rawValue)] as NSArray)
            trlog(.info, "TAP", "使用 initTapInternalWithFormat:PIDs:（新版），PIDs=[\(target.rawValue)]")
        } else if let imp = tr_implementation(of: descriptionClass, "initProcessTapInternalWithFormat:PID:") {
            // The legacy argument is a plain int; passing an object pointer here would
            // hand the callee the low 32 bits of a pointer.
            let initialize = unsafeBitCast(imp, to: InitObjectAndIntFn.self)
            description = initialize(allocated, NSSelectorFromString("initProcessTapInternalWithFormat:PID:"),
                                     requested, target.rawValue)
            trlog(.info, "TAP", "使用 initProcessTapInternalWithFormat:PID:（旧版），PID=\(target.rawValue)")
        } else {
            trlog(.error, "TAP", "ATAudioTapDescription 两个初始化选择子都不存在")
        }
        guard let description else {
            throw TapRecorderError.tapCreationFailed
        }
        // The private class describes its resolved target, which is the one fact a silent
        // recording needs when the sentinel and the actual tap disagree.
        trlog(.info, "TAP", "tap 描述：\(String(describing: description))")

        guard let tapAllocIMP = tr_implementation(of: tapClass, "alloc", classMethod: true) else {
            throw TapRecorderError.tapCreationFailed
        }
        let allocateTap = unsafeBitCast(tapAllocIMP, to: AllocFn.self)
        guard let allocatedTap = allocateTap(tapClass, NSSelectorFromString("alloc")),
              let initIMP = tr_implementation(of: tapClass, "initWithTapDescription:") else {
            throw TapRecorderError.tapCreationFailed
        }
        let initializeTap = unsafeBitCast(initIMP, to: InitOneObjectFn.self)
        guard let tapObject = initializeTap(allocatedTap, NSSelectorFromString("initWithTapDescription:"), description, nil) else {
            throw TapRecorderError.tapCreationFailed
        }
        tap = tapObject
        trlog(.info, "TAP", "ATAudioTap 已创建：\(String(describing: tapObject))")
    }

    public func start() throws {
        guard !isRunning else { return }
        if !bypassTap, tap == nil { throw TapRecorderError.tapCreationFailed }

        var queue: AudioQueueRef?
        // 0x800 is the flag the tap queues are created with upstream; a plain microphone
        // queue uses 0.
        let flags: UInt32 = bypassTap ? 0 : kTapQueueFlags
        var status = AudioQueueNewInput(&format, TapRecorder.callback,
                                        Unmanaged.passUnretained(self).toOpaque(),
                                        nil, nil, flags, &queue)
        guard status == noErr, let queue else {
            trlog(.error, "TAP", "AudioQueueNewInput 失败：\(status) \(Self.fourCC(status))")
            throw TapRecorderError.queueSetupFailed(status)
        }
        self.queue = queue
        trlog(.info, "TAP", "AudioQueueNewInput 成功（flags \(flags)）")

        if bypassTap {
            trlog(.info, "TAP", "直录模式：跳过 ATAudioTap / 'qtob' 绑定")
        } else if let tap {
            // Bind the queue input to the tap instead of the microphone. Upstream passes
            // the tap pointer itself for an 8 byte payload.
            let tapPointer = Unmanaged.passUnretained(tap).toOpaque()
            status = AudioQueueSetProperty(queue, kTapOutputBypassProperty, tapPointer, 8)
            guard status == noErr else {
                trlog(.error, "TAP", "AudioQueueSetProperty('qtob') 失败：\(status) \(Self.fourCC(status))")
                AudioQueueDispose(queue, true)
                self.queue = nil
                throw TapRecorderError.queueSetupFailed(status)
            }
            trlog(.info, "TAP", "AudioQueueSetProperty('qtob') 成功")
        }

        // A tap queue can sit in "waiting for device"; log the state so a 0-packet run is
        // distinguishable from a route that never became ready.
        status = AudioQueueAddPropertyListener(queue, kAudioQueueProperty_IsRunning,
                                               TapRecorder.runningListener,
                                               Unmanaged.passUnretained(self).toOpaque())
        if status == noErr {
            trlog(.info, "TAP", "已添加 IsRunning 监听")
        }

        // The queue may not give back what was requested, so adopt the real format.
        var actual = AudioStreamBasicDescription()
        var actualSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioQueueGetProperty(queue, kAudioQueueProperty_StreamDescription, &actual, &actualSize) == noErr,
           actual.mSampleRate > 0, actual.mChannelsPerFrame > 0 {
            format = actual
            trlog(.info, "TAP", "队列实际格式：\(Self.describe(format))")
        } else {
            trlog(.warn, "TAP", "读不到队列的 StreamDescription，沿用请求格式")
        }

        let destinationDirectory = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: destinationDirectory.path) {
            try? FileManager.default.createDirectory(at: destinationDirectory,
                                                     withIntermediateDirectories: true)
            trlog(.warn, "TAP", "录音目录不存在，已创建：\(destinationDirectory.path)")
        }
        trlog(.info, "TAP", "写入目标：\(destination.path)")

        // ExtAudioFile converts the queue's PCM to AAC for m4a and writes it unchanged for
        // CAF. The client format is the format the queue actually delivers.
        var clientFormat = format
        var fileFormat = clientFormat
        var fileType: AudioFileTypeID = kAudioFileCAFType
        if compress {
            fileType = kAudioFileM4AType
            fileFormat = Self.aacFormat(sampleRate: format.mSampleRate,
                                        channels: format.mChannelsPerFrame)
        }
        trlog(.info, "TAP", "文件格式（\(compress ? "m4a/AAC" : "caf/LPCM")）：\(Self.describe(fileFormat))")

        var ref: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(destination as CFURL, fileType, &fileFormat, nil,
                                           AudioFileFlags.eraseFile.rawValue, &ref)
        if status != noErr, compress {
            trlog(.warn, "TAP", "m4a 创建失败：\(status) \(Self.fourCC(status))，回退为 CAF/LPCM")
            fileType = kAudioFileCAFType
            fileFormat = clientFormat
            status = ExtAudioFileCreateWithURL(destination as CFURL, fileType, &fileFormat, nil,
                                               AudioFileFlags.eraseFile.rawValue, &ref)
        }
        guard status == noErr, let ref else {
            trlog(.error, "TAP", "ExtAudioFileCreateWithURL 失败：\(status) \(Self.fourCC(status))；"
                  + "目录存在=\(FileManager.default.fileExists(atPath: destinationDirectory.path))")
            AudioQueueDispose(queue, true)
            self.queue = nil
            throw TapRecorderError.fileCreationFailed(status)
        }
        status = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                         &clientFormat)
        guard status == noErr else {
            trlog(.error, "TAP", "ExtAudioFileSetProperty(ClientDataFormat) 失败：\(status) \(Self.fourCC(status))")
            ExtAudioFileDispose(ref)
            AudioQueueDispose(queue, true)
            self.queue = nil
            throw TapRecorderError.fileCreationFailed(status)
        }
        self.extFile = ref

        if format.mBytesPerPacket != requestedFormat.mBytesPerPacket {
            trlog(.warn, "TAP", "队列格式与请求格式的 bytes-per-packet 不同"
                  + "（\(format.mBytesPerPacket) vs \(requestedFormat.mBytesPerPacket)）")
        }

        let bytesPerPacket = format.mBytesPerPacket != 0
            ? format.mBytesPerPacket
            : max(1, format.mBytesPerFrame)
        let wanted = UInt32(format.mSampleRate * Double(bytesPerPacket) * 0.5)
        let bufferByteSize = min(max(wanted, kMinimumBufferSize), kMaximumBufferSize)

        buffers.reserveCapacity(3)
        for index in 0..<3 {
            var buffer: AudioQueueBufferRef?
            guard AudioQueueAllocateBuffer(queue, bufferByteSize, &buffer) == noErr, let buffer else {
                trlog(.error, "TAP", "AudioQueueAllocateBuffer 第 \(index + 1) 个失败")
                continue
            }
            // Enqueue before starting: a tap queue with no buffers delivers nothing.
            let enqueueStatus = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            if enqueueStatus != noErr {
                trlog(.warn, "TAP", "AudioQueueEnqueueBuffer 第 \(index + 1) 个失败：\(enqueueStatus)")
            }
            buffers.append(buffer)
        }
        trlog(.info, "TAP", "已分配并入队 \(buffers.count) 个缓冲区，每个 \(bufferByteSize) 字节")

        status = AudioQueueStart(queue, nil)
        guard status == noErr else {
            trlog(.error, "TAP", "AudioQueueStart 失败：\(status) \(Self.fourCC(status))")
            throw TapRecorderError.queueSetupFailed(status)
        }
        isRunning = true
        trlog(.info, "TAP", "AudioQueueStart 成功，开始接收音频")
    }

    fileprivate func handle(buffer: AudioQueueBufferRef, queue: AudioQueueRef) {
        let byteCount = buffer.pointee.mAudioDataByteSize
        if byteCount > 0, !receivedFirstBuffer {
            receivedFirstBuffer = true
            trlog(.info, "TAP", "第一个音频缓冲区到达 (\(byteCount) 字节)")
        }
        updatePeak(from: buffer, byteCount: byteCount)
        if byteCount > 0, let extFile {
            let bytesPerFrame = max(1, format.mBytesPerFrame)
            let frames = byteCount / bytesPerFrame
            if frames > 0 {
                let audioBuffer = AudioBuffer(mNumberChannels: format.mChannelsPerFrame,
                                              mDataByteSize: byteCount,
                                              mData: buffer.pointee.mAudioData)
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
                let status = ExtAudioFileWrite(extFile, frames, &list)
                if status == noErr {
                    lock.lock()
                    storedPackets += UInt64(frames)
                    lock.unlock()
                }
            }
        }
        if isRunning {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }

    /// Samples the buffer to report a peak level; a cheap way to tell audio from silence.
    private func updatePeak(from buffer: AudioQueueBufferRef, byteCount: UInt32) {
        guard byteCount >= 4 else { return }
        let data = buffer.pointee.mAudioData
        var peak: Float = 0

        switch (format.mBitsPerChannel, format.mFormatFlags & kAudioFormatFlagIsFloat != 0) {
        case (32, true):
            let count = Int(byteCount) / MemoryLayout<Float32>.size
            let samples = data.assumingMemoryBound(to: Float32.self)
            var index = 0
            while index < count {
                let value = abs(samples[index])
                if value > peak { peak = value }
                index += 4
            }
        case (16, false):
            let count = Int(byteCount) / MemoryLayout<Int16>.size
            let samples = data.assumingMemoryBound(to: Int16.self)
            var index = 0
            while index < count {
                let value = abs(Float(samples[index]) / 32768.0)
                if value > peak { peak = value }
                index += 4
            }
        default:
            // Unknown sample layout: report "no measurement" rather than a wrong number.
            return
        }

        peakAmplitude = peak
        if peak > maxPeakAmplitude { maxPeakAmplitude = peak }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
            self.queue = nil
        }
        if let extFile {
            ExtAudioFileDispose(extFile)
            self.extFile = nil
        }
        buffers = []
        tap = nil
    }

    /// Human-readable ASBD, so the log shows every field the file writer depends on.
    private static func describe(_ format: AudioStreamBasicDescription) -> String {
        let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        return String(format: "id=%@ flags=0x%X %.0f Hz / %u ch / %u bit / %@ / %@ / pkt=%u bytes / frame=%u bytes / %u frames-per-packet",
                      fourCCString(format.mFormatID), format.mFormatFlags,
                      format.mSampleRate, format.mChannelsPerFrame, format.mBitsPerChannel,
                      float ? "float" : "int", interleaved ? "interleaved" : "planar",
                      format.mBytesPerPacket, format.mBytesPerFrame, format.mFramesPerPacket)
    }

    private static func fourCCString(_ value: UInt32) -> String {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "0x\(String(value, radix: 16))"
    }

    /// Fills in every derived field, so the result is always valid for a file writer.
    private static func normalized(_ source: AudioStreamBasicDescription) -> AudioStreamBasicDescription {
        var format = source
        if format.mFormatID == 0 { format.mFormatID = kAudioFormatLinearPCM }
        if format.mSampleRate == 0 { format.mSampleRate = 44100 }
        if format.mChannelsPerFrame == 0 { format.mChannelsPerFrame = 2 }
        if format.mBitsPerChannel == 0 { format.mBitsPerChannel = 32 }
        if format.mFramesPerPacket == 0 { format.mFramesPerPacket = 1 }
        if format.mBytesPerFrame == 0 {
            format.mBytesPerFrame = max(1, format.mChannelsPerFrame * format.mBitsPerChannel / 8)
        }
        if format.mBytesPerPacket == 0 {
            format.mBytesPerPacket = format.mBytesPerFrame * format.mFramesPerPacket
        }
        return format
    }

    /// AAC (m4a) output format for ExtAudioFile. AudioFormatGetProperty fills in the
    /// derived fields that a bare mFormatID/mSampleRate/mChannelsPerFrame leaves at zero.
    private static func aacFormat(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        format.mFormatID = kAudioFormatMPEG4AAC
        format.mSampleRate = sampleRate > 0 ? sampleRate : 44100
        format.mChannelsPerFrame = max(1, channels)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &format)
        return format
    }

    /// Last-resort description: plain interleaved float32 PCM, which every writer accepts.
    private static func explicitLinearPCM(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        let channelCount = max(1, channels)
        let bytesPerFrame = 4 * channelCount
        return AudioStreamBasicDescription(mSampleRate: sampleRate > 0 ? sampleRate : 44100,
                                           mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                           mBytesPerPacket: bytesPerFrame,
                                           mFramesPerPacket: 1,
                                           mBytesPerFrame: bytesPerFrame,
                                           mChannelsPerFrame: channelCount,
                                           mBitsPerChannel: 32,
                                           mReserved: 0)
    }

    deinit { stop() }
}
