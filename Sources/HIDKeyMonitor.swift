//
//  HIDKeyMonitor.swift
//  MyCallRec — hardware volume-key events from the private IOHID event system.
//
//  Why this exists
//  ---------------
//  VolumeKeyMonitor infers a press from a change in the volume value sampled 10 times a
//  second. That loses the press completely when the two buttons cancel each other out
//  (volume+ and volume- pressed together), and it loses one direction entirely at the
//  volume bounds (0 % and 100 %). Those are exactly the cases the user hits.
//
//  The analysed target does not have that problem: its daemon keeps an
//  IOHIDEventSystemClient and receives the real button transitions. The strings in
//  TRCallMonitor name the events it handles —
//    volumeIncrementDown / volumeIncrementPress / volumeIncrementUp
//    volumeDecrementDown / volumeDecrementPress / volumeDecrementUp
//    powerLongPress / menuLongPress
//  — and the import table lists _IOHIDEventSystemClientCreate,
//  _IOHIDEventSystemClientRegisterEventCallback and
//  _IOHIDEventSystemClientScheduleWithRunLoop (see
//  target/decompiled/security/imports/TRCallMonitor.json). Its settings text is
//  "Press Both Volume Buttons" / "press both of the physical volume buttons to start or
//  stop recording during a call" (target/decompiled/security/strings/TRApp.txt).
//
//  The entitlement this needs (com.apple.private.hid.client.event-monitor) is already in
//  entitlements.plist, so the same mechanism is reachable from this app. The entry points
//  are resolved with dlsym, so the build still links against the public SDK only.
//
//  Limits, stated up front
//  -----------------------
//  The process has to be running to receive the events, so the app must not be suspended
//  in the background. BackgroundKeepAlive keeps an audio session busy for that. A trigger
//  that survives the app being killed needs the daemon phase that the analysed target has
//  and this app does not — it is out of scope here and called out in the summary.
//
//  If the client cannot be created, HIDKeyMonitor simply reports why and stays out of the
//  way; VolumeKeyMonitor keeps working as the fallback.
//

import Foundation
import CoreFoundation
import Darwin

// The private entry points, declared only as function-pointer types.
private typealias IOHIDEventSystemClientCreateFn =
    @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
