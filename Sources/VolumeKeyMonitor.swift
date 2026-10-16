//
//  VolumeKeyMonitor.swift
//  MyCallRec — trigger recording from the hardware volume buttons.
//
//  Volume buttons are system-wide, but a running app can observe them through the
//  audio session's output volume. The system's own volume HUD is suppressed by
//  keeping an off-screen MPVolumeView in the window hierarchy, and the observed
//  volume is restored so the combo does not change the actual volume.
//
//  This works while the app is alive (foreground, or background with an active audio
//  session). Intercepting the buttons while the app is suspended or killed needs the
//  daemon plus the private HID entitlements, which is the next phase.
//

import Foundation
import AVFAudio
import MediaPlayer
import UIKit
import AudioToolbox

final class VolumeKeyMonitor {
    /// Shortest and longest gap between the two halves of a combo.
    private let comboWindow: TimeInterval = 0.6
    private let doublePressWindow: TimeInterval = 0.9

    private enum Press { case up, down }

    private var observation: NSKeyValueObservation?
    private var sliderObservation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    /// Both the session volume and the slider can report the same press; the second
    /// signal for the same direction inside this window is the echo, not a new press.
    private let echoWindow: TimeInterval = 0.15
    private var lastPress: (press: Press, at: Date)?
    private var recent: [(press: Press, at: Date)] = []
    private var lastKnownVolume: Float = 0
    private var suppressVolumeHUD = true
    private var restoreVolume = true
    private var active = false

    /// Called when a combo fires; the string describes what was detected.
    var onCombo: ((String) -> Void)?
    /// Called for every individual press, for logging and diagnostics.
    var onPress: ((String) -> Void)?

    static var isSupported: Bool { true }

    /// Set when the hidden MPVolumeView could not be installed yet, so the HUD
    /// suppression is retried once the window exists instead of being given up on.
    private var needsVolumeViewRetry = false
    private var retryAttempts = 0

    func start(suppressHUD: Bool = true, restoreVolume: Bool = true) {
        guard !active else { return }
        active = true
        self.suppressVolumeHUD = suppressHUD
        self.restoreVolume = restoreVolume

        let session = AVAudioSession.sharedInstance()
        lastKnownVolume = session.outputVolume

        observation = session.observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self, let new = change.newValue, let old = change.oldValue, new != old else { return }
            trlog(.debug, "KEY", "会话音量变化 \(String(format: "%.3f -> %.3f", old, new))")
            self.handle(press: new > old ? .up : .down, volume: new)
        }

        if suppressVolumeHUD {
            installVolumeView()
        }

        let sliderValue = volumeSlider.map { String(format: "%.3f", $0.value) } ?? "（无 slider）"
        trlog(.info, "KEY", "音量键监听已启动（HUD 抑制=\(suppressVolumeHUD)，音量还原=\(restoreVolume)，"
              + "会话音量 \(String(format: "%.3f", session.outputVolume))，slider \(sliderValue)）")
        if session.outputVolume <= 0.005 {
            trlog(.warn, "KEY", "当前音量为 0：此时「音量-」不会产生变化事件（已在下界），"
                  + "请用「音量+」双击，或先把音量调到中间再试")
        } else if session.outputVolume >= 0.995 {
            trlog(.warn, "KEY", "当前音量已到最大：「音量+」不会产生变化事件，请用「音量-」双击")
        }
    }

    /// Called from the view when it appears: by then a key window exists.
    func retryVolumeViewIfNeeded() {
        guard active, needsVolumeViewRetry, suppressVolumeHUD else { return }
        installVolumeView()
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
        active = false
        trlog(.info, "KEY", "音量键监听已停止")
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
        // The slider reports the same presses as the session volume. Observing both and
        // dropping the duplicate makes the trigger work even if one of them is silent.
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            sliderObservation = slider.observe(\.value, options: [.new, .old]) { [weak self] _, change in
                guard let self, let new = change.newValue, let old = change.oldValue,
                      abs(new - old) > 0.0001 else { return }
                trlog(.debug, "KEY", "slider 变化 \(String(format: "%.3f -> %.3f", old, new))")
                self.handle(press: new > old ? .up : .down, volume: new)
            }
        }
        trlog(.info, "KEY", "已安装隐藏 MPVolumeView（音量 HUD 已抑制）")
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

    private func handle(press: Press, volume: Float) {
        let now = Date()

        // The session volume and the slider both report one press; ignore the echo.
        if let last = lastPress, last.press == press,
           now.timeIntervalSince(last.at) < echoWindow {
            return
        }
        lastPress = (press, now)

        // A press that stopped changing the slider value still counts.
        let sliderBefore = volumeSlider.map { $0.value }
        if restoreVolume, let slider = volumeSlider, abs(slider.value - lastKnownVolume) > 0.0001 {
            slider.value = lastKnownVolume
        }

        onPress?(press == .up ? "音量+" : "音量-")
        recent.append((press, now))
        recent.removeAll { now.timeIntervalSince($0.at) > doublePressWindow }

        var description: String?
        let ups = recent.filter { $0.press == .up }
        let downs = recent.filter { $0.press == .down }

        if !ups.isEmpty, let firstUp = ups.first, let lastDown = downs.last,
           abs(firstUp.at.timeIntervalSince(lastDown.at)) <= comboWindow {
            description = "音量+ 与 音量- 组合"
        } else if downs.count >= 2 {
            description = "音量- 双击"
        } else if ups.count >= 2 {
            description = "音量+ 双击"
        }

        if let description {
            recent.removeAll()
            trlog(.info, "KEY", "触发按键组合：\(description)")
            onCombo?(description)
        } else {
            let sliderText = sliderBefore.map { String(format: "%.3f", $0) } ?? "-"
            trlog(.info, "KEY", "按键：\(press == .up ? "音量+" : "音量-")（等待组合；"
                  + "事件值 \(String(format: "%.3f", volume))，改前 slider \(sliderText)）")
        }
        lastKnownVolume = AVAudioSession.sharedInstance().outputVolume
    }

    /// Short vibration feedback. The screen shows nothing.
    static func feedback(pulses: Int) {
        guard pulses > 0 else { return }
        for index in 0..<pulses {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.18) {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
    }
}
