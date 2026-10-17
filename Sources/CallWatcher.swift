//
//  CallWatcher.swift
//  MyCallRec — Phase 1 proof of concept.
//
//  Observes telephone call state with the CoreTelephony notification centre.
//  The private symbols are resolved at runtime, so the app links against the public
//  SDK only and does not need CoreTelephony's private headers.
//
//  Note: CoreTelephony ships in /System/Library/Frameworks, not PrivateFrameworks.
//  The candidate list below is tried in order and the failure reason is reported so
//  a device log alone is enough to diagnose a mismatch.
//

import Foundation
import CoreFoundation
import Darwin

public enum CallState: Int32 {
    case unknown = 0
    case answered = 1
    case droppedInterrupted = 2
    case outgoingInitiated = 3
    case incoming = 4
    case incomingEnded = 5

    public var label: String {
        switch self {
        case .unknown: return "未知"
        case .answered: return "已接通"
        case .droppedInterrupted: return "通话中断"
        case .outgoingInitiated: return "去电呼叫中"
        case .incoming: return "来电"
        case .incomingEnded: return "来电结束"
        }
    }

    /// True when the call has ended and a recording should stop.
    public var isTerminal: Bool {
        self == .droppedInterrupted || self == .incomingEnded
    }
}

public struct CallEvent {
    public let notification: String
    public let state: CallState
    public let activeCallCount: Int32
    public let onlyCall: Bool
    public let address: String?
    public let displayName: String?
    public let uniqueIdentifier: String?
    /// Friendly call type (normal / VoIP / …) when CTCallGetCallType is available.
    public let callType: String?
    /// Direction, when CTCallIsOutgoing is available.
    public let isOutgoing: Bool?
}

/// Call identity kept with a recording, so the library can show who a file belongs to.
public struct CallInfo: Codable, Hashable {
    public let address: String?
    public let name: String?
    public let type: String?
    public let outgoing: Bool?
    public let state: String
}

private typealias TelephonyCenterGetDefaultFn = @convention(c) () -> CFNotificationCenter?
private typealias TelephonyCenterAddObserverFn = @convention(c) (CFNotificationCenter?, UnsafeRawPointer?,
                                                                  CFNotificationCallback?, CFString?,
                                                                  UnsafeRawPointer?,
                                                                  CFNotificationSuspensionBehavior) -> Void
private typealias TelephonyCenterRemoveObserverFn = @convention(c) (CFNotificationCenter?, UnsafeRawPointer?,
                                                                   CFString?, UnsafeRawPointer?) -> Void
private typealias CallGetStatusFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
private typealias CallCopyStringFn = @convention(c) (CFAllocator?, UnsafeMutableRawPointer?) -> CFString?
private typealias CallGetTypeFn = @convention(c) (UnsafeMutableRawPointer?) -> CFString?
private typealias CallIsOutgoingFn = @convention(c) (UnsafeMutableRawPointer?) -> UInt8
private typealias CurrentCallCountFn = @convention(c) () -> Int32

public final class CallWatcher {
    /// Tried in order. The first entry is where CoreTelephony actually lives on iOS.
    private static let candidatePaths = [
        "/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony",
        "/System/Library/PrivateFrameworks/CoreTelephony.framework/CoreTelephony",
    ]

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    /// Resolved framework handle; nil means the symbols came from an already-loaded image.
    private var handle: UnsafeMutableRawPointer?
    private var ownsHandle = false
    private var center: CFNotificationCenter?
    private var addObserver: TelephonyCenterAddObserverFn?
    private var removeObserver: TelephonyCenterRemoveObserverFn?
    private var getStatus: CallGetStatusFn?
    private var copyAddress: CallCopyStringFn?
    private var copyName: CallCopyStringFn?
    private var copyUniqueID: CallCopyStringFn?
    private var currentCallCount: CurrentCallCountFn?
    private var getCallType: CallGetTypeFn?
    private var isOutgoing: CallIsOutgoingFn?
    /// Raw CTCallType value -> readable label, resolved from the framework globals.
    private var callTypeLabels: [String: String] = [:]
    private var onEvent: ((CallEvent) -> Void)?

