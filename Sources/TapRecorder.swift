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
    private var file: AudioFileID?
    private var buffers: [AudioQueueBufferRef] = []
    private var format = AudioStreamBasicDescription()
    private var packetIndex: Int64 = 0
    private let lock = NSLock()
    private var storedPackets: UInt64 = 0
    /// Held for the whole recording: the queue keeps an unretained reference.
    private var tap: AnyObject?
    private var destination: URL

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

    /// Renders an OSStatus four-character result so a failure is readable in the log.
    static func fourCC(_ status: OSStatus) -> String {
        let raw = UInt32(bitPattern: status)
        guard raw >= 0x2020_2020, raw <= 0x7E7E_7E7E else { return "" }
        let bytes = [UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF),
                     UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
        guard let text = String(bytes: bytes, encoding: .ascii) else { return "" }
        return "('\(text)')"
    }

    public init(target: TapTarget, sampleRate: Double, channels: UInt32, fileURL: URL) throws {
        destination = fileURL

        guard let requested = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sampleRate,
                                            channels: AVAudioChannelCount(channels),
                                            interleaved: true) else {
            throw TapRecorderError.formatRejected
        }
        self.format = requested.streamDescription.pointee
        trlog(.info, "TAP", "请求格式：\(Self.describe(self.format))")

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
        trlog(.info, "TAP", "ATAudioTap 已创建")
    }

    public func start() throws {
        guard !isRunning else { return }
        guard let tap else { throw TapRecorderError.tapCreationFailed }

        var queue: AudioQueueRef?
        // 0x800 is the flag the tap queues are created with upstream; a plain microphone
        // queue uses 0.
        var status = AudioQueueNewInput(&format, TapRecorder.callback,
                                        Unmanaged.passUnretained(self).toOpaque(),
                                        nil, nil, kTapQueueFlags, &queue)
        guard status == noErr, let queue else {
            trlog(.error, "TAP", "AudioQueueNewInput 失败：\(status) \(Self.fourCC(status))")
            throw TapRecorderError.queueSetupFailed(status)
        }
        self.queue = queue
        trlog(.info, "TAP", "AudioQueueNewInput 成功（flags \(kTapQueueFlags)）")

        // Bind the queue input to the tap instead of the microphone. Upstream passes the
        // tap pointer itself for an 8 byte payload.
        let tapPointer = Unmanaged.passUnretained(tap).toOpaque()
        status = AudioQueueSetProperty(queue, kTapOutputBypassProperty, tapPointer, 8)
        guard status == noErr else {
            trlog(.error, "TAP", "AudioQueueSetProperty('qtob') 失败：\(status) \(Self.fourCC(status))")
            AudioQueueDispose(queue, true)
            self.queue = nil
            throw TapRecorderError.queueSetupFailed(status)
        }
        trlog(.info, "TAP", "AudioQueueSetProperty('qtob') 成功")

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

        var file: AudioFileID?
        status = AudioFileCreateWithURL(destination as CFURL, kAudioFileCAFType, &format,
                                        AudioFileFlags.eraseFile, &file)
        guard status == noErr, let file else {
            trlog(.error, "TAP", "AudioFileCreateWithURL 失败：\(status) \(Self.fourCC(status))")
            AudioQueueDispose(queue, true)
            self.queue = nil
            throw TapRecorderError.fileCreationFailed(status)
        }
        self.file = file

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
        if byteCount > 0, let file {
            let bytesPerPacket = format.mBytesPerPacket != 0
                ? format.mBytesPerPacket
                : max(1, format.mBytesPerFrame)
            var packets = byteCount / bytesPerPacket
            if packets > 0 {
                let status = AudioFileWritePackets(file, false, byteCount, nil, packetIndex, &packets,
                                                   buffer.pointee.mAudioData)
                if status == noErr {
                    packetIndex += Int64(packets)
                    lock.lock()
                    storedPackets += UInt64(packets)
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
        if let file {
            AudioFileClose(file)
            self.file = nil
        }
        buffers = []
        tap = nil
    }

    /// Human-readable ASBD, so the log shows what the tap really produced.
    private static func describe(_ format: AudioStreamBasicDescription) -> String {
        let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        return String(format: "%.0f Hz / %u ch / %u bit / %@ / %@ / %u bytes-per-packet",
                      format.mSampleRate, format.mChannelsPerFrame, format.mBitsPerChannel,
                      float ? "float" : "int", interleaved ? "interleaved" : "planar",
                      format.mBytesPerPacket)
    }

    deinit { stop() }
}
