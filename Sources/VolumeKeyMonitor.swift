//
//  VolumeKeyMonitor.swift
//  MyCallRec — the volume-delta fallback for the hardware-key trigger.
//
//  This is the fallback path, not the primary one. HIDKeyMonitor receives the real button
//  transitions; this sampler only reads AVAudioSession.outputVolume (and the hidden
//  MPVolumeView's slider when HUD suppression is on) every 0.1 s and turns a change into a
//  press. It stays because it works without any private HID facility, but it is inherently
//  lossy: pressing both buttons together cancels the volume change out, and a press at
//  either volume bound changes nothing at all.
//
//  To keep the two sources from double-reporting, emitPress is suppressed once
//  HIDKeyMonitor has decoded a real volume event (see hidIsPrimary). That is also what
//  stops the volume restore from looking like the second half of a combo.
//
//  HUD suppression installs an off-screen MPVolumeView. On some builds that view takes the
//  volume buttons over, which is why it is off by default: get the trigger working first,
//  then suppress the HUD. Intercepting the buttons while the app is suspended or killed
//  needs the daemon phase.
//

import Foundation
import AVFAudio
import MediaPlayer
import UIKit
import AudioToolbox

final class VolumeKeyMonitor {
    /// How often the volume is read. Coarser than a press.
    private let sampleInterval: TimeInterval = 0.1

    /// Shared detector. Every press is handed to it; nothing is classified here.
    private let detector: KeyComboDetector
    /// When this returns true the delta sampler stays quiet: the HID path has real events,
    /// so the derived presses would only duplicate them.
    var hidIsPrimary: (() -> Bool)?

    private var timer: Timer?
    private var volumeView: MPVolumeView?

    private var suppressVolumeHUD = true
    private var restoreVolume = true
    private var active = false

    private var baseline: Float = 0
    private var lastSessionVolume: Float = -1
    private var lastSliderValue: Float = -1

    private var needsVolumeViewRetry = false
    private var retryAttempts = 0
    private var warnedAboutBound = false

    static var isSupported: Bool { true }

    init(detector: KeyComboDetector) {
        self.detector = detector
    }

    func start(suppressHUD: Bool = true, restoreVolume: Bool = true) {
        guard !active else { return }
        active = true
        self.suppressVolumeHUD = suppressHUD
        self.restoreVolume = restoreVolume

        let session = AVAudioSession.sharedInstance()
        baseline = session.outputVolume
        lastSessionVolume = baseline
        lastSliderValue = -1

        if suppressHUD {
            installVolumeView()
        }

        let timer = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        // .common keeps the timer running while a scroll or gesture is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let sliderText = volumeSlider.map { String(format: "%.3f", $0.value) } ?? "无（HUD 抑制关闭）"
        trlog(.info, "KEY", "音量键采样后备已启动（采样 \(Int(sampleInterval * 1000)) ms，HUD 抑制=\(suppressVolumeHUD)，"
              + "音量还原=\(restoreVolume)，会话音量 \(String(format: "%.3f", session.outputVolume))，slider \(sliderText)）")

        if baseline <= 0.005 {
            trlog(.warn, "KEY", "当前音量为 0：此时「音量-」不会产生变化事件（已在下界），"
                  + "请用「音量+」或组合键")
        } else if baseline >= 0.995 {
            trlog(.warn, "KEY", "当前音量已到最大：「音量+」不会产生变化事件，请用「音量-」或组合键")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
        active = false
        trlog(.info, "KEY", "音量键采样后备已停止")
    }

    /// Called from the view when it appears: by then a key window exists.
    func retryVolumeViewIfNeeded() {
        guard active, needsVolumeViewRetry, suppressVolumeHUD else { return }
        installVolumeView()
    }

    private func installVolumeView() {
        guard volumeView == nil else { return }
        guard let window = Self.frontmostWindow() else {
            needsVolumeViewRetry = true
            retryAttempts += 1
            trlog(.warn, "KEY", "找不到窗口，音量 HUD 抑制暂不生效（第 \(retryAttempts) 次，1 秒后重试）")
            if retryAttempts <= 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.retryVolumeViewIfNeeded()
                }
            }
            return
        }
        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 200, height: 40))
        window.addSubview(view)
        volumeView = view
        needsVolumeViewRetry = false
        trlog(.info, "KEY", "已安装隐藏 MPVolumeView（音量 HUD 已抑制；若按键失去反应请关闭此开关）")
    }

    static func frontmostWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first
    }

    private var volumeSlider: UISlider? {
        volumeView?.subviews.compactMap { $0 as? UISlider }.first
    }

    // MARK: - Sampling

    private func sample() {
        guard active else { return }

        // Once the real HID events are flowing, a derived volume press can only ever be a
        // duplicate, so stop the 10 Hz poll instead of keeping it (and the CPU) awake.
        if hidIsPrimary?() == true {
            timer?.invalidate()
            timer = nil
            trlog(.info, "KEY", "IOHID 已生效，停止音量采样（省电）")
            return
        }

        let sessionValue = AVAudioSession.sharedInstance().outputVolume
        if lastSessionVolume < 0 { lastSessionVolume = sessionValue }
        if abs(sessionValue - lastSessionVolume) > 0.001 {
            let delta = sessionValue - lastSessionVolume
            trlog(.debug, "KEY", "会话音量 \(String(format: "%.3f -> %.3f", lastSessionVolume, sessionValue))")
            lastSessionVolume = sessionValue
            emitPress(from: delta, source: "会话")
        }

        // The slider only exists with HUD suppression on, and it is the value the
        // hardware buttons drive once the view is present.
        if let slider = volumeSlider {
            if lastSliderValue < 0 { lastSliderValue = slider.value }
            if abs(slider.value - lastSliderValue) > 0.001 {
                let delta = slider.value - lastSliderValue
                trlog(.debug, "KEY", "slider \(String(format: "%.3f -> %.3f", lastSliderValue, slider.value))")
                lastSliderValue = slider.value
                emitPress(from: delta, source: "slider")
            }
        }
    }

    private func emitPress(from delta: Float, source: String) {
        // Once the HID path has real events, a derived press would only be a duplicate or a
        // volume-restore artefact.
        if hidIsPrimary?() == true { return }
        detector.press(delta > 0 ? .up : .down, source: source)

        // Put the volume back so the combo does not change it, and keep the samplers in
        // step with the restored value so the restore is not read as another press.
        if restoreVolume, let slider = volumeSlider {
            if abs(slider.value - baseline) > 0.0001 {
                slider.value = baseline
            }
            lastSliderValue = baseline
            lastSessionVolume = AVAudioSession.sharedInstance().outputVolume
        } else {
            baseline = AVAudioSession.sharedInstance().outputVolume
            lastSessionVolume = baseline
            if !warnedAboutBound, !suppressVolumeHUD {
                warnedAboutBound = true
                trlog(.info, "KEY", "音量 HUD 抑制关闭时无法还原音量：每次按键会让音量变化一格")
            }
        }
    }

    /// Short vibration feedback. The screen shows nothing. The interval lets start and
    /// stop use the same pulse count with a different rhythm, and lets a single pulse
    /// become a more noticeable pair.
    static func feedback(pulses: Int, interval: TimeInterval = 0.18) {
        guard pulses > 0 else { return }
        for index in 0..<pulses {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * interval) {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
    }
}