    /// Human-readable resolution outcome, shown in the UI so a failing device needs no debugger.
    public private(set) var statusDetail = "尚未解析"

    public init() {}

    // MARK: - Symbol resolution

    private static func lookup(_ name: String, in handle: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        if let handle {
            return dlsym(handle, name)
        }
        guard let rtldDefault else { return nil }
        return dlsym(rtldDefault, name)
    }

    /// Opens CoreTelephony, or reports why it could not.
    /// Returns nil when the framework is reachable through an already-loaded image.
    private static func openFramework() -> (handle: UnsafeMutableRawPointer?, detail: String) {
        if visibleInGlobalScope() {
            return (nil, "已加载（dyld 全局作用域）")
        }

        var lastFailure = "没有可用的候选路径"
        for path in candidatePaths {
            guard let candidate = dlopen(path, RTLD_NOW) else {
                if let error = dlerror() {
                    lastFailure = "\(path) 打开失败：\(String(cString: error))"
                } else {
                    lastFailure = "\(path) 打开失败"
                }
                continue
            }
            if dlsym(candidate, "CTTelephonyCenterGetDefault") != nil {
                return (candidate, path)
            }
            lastFailure = "\(path) 已加载但缺少 CTTelephonyCenterGetDefault"
            dlclose(candidate)
        }
        return (nil, lastFailure)
    }

    /// True when the symbols are reachable from an image dyld already loaded.
    private static func visibleInGlobalScope() -> Bool {
        guard let rtldDefault else { return false }
        return dlsym(rtldDefault, "CTTelephonyCenterGetDefault") != nil
    }

    public static var isAvailable: Bool { probe().available }

    /// Full diagnostic string for the UI / log.
    public static func probe() -> (available: Bool, detail: String) {
        let result = openFramework()
        let available = result.handle != nil || visibleInGlobalScope()
        // Only the detail string is kept; observation reopens the framework.
        if let handle = result.handle { dlclose(handle) }
        return (available, result.detail)
    }

