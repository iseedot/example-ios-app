//
//  AudioProcessProbe.swift
//  MyCallRec — enumerate CoreAudio process objects to learn which process owns audio.
//
//  The iOS SDK does not expose the HAL process-object API, so everything here is
//  resolved at runtime: the entry point through dlsym and the property selectors as
//  four-character codes. Nothing depends on SDK declarations, and every failure is
//  logged so the caller can fall back to a sysctl process listing.
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

    private static let getPropertyData: AudioObjectGetPropertyDataFn? = {
        // Load explicitly so the symbol is reachable even if nothing else pulled it in.
        dlopen(frameworkPath, RTLD_NOW)
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AudioObjectGetPropertyData") else {
            trlog(.warn, "AUDIO", "未找到 AudioObjectGetPropertyData 符号")
            return nil
        }
        return unsafeBitCast(symbol, to: AudioObjectGetPropertyDataFn.self)
    }()

    private static let fourCC: (String) -> UInt32 = { code in
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

    /// Enumerates every CoreAudio process object. Failures are logged, not thrown.
    static func processes() -> [AudioProcessInfo] {
        guard let getPropertyData else { return [] }

        // The first call only reports the required size, so the data pointer stays nil.
        var size: UInt32 = 0
        var status = withAddress(propertyProcessObjectList) { address in
            getPropertyData(systemObject, address, 0, nil, &size, nil)
        }
        guard size > 0 else {
            trlog(.warn, "AUDIO", "音频进程列表为空 (status=\(status), size=\(size))")
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
            trlog(.warn, "AUDIO", "读取音频进程列表失败 (status=\(status))")
            return []
        }

        return identifiers.compactMap { info(for: $0, using: getPropertyData) }
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

    /// Processes currently capturing audio. This is the set a call recorder taps.
    static func inputProcesses() -> [AudioProcessInfo] {
        processes().filter { $0.isRunningInput }
    }

    static func process(matchingBundleIdentifier identifier: String) -> AudioProcessInfo? {
        let target = identifier.lowercased()
        return processes().first { ($0.bundleIdentifier ?? "").lowercased() == target }
    }
}
