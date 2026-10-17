//
//  DualRecorder.swift
//  MyCallRec — record both sides of a call at the same time.
//
//  Measured on this device (2026-10-17 capture test, confirmed by listening to the files):
//    * the speaker tap (-2) carries the other party's voice while a call is up,
//    * the process tap on WeChat carries only its ringtone,
//    * the system mix carries nothing for a call,
//    * the microphone records my side, but only while no telephone call owns the input.
//
//  The analysed target records exactly these two sides and mixes them: its helper logs
//  "Running in mixer mode / Initialized recorder for microphone / Initialized recorder for
//  speaker / Initialized mixer with sample rate: 16000.00". One private tap can only be
//  bound to one target, so this engine runs two recorders and AudioMixer joins the files
//  when the recording ends.
//

import Foundation

final class DualRecorder: RecordingEngine {
    /// My side (microphone). Nil when that path refused to start; the other side is kept.
    private(set) var uplink: TapRecorder?
    /// The other side (speaker tap).
    private(set) var downlink: TapRecorder?

    let targetLabel = "麦克风+扬声器（双路混音）"
    let startedAt = Date()
    private(set) var hasStopped = false
    /// 未混音 / 已混音 / 混音失败（两路文件保留）/ 单路 / 没有可用音轨
    private(set) var mergeState = "未混音"
    /// Where the two source files are, for the log when a merge fails.
    private(set) var sourceFiles: [URL] = []
    /// Called on the main queue once the engine is completely finished with its files.
    var onFinishedMerging: (() -> Void)?

    private let destination: URL

    /// The merged file. It appears a moment after stop() while the mix runs.
    var fileURL: URL { destination }

    var secondsRecorded: Double {
        max(uplink?.secondsRecorded ?? 0, downlink?.secondsRecorded ?? 0)
    }
    var packetsWritten: UInt64 {
        (uplink?.packetsWritten ?? 0) + (downlink?.packetsWritten ?? 0)
    }
    var peakAmplitude: Float {
        max(uplink?.peakAmplitude ?? 0, downlink?.peakAmplitude ?? 0)
    }
    var maxPeakAmplitude: Float {
        max(uplink?.maxPeakAmplitude ?? 0, downlink?.maxPeakAmplitude ?? 0)
    }
    var receivedFirstBuffer: Bool {
        (uplink?.receivedFirstBuffer ?? false) || (downlink?.receivedFirstBuffer ?? false)
    }

    init(directory: URL, baseName: String, compress: Bool) throws {
        destination = directory.appendingPathComponent("\(baseName).m4a")
        let microphoneURL = directory.appendingPathComponent("\(baseName)-mic.m4a")
        let speakerURL = directory.appendingPathComponent("\(baseName)-spk.m4a")

        // The microphone needs no private tap, and the session stays deactivated: an active
        // play-and-record session is what made the microphone fail with '!pri' while a
        // telephone call was up.
        do {
            let created = try TapRecorder(target: .microphone, sampleRate: 44100, channels: 1,
                                          fileURL: microphoneURL, bypassTap: true, compress: compress)
            try created.start()
            uplink = created
        } catch {
            trlog(.error, "REC", "双路录音：本机一路（麦克风）失败：\(error)")
        }

        do {
            let created = try TapRecorder(target: .speaker, sampleRate: 44100, channels: 2,
                                          fileURL: speakerURL, bypassTap: false, compress: compress)
            try created.start()
            downlink = created
        } catch {
            trlog(.error, "REC", "双路录音：对端一路（扬声器）失败：\(error)")
        }

        guard uplink != nil || downlink != nil else {
            throw TapRecorderError.tapCreationFailed
        }
    }

    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        uplink?.stop()
        downlink?.stop()

        trlog(.info, "REC", String(format: "双路结果：本机峰值=%.4f（%llu 包） 对端峰值=%.4f（%llu 包）",
                                   uplink?.maxPeakAmplitude ?? 0, uplink?.packetsWritten ?? 0,
                                   downlink?.maxPeakAmplitude ?? 0, downlink?.packetsWritten ?? 0))

        var sources: [URL] = []
        if let url = uplink?.fileURL { sources.append(url) }
        if let url = downlink?.fileURL { sources.append(url) }
        sourceFiles = sources

        if sources.isEmpty {
            mergeState = "没有可用音轨"
            onFinishedMerging?()
            return
        }

        // One side is already a usable recording: move it into the place the app expects.
        if sources.count == 1 {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: sources[0], to: destination)
                mergeState = "单路"
            } catch {
                mergeState = "单路（改名失败，保留 \(sources[0].lastPathComponent)）"
            }
            onFinishedMerging?()
            return
        }

        let destination = destination
        let sourceFiles = sources
        DispatchQueue.global(qos: .utility).async { [weak self] in
            AudioMixer.merge(sourceFiles, to: destination) { merged in
                if merged {
                    for url in sourceFiles { try? FileManager.default.removeItem(at: url) }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.mergeState = merged ? "已混音" : "混音失败（两路文件保留）"
                    self.onFinishedMerging?()
                }
            }
        }
    }
}
