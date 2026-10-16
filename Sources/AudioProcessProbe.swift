//
//  AudioProcessProbe.swift
//  MyCallRec — probe the CoreAudio HAL process-object list.
//
//  Result on the test device: the system object answers
//  kAudioHardwareIllegalOperationError ('nope') for 'prco', so this API cannot
//  enumerate audio processes here. The probe therefore stays as a *diagnostic*: it
//  reports once, in readable form, and the caller stops treating it as a trigger.
//  The analysed target does not use this API at all.
//
//  The iOS SDK does not expose the HAL process-object types, so the entry point is
//  resolved with dlsym and the property selectors are four-character codes.
//

import Foundation
import CoreFoundation
import CoreAudio
import Darwin

struct AudioProcessInfo: Identifiable, Hashable {
    let objectID: UInt32
    let pid: Int32
    let bundleIdentifier: String?
    let isRunning: Bool
    let isRunningInput: Bool
    let isRunningOutput: Bool

    var id: Int32 { pid }
    var displayName: String { bundleIdentifier ?? "pid \(pid)" }
}

/// The HAL address structure is three contiguous UInt32 values; a tuple has the same
/// layout without needing the SDK type.
private typealias PropertyAddress = (selector: UInt32, scope: UInt32, element: UInt32)

private typealias AudioObjectGetPropertyDataFn = @convention(c) (UInt32,
                                                                 UnsafeRawPointer,
                                                                 UInt32,
                                                                 UnsafeRawPointer?,
                                                                 UnsafeMutablePointer<UInt32>,
                                                                 UnsafeMutableRawPointer?) -> Int32

enum AudioProcessProbe {
    private static let frameworkPath = "/System/Library/Frameworks/CoreAudio.framework/CoreAudio"

    /// Reported once per launch; the UI and the log both read it.
    private(set) static var statusDescription = "尚未探测"
    private static var reportedFailure = false

