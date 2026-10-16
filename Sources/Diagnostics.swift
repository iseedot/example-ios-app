//
//  Diagnostics.swift
//  MyCallRec — one-button collection of everything needed to debug a run.
//
//  The snapshot answers, without a debugger:
//    * which entitlements TrollStore actually granted this app;
//    * whether the private tap classes exist and which initialisers they expose;
//    * whether a system-audio tap delivers data, and its peak level;
//    * which processes own audio at that moment (the PID to tap);
//    * the audio session and CoreTelephony state.
//

import Foundation
import AVFAudio
import UIKit
import Darwin
import ObjectiveC

private typealias SecTaskCreateFromSelfFn = @convention(c) (CFAllocator?) -> CFTypeRef?
private typealias SecTaskCopyValueForEntitlementFn = @convention(c) (CFTypeRef?, CFString,
                                                                    UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFTypeRef?

enum Diagnostics {
    /// Entitlements this app expects; missing ones explain most failures.
    static let expectedEntitlements = [
        "platform-application",
        "com.apple.private.security.no-sandbox",
        "application-identifier",
        "com.apple.coreaudio.CanTapTelephony",
        "com.apple.coreaudio.app-tap",
        "com.apple.coreaudio.private.SystemWideTap",
        "com.apple.coreaudio.CanRecordWithoutSessionActivation",
        "com.apple.private.coreaudio.mxsessionPropertyPipe",
        "com.apple.private.mediaexperience.startrecordinginthebackground.allow",
        "inter-app-audio",
        "com.apple.CommCenter.fine-grained",
        "com.apple.telephonyutilities.callservicesd",
        "com.apple.private.tcc.allow",
        "com.apple.security.exception.files.absolute-path.read-write",
        "com.apple.private.hid.client.event-monitor",
        "com.apple.private.hid.client.event-dispatch",
        "com.apple.private.hid.client.event-filter",
        "com.apple.private.hid.manager.client",
    ]

    private static let secTaskCreate: SecTaskCreateFromSelfFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecTaskCreateFromSelf") else { return nil }
        return unsafeBitCast(symbol, to: SecTaskCreateFromSelfFn.self)
    }()

    private static let secTaskCopyValue: SecTaskCopyValueForEntitlementFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "SecTaskCopyValueForEntitlement") else { return nil }
        return unsafeBitCast(symbol, to: SecTaskCopyValueForEntitlementFn.self)
    }()

    /// Reads the app's own entitlements. Absent keys are as informative as present ones.
    static func entitlementReport() -> [String: String] {
        var report: [String: String] = [:]
        guard let create = secTaskCreate, let copy = secTaskCopyValue else {
            report["_error"] = "SecTask API 不可用"
            return report
        }
        guard let task = create(kCFAllocatorDefault) else {
            report["_error"] = "SecTaskCreateFromSelf 失败"
            return report
        }
        for key in expectedEntitlements {
            var error: Unmanaged<CFError>?
            let value = copy(task, key as CFString, &error)
            if let value {
                report[key] = String(describing: value)
            } else {
                report[key] = "缺失"
            }
        }
        return report
    }

    static func tapCapability() -> [String: String] {
        var report: [String: String] = [:]
        guard let descriptionClass = NSClassFromString("ATAudioTapDescription") else {
            report["ATAudioTapDescription"] = "不存在"
            return report
        }
        report["ATAudioTapDescription"] = "存在"
        report["ATAudioTap"] = NSClassFromString("ATAudioTap") == nil ? "不存在" : "存在"
        report["initTapInternalWithFormat:PIDs:"] =
            class_respondsToSelector(descriptionClass,
                                     NSSelectorFromString("initTapInternalWithFormat:PIDs:")) ? "有" : "无"
        report["initProcessTapInternalWithFormat:PID:"] =
            class_respondsToSelector(descriptionClass,
                                     NSSelectorFromString("initProcessTapInternalWithFormat:PID:")) ? "有" : "无"
        return report
    }

    /// Records the system-audio tap for a few seconds and reports what arrived.
    /// Returns a description; never throws.
    static func tapSelfTest(seconds: Double = 3) -> [String: String] {
        var report: [String: String] = [:]
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            report["error"] = "无法访问沙盒目录"
            return report
        }
        let directory = documents.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("selftest.caf")
        try? FileManager.default.removeItem(at: url)

        var recorder: TapRecorder?
        var failure: String?
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.signal() }
            do {
                let created = try TapRecorder(target: .systemAudio, sampleRate: 44100, channels: 2, fileURL: url)
                try created.start()
                recorder = created
                Thread.sleep(forTimeInterval: seconds)
                created.stop()
            } catch {
                failure = String(describing: error)
            }
        }

        if finished.wait(timeout: .now() + seconds + 6) == .timedOut {
            report["result"] = "超时"
        }
        if let failure {
            report["result"] = "失败：\(failure)"
            return report
        }
        guard let recorder else {
            report["result"] = "未创建录音器"
            return report
        }
        report["result"] = "完成"
        report["packets"] = "\(recorder.packetsWritten)"
        report["seconds"] = String(format: "%.2f", recorder.secondsRecorded)
        report["firstBufferReceived"] = recorder.receivedFirstBuffer ? "是" : "否"
        report["peak"] = String(format: "%.4f", recorder.maxPeakAmplitude)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        report["fileSize"] = "\(size)"
        return report
    }

    /// Full snapshot as pretty JSON plus a pasteboard-friendly rendering.
    static func collect(includeTapSelfTest: Bool) -> (json: String, text: String) {
        var payload: [String: Any] = [:]

        let device = UIDevice.current
        payload["app"] = [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "?",
        ]
        payload["device"] = [
            "model": device.model,
            "systemName": device.systemName,
            "systemVersion": device.systemVersion,
            "name": device.name,
        ]

        let session = AVAudioSession.sharedInstance()
        payload["audioSession"] = [
            "category": session.category.rawValue,
            "mode": session.mode.rawValue,
            "outputVolume": String(format: "%.2f", session.outputVolume),
            "isOtherAudioPlaying": "\(session.isOtherAudioPlaying)",
            "secondaryAudioShouldBeSilencedHint": "\(session.secondaryAudioShouldBeSilencedHint)",
        ]

        payload["entitlements"] = entitlementReport()
        payload["tapCapability"] = tapCapability()
        payload["keyEvents"] = [
            "hidSupported": "\(HIDKeyMonitor.isSupported)",
            "entitlement": "com.apple.private.hid.client.event-monitor",
        ]

        let probe = CallWatcher.probe()
        payload["coreTelephony"] = ["available": "\(probe.available)", "detail": probe.detail]

        let processes = AudioProcessProbe.processes()
        payload["audioProcessCount"] = processes.count
        payload["audioProcesses"] = processes.map { info -> [String: String] in
            ["pid": "\(info.pid)",
             "bundleIdentifier": info.bundleIdentifier ?? "?",
             "running": "\(info.isRunning)",
             "runningInput": "\(info.isRunningInput)",
             "runningOutput": "\(info.isRunningOutput)"]
        }
        if processes.isEmpty {
            let entries = ProcessList.interesting(from: ProcessList.running())
            payload["sysctlFallback"] = entries.map { "\($0.pid):\($0.name)" }
        }

        if includeTapSelfTest {
            payload["tapSelfTest"] = tapSelfTest()
        }

        let json = (try? JSONSerialization.data(withJSONObject: payload,
                                                options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        var lines: [String] = ["===== MyCallRec 诊断快照 ====="]
        func section(_ title: String) {
            lines.append("")
            lines.append("--- \(title) ---")
        }
        section("设备")
        for (key, value) in (payload["device"] as? [String: String]) ?? [:] { lines.append("\(key): \(value)") }
        section("音频会话")
        for (key, value) in (payload["audioSession"] as? [String: String]) ?? [:] { lines.append("\(key): \(value)") }
        section("entitlements（TrollStore 实际授予）")
        for key in expectedEntitlements {
            let value = (payload["entitlements"] as? [String: String])?[key] ?? "未知"
            lines.append("\(key) = \(value)")
        }
        section("私有 tap")
        for (key, value) in (payload["tapCapability"] as? [String: String]) ?? [:] { lines.append("\(key): \(value)") }
        section("按键事件源")
        lines.append("IOHID 可用: \(HIDKeyMonitor.isSupported)（真实按键事件优先，音量采样作后备）")
        section("CoreTelephony")
        lines.append("available: \(probe.available)")
        lines.append("detail: \(probe.detail)")
        section("音频进程（\(processes.count)）")
        lines.append(AudioProcessProbe.describe(processes))
        if includeTapSelfTest {
            section("tap 自检（系统音频 3 秒）")
            for (key, value) in (payload["tapSelfTest"] as? [String: String]) ?? [:] { lines.append("\(key): \(value)") }
        }

        let text = lines.joined(separator: "\n")
        let directory = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ??
                         URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("diagnostics-\(formatter.string(from: Date())).json")
        try? json.write(to: url, atomically: true, encoding: .utf8)

        // The full text plus the log tail is what the user pastes back.
        let combined = text + "\n\n===== 运行日志 =====\n" + Log.shared.transcript(includeHeader: false)
        return (json, combined)
    }
}