    private func symbol<T>(_ name: String, as type: T.Type, in handle: UnsafeMutableRawPointer?) -> T? {
        guard let pointer = Self.lookup(name, in: handle) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    // MARK: - Observation

    @discardableResult
    public func start(handler: @escaping (CallEvent) -> Void) -> Bool {
        guard center == nil else { return true }

        let opened = Self.openFramework()
        handle = opened.handle
        ownsHandle = opened.handle != nil
        statusDetail = opened.detail

        guard let getDefault = symbol("CTTelephonyCenterGetDefault", as: TelephonyCenterGetDefaultFn.self,
                                      in: handle),
              let add = symbol("CTTelephonyCenterAddObserver", as: TelephonyCenterAddObserverFn.self, in: handle) else {
            statusDetail = "\(opened.detail)；缺少 CTTelephonyCenterGetDefault/AddObserver"
            return false
        }
        addObserver = add
        removeObserver = symbol("CTTelephonyCenterRemoveObserver", as: TelephonyCenterRemoveObserverFn.self, in: handle)
        getStatus = symbol("CTCallGetStatus", as: CallGetStatusFn.self, in: handle)
        copyAddress = symbol("CTCallCopyAddress", as: CallCopyStringFn.self, in: handle)
        copyName = symbol("CTCallCopyName", as: CallCopyStringFn.self, in: handle)
        copyUniqueID = symbol("CTCallCopyUniqueStringID", as: CallCopyStringFn.self, in: handle)
        currentCallCount = symbol("CTGetCurrentCallCount", as: CurrentCallCountFn.self, in: handle)
        getCallType = symbol("CTCallGetCallType", as: CallGetTypeFn.self, in: handle)
        isOutgoing = symbol("CTCallIsOutgoing", as: CallIsOutgoingFn.self, in: handle)

        callTypeLabels.removeAll()
        for (name, label) in [("kCTCallTypeNormal", "普通电话"),
                              ("kCTCallTypeVOIP", "网络电话"),
                              ("kCTCallTypeVideoConference", "视频通话"),
                              ("kCTCallTypeVoicemail", "语音信箱")] {
            guard let pointer = Self.lookup(name, in: handle),
                  let value = pointer.assumingMemoryBound(to: CFString?.self).pointee else { continue }
            callTypeLabels[value as String] = label
        }

        guard let statusPointer = Self.lookup("kCTCallStatusChangeNotification", in: handle) else {
            statusDetail = "\(opened.detail)；缺少 kCTCallStatusChangeNotification"
            return false
        }
        let statusNotification = statusPointer.assumingMemoryBound(to: CFString?.self).pointee
        let identificationNotification = Self.lookup("kCTCallIdentificationChangeNotification", in: handle)?
            .assumingMemoryBound(to: CFString?.self).pointee

        guard let telephonyCenter = getDefault() else {
            statusDetail = "\(opened.detail)；CTTelephonyCenterGetDefault() 返回空"
            return false
        }
        center = telephonyCenter
        onEvent = handler

        let observer = Unmanaged.passUnretained(self).toOpaque()
        add(telephonyCenter, observer, CallWatcherCallback, statusNotification, nil,
            CFNotificationSuspensionBehavior.deliverImmediately)
        if let identificationNotification {
            add(telephonyCenter, observer, CallWatcherCallback, identificationNotification, nil,
                CFNotificationSuspensionBehavior.deliverImmediately)
        }
        statusDetail = "\(opened.detail)；已注册观察者"
        return true
    }

    /// Number of calls CoreTelephony reports right now, or nil when the symbol is absent.
    ///
    /// This is the watchdog source: on 2026-10-17 a call that CallKit had already ended
    /// at 18:53:35 (CXCallObserver reported it) produced no terminal CoreTelephony
    /// notification at all, so the recording ran on until it was stopped by hand 33 s
    /// later. Notification delivery is not guaranteed, the live call count is.
    public func liveCallCount() -> Int32? {
        guard center != nil else { return nil }
        return currentCallCount?()
    }

    fileprivate func dispatch(name: CFNotificationName?, call: UnsafeMutableRawPointer?, payload: CFDictionary?) {
        // CFDictionary is toll-free bridged; go through AnyObject so the cast is unambiguous.
        let dictionary: [String: Any]? = {
            guard let payload else { return nil }
            let object: AnyObject = payload as AnyObject
            return object as? [String: Any]
        }()

        // CTCallGetStatus is authoritative when available, but some events carry the
        // status only in the notification payload.
        var state = CallState.unknown
        if let getStatus, let call {
            state = CallState(rawValue: getStatus(call)) ?? .unknown
        }
        if let rawStatus = dictionary?["kCTCallStatus"] as? Int, let payloadState = CallState(rawValue: Int32(rawStatus)) {
            state = payloadState
        }

        func string(_ converter: CallCopyStringFn?) -> String? {
            guard let converter, let call, let copied = converter(nil, call) else { return nil }
            return copied as String
        }

        let onlyCall = (dictionary?["kCTCallIsTheOnlyCall"] as? Bool) ?? true
        let rawType = (call.flatMap { getCallType?($0) }).map { $0 as String }
        let event = CallEvent(notification: name.map { $0.rawValue as String } ?? "",
                              state: state,
                              activeCallCount: currentCallCount?() ?? 0,
                              onlyCall: onlyCall,
                              address: string(copyAddress),
                              displayName: string(copyName),
                              uniqueIdentifier: string(copyUniqueID),
                              callType: rawType.map { callTypeLabels[$0] ?? $0 },
                              isOutgoing: call.flatMap { isOutgoing?($0) }.map { $0 != 0 })
        onEvent?(event)
    }

    public func stop() {
        if let center, let removeObserver {
            removeObserver(center, Unmanaged.passUnretained(self).toOpaque(), nil, nil)
        }
        center = nil
        onEvent = nil
        if ownsHandle, let handle { dlclose(handle) }
        handle = nil
        ownsHandle = false
    }

    deinit { stop() }
}

private let CallWatcherCallback: CFNotificationCallback = { _, observer, name, object, payload in
    guard let observer else { return }
    let watcher = Unmanaged<CallWatcher>.fromOpaque(observer).takeUnretainedValue()
    watcher.dispatch(name: name,
                     call: UnsafeMutableRawPointer(mutating: object),
                     payload: payload)
}