    /// Resolved on first use. No other static is touched from this initialiser: a
    /// static initialiser that writes another static is easy to get subtly wrong, so
    /// `processes()` is what records the reason instead.
    private static let getPropertyData: AudioObjectGetPropertyDataFn? = {
        // Load explicitly so the symbol is reachable even if nothing else pulled it in.
        dlopen(frameworkPath, RTLD_NOW)
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AudioObjectGetPropertyData") else {
            return nil
        }
        return unsafeBitCast(symbol, to: AudioObjectGetPropertyDataFn.self)
    }()

    /// A function rather than a closure property so other static initialisers can call it.
    private static func fourCC(_ code: String) -> UInt32 {
        code.unicodeScalars.reduce(UInt32(0)) { ($0 << 8) | UInt32($1.value & 0xFF) }
    }

    private static let systemObject = UInt32(1)          // kAudioObjectSystemObject
    private static let scopeGlobal = fourCC("glob")      // kAudioObjectPropertyScopeGlobal
    private static let elementMain = UInt32(0)           // kAudioObjectPropertyElementMain

    private static let propertyProcessObjectList = fourCC("prco")
    private static let propertyProcessPID = fourCC("ppid")
    private static let propertyProcessBundleID = fourCC("pbid")
    private static let propertyProcessIsRunning = fourCC("pirs")
    private static let propertyProcessIsRunningInput = fourCC("piri")
    private static let propertyProcessIsRunningOutput = fourCC("piro")

    static var isAvailable: Bool { getPropertyData != nil }

    /// Known CoreAudio OSStatus four-character results, so the log is self-explaining.
    private static let knownStatus: [UInt32: String] = [
        fourCC("nope"): "kAudioHardwareIllegalOperationError",
        fourCC("who?"): "kAudioHardwareUnknownPropertyError",
        fourCC("obj!"): "kAudioHardwareBadObjectError",
        fourCC("!siz"): "kAudioHardwareBadPropertySizeError",
        fourCC("!dat"): "kAudioDeviceUnsupportedFormatError",
        fourCC("unop"): "kAudioHardwareUnsupportedOperationError",
        fourCC("stop"): "kAudioHardwareNotRunningError",
        fourCC("what"): "kAudioHardwareUnspecifiedError",
        fourCC("!hog"): "kAudioDevicePermissionsError",
    ]

    /// Renders an OSStatus so the reader does not have to decode it by hand.
    static func describe(status: Int32) -> String {
        let raw = UInt32(bitPattern: status)
        let printable = raw >= 0x2020_2020 && raw <= 0x7E7E_7E7E
        let text = String(bytes: [UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF),
                                  UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)], encoding: .ascii)
        var result = "\(status)"
        if printable, let text { result += " ('\(text)')" }
        if let name = knownStatus[raw] { result += " \(name)" }
        return result
    }

    /// Enumerates every CoreAudio process object. Failures are logged, not thrown.
    static func processes() -> [AudioProcessInfo] {
        guard let getPropertyData else {
            statusDescription = "不可用（dlsym AudioObjectGetPropertyData 失败）"
            report("AudioObjectGetPropertyData 不可用：\(statusDescription)")
            return []
        }

        // The first call only reports the required size, so the data pointer stays nil.
        var size: UInt32 = 0
        var status = withAddress(propertyProcessObjectList) { address in
            getPropertyData(systemObject, address, 0, nil, &size, nil)
        }
        guard size > 0 else {
            statusDescription = "不可用（\(describe(status: status))）"
            report("音频进程列表不可用 (status=\(describe(status: status)), size=0)")
            return []
        }

        let count = Int(size) / MemoryLayout<UInt32>.size
        var identifiers = [UInt32](repeating: 0, count: count)
        status = withAddress(propertyProcessObjectList) { address in
            identifiers.withUnsafeMutableBytes { raw in
                getPropertyData(systemObject, address, 0, nil, &size, raw.baseAddress)
            }
        }
        guard status == 0 else {
            statusDescription = "读取失败（\(describe(status: status))）"
            report("读取音频进程列表失败 (status=\(describe(status: status)))")
            return []
        }

        let result = identifiers.compactMap { info(for: $0, using: getPropertyData) }
        statusDescription = "可用（\(result.count) 个进程）"
        return result
    }

    /// Warns the first time, then drops to debug: the ticker calls this repeatedly and
    /// a permanently unavailable API must not flood the log.
    private static func report(_ message: String) {
        if reportedFailure {
            trlog(.debug, "AUDIO", message)
        } else {
            reportedFailure = true
            trlog(.warn, "AUDIO", message)
        }
    }

    private static func withAddress<T>(_ selector: UInt32, _ body: (UnsafeRawPointer) -> T) -> T {
        var address: PropertyAddress = (selector, scopeGlobal, elementMain)
        return withUnsafePointer(to: &address) { body(UnsafeRawPointer($0)) }
    }

    private static func info(for object: UInt32,
                             using getPropertyData: AudioObjectGetPropertyDataFn) -> AudioProcessInfo? {
        let pid = uint32Property(object, propertyProcessPID, using: getPropertyData)
            .map { Int32(bitPattern: $0) } ?? -1
        guard pid > 0 else { return nil }
        return AudioProcessInfo(objectID: object,
                                pid: pid,
                                bundleIdentifier: stringProperty(object, propertyProcessBundleID,
                                                                using: getPropertyData),
                                isRunning: uint32Property(object, propertyProcessIsRunning,
                                                          using: getPropertyData) == 1,
                                isRunningInput: uint32Property(object, propertyProcessIsRunningInput,
                                                               using: getPropertyData) == 1,
                                isRunningOutput: uint32Property(object, propertyProcessIsRunningOutput,
                                                                using: getPropertyData) == 1)
    }

    private static func uint32Property(_ object: UInt32, _ selector: UInt32,
                                       using getPropertyData: AudioObjectGetPropertyDataFn) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = withAddress(selector) { address in
            getPropertyData(object, address, 0, nil, &size, &value)
        }
        return status == 0 ? value : nil
    }

    private static func stringProperty(_ object: UInt32, _ selector: UInt32,
                                       using getPropertyData: AudioObjectGetPropertyDataFn) -> String? {
        var pointer: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withAddress(selector) { address in
            withUnsafeMutablePointer(to: &pointer) { buffer in
                getPropertyData(object, address, 0, nil, &size, UnsafeMutableRawPointer(buffer))
            }
        }
        guard status == 0, let value = pointer?.takeRetainedValue() else { return nil }
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

    /// Processes currently capturing audio. Empty when the API is unavailable.
    static func inputProcesses() -> [AudioProcessInfo] {
        processes().filter { $0.isRunningInput }
    }

    static func process(matchingBundleIdentifier identifier: String) -> AudioProcessInfo? {
        let target = identifier.lowercased()
        return processes().first { ($0.bundleIdentifier ?? "").lowercased() == target }
    }
}
