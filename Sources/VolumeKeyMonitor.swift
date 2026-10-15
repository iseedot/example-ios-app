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
    private var volumeView: MPVolumeView?
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

    func start(suppressHUD: Bool = true, restoreVolume: Bool = true) {
        guard !active else { return }
        active = true
        self.suppressVolumeHUD = suppressHUD
        self.restoreVolume = restoreVolume

        let session = AVAudioSession.sharedInstance()
        lastKnownVolume = session.outputVolume

        observation = session.observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self, let new = change.newValue, let old = change.oldValue, new != old else { return }
            let press: Press = new > old ? .up : .down
            self.handle(press: press, volume: new)
        }

        if suppressVolumeHUD {
            installVolumeView()
        }
        trlog(.info, "KEY", "音量键监听已启动（HUD 抑制=\(suppressVolumeHUD)，音量还原=\(restoreVolume)）")
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
        guard let window = Self.frontmostWindow() else {
            trlog(.warn, "KEY", "找不到窗口，音量 HUD 抑制可能不生效")
            return
        }
        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 200, height: 40))
        window.addSubview(view)
        volumeView = view
        trlog(.debug, "KEY", "已安装隐藏 MPVolumeView（HUD 抑制）")
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

        // A press that stopped changing the slider value still counts.
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
            trlog(.debug, "KEY", "按键：\(press == .up ? "音量+" : "音量-")（等待组合）")
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
