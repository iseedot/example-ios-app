//
//  KeyComboDetector.swift
//  MyCallRec — the one place that turns individual volume-key presses into a gesture.
//
//  Two sources can feed presses in here:
//
//    * HIDKeyMonitor    — the real hardware key transitions from the private IOHID event
//                         system. One physical press is one press, so a fast double press
//                         must be accepted.
//    * VolumeKeyMonitor — the volume-delta sampler, the fallback. Holding a button ramps
//                         the volume at about 0.1 s per step, so its repeats must not be
//                         mistaken for a double press.
//
//  The required gap therefore depends on the source. The first version used one 0.18 s gap
//  for both, which silently dropped a deliberate fast double press (~0.16 s) from the real
//  buttons.
//

import Foundation

enum VolumeKeyDirection {
    case up
    case down
}

final class KeyComboDetector {
    /// How far apart the two directions of the combo may be.
    var comboWindow: TimeInterval = 0.8
    /// Outer bound for a double press.
    var doublePressWindow: TimeInterval = 0.9
    /// Two real HID presses this far apart are a deliberate double press.
    var hidDoublePressGap: TimeInterval = 0.06
    /// A held button ramps the volume at about 0.1 s, so the sampler needs a bigger gap.
    var samplerDoublePressGap: TimeInterval = 0.18
    /// The duplicate report of one press from the other source.
    var echoWindow: TimeInterval = 0.15
    /// A duplicate report of one press from the same source (driver repeats).
    var sameSourceDebounce: TimeInterval = 0.05

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
        // A repeat from a different source is the same physical press reported twice; a
        // repeat from the same source is a driver duplicate. Anything past that is a real
        // second press.
        if let last = lastPress, last.direction == direction {
            let gap = at.timeIntervalSince(last.at)
            let threshold = last.source == source ? sameSourceDebounce : echoWindow
            if gap < threshold { return }
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

    private func classify() -> String? {
        guard let first = recent.first, let last = recent.last else { return nil }
        let hasUp = recent.contains { $0.direction == .up }
        let hasDown = recent.contains { $0.direction == .down }

        // "Press both volume buttons": either order, both inside one window.
        if hasUp, hasDown, last.at.timeIntervalSince(first.at) <= comboWindow {
            return "音量+ 与 音量- 组合"
        }
        if isDoublePress(.down) { return "音量- 双击" }
        if isDoublePress(.up) { return "音量+ 双击" }
        return nil
    }

    private func isDoublePress(_ direction: VolumeKeyDirection) -> Bool {
        let presses = recent.filter { $0.direction == direction }
        guard presses.count >= 2 else { return false }
        let second = presses[presses.count - 1]
        let first = presses[presses.count - 2]
        let gap = second.at.timeIntervalSince(first.at)
        let required = (first.source == "HID" && second.source == "HID")
            ? hidDoublePressGap : samplerDoublePressGap
        return gap >= required && gap <= doublePressWindow
    }
}
