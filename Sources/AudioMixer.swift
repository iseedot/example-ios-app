//
//  AudioMixer.swift
//  MyCallRec — mix the two recorded sides of a call into one file.
//
//  The private tap binds one queue to one target, so my side (microphone) and the other
//  side (speaker tap) are two files. The analysed target does the same thing and calls it
//  mixer mode ("Running in mixer mode / Initialized recorder for microphone / for speaker",
//  TRCallRecorder log). This is the step that turns them back into one recording.
//

import AVFoundation

enum AudioMixer {
    /// Mixes overlapping audio files into one m4a at `destination`.
    ///
    /// Each source gets its own composition track starting at zero, so they play together
    /// instead of one after the other; the export session then mixes the tracks into the
    /// single AAC track an m4a holds. The completion runs on an internal queue.
    static func merge(_ sources: [URL], to destination: URL, completion: @escaping (Bool) -> Void) {
        guard sources.count > 1 else { completion(false); return }

        let composition = AVMutableComposition()
        var mixParameters: [AVMutableAudioMixInputParameters] = []
        var inserted = 0

        for url in sources {
            let asset = AVURLAsset(url: url)
            guard let sourceTrack = asset.tracks(withMediaType: .audio).first else {
                trlog(.warn, "MIX", "跳过 \(url.lastPathComponent)：没有音轨")
                continue
            }
            guard asset.duration.seconds > 0 else {
                trlog(.warn, "MIX", "跳过 \(url.lastPathComponent)：时长为 0")
                continue
            }
            guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
                continue
            }
            do {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration),
                                          of: sourceTrack, at: .zero)
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(1.0, at: .zero)
                mixParameters.append(parameters)
                inserted += 1
            } catch {
                trlog(.warn, "MIX", "跳过 \(url.lastPathComponent)：\(error)")
            }
        }

        guard inserted > 1 else {
            trlog(.warn, "MIX", "可用音轨不足两路，放弃混音")
            completion(false)
            return
        }

        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            trlog(.error, "MIX", "无法创建导出会话")
            completion(false)
            return
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixParameters
        export.audioMix = mix
        export.outputURL = destination
        export.outputFileType = .m4a
        export.shouldOptimizeForNetworkUse = false

        try? FileManager.default.removeItem(at: destination)
        export.exportAsynchronously {
            let status = export.status
            if status == .completed {
                trlog(.info, "MIX", "混音完成：\(destination.lastPathComponent)")
                completion(true)
            } else {
                trlog(.error, "MIX", "混音失败（status=\(status.rawValue)）：\(export.error.map { String(describing: $0) } ?? "-")")
                completion(false)
            }
        }
    }
}
