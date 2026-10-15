//
//  TapRecorder.swift
//  callrec — Phase 1 proof of concept, Swift implementation.
//
//  Private AudioToolbox classes are reached through the Objective-C runtime, so the
//  target builds against the public SDK only. Interface facts came from the static
//  analysis in ../../analysis/TECHNIQUE-call-audio-tap.md.
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
        case .queueSetupFailed(let status): return "AudioQueue setup failed (OSStatus \(status))"
        case .fileCreationFailed(let status): return "AudioFile creation failed (OSStatus \(status))"
        }
    }
}

private typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
private typealias InitOneArgFn = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
private typealias InitTwoArgFn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> AnyObject?

private func tr_implementation(of cls: AnyClass, _ name: String, classMethod: Bool = false) -> IMP? {
    let selector = NSSelectorFromString(name)
    let method = classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector)
    return method.map(method_getImplementation)
}

/// Receives audio from a private tap and writes it to a CAF file.
public final class TapRecorder {
    private var queue: AudioQueueRef?
    private var file: AudioFileID?
    private var buffers: [AudioQueueBufferRef?] = []
    private var format = AudioStreamBasicDescription()
    private var packetIndex: Int64 = 0
    private let lock = NSLock()
    private var storedPackets: UInt64 = 0
    private var tap: AnyObject?
    private var destination: URL

    public private(set) var isRunning = false

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

    public init(target: TapTarget, sampleRate: Double, channels: UInt32, fileURL: URL) throws {
        destination = fileURL

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: true) else {
            throw TapRecorderError.formatRejected
        }
        self.format = format.streamDescription.pointee

        guard let descriptionClass = NSClassFromString("ATAudioTapDescription"),
              let tapClass = NSClassFromString("ATAudioTap") else {
            throw TapRecorderError.privateClassesUnavailable
        }

        // ATAudioTapDescription: prefer the iOS 16+ PIDs: variant and fall back to the older PID: one.
        guard let allocIMP = tr_implementation(of: descriptionClass, "alloc", classMethod: true) else {
            throw TapRecorderError.tapCreationFailed
        }
        let allocate = unsafeBitCast(allocIMP, to: AllocFn.self)
        guard let allocated = allocate(descriptionClass, NSSelectorFromString("alloc")) else {
            throw TapRecorderError.tapCreationFailed
        }

        var description: AnyObject?
        if let imp = tr_implementation(of: descriptionClass, "initTapInternalWithFormat:PIDs:") {
            let initialize = unsafeBitCast(imp, to: InitTwoArgFn.self)
            description = initialize(allocated, NSSelectorFromString("initTapInternalWithFormat:PIDs:"),
                                     format, [NSNumber(value: target.rawValue)] as NSArray)
        } else if let imp = tr_implementation(of: descriptionClass, "initProcessTapInternalWithFormat:PID:") {
            let initialize = unsafeBitCast(imp, to: InitTwoArgFn.self)
            description = initialize(allocated, NSSelectorFromString("initProcessTapInternalWithFormat:PID:"),
                                     format, NSNumber(value: target.rawValue))
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
        let initializeTap = unsafeBitCast(initIMP, to: InitOneArgFn.self)
        guard let tapObject = initializeTap(allocatedTap, NSSelectorFromString("initWithTapDescription:"), description) else {
            throw TapRecorderError.tapCreationFailed
        }
        tap = tapObject
    }

    public func start() throws {
        guard !isRunning else { return }
        var queue: AudioQueueRef?
        var status = AudioQueueNewInput(&format, TapRecorder.callback,
                                        Unmanaged.passUnretained(self).toOpaque(),
                                        nil, nil, 0, &queue)
        guard status == noErr, let queue else { throw TapRecorderError.queueSetupFailed(status) }
        self.queue = queue

        // Bind the queue input to the tap instead of the microphone.
        status = AudioQueueSetProperty(queue, kTapOutputBypassProperty, &tap, 8)
        guard status == noErr else {
            AudioQueueDispose(queue, true)
            self.queue = nil
            throw TapRecorderError.queueSetupFailed(status)
        }

        var file: AudioFileID?
        status = AudioFileCreateWithURL(destination as CFURL, kAudioFileCAFType, &format,
                                        AudioFileFlags.eraseFile, &file)
        guard status == noErr, let file else {
            AudioQueueDispose(queue, true)
            self.queue = nil
            throw TapRecorderError.fileCreationFailed(status)
        }
        self.file = file

        let bytesPerPacket = format.mBytesPerPacket != 0 ? format.mBytesPerPacket : 4 * format.mChannelsPerFrame
        let bufferByteSize = UInt32(format.mSampleRate * Double(bytesPerPacket) * 0.5)
        buffers = Array(repeating: nil, count: 3)
        for index in 0..<3 {
            var buffer: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(queue, max(bufferByteSize, 16384), &buffer) == noErr {
                buffers[index] = buffer
            }
        }

        status = AudioQueueStart(queue, nil)
        guard status == noErr else { throw TapRecorderError.queueSetupFailed(status) }
        isRunning = true
    }

    fileprivate func handle(buffer: AudioQueueBufferRef, queue: AudioQueueRef) {
        let byteCount = buffer.pointee.mAudioDataByteSize
        if byteCount > 0, let file {
            let bytesPerPacket = format.mBytesPerPacket != 0 ? format.mBytesPerPacket : 4 * format.mChannelsPerFrame
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

    deinit { stop() }
}
