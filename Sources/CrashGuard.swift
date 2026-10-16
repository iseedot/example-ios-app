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
//  The two handlers are file-scope functions rather than closures: a closure that
//  references any enclosing declaration cannot be converted to a C function pointer,
//  and both of these are C function pointers.
//

import Foundation
import Darwin

/// Open descriptor, kept so a signal handler can append with write(2) alone.
private var trCrashDescriptor: Int32 = -1

/// Prepared at install time; the signal handler must not build anything.
private let trCrashBanner = Array(
    "[MyCallRec] 致命信号：进程即将终止。上一次运行的日志尾部即为崩溃位置。\n".utf8)

private func trCrashFileURL() -> URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("logs", isDirectory: true)
        .appendingPathComponent("crash.log")
}

private func trCrashAppend(_ text: String) {
    guard trCrashDescriptor >= 0 else { return }
    let line = text.hasSuffix("\n") ? text : text + "\n"
    _ = line.withCString { write(trCrashDescriptor, $0, strlen($0)) }
}

private func trCrashTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

/// Runs in normal context, so using Foundation here is safe.
private func trCrashHandleException(_ exception: NSException) {
    let stack = exception.callStackSymbols.joined(separator: "\n")
    trCrashAppend("""
    [\(trCrashTimestamp())] 未捕获的 Objective-C 异常
      name: \(exception.name.rawValue)
      reason: \(exception.reason ?? "（无 reason）")
      stack:
    \(stack)
    """)
    // The process aborts as it normally would, now that the evidence is on disk.
}

/// Async-signal-safe section: write(2) on a prepared buffer, nothing else.
private func trCrashHandleSignal(_ received: Int32) {
    trCrashBanner.withUnsafeBufferPointer { buffer in
        if trCrashDescriptor >= 0, let base = buffer.baseAddress {
            _ = write(trCrashDescriptor, base, buffer.count)
        }
    }
    signal(received, SIG_DFL)
    raise(received)
}

enum CrashGuard {
    static var fileURL: URL? { trCrashFileURL() }

    static func install() {
        if trCrashDescriptor >= 0 {
            close(trCrashDescriptor)
            trCrashDescriptor = -1
        }
        guard let url = trCrashFileURL() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        trCrashDescriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)

        // Force the banner to exist before any handler can run.
        _ = trCrashBanner.count

        NSSetUncaughtExceptionHandler(trCrashHandleException)

        for number in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(number, trCrashHandleSignal)
        }
    }

    /// Returns the previous crash text and clears the file, so it is reported once.
    static func consumePreviousCrash() -> String? {
        guard let url = trCrashFileURL(),
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        install()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
