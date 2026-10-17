//
//  AudioSessionConfig.swift
//  MyCallRec — the one place the audio session is configured.
//
//  A file-level function rather than a method on the app model: the capture-test session
//  is not main-actor isolated and has to configure the session per slice, and both callers
//  must produce exactly the same session state or a probe result would not describe the
//  normal recording path.
//

import AVFAudio

/// Sets the category every recording path needs, and optionally activates the session.
///
/// The category is set even when the session stays deactivated: the tap path relies on
/// com.apple.coreaudio.CanRecordWithoutSessionActivation, and an active play-and-record
/// session disturbs the application being recorded.
func trCreateRecordingSession(activate: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
        if activate {
            try session.setActive(true)
            trlog(.info, "AUDIO", "音频会话已激活：\(session.category.rawValue)")
        } else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            trlog(.info, "AUDIO", "音频会话已停用（仅设置分类），避免影响被录音的应用")
        }
    } catch {
        trlog(.error, "AUDIO", "音频会话配置失败：\(error)")
    }
}
