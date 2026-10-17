//
//  AppProcessFinder.swift
//  MyCallRec — resolve a bundle identifier to a running pid.
//
//  The CoreAudio process list is unavailable on this build (see AudioUseWatcher), so
//  the pid of the application to tap is found from the process table instead: the
//  executable path of a running iOS app is
//      /private/var/containers/Bundle/Application/<uuid>/<Name>.app/<Name>
//  so the bundle directory is the parent of the executable, and its Info.plist holds
//  the bundle identifier. Reading it needs the no-sandbox entitlement, which this
//  build carries; when the read fails a small alias table for the common VoIP apps
//  is used instead, and either outcome is logged once.
//

import Foundation
import Darwin

enum AppProcessFinder {
    /// Fallback when the bundle's Info.plist cannot be read.
    private static let executableAliases: [String: [String]] = [
        "com.tencent.xin": ["WeChat"],
        "net.whatsapp.whatsapp": ["WhatsApp"],
        "net.whatsapp.whatsappsmb": ["WhatsApp"],
        "org.whispersystems.signal": ["Signal"],
        "com.toyopagroup.picaboo": ["Snapchat"],
        "com.google.gvdialer": ["GoogleVoice"],
        "com.atebits.tweetie2": ["Twitter"],
        "com.zenmen.palmchat": ["Aloha"],
        "im.thebot": ["BotIM"],
        "com.huawei.works": ["W3"],
    ]

    private static let lock = NSLock()
    private static var cache: [String: Int32] = [:]
    private static var plistReadFailed = false

    /// True while the pid still names a live process.
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // Signal 0 performs the permission and existence checks without delivering.
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func pid(forBundleIdentifier identifier: String) -> Int32? {
        let key = identifier.lowercased()

        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached {
            if isAlive(cached) { return cached }
            lock.lock(); cache.removeValue(forKey: key); lock.unlock()
        }

        // One process-table scan per lookup, from the shared snapshot; a miss rescans once
        // in case the app started after the snapshot was taken.
        var candidates = runningAppProcesses()
        if let match = matchBundle(key, in: candidates) {
            lock.lock(); cache[key] = match.pid; lock.unlock()
            trlog(.info, "APP", "\(identifier) -> pid \(match.pid)（\(match.path)）")
            return match.pid
        }
        candidates = runningAppProcesses(fresh: true)
        if let match = matchBundle(key, in: candidates) {
            lock.lock(); cache[key] = match.pid; lock.unlock()
            trlog(.info, "APP", "\(identifier) -> pid \(match.pid)（\(match.path)）")
            return match.pid
        }

        // Fallback: match the executable name against the alias table.
        let aliases = executableAliases[key] ?? []
        for entry in candidates {
            let executable = (entry.path as NSString).lastPathComponent.lowercased()
            guard aliases.contains(where: { $0.lowercased() == executable }) else { continue }
            lock.lock(); cache[key] = entry.pid; lock.unlock()
            trlog(.warn, "APP", "\(identifier) -> pid \(entry.pid)（按可执行名 \(entry.name) 匹配，未读到 Info.plist）")
            return entry.pid
        }

        trlog(.warn, "APP", "未找到 \(identifier) 的运行进程（未读过 Info.plist=\(plistReadFailed)，候选 \(candidates.count) 个）")
        return nil
    }

    private static func matchBundle(_ key: String, in candidates: [ProcessEntry]) -> ProcessEntry? {
        for entry in candidates {
            guard let bundleIdentifier = bundleIdentifier(forExecutable: entry.path),
                  bundleIdentifier.lowercased() == key else { continue }
            return entry
        }
        return nil
    }

    /// Every process whose executable lives inside an application bundle. Uses the shared
    /// short-lived snapshot so a lookup does not rescan the whole process table every time.
    static func runningAppProcesses(fresh: Bool = false) -> [ProcessEntry] {
        ProcessList.snapshot(maxAge: fresh ? 0 : 10)
            .filter { $0.path.contains("/Bundle/Application/") && $0.path.contains(".app/") }
    }

    /// Same helper exposed for the diagnostics snapshot.
    static func appProcessSummary() -> String {
        let entries = runningAppProcesses()
        guard !entries.isEmpty else { return "（无 App 进程）" }
        return entries
            .map { entry in
                let identifier = bundleIdentifier(forExecutable: entry.path) ?? "?"
                return "\(entry.pid):\(entry.name)[\(identifier)]"
            }
            .joined(separator: " ")
    }

    private static func bundleIdentifier(forExecutable path: String) -> String? {
        // <bundle>/<Name>.app/<Name> — walk up to the .app directory.
        let bundleDirectory = (path as NSString).deletingLastPathComponent
        guard bundleDirectory.hasSuffix(".app") else { return nil }

        let plistPath = (bundleDirectory as NSString).appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath) else {
            lock.lock()
            let first = !plistReadFailed
            plistReadFailed = true
            lock.unlock()
            if first {
                trlog(.warn, "APP", "读不到其他 App 的 Info.plist（\(plistPath)）：改用可执行名匹配")
            }
            return nil
        }
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary["CFBundleIdentifier"] as? String
    }
}
