//
//  RecordingLibrary.swift
//  MyCallRec — recording files on disk and playback.
//

import Foundation
import AVFoundation

struct Recording: Identifiable, Hashable {
    let url: URL
    let name: String
    let size: Int
    let modified: Date
    var id: URL { url }
}

@MainActor
final class RecordingLibrary: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    let directory: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = documents.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? []

        recordings = contents.compactMap { url in
            guard url.pathExtension.lowercased() == "caf" || url.pathExtension.lowercased() == "m4a" else {
                return nil
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Recording(url: url,
                             name: url.lastPathComponent,
                             size: values?.fileSize ?? 0,
                             modified: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.modified > $1.modified }
    }

    func newRecordingURL(prefix: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: Date())
        return directory.appendingPathComponent("\(prefix)-\(stamp).caf")
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.url)
        refresh()
    }

    static func duration(of url: URL) -> Double {
        (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
    }
}
