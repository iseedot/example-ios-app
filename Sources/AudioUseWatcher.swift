//
//  AudioUseWatcher.swift
//  MyCallRec — notice when another application takes over audio, so a recording can
//  start for a call that does not go through the telephone stack (WeChat and other
//  non-CallKit VoIP apps).
//
//  Why not the CoreAudio process-object list: on this iOS build
//  AudioObjectGetPropertyData(kAudioObjectSystemObject, 'prco') answers
//  kAudioHardwareIllegalOperationError ('nope'), so the HAL cannot tell us which
//  process is capturing. The analysed target does not use that API either.
//
//  Instead three public signals are observed, all of which a competing session
//  produces and all of which can be logged:
//    * AVAudioSession interruption            — another app took the session
//    * AVAudioSession secondary-audio silence — another app started non-mixable audio
//    * CXCallObserver                         — a CallKit VoIP call changed state
//
//  These are heuristics: the trigger is only a hint about *when* to record. Whether
//  the tap actually captured anything is decided by the packet count and peak level
//  that the recorder reports, and the volume-button trigger stays authoritative.
//

import Foundation
import AVFAudio
import CallKit

enum AudioUseKind: String {
    case interruption = "音频中断"
    case secondaryAudio = "次要音频"
    case callKit = "CallKit 通话"
}

enum AudioUseEvent {
    case started(AudioUseKind, String)
    case ended(AudioUseKind, String)
}

final class AudioUseWatcher: NSObject, CXCallObserverDelegate {
    var onEvent: ((AudioUseEvent) -> Void)?

    private(set) var statusDetail = "尚未启动"

    private var tokens: [NSObjectProtocol] = []
    private var callObserver: CXCallObserver?
    /// CallKit calls that have connected and not yet ended.
    private var connectedCalls: Set<UUID> = []
    private var interrupted = false
    private var secondarySilenced = false

    /// Observers are registered on the main queue, so every callback is main-thread.
    func start() -> Bool {
        guard tokens.isEmpty, callObserver == nil else { return true }

        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            switch type {
            case .began:
                self.interrupted = true
                self.emit(.started(.interruption, "其他应用占用了音频会话"))
            case .ended:
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                self.interrupted = false
                self.emit(.ended(.interruption, "音频会话中断结束（shouldResume=\(shouldResume)）"))
            default:
                trlog(.debug, "APP", "音频中断通知：未知类型 (raw=\(raw.map(String.init) ?? "-"))")
            }
        })

        tokens.append(center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification,
                                        object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            let raw = (note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? NSNumber)?.uintValue
            let type = raw.flatMap(AVAudioSession.SilenceSecondaryAudioHintType.init(rawValue:))
            switch type {
            case .begin:
                self.secondarySilenced = true
                self.emit(.started(.secondaryAudio, "其他应用开始播放/采集不可混音音频"))
            case .end:
                self.secondarySilenced = false
                self.emit(.ended(.secondaryAudio, "其他应用结束不可混音音频"))
            default:
                trlog(.debug, "APP", "次要音频通知：未知类型 (raw=\(raw.map(String.init) ?? "-"))")
            }
        })

        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: session, queue: .main) { note in
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)?.debugLabel ?? "raw=\(raw)"
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
                .map { "\($0.portType.rawValue)/\($0.portName)" }
                .joined(separator: ",")
            trlog(.debug, "APP", "音频路由变化：\(reason)；输出=\(outputs.isEmpty ? "-" : outputs)")
        })

        tokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                        object: session, queue: .main) { _ in
            trlog(.warn, "APP", "音频服务已重启（mediaServicesWereReset）：触发源可能已失效")
        })

        let observer = CXCallObserver()
        observer.setDelegate(self, queue: .main)
        callObserver = observer

        statusDetail = "已订阅 音频中断/次要音频/路由 + CXCallObserver"
        return true
    }

    func stop() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        callObserver?.setDelegate(nil, queue: nil)
        callObserver = nil
        connectedCalls.removeAll()
        interrupted = false
        secondarySilenced = false
        statusDetail = "已停止"
    }

    private func emit(_ event: AudioUseEvent) {
        onEvent?(event)
    }

    // MARK: - CXCallObserverDelegate

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let label = "uuid=\(call.uuid.uuidString.prefix(8)) 去电=\(call.isOutgoing)"

        if call.hasEnded {
            guard connectedCalls.remove(call.uuid) != nil else { return }
            trlog(.info, "APP", "CallKit 通话结束（\(label)）")
            if connectedCalls.isEmpty {
                emit(.ended(.callKit, "CallKit 通话全部结束"))
            }
            return
        }

        guard call.hasConnected else {
            trlog(.debug, "APP", "CallKit 通话状态变化（\(label) 未接通）")
            return
        }

        let inserted = connectedCalls.insert(call.uuid).inserted
        trlog(.info, "APP", "CallKit 通话已接通（\(label)，新通知=\(inserted)）")
        if inserted, connectedCalls.count == 1 {
            emit(.started(.callKit, "CallKit 通话接通"))
        }
    }
}

private extension AVAudioSession.RouteChangeReason {
    /// Small readable label so the log alone identifies the transition.
    var debugLabel: String {
        switch self {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        @unknown default: return "unhandled(\(rawValue))"
        }
    }
}
