//
//  CallWatcher.swift
//  callrec — Phase 1 proof of concept, Swift implementation.
//
//  Observes telephone call state with the CoreTelephony notification centre. The
//  private symbols are resolved with dlsym, so no private headers are required.
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
}

public struct CallEvent {
    public let notification: String
    public let state: CallState
    public let activeCallCount: Int32
    public let address: String?
    public let displayName: String?
    public let uniqueIdentifier: String?
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
private typealias CurrentCallCountFn = @convention(c) () -> Int32

public final class CallWatcher {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/CoreTelephony.framework/CoreTelephony"

    private var handle: UnsafeMutableRawPointer?
    private var center: CFNotificationCenter?
    private var addObserver: TelephonyCenterAddObserverFn?
    private var removeObserver: TelephonyCenterRemoveObserverFn?
    private var getStatus: CallGetStatusFn?
    private var copyAddress: CallCopyStringFn?
    private var copyName: CallCopyStringFn?
    private var copyUniqueID: CallCopyStringFn?
    private var currentCallCount: CurrentCallCountFn?
    private var onEvent: ((CallEvent) -> Void)?

    public static var isAvailable: Bool {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        return dlsym(handle, "CTTelephonyCenterGetDefault") != nil
            && dlsym(handle, "CTTelephonyCenterAddObserver") != nil
            && dlsym(handle, "kCTCallStatusChangeNotification") != nil
    }

    public init() {}

    private func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    public func start(handler: @escaping (CallEvent) -> Void) -> Bool {
        guard center == nil else { return true }
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else { return false }
        self.handle = handle

        guard let getDefault = symbol("CTTelephonyCenterGetDefault", as: TelephonyCenterGetDefaultFn.self),
              let add = symbol("CTTelephonyCenterAddObserver", as: TelephonyCenterAddObserverFn.self) else {
            return false
        }
        addObserver = add
        removeObserver = symbol("CTTelephonyCenterRemoveObserver", as: TelephonyCenterRemoveObserverFn.self)
        getStatus = symbol("CTCallGetStatus", as: CallGetStatusFn.self)
        copyAddress = symbol("CTCallCopyAddress", as: CallCopyStringFn.self)
        copyName = symbol("CTCallCopyName", as: CallCopyStringFn.self)
        copyUniqueID = symbol("CTCallCopyUniqueStringID", as: CallCopyStringFn.self)
        currentCallCount = symbol("CTGetCurrentCallCount", as: CurrentCallCountFn.self)

        guard let statusPointer = dlsym(handle, "kCTCallStatusChangeNotification") else { return false }
        let statusNotification = statusPointer.assumingMemoryBound(to: CFString?.self).pointee
        let identificationPointer = dlsym(handle, "kCTCallIdentificationChangeNotification")
        let identificationNotification = identificationPointer?.assumingMemoryBound(to: CFString?.self).pointee

        guard let telephonyCenter = getDefault() else { return false }
        center = telephonyCenter
        onEvent = handler

        let observer = Unmanaged.passUnretained(self).toOpaque()
        add(telephonyCenter, observer, CallWatcherCallback, statusNotification, nil,
            CFNotificationSuspensionBehavior.deliverImmediately)
        if let identificationNotification {
            add(telephonyCenter, observer, CallWatcherCallback, identificationNotification, nil,
                CFNotificationSuspensionBehavior.deliverImmediately)
        }
        return true
    }

    fileprivate func dispatch(name: CFNotificationName?, call: UnsafeMutableRawPointer?) {
        // CTCallCopy* take an allocator as their first argument; NULL means "use the default".
        func string(_ converter: CallCopyStringFn?) -> String? {
            guard let converter, let call, let copied = converter(nil, call) else { return nil }
            return copied as String
        }

        var state = CallState.unknown
        if let getStatus, let call {
            state = CallState(rawValue: getStatus(call)) ?? .unknown
        }

        let event = CallEvent(notification: name.map { $0.rawValue as String } ?? "",
                              state: state,
                              activeCallCount: currentCallCount?() ?? 0,
                              address: string(copyAddress),
                              displayName: string(copyName),
                              uniqueIdentifier: string(copyUniqueID))
        onEvent?(event)
    }

    public func stop() {
        if let center, let removeObserver {
            removeObserver(center, Unmanaged.passUnretained(self).toOpaque(), nil, nil)
        }
        center = nil
        onEvent = nil
        if let handle { dlclose(handle) }
        handle = nil
    }

    deinit { stop() }
}

private let CallWatcherCallback: CFNotificationCallback = { _, observer, name, object, _ in
    guard let observer else { return }
    let watcher = Unmanaged<CallWatcher>.fromOpaque(observer).takeUnretainedValue()
    watcher.dispatch(name: name, call: UnsafeMutableRawPointer(mutating: object))
}
