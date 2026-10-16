//
//  Log.swift
//  MyCallRec — structured, copyable logging.
//
//  Every line carries a level and a category so a device log alone is enough to
//  diagnose a run. Lines are kept in memory for the UI and appended to
//  Documents/logs/MyCallRec.log, which is reachable through the Files app
//  (UIFileSharingEnabled) and can be copied or shared from the app.
//

import Foundation

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"

    var isVisibleByDefault: Bool { self != .debug }
}

final class Log {
    static let shared = Log()

    /// Called on the main queue for every appended line.
    var onAppend: ((String) -> Void)?

    /// Lines kept in memory for the UI and for copy/share.
    private(set) var lines: [String] = []

    private let memoryLimit = 800
    private let fileSizeLimit = 2 * 1024 * 1024
    private let queue = DispatchQueue(label: "com.example.mycallrec.log")
    private var handle: FileHandle?
    private var fileURL: URL?
    private var sessionStart = Date()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private init() {}

    /// File path of the run log, for the share sheet.
    var logFileURL: URL? {
        logDirectory?.appendingPathComponent("MyCallRec.log")
    }

    /// Items for the share sheet: the log file when it exists, otherwise the transcript
    /// already in memory. The file is preferred because it also holds the lines written
    /// before a crash.
    func shareableFiles() -> [Any] {
        if let logFileURL, FileManager.default.fileExists(atPath: logFileURL.path) {
            return [logFileURL]
        }
        return [transcript()]
    }

    /// Directory holding the run log, resolved to a path the process can really write.
    var logDirectory: URL? { Storage.logsDirectory }

    /// Why the log file could not be opened, for the startup log. A swallowed error here
    /// is what hid the fact that nothing was ever written to disk.
    private(set) var openError: String?
    private var lastOpenAttempt: Date?

    func start() {
        // Resolve storage first: the container's Documents directory may be unusable.
        Storage.resolve()
        queue.sync { self.openFile() }
    }

    private func openFile() {
        // Retry, but not on every single line when the failure is permanent.
        if let lastOpenAttempt, handle == nil, Date().timeIntervalSince(lastOpenAttempt) < 3 { return }
        lastOpenAttempt = Date()

        let directory = Storage.logsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            let error = error as NSError
            openError = "建日志目录失败：\(error.domain) \(error.code) \(error.localizedDescription)"
        }

        let url = directory.appendingPathComponent("MyCallRec.log")
        fileURL = url
        do {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? Int, size > fileSizeLimit {
                let rotated = directory.appendingPathComponent("MyCallRec.1.log")
                try? FileManager.default.removeItem(at: rotated)
                try? FileManager.default.moveItem(at: url, to: rotated)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let opened = try FileHandle(forWritingTo: url)
            try opened.seekToEndOfFile()
            handle = opened
            openError = nil
        } catch {
            let error = error as NSError
            openError = "打开日志文件失败：\(error.domain) \(error.code) \(error.localizedDescription)（\(url.path)）"
            handle = nil
        }
    }

    /// Writes the file line before returning.
    ///
    /// A trigger that crashes the process must still leave its own line on disk, so
    /// the write cannot be deferred to another queue: if the process dies before the
    /// block runs, the evidence is gone. Only DEBUG lines stay asynchronous, since
    /// they are the high-frequency ones and never the last line before a crash.
    func write(_ level: LogLevel, _ category: String, _ message: String) {
        let memoryLine = "[\(Self.formatter.string(from: Date()))] [\(level.rawValue)] [\(category)] \(message)"
        let fileLine = "[\(Self.fileFormatter.string(from: Date()))] [\(level.rawValue)] [\(category)] \(message)\n"

        let flush: () -> Void = {
            if self.handle == nil { self.openFile() }
            self.handle?.write(Data(fileLine.utf8))
        }

        if level == .debug {
            queue.async(execute: flush)
        } else {
            queue.sync(execute: flush)
        }

        let appendMemory = {
            self.lines.insert(memoryLine, at: 0)
            if self.lines.count > self.memoryLimit {
                self.lines.removeLast(self.lines.count - self.memoryLimit)
            }
            self.onAppend?(memoryLine)
        }
        if Thread.isMainThread {
            appendMemory()
        } else {
            DispatchQueue.main.async(execute: appendMemory)
        }
    }

    /// Complete in-memory transcript, oldest first, for the clipboard or a share sheet.
    func transcript(includeHeader: Bool = true) -> String {
        let body = lines.reversed().joined(separator: "\n")
        guard includeHeader else { return body }
        let header = """
        MyCallRec 日志
        导出时间: \(Self.fileFormatter.string(from: Date()))
        本次启动: \(Self.fileFormatter.string(from: sessionStart))
        行数: \(lines.count)
        ----------------------------------------
        """
        return header + "\n" + body
    }

    func markSessionStart() {
        sessionStart = Date()
        lines.removeAll()
    }
}

func trlog(_ level: LogLevel, _ category: String, _ message: String) {
    Log.shared.write(level, category, message)
}
