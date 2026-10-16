//
//  RecordingLibrary.swift
//  MyCallRec — recording files on disk and playback.
//

import Foundation
import AVFoundation

/// What produced a recording. The analysed target keeps a manifest per file; this is
/// the small version, written next to the audio as "<file>.json".
struct RecordingMeta: Codable, Hashable {
    let trigger: String
    let target: String
    let call: CallInfo?
    let startedAt: Date
    let seconds: Double
    let packets: UInt64
    let peak: Float
    let silent: Bool
}

struct Recording: Identifiable, Hashable {
    let url: URL
    let name: String
    let size: Int
    let modified: Date
    let meta: RecordingMeta?
    var id: URL { url }
}

@MainActor
final class RecordingLibrary: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    let directory: URL

    init() {
        // Storage.resolve() has already picked a directory that accepts writes; the
        // container's Documents directory does not on this install.
        directory = Storage.recordingsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            let error = error as NSError
            trlog(.error, "APP", "建录音目录失败：\(error.domain) \(error.code) \(error.localizedDescription)（\(directory.path)）")
        }
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
                             modified: values?.contentModificationDate ?? .distantPast,
                             meta: loadMeta(for: url))
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
        try? FileManager.default.removeItem(at: metaURL(for: recording.url))
        refresh()
    }

    /// Writes the metadata sidecar next to the audio file. Failure is not fatal: the audio
    /// is what matters, and the path is logged by the caller if it ever becomes important.
    func writeMeta(_ meta: RecordingMeta, for url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(meta) else { return }
        try? data.write(to: metaURL(for: url), options: .atomic)
    }

    private func metaURL(for url: URL) -> URL {
        url.appendingPathExtension("json")
    }

    private func loadMeta(for url: URL) -> RecordingMeta? {
        guard let data = try? Data(contentsOf: metaURL(for: url)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingMeta.self, from: data)
    }

    static func duration(of url: URL) -> Double {
        (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
    }
}
