//
//  CrashGuard.swift
//  MyCallRec — capture why the process died, so a crash is diagnosable from the log
//  alone.
//
//  The private tap API can raise an Objective-C exception rather than return an error,
//  and that terminates the process with no message. Two handlers are installed:
//
//    * NSSetUncaughtExceptionHandler — runs in normal context, so it records the
//      exception name, reason and call stack in full. This is the handler that matters
//      for a private API that raises.
//    * POSIX signal handlers — a fault inside AudioToolbox or a Swift runtime failure
//      arrives as a signal. The handler only calls write(2) on a buffer prepared at
//      install time: string interpolation, Swift allocation and locks are not
//      async-signal-safe and would turn a fault into a hang.
//
//  Both append to Documents/logs/crash.log. The next launch drains that file into the
//  run log, so `复制全部日志` carries the previous crash without needing the Files app.
//

import Foundation
import Darwin

enum CrashGuard {
    private static let fileName = "crash.log"

    /// Kept open so a signal handler can append with write(2) alone.
    private static var descriptor: Int32 = -1

    /// Prepared once at install time; the signal handler must not build anything.
    private static let banner = Array(
        "[MyCallRec] 致命信号：进程即将终止。上一次运行的日志尾部即为崩溃位置。\n".utf8)

    static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func install() {
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        guard let url = fileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)

        // Force the banner to exist before any handler can run.
        _ = banner.count

        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            append("""
            [\(timestamp())] 未捕获的 Objective-C 异常
              name: \(exception.name.rawValue)
              reason: \(exception.reason ?? "（无 reason）")
              stack:
            \(stack)
            """)
            // Let the process abort as it normally would, now that the evidence is on disk.
        }

        for number in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(number) { received in
                // Async-signal-safe section: write(2) on a prepared buffer, nothing else.
                banner.withUnsafeBufferPointer { buffer in
                    if descriptor >= 0, let base = buffer.baseAddress {
                        _ = write(descriptor, base, buffer.count)
                    }
                }
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    /// Returns the previous crash text and clears the file, so it is reported once.
    static func consumePreviousCrash() -> String? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        install()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func append(_ text: String) {
        guard descriptor >= 0 else { return }
        let line = text.hasSuffix("\n") ? text : text + "\n"
        _ = line.withCString { write(descriptor, $0, strlen($0)) }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
