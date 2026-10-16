//
//  BackgroundKeepAlive.swift
//  MyCallRec — keep the process running so a trigger can still fire in the background.
//
//  A hardware-key trigger and the automatic call/app triggers only work while the process
//  is alive. On this device the app is suspended as soon as another app is foreground and
//  nothing is playing, which is one of the reasons the volume keys "sometimes do not work
//  under another app".
//
//  The analysed target solves the same problem in the daemon by playing a background audio
//  file while it waits for key events (TRCallMonitor imports
//  playBackgroundAudioWithContentsOfFile:rate:volume:repeat: and keeps a flag
//  mShouldAlwaysAllowReceivingKeyEvents). A daemon is the real answer, but an app that
//  keeps one silent audio session busy is not suspended, so the same trick is enough for
//  the foreground/background transitions this app has to survive.
//
//  The tone is generated in memory (a one second silent 8 kHz mono WAV) rather than
//  shipped as a file, so there is nothing to keep in sync with the bundle.
//

import Foundation
import AVFAudio
import AVFoundation

final class BackgroundKeepAlive {
    private(set) var statusDetail = "未启用"
    private var player: AVAudioPlayer?
    private var fileURL: URL?

    var isActive: Bool { player?.isPlaying == true }

    @discardableResult
    func start() -> Bool {
        guard player == nil else { return true }
        guard let url = writeSilentTone() else {
            statusDetail = "无法生成静音文件"
            trlog(.warn, "APP", "后台保活启动失败：\(statusDetail)")
            return false
        }
        do {
            let created = try AVAudioPlayer(contentsOf: url)
            created.numberOfLoops = -1
            // The tone itself is ~-78 dBFS, so full volume is still inaudible.
            created.volume = 1
            created.prepareToPlay()
            guard created.play() else {
                statusDetail = "AVAudioPlayer 拒绝播放"
                trlog(.warn, "APP", "后台保活启动失败：\(statusDetail)")
                return false
            }
            player = created
            fileURL = url
            statusDetail = "循环播放近静音音频，避免后台挂起"
            trlog(.info, "APP", "后台保活已启动（近静音循环，避免被挂起后按键/通话事件收不到）")
            return true
        } catch {
            statusDetail = "AVAudioPlayer 创建失败：\(error.localizedDescription)"
            trlog(.warn, "APP", "后台保活启动失败：\(statusDetail)")
            return false
        }
    }

    func stop() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        statusDetail = "未启用"
        trlog(.info, "APP", "后台保活已停止")
    }

    /// A 1 s, 8 kHz, mono, 16-bit PCM WAV of a near-silent tone, written to the log
    /// directory. It is deliberately not bit-exact silence: some iOS versions treat a
    /// purely silent stream as inactivity and suspend the app anyway. -78 dBFS is
    /// inaudible but keeps the stream "playing".
    private func writeSilentTone() -> URL? {
        let directory = Storage.logsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("keepalive-silence.wav")

        let sampleRate: UInt32 = 8_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleCount = Int(sampleRate)  // 1 second
        let dataSize = sampleCount * Int(channels) * Int(bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data()
        func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)                 // PCM
        appendUInt16(channels)
        appendUInt32(sampleRate)
        appendUInt32(byteRate)
        appendUInt16(blockAlign)
        appendUInt16(bitsPerSample)
        appendASCII("data")
        appendUInt32(UInt32(dataSize))

        // ~200 Hz sine at amplitude 4/32767, two bytes little-endian per sample.
        let amplitude = 4.0
        let angularStep = 2.0 * Double.pi * 200.0 / Double(sampleRate)
        for index in 0..<sampleCount {
            let value = Int16((sin(angularStep * Double(index)) * amplitude).rounded())
            appendUInt16(UInt16(bitPattern: value))
        }

        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
