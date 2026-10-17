//
//  CallMicMute.swift
//  MyCallRec — mute the call microphone (uplink) automatically.
//
//  There is no public API to mute a live call. The analysed target does it through the
//  private TelephonyUtilities classes: TRCallMonitor imports TUCall / TUCallCenter and its
//  settings are literally "Uplink (Microphone)", "Downlink (Speaker)", with the selectors
//  setUplinkMuted: / setDownlinkMuted: and the App Intents MuteCallIntent / MuteChannel.
//
//  This mirrors the target: find the active calls through +[TUCallCenter sharedInstance]
//  -calls and send -setUplinkMuted:. Everything is resolved with the Objective-C runtime so
//  the build links no private framework. If anything is missing it is a logged no-op.
//
//  Scope, stated honestly: TelephonyUtilities only knows about cellular calls and calls that
//  go through CallKit. A third-party app that runs its own VoIP stack manages its own
//  microphone and is not a TUCall, so it cannot be muted this way; muting it would need an
//  injected tweak, which a TrollStore app cannot do.
//

import Foundation
import ObjectiveC

enum CallMicMute {
    private typealias SharedInstanceFn = @convention(c) (AnyClass, Selector) -> AnyObject?
    private typealias CallsFn = @convention(c) (AnyObject, Selector) -> AnyObject?
    private typealias SetBoolFn = @convention(c) (AnyObject, Selector, UInt8) -> Void

    /// Mutes or unmutes the uplink of every active call. Returns true when at least one call
    /// accepted the change.
    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let centerClass = NSClassFromString("TUCallCenter") else {
            trlog(.warn, "MUTE", "TUCallCenter 不可用，无法静音通话")
            return false
        }
        guard let sharedIMP = class_getClassMethod(centerClass, NSSelectorFromString("sharedInstance"))
                .map(method_getImplementation) else {
            trlog(.warn, "MUTE", "TUCallCenter 缺少 sharedInstance")
            return false
        }
        let shared = unsafeBitCast(sharedIMP, to: SharedInstanceFn.self)
        guard let center = shared(centerClass, NSSelectorFromString("sharedInstance")) else {
            trlog(.warn, "MUTE", "TUCallCenter sharedInstance 返回空")
            return false
        }

        guard let callsIMP = class_getInstanceMethod(centerClass, NSSelectorFromString("calls"))
                .map(method_getImplementation) else {
            trlog(.warn, "MUTE", "TUCallCenter 缺少 calls")
            return false
        }
        let getCalls = unsafeBitCast(callsIMP, to: CallsFn.self)
        guard let calls = getCalls(center, NSSelectorFromString("calls")) as? [AnyObject], !calls.isEmpty else {
            trlog(.info, "MUTE", "当前没有可静音的 TUCall")
            return false
        }

        guard let callClass = NSClassFromString("TUCall"),
              let setIMP = class_getInstanceMethod(callClass, NSSelectorFromString("setUplinkMuted:"))
                .map(method_getImplementation) else {
            trlog(.warn, "MUTE", "TUCall 缺少 setUplinkMuted:")
            return false
        }
        let setMutedFn = unsafeBitCast(setIMP, to: SetBoolFn.self)
        let selector = NSSelectorFromString("setUplinkMuted:")
        for call in calls {
            setMutedFn(call, selector, muted ? 1 : 0)
        }
        trlog(.info, "MUTE", "通话上行静音=\(muted ? "开" : "关")，共 \(calls.count) 路 TUCall")
        return true
    }
}
