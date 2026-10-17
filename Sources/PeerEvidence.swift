//
//  PeerEvidence.swift
//  MyCallRec — read what the installed TrollRecorder left on disk.
//
//  Our own probe can only measure what *we* manage to capture. TrollRecorder records this
//  device's calls successfully, and it writes a manifest next to every recording that
//  carries the tap target and the client PIDs it used — the one fact the Ghidra work could
//  not recover (the pseudo-code is obfuscated, see target/decompiled/REA-FINDINGS).
//
//  So the report attaches: its preference file, the file listing of its recording
//  directories, and the head of its newest manifests and logs. Everything is read-only,
//  bounded (depth, count, bytes, 2 s deadline) and redacted like the rest of the log.
//

import Foundation

enum PeerEvidence {
    /// Rootful and rootless locations of the analysed app's preferences.
    private static let preferencePaths = [
        "/var/mobile/Library/Preferences/wiki.qaq.trapp.plist",
        "/var/preferences/wiki.qaq.trapp.plist",
        "/var/jb/var/mobile/Library/Preferences/wiki.qaq.trapp.plist",
    ]

    /// Directories the analysed app is known to use (its entitlements name
    /// /Media/DCIM/TrollRecorder/), plus anything the preferences point at.
    private static let directoryCandidates = [
        "/var/mobile/Media/TrollRecorder",
        "/var/mobile/Media/DCIM/TrollRecorder",
        "/var/mobile/Documents/TrollRecorder",
    ]

    private static let processNeedles = ["TrollRecorder", "TRCallMonitor", "TRCallRecorder",
                                         "TRAudioRecorder", "TRRealtimeRecorder", "TRHud", "TRApp"]

    private static let textExtensions: Set<String> = ["json", "plist", "txt", "log", "md", "xml"]

    private static let maximumFiles = 60
    private static let maximumDumps = 3
    private static let maximumDumpBytes = 4096
    private static let deadlineSeconds: TimeInterval = 2.0

    static func collect() -> String {
        var lines: [String] = ["===== 对照：TrollRecorder 留下的证据 ====="]
        let deadline = Date().addingTimeInterval(deadlineSeconds)

        lines.append("")
        lines.append("--- 正在运行的进程 ---")
        let processes = ProcessList.running().filter { entry in
            processNeedles.contains { entry.name.contains($0) }
        }
        if processes.isEmpty {
            lines.append("  （未发现 TrollRecorder 相关进程）")
        } else {
            for entry in processes { lines.append("  \(entry.pid) \(entry.name) \(entry.path)") }
        }

        lines.append("")
        lines.append("--- 偏好设置 ---")
        // Paths found in the preferences are appended to the known candidates.
        var hintedPaths: [String] = []
        for path in preferencePaths {
            guard let data = FileManager.default.contents(atPath: path) else {
                lines.append("  \(path)：读不到")
                continue
            }
            lines.append("  \(path)：\(data.count) 字节")
            guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dictionary = object as? [String: Any] else {
                lines.append("    （不是可解析的 plist）")
                continue
            }
            for key in dictionary.keys.sorted().prefix(60) {
                let value = dictionary[key] ?? ""
                lines.append("    \(key) = \(describe(value))")
            }
            // A path-valued preference is where the recordings actually live.
            for value in dictionary.values {
                guard let text = value as? String, text.hasPrefix("/"),
                      text.contains("Troll") || text.contains("Record") else { continue }
                hintedPaths.append(text)
            }
        }

        lines.append("")
        lines.append("--- 录音目录 ---")
        var directories = directoryCandidates
        for path in hintedPaths where !directories.contains(path) { directories.append(path) }
        var found: [(path: String, modified: Date, size: Int)] = []
        for directory in directories {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                lines.append("  \(directory)：不存在")
                continue
            }
            walk(directory, depth: 0, deadline: deadline, into: &found)
        }
        found.sort { $0.modified > $1.modified }
        if found.isEmpty {
            lines.append("  （没有可读文件）")
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            for entry in found.prefix(maximumFiles) {
                lines.append("  \(formatter.string(from: entry.modified)) \(entry.size) 字节  \(entry.path)")
            }
            if found.count > maximumFiles { lines.append("  …共 \(found.count) 个文件") }
        }

        lines.append("")
        lines.append("--- 最新清单/日志内容（前 \(maximumDumpBytes) 字节，已脱敏） ---")
        let dumps = found.filter { textExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
        if dumps.isEmpty {
            lines.append("  （没有可读的清单或日志文件）")
        }
        for entry in dumps.prefix(maximumDumps) {
            lines.append("  ▸ \(entry.path)")
            lines.append("    \(dump(entry.path))")
        }

        let text = lines.joined(separator: "\n")
        return Privacy.redact(text)
    }

    private static func walk(_ directory: String, depth: Int, deadline: Date,
                             into found: inout [(path: String, modified: Date, size: Int)]) {
        guard depth <= 2, Date() < deadline, found.count < maximumFiles * 2 else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        let contents = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory),
                                                                    includingPropertiesForKeys: keys,
                                                                    options: [.skipsHiddenFiles])) ?? []
        for url in contents {
            guard Date() < deadline else { return }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                walk(url.path, depth: depth + 1, deadline: deadline, into: &found)
                continue
            }
            // Only recent files matter: the test call was made minutes ago.
            let modified = values?.contentModificationDate ?? .distantPast
            guard Date().timeIntervalSince(modified) < 3 * 24 * 3600 else { continue }
            found.append((path: url.path, modified: modified, size: values?.fileSize ?? 0))
        }
    }

    private static func dump(_ path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "（打不开）" }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maximumDumpBytes)
        guard !data.isEmpty else { return "（空文件）" }

        // A manifest or preference file is far more useful parsed than as raw bytes.
        let extensionName = (path as NSString).pathExtension.lowercased()
        if extensionName == "plist" || extensionName == "json" {
            if let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                return bounded(describe(object))
            }
            if let object = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: pretty, encoding: .utf8) {
                return bounded(text)
            }
        }
        return bounded(String(data: data, encoding: .utf8) ?? "（非文本内容 \(data.count) 字节）")
    }

    private static func bounded(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 1800 ? String(trimmed.prefix(1800)) + "…" : trimmed
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case let array as [Any]: return "[" + array.map { describe($0) }.joined(separator: ", ") + "]"
        case let dictionary as [String: Any]:
            return "{" + dictionary.keys.sorted().map { "\($0): \(describe(dictionary[$0] ?? ""))" }.joined(separator: ", ") + "}"
        default: return String(describing: value)
        }
    }
}
