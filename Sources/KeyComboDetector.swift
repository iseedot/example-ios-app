//
//  KeyComboDetector.swift
//  MyCallRec — the one place that turns individual volume-key presses into a gesture.
//
//  Only the "press both volume buttons" combo triggers. Double presses are deliberately NOT
//  a trigger: pressing a volume key twice is an ordinary volume adjustment, and treating it
//  as a hotkey started recordings by accident. The analysed target's setting text is exactly
//  "Press Both Volume Buttons".
//
//  Two sources can feed presses in here:
//
//    * HIDKeyMonitor    — the real hardware key transitions from the private IOHID event
//                         system.
//    * VolumeKeyMonitor — the volume-delta sampler fallback.
//
//  The same direction twice within the echo window is one press reported twice by the two
//  sources (or a driver duplicate), not a new press.
//

import Foundation

enum VolumeKeyDirection {
    case up
    case down
}

final class KeyComboDetector {
    /// How far apart the two directions of the combo may be.
    var comboWindow: TimeInterval = 0.8
    /// How long a press is remembered while looking for the other direction.
    var comboMemory: TimeInterval = 0.9
    /// The duplicate report of one press from the other source.
    var echoWindow: TimeInterval = 0.15
    /// A duplicate report of one press from the same source (driver repeats).
    var sameSourceDebounce: TimeInterval = 0.05

    /// Fires with a human-readable description when the gesture is recognised.
    var onCombo: ((String) -> Void)?
    /// Fires for every individual press, for the log and for diagnostics.
    var onPress: ((String) -> Void)?

    private struct Press {
        let direction: VolumeKeyDirection
        let at: Date
        let source: String
    }

    private var recent: [Press] = []
    private var lastPress: Press?

    func reset() {
        recent.removeAll()
        lastPress = nil
    }

    func press(_ direction: VolumeKeyDirection, source: String, at: Date = Date()) {
        if let last = lastPress, last.direction == direction {
            let gap = at.timeIntervalSince(last.at)
            let threshold = last.source == source ? sameSourceDebounce : echoWindow
            if gap < threshold { return }
        }
        lastPress = Press(direction: direction, at: at, source: source)

        onPress?(direction == .up ? "音量+" : "音量-")
        recent.append(Press(direction: direction, at: at, source: source))
        recent.removeAll { at.timeIntervalSince($0.at) > comboMemory }

        guard let first = recent.first, let last = recent.last else { return }
        let hasUp = recent.contains { $0.direction == .up }
        let hasDown = recent.contains { $0.direction == .down }

        // "Press both volume buttons": either order, both inside one window.
        if hasUp, hasDown, last.at.timeIntervalSince(first.at) <= comboWindow {
            recent.removeAll()
            trlog(.info, "KEY", "触发按键组合：音量+ 与 音量- 组合（来源 \(source)）")
            onCombo?("音量+ 与 音量- 组合")
            return
        }
        trlog(.info, "KEY", "按键：\(direction == .up ? "音量+" : "音量-")（等待另一个音量键，来源 \(source)）")
    }
}