private typealias IOHIDEventSystemClientRegisterEventCallbackFn =
    @convention(c) (UnsafeMutableRawPointer?, IOHIDEventCallbackFn?,
                    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
private typealias IOHIDEventSystemClientScheduleWithRunLoopFn =
    @convention(c) (UnsafeMutableRawPointer?, CFRunLoop?, CFString?) -> Void
private typealias IOHIDEventSystemClientUnregisterEventCallbackFn =
    @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias IOHIDEventSystemClientUnscheduleWithRunLoopFn =
    @convention(c) (UnsafeMutableRawPointer?, CFRunLoop?, CFString?) -> Void
private typealias IOHIDEventGetTypeFn =
    @convention(c) (UnsafeMutableRawPointer?) -> UInt32
private typealias IOHIDEventGetIntegerValueFn =
    @convention(c) (UnsafeMutableRawPointer?, UInt32) -> Int64

/// void (*)(void *target, void *refcon, IOHIDServiceClientRef service, IOHIDEventRef event)
private typealias IOHIDEventCallbackFn =
    @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

// IOHIDEvent constants. The field values are the type shifted into the high 16 bits, which
// is how the private header defines them.
private let kIOHIDEventTypeKeyboard: UInt32 = 3
private let kIOHIDEventFieldKeyboardUsagePage: UInt32 = 0x0003_0000
private let kIOHIDEventFieldKeyboardUsage: UInt32 = 0x0003_0001
private let kIOHIDEventFieldKeyboardDown: UInt32 = 0x0003_0002

private let kHIDUsagePageConsumer: Int64 = 0x0C
private let kHIDUsageVolumeIncrement: Int64 = 0xE9
private let kHIDUsageVolumeDecrement: Int64 = 0xEA

final class HIDKeyMonitor {
    /// One transition of a hardware volume button.
    var onPress: ((VolumeKeyDirection, String) -> Void)?

    private(set) var statusDetail = "尚未启动"
    /// Every event the client delivered, whatever its type. Embedded in diagnostics so a
    /// build that delivers nothing is distinguishable from one that never starts.
    private(set) var eventCount = 0
    /// True once at least one volume event has been decoded. VolumeKeyMonitor reads this
    /// to stop feeding the fallback path, so one physical press is never counted twice.
    private(set) var hasReceivedVolumeEvent = false

    private var client: UnsafeMutableRawPointer?

    private let create: IOHIDEventSystemClientCreateFn?
    private let register: IOHIDEventSystemClientRegisterEventCallbackFn?
    private let schedule: IOHIDEventSystemClientScheduleWithRunLoopFn?
    private let unregister: IOHIDEventSystemClientUnregisterEventCallbackFn?
    private let unschedule: IOHIDEventSystemClientUnscheduleWithRunLoopFn?
    private let getType: IOHIDEventGetTypeFn?
    private let getInteger: IOHIDEventGetIntegerValueFn?

    /// Tracks the down/up state per button so a stream of "down" events is one press.
    private var volumeUpDown = false
    private var volumeDownDown = false
    private var unknownPagesLogged: Set<Int64> = []

    init() {
        let path = "/System/Library/Frameworks/IOKit.framework/IOKit"
        let handle = dlopen(path, RTLD_NOW)
        let scope = UnsafeMutableRawPointer(bitPattern: -2)

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            var raw: UnsafeMutableRawPointer?
            if let handle { raw = dlsym(handle, name) }
            if raw == nil, let scope { raw = dlsym(scope, name) }
            guard let raw else { return nil }
            return unsafeBitCast(raw, to: T.self)
        }

        create = symbol("IOHIDEventSystemClientCreate", as: IOHIDEventSystemClientCreateFn.self)
        register = symbol("IOHIDEventSystemClientRegisterEventCallback",
                          as: IOHIDEventSystemClientRegisterEventCallbackFn.self)
        schedule = symbol("IOHIDEventSystemClientScheduleWithRunLoop",
                          as: IOHIDEventSystemClientScheduleWithRunLoopFn.self)
        unregister = symbol("IOHIDEventSystemClientUnregisterEventCallback",
                            as: IOHIDEventSystemClientUnregisterEventCallbackFn.self)
        unschedule = symbol("IOHIDEventSystemClientUnscheduleWithRunLoop",
                            as: IOHIDEventSystemClientUnscheduleWithRunLoopFn.self)
        getType = symbol("IOHIDEventGetType", as: IOHIDEventGetTypeFn.self)
        getInteger = symbol("IOHIDEventGetIntegerValue", as: IOHIDEventGetIntegerValueFn.self)

        statusDetail = create == nil
            ? "IOKit 已加载=\(handle != nil)，缺少 IOHIDEventSystemClientCreate"
            : "IOHID 符号已解析"
    }

    static var isSupported: Bool {
        let probe = HIDKeyMonitor()
        return probe.create != nil && probe.register != nil && probe.schedule != nil
    }

    @discardableResult
    func start() -> Bool {
        guard client == nil else { return true }
        guard let create, let register, let schedule else {
            statusDetail = "IOHID 符号不完整，回退到音量采样"
            trlog(.warn, "KEY", "IOHID 事件系统不可用：\(statusDetail)")
            return false
        }
        guard let created = create(kCFAllocatorDefault) else {
            statusDetail = "IOHIDEventSystemClientCreate 返回空，回退到音量采样"
            trlog(.warn, "KEY", "IOHIDEventSystemClientCreate 失败：\(statusDetail)")
            return false
        }
        client = created

        register(created, hidKeyEventCallback, Unmanaged.passUnretained(self).toOpaque(), nil)
        schedule(created, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        statusDetail = "已订阅 IOHID 事件"
        trlog(.info, "KEY", "IOHID 事件已订阅（真实按键事件优先，音量采样作后备）")
        return true
    }

    func stop() {
        guard let client else { return }
        unregister?(client)
        unschedule?(client, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.client = nil
        volumeUpDown = false
        volumeDownDown = false
        statusDetail = "已停止"
        trlog(.info, "KEY", "IOHID 事件已停止")
    }

    fileprivate func handle(event: UnsafeMutableRawPointer) {
        eventCount += 1
        let type = getType?(event) ?? 0
        guard type == kIOHIDEventTypeKeyboard else { return }

        let usagePage = getInteger?(event, kIOHIDEventFieldKeyboardUsagePage) ?? 0
        let usage = getInteger?(event, kIOHIDEventFieldKeyboardUsage) ?? 0
        // Most drivers send the down field; treat an absent field as "down" so a single
        // event per press still works.
        let down = (getInteger?(event, kIOHIDEventFieldKeyboardDown) ?? 1) != 0

        guard usagePage == kHIDUsagePageConsumer else {
            noteUnknown(usagePage: usagePage, usage: usage)
            return
        }

        switch usage {
        case kHIDUsageVolumeIncrement:
            if down, !volumeUpDown {
                volumeUpDown = true
                hasReceivedVolumeEvent = true
                onPress?(.up, "HID")
            } else if !down {
                volumeUpDown = false
            }
        case kHIDUsageVolumeDecrement:
            if down, !volumeDownDown {
                volumeDownDown = true
                hasReceivedVolumeEvent = true
                onPress?(.down, "HID")
            } else if !down {
                volumeDownDown = false
            }
        default:
            if eventCount <= 20 || hasReceivedVolumeEvent == false {
                trlog(.debug, "KEY", "IOHID 键盘事件：page=0x\(String(usagePage, radix: 16)) "
                      + "usage=0x\(String(usage, radix: 16)) down=\(down)")
            }
        }
    }

    /// Logs an unexpected usage page once, so the mapping can be extended from a log
    /// without a debugger — this is how the HID codes are meant to be confirmed on device.
    private func noteUnknown(usagePage: Int64, usage: Int64) {
        guard !unknownPagesLogged.contains(usagePage) else { return }
        unknownPagesLogged.insert(usagePage)
        trlog(.warn, "KEY", "IOHID 收到未映射的事件 page=0x\(String(usagePage, radix: 16)) "
              + "usage=0x\(String(usage, radix: 16))；若音量键无反应，请把这一行发回")
    }
}

/// File-scope so it converts to a C function pointer; the target pointer is the monitor.
private let hidKeyEventCallback: IOHIDEventCallbackFn = { target, _, _, event in
    guard let target, let event else { return }
    let monitor = Unmanaged<HIDKeyMonitor>.fromOpaque(target).takeUnretainedValue()
    monitor.handle(event: event)
}
