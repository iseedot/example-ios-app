//
//  NowPlayingWatcher.swift
//  MyCallRec — identify the app that is producing audio right now.
//
//  Why this exists (from the REA decompilation)
//  --------------------------------------------
//  The analysed daemon does NOT enumerate CoreAudio HAL process objects: none of its
//  binaries imports AudioObjectGetPropertyData or the 'prco' selector (checked across
//  TRApp / TRCallMonitor / TRCallRecorder / TRAudioRecorder / TRRealtimeRecorder).
//
//  It identifies the client to tap with MediaRemote's "now playing application"
//  notifications instead. The strings and imports of TRCallMonitor name:
//
//    _MRMediaRemoteSetWantsNowPlayingNotifications
//    _kMRMediaRemoteNowPlayingApplicationDidChangeNotification
//    _kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification
//    setupMediaRemoteObservers / systemAudioNowPlayingAppDidChange: /
//    handleSystemAudioNowPlayingAppDidChange: / mLastReportedNowPlayingApplicationIdentifier
//
//  and it keeps a small set of "audio tracks" (ActiveAudioTracks / PrimaryAudioTrack /
//  currentAudioTrack / otherAudioTracks) whose attribute keys carry the bundle
//  identifier (_TRAudioTrackAttributeKeyBundleIdentifier). It then resolves that bundle
//  identifier / pid and taps it (populateCallAttributes:applicationState:recordingClientPIDs:).
//
//  MyCallRec used to locate the pid only from a configured Bundle ID by scanning the
//  process table. This adds the same now-playing source, so a WeChat (or other VoIP) call
//  can be identified from the audio it is producing without the user configuring
//  anything. The framework is private and resolved with dlsym, so the build still links
//  against the public SDK only.
//
//  Everything here is best-effort: if MediaRemote cannot be loaded or the notification
//  payload has no pid, the watcher reports why and stays out of the way, and the existing
//  Bundle ID lookup keeps working.
//

import Foundation
import CoreFoundation
import Darwin

private typealias SetWantsNowPlayingNotificationsFn = @convention(c) (UInt8) -> Void

final class NowPlayingWatcher {
    struct Client: Equatable {
        let pid: Int32
        let bundleIdentifier: String
        let displayName: String
        let isPlaying: Bool
    }

    /// Called on the main queue whenever the now-playing client changes. nil means the
    /// now-playing app stopped.
    var onClientChanged: ((Client?) -> Void)?

    private(set) var statusDetail = "尚未启动"

    private static let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

    private var handle: UnsafeMutableRawPointer?
    private var setWants: SetWantsNowPlayingNotificationsFn?
    private var tokens: [NSObjectProtocol] = []
    private var current: Client?
    private var lastEmitted: Client?
    private var loggedKeys = false

    private func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let raw = dlsym(handle, name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }

    private func stringSymbol(_ name: String) -> String? {
        guard let handle, let raw = dlsym(handle, name) else { return nil }
        guard let value = raw.assumingMemoryBound(to: CFString?.self).pointee else { return nil }
        return value as String
    }

    @discardableResult
    func start() -> Bool {
        guard tokens.isEmpty else { return true }
        handle = dlopen(Self.frameworkPath, RTLD_NOW)
        guard handle != nil else {
            statusDetail = "MediaRemote 无法加载"
            trlog(.warn, "APP", "MediaRemote 加载失败，回退到 Bundle ID 匹配：\(statusDetail)")
            return false
        }
        setWants = symbol("MRMediaRemoteSetWantsNowPlayingNotifications",
                          as: SetWantsNowPlayingNotificationsFn.self)
        setWants?(1)

        let change = stringSymbol("kMRMediaRemoteNowPlayingApplicationDidChangeNotification")
        let playing = stringSymbol("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")

        let center = NotificationCenter.default
        for value in [change, playing].compactMap({ $0 }) {
            tokens.append(center.addObserver(forName: Notification.Name(rawValue: value),
                                            object: nil, queue: .main) { [weak self] note in
                self?.handle(note)
            })
        }

        statusDetail = "已订阅 MediaRemote 正在播放通知"
        trlog(.info, "APP", "MediaRemote 正在播放监听已启动（\(change ?? "无 change 名称")，"
              + "\(playing ?? "无 playing 名称")）")
        return true
    }

    func stop() {
        guard !tokens.isEmpty || handle != nil else { return }
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        setWants?(0)
        handle = nil
        current = nil
        statusDetail = "已停止"
        trlog(.info, "APP", "MediaRemote 正在播放监听已停止")
    }

    private func handle(_ note: Notification) {
        guard let client = client(from: note) else { return }
        if client != current {
            current = client
            trlog(.info, "APP", "正在播放音频的 App：\(client.displayName) [\(client.bundleIdentifier)] "
                  + "pid \(client.pid) playing=\(client.isPlaying)")
        }
        // MediaRemote can repeat the same payload; only report an actual change so the UI
        // and the evaluator are not re-run for nothing.
        let emitted = client.isPlaying ? client : nil
        guard emitted != lastEmitted else { return }
        lastEmitted = emitted
        onClientChanged?(emitted)
    }

    /// Pulls a client out of the notification payload. MediaRemote puts the pid, the
    /// bundle identifier and the display name in the userInfo under keys whose names
    /// contain PID / DisplayID / Bundle / DisplayName. Reading them by substring keeps
    /// this working across the slightly different key sets of different iOS builds, and a
    /// bundle identifier without a pid is resolved through the process table.
    private func client(from note: Notification) -> Client? {
        let info = note.userInfo ?? [:]
        var pid: Int32?
        var bundle = ""
        var display = ""
        var playing = true

        for (rawKey, rawValue) in info {
            let key = (rawKey as? String) ?? String(describing: rawKey)
            if key.contains("PID"), let number = rawValue as? NSNumber {
                pid = number.int32Value
            } else if key.contains("IsPlaying"), let number = rawValue as? NSNumber {
                playing = number.boolValue
            } else if key.contains("DisplayID") || key.contains("BundleIdentifier") {
                if let text = rawValue as? String { bundle = text }
            } else if key.contains("DisplayName") {
                if let text = rawValue as? String { display = text }
            }
        }
        if !loggedKeys, !info.isEmpty {
            loggedKeys = true
            let pairs = info.map { "\($0.key)=\(String(describing: $0.value))" }.sorted()
            trlog(.info, "APP", "MediaRemote 通知 userInfo：\(pairs.joined(separator: ", "))")
        }

        if pid == nil, !bundle.isEmpty {
            pid = AppProcessFinder.pid(forBundleIdentifier: bundle)
        }
        guard let pid, pid > 0 else { return nil }

        let name = display.isEmpty ? (bundle.isEmpty ? "pid \(pid)" : bundle) : display
        return Client(pid: pid,
                      bundleIdentifier: bundle.isEmpty ? "未知 Bundle ID" : bundle,
                      displayName: name,
                      isPlaying: playing)
    }
}
