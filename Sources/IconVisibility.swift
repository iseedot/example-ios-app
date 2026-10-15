//
//  IconVisibility.swift
//  MyCallRec — best-effort home screen icon visibility.
//
//  The analyzed target's own TrollStore build carries
//  com.apple.springboard.iconState and com.apple.springboard.iconState.mutate, which means
//  a TrollStore app can hide its own icon without jailbreak injection. The exact entry
//  point is not documented; this implementation tries the known candidates in order and
//  reports every step, so a failed attempt is diagnosable rather than silent.
//
//  Nothing here can lock the user out: the app registers a mycallrec:// URL scheme and
//  TrollStore can always launch an installed app from its list.
//

import Foundation
import Darwin
import ObjectiveC

private typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
private typealias InitHandleFn = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
private typealias SetVisibilityFn = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
private typealias ConnectionInitFn = @convention(c) (AnyObject, Selector, AnyObject, UInt) -> AnyObject?

enum IconVisibility {
    private static let machServiceCandidates = [
        "com.apple.springboard.iconState",
        "com.apple.springboard.services",
    ]

    private static let frameworkCandidates = [
        "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
        "/System/Library/PrivateFrameworks/SpringBoardUI.framework/SpringBoardUI",
        "/System/Library/PrivateFrameworks/SpringBoardFoundation.framework/SpringBoardFoundation",
    ]

    /// Sets this app's icon visibility. Returns a human-readable outcome for the log.
    @discardableResult
    static func setVisible(_ visible: Bool, bundleIdentifier: String) -> String {
        for path in frameworkCandidates {
            if dlopen(path, RTLD_NOW) != nil {
                trlog(.debug, "ICON", "已加载 \(path)")
            }
        }

        guard let serviceClass = NSClassFromString("SBIconVisibilityService") else {
            return "SBIconVisibilityService 在本进程不可见（无注入环境），未改动图标"
        }
        trlog(.info, "ICON", "找到 SBIconVisibilityService，尝试建立连接")

        guard let allocIMP = class_getClassMethod(serviceClass, NSSelectorFromString("alloc"))
            .map(method_getImplementation) else {
            return "SBIconVisibilityService 缺少 alloc"
        }
        let allocate = unsafeBitCast(allocIMP, to: AllocFn.self)
        guard let allocated = allocate(serviceClass, NSSelectorFromString("alloc")) else {
            return "SBIconVisibilityService 分配失败"
        }

        guard let initIMP = class_getInstanceMethod(serviceClass, NSSelectorFromString("initWithProcessHandle:"))
            .map(method_getImplementation) else {
            return "SBIconVisibilityService 缺少 initWithProcessHandle:"
        }
        let initialize = unsafeBitCast(initIMP, to: InitHandleFn.self)

        guard let setIMP = class_getInstanceMethod(serviceClass,
                                                   NSSelectorFromString("setIconVisibility:forApplicationWithBundleIdentifier:"))
            .map(method_getImplementation) else {
            return "SBIconVisibilityService 缺少 setIconVisibility:forApplicationWithBundleIdentifier:"
        }
        let setVisibility = unsafeBitCast(setIMP, to: SetVisibilityFn.self)

        // Swift marks -[NSXPCConnection initWithMachServiceName:options:] unavailable on iOS
        // because NSXPCConnectionOptions is macOS-only, so the selector is invoked directly.
        guard let connectionAllocIMP = class_getClassMethod(NSXPCConnection.self,
                                                            NSSelectorFromString("alloc"))
                .map(method_getImplementation),
              let connectionInitIMP = class_getInstanceMethod(NSXPCConnection.self,
                                                              NSSelectorFromString("initWithMachServiceName:options:"))
                .map(method_getImplementation) else {
            return "NSXPCConnection 缺少 mach 服务初始化器"
        }
        let allocateConnection = unsafeBitCast(connectionAllocIMP, to: AllocFn.self)
        let initConnection = unsafeBitCast(connectionInitIMP, to: ConnectionInitFn.self)

        var attempts: [String] = []
        for name in machServiceCandidates {
            guard let allocatedConnection = allocateConnection(NSXPCConnection.self, NSSelectorFromString("alloc")),
                  let connection = initConnection(allocatedConnection,
                                                  NSSelectorFromString("initWithMachServiceName:options:"),
                                                  name as NSString, 0) as? NSXPCConnection else {
                attempts.append("\(name): 连接创建失败")
                continue
            }
            connection.resume()
            guard let service = initialize(allocated, NSSelectorFromString("initWithProcessHandle:"),
                                           connection) else {
                attempts.append("\(name): 初始化失败")
                connection.invalidate()
                continue
            }
            setVisibility(service, NSSelectorFromString("setIconVisibility:forApplicationWithBundleIdentifier:"),
                          visible, bundleIdentifier as NSString)
            attempts.append("\(name): 已发送可见性=\(visible)")
            trlog(.info, "ICON", "图标可见性请求已发送（\(name)，visible=\(visible)）")
            return attempts.joined(separator: "；")
        }
        return "所有 mach 服务均不可用：" + attempts.joined(separator: "；")
    }
}
