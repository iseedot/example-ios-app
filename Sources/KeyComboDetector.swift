//
//  KeyComboDetector.swift
//  MyCallRec — the one place that turns individual volume-key presses into a gesture.
//
//  Two sources can feed presses in here:
//
//    * HIDKeyMonitor    — the real hardware key events from the private IOHID event
//                         system. It reports the actual button transitions, so the two
//                         buttons of the combo are still distinguishable when they are
//                         pressed together and the volume cancels out.
//    * VolumeKeyMonitor — the volume-delta sampler, the fallback used on builds where
//                         the HID client cannot be created.
//
//  Detection lives in one place for two reasons: a press that both sources report is
//  only counted once, and the rules cannot drift apart between the two paths. The rules
//  are deliberately forgiving, because the previous strict version is what made the
//  trigger feel unreliable:
//
//    * "Press both volume buttons" needs the two directions to fall inside one window,
//      in either order. It does not require the up first or the down first.
//    * A held button ramps the volume in ~0.1 s steps. Those repeats are closer together
//      than the minimum double-press gap, so a hold can no longer masquerade as a
//      double press (which used to start a recording by accident).
//    * The same direction twice within the echo window is one press reported twice by
//      the two sources, not a double press.
//

import Foundation

enum VolumeKeyDirection {
    case up
    case down
}

final class KeyComboDetector {
    /// How far apart the two directions of the combo may be. Generous: two fingers do
    /// not land on the buttons at exactly the same instant.
    var comboWindow: TimeInterval = 0.8
    /// Outer bound for a double press.
    var doublePressWindow: TimeInterval = 0.9
    /// Inner bound. A hold repeats faster than this, so those repeats are not a press.
    var minimumDoublePressGap: TimeInterval = 0.18
    /// The duplicate report of one physical press from the other source.
    var echoWindow: TimeInterval = 0.15

    /// Fires with a human-readable description when a gesture is recognised.
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
        // Same direction twice within the echo window is one press seen twice, not the
        // second half of a double press.
        if let last = lastPress, last.direction == direction,
           at.timeIntervalSince(last.at) < echoWindow {
            return
        }
        lastPress = Press(direction: direction, at: at, source: source)

        onPress?(direction == .up ? "音量+" : "音量-")
        recent.append(Press(direction: direction, at: at, source: source))
        recent.removeAll { at.timeIntervalSince($0.at) > max(comboWindow, doublePressWindow) }

        guard let description = classify() else {
            trlog(.info, "KEY", "按键：\(direction == .up ? "音量+" : "音量-")（等待组合，来源 \(source)）")
            return
        }
        recent.removeAll()
        trlog(.info, "KEY", "触发按键组合：\(description)（来源 \(source)）")
        onCombo?(description)
    }

    /// Returns the annotation for the current window, or nil while only one press is known.
    private func classify() -> String? {
        guard let first = recent.first, let last = recent.last else { return nil }
        let hasUp = recent.contains { $0.direction == .up }
        let hasDown = recent.contains { $0.direction == .down }

        // "Press both volume buttons": either order, both inside one window.
        if hasUp, hasDown, last.at.timeIntervalSince(first.at) <= comboWindow {
            return "音量+ 与 音量- 组合"
        }
        if let gap = lastGap(for: .down), gap >= minimumDoublePressGap, gap <= doublePressWindow {
            return "音量- 双击"
        }
        if let gap = lastGap(for: .up), gap >= minimumDoublePressGap, gap <= doublePressWindow {
            return "音量+ 双击"
        }
        return nil
    }

    private func lastGap(for direction: VolumeKeyDirection) -> TimeInterval? {
        let times = recent.filter { $0.direction == direction }.map(\.at)
        guard times.count >= 2 else { return nil }
        return times[times.count - 1].timeIntervalSince(times[times.count - 2])
    }
}
