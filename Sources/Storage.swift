//
//  Storage.swift
//  MyCallRec — pick a directory the process can actually write to.
//
//  The app carries com.apple.private.security.no-sandbox, platform-application and a
//  files.absolute-path.read-write exception for "/", but its own container's Documents
//  directory still turned out to be unusable: createDirectory failed, fileExists
//  answered false, AudioFileCreateWithURL answered kAudioFileUnspecifiedError ('wht?')
//  and the run log was never written at all.
//
//  So every candidate directory is probed for real, by creating it and writing a file,
//  and the failure reason is kept for the log. Nothing here uses try?, because a
//  swallowed error is exactly what made this hard to find.
//

import Foundation

enum Storage {
    struct Candidate {
        let label: String
        let url: URL
    }

    /// One line per candidate, in probe order, for the run log.
    private(set) static var resolutionLog: [String] = []
    private(set) static var rootLabel = "尚未解析"
    private static var root: URL?
    private static var didResolve = false

    private static var fallback: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MyCallRec", isDirectory: true)
    }

    static var baseDirectory: URL { root ?? fallback }
    static var recordingsDirectory: URL { baseDirectory.appendingPathComponent("Recordings", isDirectory: true) }
    static var logsDirectory: URL { baseDirectory.appendingPathComponent("logs", isDirectory: true) }

    static func resolve() {
        guard !didResolve else { return }
        didResolve = true

        resolutionLog.append("NSHomeDirectory = \(NSHomeDirectory())")
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            resolutionLog.append("Documents URL  = \(documents.path)")
            if let attributes = try? FileManager.default.attributesOfItem(atPath: documents.path) {
                let owner = (attributes[.ownerAccountName] as? String) ?? "?"
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                resolutionLog.append("  Documents 属性：owner=\(owner) mode=\(String(permissions, radix: 8))")
            } else {
                resolutionLog.append("  Documents 属性：读不到（目录可能不存在）")
            }
        } else {
            resolutionLog.append("Documents URL  = 无法解析")
        }

        for candidate in candidates() {
            let outcome = probe(candidate.url)
            resolutionLog.append("\(candidate.label) -> \(outcome)")
            if root == nil, outcome.hasPrefix("可写") {
                root = candidate.url
                rootLabel = candidate.label
            }
        }

        if root == nil {
            rootLabel = "全部不可写，回退到临时目录"
            resolutionLog.append("没有可写候选，回退到 \(fallback.path)")
        } else {
            resolutionLog.append("选中：\(rootLabel) = \(baseDirectory.path)")
        }
    }

    private static func candidates() -> [Candidate] {
        var list: [Candidate] = []
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            list.append(Candidate(label: "容器 Documents", url: documents.appendingPathComponent("MyCallRec", isDirectory: true)))
        }
        // The analysed target writes recordings here, so this path is known to work with
        // this entitlement set on a TrollStore install.
        list.append(Candidate(label: "媒体目录 /var/mobile/Media",
                              url: URL(fileURLWithPath: "/var/mobile/Media/MyCallRec", isDirectory: true)))
        list.append(Candidate(label: "缓存目录 /var/mobile/Library/Caches",
                              url: URL(fileURLWithPath: "/var/mobile/Library/Caches/MyCallRec", isDirectory: true)))
        list.append(Candidate(label: "临时目录", url: fallback))
        return list
    }

    /// Creates the directory and writes a real file; returns the outcome as text.
    private static func probe(_ url: URL) -> String {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            let error = error as NSError
            return "不可写（建目录失败：\(error.domain) \(error.code) \(error.localizedDescription)）"
        }

        let probeFile = url.appendingPathComponent(".mycallrec-write-probe")
        do {
            try Data("probe".utf8).write(to: probeFile)
            try? FileManager.default.removeItem(at: probeFile)
            return "可写"
        } catch {
            let error = error as NSError
            return "不可写（写文件失败：\(error.domain) \(error.code) \(error.localizedDescription)）"
        }
    }
}
