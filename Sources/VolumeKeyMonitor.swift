//
//  VolumeKeyMonitor.swift
//  MyCallRec — trigger recording from the hardware volume buttons.
//
//  The first implementation observed AVAudioSession.outputVolume with KVO. On this
//  device that never delivered a single callback, so the presses are now *sampled*:
//  a 0.1 s timer reads the volume and turns a change into a press. Two sources are
//  read at once, because they fail independently:
//
//    * AVAudioSession.outputVolume — always available
//    * the hidden MPVolumeView's slider — only when HUD suppression is on, and it is
//      the value the hardware buttons drive once such a view exists
//
//  A press that changes the volume by more than one step counts as that many presses,
//  so two quick presses inside one sample are not lost.
//
//  HUD suppression installs an off-screen MPVolumeView. On some builds that view takes
//  the volume buttons over, which is why it is now off by default: get the trigger
//  working first, then suppress the HUD. Intercepting the buttons while the app is
//  suspended or killed needs the daemon phase.
//

import Foundation
import AVFAudio
import MediaPlayer
import UIKit
import AudioToolbox

final class VolumeKeyMonitor {
    /// Shortest and longest gap between the two directions of a combo.
    private let comboWindow: TimeInterval = 0.6
    private let doublePressWindow: TimeInterval = 0.9
    /// How often the volume is read. Coarser than a press, finer than a double press.
    private let sampleInterval: TimeInterval = 0.1
    /// One iOS volume step, so a multi-step change can be counted as several presses.
    private let volumeStep: Float = 1.0 / 16.0
    /// The two sources report the same press; the echo arrives within this window.
    private let echoWindow: TimeInterval = 0.12

    private enum Press { case up, down }

    /// Called when a combo fires; the string describes what was detected.
    var onCombo: ((String) -> Void)?
    /// Called for every individual press, for logging and diagnostics.
    var onPress: ((String) -> Void)?

    private var timer: Timer?
    private var volumeView: MPVolumeView?
    private var recent: [(press: Press, at: Date)] = []
    private var lastPress: (press: Press, at: Date)?

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
        trlog(.info, "KEY", "音量键监听已启动（采样 \(Int(sampleInterval * 1000)) ms，HUD 抑制=\(suppressVolumeHUD)，"
              + "音量还原=\(restoreVolume)，会话音量 \(String(format: "%.3f", session.outputVolume))，slider \(sliderText)）")

        if baseline <= 0.005 {
            trlog(.warn, "KEY", "当前音量为 0：此时「音量-」不会产生变化事件（已在下界），"
                  + "请用「音量+」双击，或先把音量调到中间再试")
        } else if baseline >= 0.995 {
            trlog(.warn, "KEY", "当前音量已到最大：「音量+」不会产生变化事件，请用「音量-」双击")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
        active = false
        trlog(.info, "KEY", "音量键监听已停止")
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
        let steps = min(4, max(1, Int((abs(delta) / volumeStep).rounded())))
        let press: Press = delta > 0 ? .up : .down
        for _ in 0..<steps {
            handle(press: press, source: source)
        }
    }

    private func handle(press: Press, source: String) {
        let now = Date()

        // Both sources report one press; ignore the second report of the same direction.
        if let last = lastPress, last.press == press, now.timeIntervalSince(last.at) < echoWindow {
            return
        }
        lastPress = (press, now)

        onPress?(press == .up ? "音量+" : "音量-")
        recent.append((press, now))
        recent.removeAll { now.timeIntervalSince($0.at) > doublePressWindow }

        let ups = recent.filter { $0.press == .up }
        let downs = recent.filter { $0.press == .down }

        var description: String?
        if !ups.isEmpty, !downs.isEmpty,
           let first = recent.first, let last = recent.last,
           abs(last.at.timeIntervalSince(first.at)) <= comboWindow {
            description = "音量+ 与 音量- 组合"
        } else if downs.count >= 2 {
            description = "音量- 双击"
        } else if ups.count >= 2 {
            description = "音量+ 双击"
        }

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
            if !warnedAboutBound, suppressVolumeHUD == false {
                warnedAboutBound = true
                trlog(.info, "KEY", "音量 HUD 抑制关闭时无法还原音量：每次按键会让音量变化一格")
            }
        }

        if let description {
            recent.removeAll()
            trlog(.info, "KEY", "触发按键组合：\(description)（来源 \(source)）")
            onCombo?(description)
        } else {
            trlog(.info, "KEY", "按键：\(press == .up ? "音量+" : "音量-")（等待组合；来源 \(source)，"
                  + "当前音量 \(String(format: "%.3f", AVAudioSession.sharedInstance().outputVolume))）")
        }
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
