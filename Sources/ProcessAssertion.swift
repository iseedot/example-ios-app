//
//  ProcessAssertion.swift
//  MyCallRec — keep the process alive with a background assertion instead of audio.
//
//  Background, from the reverse engineering: the analysed target does not play audio to stay
//  alive. Its jailbreak build runs TRCallMonitor as a LaunchDaemon with KeepAlive; its
//  TrollStore build carries com.apple.multitasking.systemappassertions (plus
//  com.apple.assertiond.app-state-monitor and com.apple.private.kernel.jetsam) and its
//  LaunchPad widget relaunches the app through
//  SBSLaunchApplicationWithIdentifierAndLaunchOptions.
//
//  A background process assertion is the efficient form of the first mechanism: it tells the
//  system "do not suspend this process" without keeping the audio hardware awake, so the
//  phone no longer has to play a silent loop. BKSProcessAssertion is private, so it is
//  reached through the Objective-C runtime; if anything is missing the caller falls back to
//  the near-silent audio loop.
//

import Foundation
import ObjectiveC

final class ProcessAssertion {
    /// BKSProcessAssertionFlags
    private let preventSuspend: UInt32 = 1
    /// BKSProcessAssertionReason
    private let reasonBackgroundUI: Int32 = 2
    private let assertionName = "com.example.mycallrec.keepalive"

    private typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
    private typealias InitFn = @convention(c) (AnyObject, Selector, Int32, UInt32, Int32, AnyObject?) -> AnyObject?
    private typealias VoidFn = @convention(c) (AnyObject, Selector) -> Void

    private var assertion: AnyObject?
    private(set) var statusDetail = "未启用"

    /// Returns true when an assertion was created and acquired.
    @discardableResult
    func acquire() -> Bool {
        guard assertion == nil else { return true }
        guard let cls = NSClassFromString("BKSProcessAssertion") else {
            statusDetail = "BKSProcessAssertion 不可用"
            return false
        }
        let initSelector = NSSelectorFromString("initWithPID:flags:reason:name:")
        guard let allocIMP = class_getClassMethod(cls, NSSelectorFromString("alloc")).map(method_getImplementation),
              let initIMP = class_getInstanceMethod(cls, initSelector).map(method_getImplementation),
              let acquireIMP = class_getInstanceMethod(cls, NSSelectorFromString("acquire")).map(method_getImplementation) else {
            statusDetail = "BKSProcessAssertion 缺少初始化器或 acquire"
            return false
        }

        let allocate = unsafeBitCast(allocIMP, to: AllocFn.self)
        let initialize = unsafeBitCast(initIMP, to: InitFn.self)
        guard let allocated = allocate(cls, NSSelectorFromString("alloc")),
              let created = initialize(allocated, initSelector, getpid(), preventSuspend,
                                       reasonBackgroundUI, assertionName as NSString) else {
            statusDetail = "BKSProcessAssertion 创建失败"
            return false
        }

        unsafeBitCast(acquireIMP, to: VoidFn.self)(created, NSSelectorFromString("acquire"))
        assertion = created
        statusDetail = "已持有 BKSProcessAssertion（PreventSuspend）"
        trlog(.info, "APP", "后台保活：进程断言已获取（不需要播放音频）")
        return true
    }

    func release() {
        guard let assertion else { return }
        if let imp = class_getInstanceMethod(object_getClass(assertion),
                                             NSSelectorFromString("invalidate")).map(method_getImplementation) {
            unsafeBitCast(imp, to: VoidFn.self)(assertion, NSSelectorFromString("invalidate"))
        }
        self.assertion = nil
        statusDetail = "已释放"
        trlog(.info, "APP", "后台保活：进程断言已释放")
    }
}
