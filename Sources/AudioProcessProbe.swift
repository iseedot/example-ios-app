//
//  AudioProcessProbe.swift
//  MyCallRec — enumerate CoreAudio process objects to learn which process owns audio.
//
//  Uses the iOS 14+ audio process object API with caller-defined four-character
//  selectors, so this compiles against any SDK that declares the basic HAL entry
//  points while still reaching the per-process properties.
//
//  Why it matters:
//    * it answers "which PID owns the call audio" without guessing;
//    * it detects a non-CallKit app (for example WeChat) that is running input audio,
//      which is what a recorder needs to start automatically.
//

import Foundation
import CoreFoundation
import CoreAudio
import Darwin

struct AudioProcessInfo: Identifiable, Hashable {
    let objectID: AudioObjectID
    let pid: Int32
    let bundleIdentifier: String?
    let isRunning: Bool
    let isRunningInput: Bool
    let isRunningOutput: Bool

    var id: Int32 { pid }
    var displayName: String { bundleIdentifier ?? "pid \(pid)" }
}

enum AudioProcessProbe {
    /// Four-character property selectors, built from their documented codes.
    private static let fourCC: (String) -> AudioObjectPropertySelector = { code in
        code.unicodeScalars.reduce(AudioObjectPropertySelector(0)) { ($0 << 8) | AudioObjectPropertySelector($1.value & 0xFF) }
    }

    private static let systemObject = AudioObjectID(1)                  // kAudioObjectSystemObject
    private static let scopeGlobal = fourCC("glob")                     // kAudioObjectPropertyScopeGlobal
    private static let elementMain = AudioObjectPropertyElement(0)      // kAudioObjectPropertyElementMain

    private static let propertyProcessObjectList = fourCC("prco")
    private static let propertyProcessPID = fourCC("ppid")
    private static let propertyProcessBundleID = fourCC("pbid")
    private static let propertyProcessIsRunning = fourCC("pirs")
    private static let propertyProcessIsRunningInput = fourCC("piri")
    private static let propertyProcessIsRunningOutput = fourCC("piro")

    static var isAvailable: Bool { true }

    /// Enumerates every CoreAudio process object. Failures are logged, not thrown.
    static func processes() -> [AudioProcessInfo] {
        var address = AudioObjectPropertyAddress(mSelector: propertyProcessObjectList,
                                                 mScope: scopeGlobal,
                                                 mElement: elementMain)
        var size: UInt32 = 0
        // The first call only reports the required size, so the data pointer stays nil.
        var status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, nil)
        guard size > 0 else {
            trlog(.warn, "AUDIO", "音频进程列表为空 (status=\(status), size=\(size))")
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var identifiers = [AudioObjectID](repeating: 0, count: count)
        status = identifiers.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, raw.baseAddress)
        }
        guard status == noErr else {
            trlog(.warn, "AUDIO", "读取音频进程列表失败 (status=\(status))")
            return []
        }

        return identifiers.compactMap { info(for: $0) }
    }

    private static func info(for object: AudioObjectID) -> AudioProcessInfo? {
        let pid = uint32Property(object, propertyProcessPID).map { Int32(bitPattern: $0) } ?? -1
        guard pid > 0 else { return nil }
        return AudioProcessInfo(objectID: object,
                                pid: pid,
                                bundleIdentifier: stringProperty(object, propertyProcessBundleID),
                                isRunning: uint32Property(object, propertyProcessIsRunning) == 1,
                                isRunningInput: uint32Property(object, propertyProcessIsRunningInput) == 1,
                                isRunningOutput: uint32Property(object, propertyProcessIsRunningOutput) == 1)
    }

    private static func uint32Property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scopeGlobal, mElement: elementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scopeGlobal, mElement: elementMain)
        var pointer: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &pointer) { buffer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer)
        }
        guard status == noErr, let value = pointer?.takeRetainedValue() else { return nil }
        return value as String
    }

    /// Compact, log-friendly rendering of the whole table.
    static func describe(_ processes: [AudioProcessInfo]) -> String {
        guard !processes.isEmpty else { return "（无音频进程）" }
        return processes
            .sorted { $0.pid < $1.pid }
            .map { info in
                let flags = [info.isRunning ? "run" : nil,
                             info.isRunningInput ? "in" : nil,
                             info.isRunningOutput ? "out" : nil]
                    .compactMap { $0 }.joined(separator: "+")
                return "\(info.pid):\(info.bundleIdentifier ?? "?")[\(flags)]"
            }
            .joined(separator: " ")
    }

    /// Processes currently capturing audio. This is the set a call recorder taps.
    static func inputProcesses() -> [AudioProcessInfo] {
        processes().filter { $0.isRunningInput }
    }

    static func process(matchingBundleIdentifier identifier: String) -> AudioProcessInfo? {
        let target = identifier.lowercased()
        return processes().first { ($0.bundleIdentifier ?? "").lowercased() == target }
    }
}
