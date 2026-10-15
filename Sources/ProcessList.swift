//
//  ProcessList.swift
//  MyCallRec — list local processes so a tap target can be chosen by pid.
//
//  Requires com.apple.private.security.no-sandbox (or at least the process-info
//  entitlements) to see other applications' paths; without it the list degrades
//  to processes the app is allowed to inspect.
//

import Foundation
import Darwin

// libproc's proc_pidpath is not exposed to Swift by the iOS SDK; bind it directly.
@_silgen_name("proc_pidpath")
private func tr_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32

struct ProcessEntry: Identifiable, Hashable {
    let pid: Int32
    let path: String
    let name: String
    var id: Int32 { pid }
}

enum ProcessList {
    static func running() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // The process table can grow between the size query and the fetch; retry a few times.
        for _ in 0..<4 {
            let capacity = size / MemoryLayout<kinfo_proc>.stride + 16
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var fetched = capacity * MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, 4, &buffer, &fetched, nil, 0) == 0 else { return [] }
            let count = fetched / MemoryLayout<kinfo_proc>.stride
            if count < capacity {
                return buffer.prefix(count).compactMap { entry(for: $0) }.sorted { $0.pid < $1.pid }
            }
            size = fetched
        }
        return []
    }

    private static func entry(for info: kinfo_proc) -> ProcessEntry? {
        let pid = info.kp_proc.p_pid
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { raw -> Int32 in
            tr_proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        let path = length > 0 ? String(cString: buffer) : ""
        let name = path.isEmpty ? "pid \(pid)" : (path as NSString).lastPathComponent
        return ProcessEntry(pid: pid, path: path, name: name)
    }

    /// Convenience lookup for the processes a call recorder usually needs to tap.
    static func interesting(from entries: [ProcessEntry]) -> [ProcessEntry] {
        let needles = ["mediaserverd", "callservicesd", "SpringBoard", "CommCenter", "audio", "WeChat", "call"]
        return entries.filter { entry in
            needles.contains { entry.name.lowercased().contains($0.lowercased()) }
        }
    }
}
