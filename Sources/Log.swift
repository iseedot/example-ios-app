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

    var logDirectory: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent("logs", isDirectory: true)
    }

    func start() {
        queue.async { self.openFile() }
    }

    private func openFile() {
        guard let directory = logDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("MyCallRec.log")

        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int, size > fileSizeLimit {
            let rotated = directory.appendingPathComponent("MyCallRec.1.log")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        fileURL = url
    }

    func write(_ level: LogLevel, _ category: String, _ message: String) {
        let memoryLine = "[\(Self.formatter.string(from: Date()))] [\(level.rawValue)] [\(category)] \(message)"
        let fileLine = "[\(Self.fileFormatter.string(from: Date()))] [\(level.rawValue)] [\(category)] \(message)\n"

        queue.async {
            if self.handle == nil { self.openFile() }
            self.handle?.write(Data(fileLine.utf8))

            DispatchQueue.main.async {
                self.lines.insert(memoryLine, at: 0)
                if self.lines.count > self.memoryLimit {
                    self.lines.removeLast(self.lines.count - self.memoryLimit)
                }
                self.onAppend?(memoryLine)
            }
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
