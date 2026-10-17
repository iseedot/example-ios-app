//
//  MyCallRecApp.swift
//  MyCallRec — self-built call recorder, Phase 1 test harness.
//
//  Recording can start from four sources:
//    * the volume-button combo (start/stop, vibration feedback, no on-screen hint)
//    * an answered telephone call (CoreTelephony)
//    * an application that is running input audio, for example WeChat
//    * the manual button
//
//  The recorder runs while any source is active and stops when the last one ends.
//
//  Target selection is automatic by default: a call is recorded from the call audio
//  (the tapped app for a VoIP call, the system mix for a telephony call) and everything
//  else from the microphone. A manual target overrides that only while no call is up.
//

import SwiftUI
import UIKit
import AVFoundation
import AVFAudio

@main
struct MyCallRecApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Storage first: the container's Documents directory turned out to be unusable
        // on this install, and the run log, the crash record and the recordings all
        // depend on which directory is chosen.
        Storage.resolve()
        Log.shared.start()
        // Mark the session before anything is logged, so the start-up lines below stay
        // in this session instead of being wiped when the model is created.
        Log.shared.markSessionStart()
        // Crash handlers next: everything after this point is diagnosable even if a
        // private API raises an exception.
        CrashGuard.install()
        AppModel.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}

enum TargetChoice: String, CaseIterable, Identifiable {
    /// The default. Pick the source from what is going on: a call is recorded from the
    /// call audio, everything else from the microphone. No manual choice to keep in sync.
    case auto = "自动（通话→通话音频 / 空闲→麦克风）"
    case microphone = "麦克风"
    case systemAudio = "系统音频"
    case speaker = "扬声器"
    case appProcess = "应用进程"
    case process = "指定 PID"

    var id: String { rawValue }
}

enum RecordTrigger: String {
    case manual = "手动"
    case volumeKey = "物理按键"
    case call = "通话"
    case app = "应用音频"
}

@MainActor
final class AppModel: ObservableObject {
    @Published var logLines: [String] = []
    @Published var isRecording = false
    @Published var currentFile: String = "-"
    @Published var elapsed: Double = 0
    @Published var packets: UInt64 = 0
    @Published var peak: Float = 0
    @Published var maxPeak: Float = 0

    @Published var targetChoice: TargetChoice = .auto
    @Published var customPID: String = ""
    @Published var callStateText: String = "无"
    @Published var coreTelephonyStatus: String = "未检测"
    @Published var tapAvailability: String = "未检测"
    @Published var audioProcessStatus: String = "未检测"
    @Published var appAudioStatus: String = "未安装"
    @Published var nowPlayingStatus: String = "未监听"
    @Published var audioProcesses: [AudioProcessInfo] = []
    @Published var keyStatus: String = "未启用"

    @Published var watchCalls = true
    @Published var watchApps = true
    @Published var watchVolumeKeys = true
    /// Activating a play-and-record session can disturb the app whose audio we tap,
    /// so it is switchable: with the tap entitlements a session is not required.
    @Published var activatesAudioSession = true
    /// Keeps a silent audio session busy so the app is not suspended while another app is
    /// in the foreground. Without it the triggers cannot fire in the background at all.
    @Published var keepAliveInBackground = true
    @Published var hideIcon = false
    /// On by default: the real HID key events. Off is the escape hatch if a build's
    /// private event system misbehaves; the volume sampler still works without it.
    @Published var useHIDKeyEvents = true
    /// Off by default: the off-screen MPVolumeView that suppresses the HUD can take the
    /// volume buttons over on some builds, which stops the trigger working at all.
    @Published var keySuppressesHUD = false
    @Published var watchedBundleIDs = "com.tencent.xin"

    let library = RecordingLibrary()

    private var recorder: TapRecorder?
    private var watcher: CallWatcher?
    private var audioUseWatcher: AudioUseWatcher?
    /// MediaRemote now-playing source, mirroring the analysed daemon's MediaRemote observers.
    private var nowPlayingWatcher: NowPlayingWatcher?
    private var nowPlayingClient: NowPlayingWatcher.Client?
    /// The shared gesture state machine, fed by both key-event sources.
    private let keyDetector = KeyComboDetector()
    private var hidMonitor: HIDKeyMonitor?
    private var volumeMonitor: VolumeKeyMonitor?
    private var keepAlive: BackgroundKeepAlive?
    private var ticker: Timer?
    /// Guards `startEnabledTriggers`: the view calls it on every appearance.
    private var triggersStarted = false

    // Which sources currently want a recording.
    private var manualWants = false
    private var callWants = false
    private var appWants = false
    private var appWantedPID: Int32?
    /// Set while a non-telephony (CallKit / VoIP) call is up, so the default target knows
    /// to take the call audio rather than the microphone.
    private var voipCallActive = false
    /// The audio-use signals currently accepted, so one ending does not clear the source
    /// while another (e.g. CallKit) is still up.
    private var activeAudioUseSignals: Set<String> = []
    /// How the current manual recording started, for the log and the metadata sidecar.
    private var manualTrigger: RecordTrigger = .manual
    /// Set once the source has changed mid-recording, to avoid restart loops.
    private var recordingTargetSnapshot: TapTarget?
    /// The trigger that started the current recording, for the log and the sidecar.
    private var runningTriggerSnapshot: RecordTrigger = .manual
    /// Call metadata captured with the recording, written to the sidecar on stop.
    private var activeCallInfo: CallInfo?
    /// Most recent call event, so a recording started later still carries the call it is for.
    private var latestCall: CallInfo?
    /// Set when the volume key stopped a recording: auto sources stay muted
    /// until they have all gone inactive once.
    private var autoMutedUntilSourcesEnd = false
    private var appIdleTicks = 0
    private var tickCount = 0
    private var lastLoggedSecond = -1
    /// Process list as last written to the log, so an unchanged list is not repeated.
    private var lastProcessSummary = ""

    init() {
        Log.shared.onAppend = { [weak self] line in
            guard let self else { return }
            self.logLines.insert(line, at: 0)
            if self.logLines.count > 400 { self.logLines.removeLast(self.logLines.count - 400) }
        }
        // Seed from the lines written before this model existed: storage resolution and
        // the audio session are logged from the app's init.
        logLines = Log.shared.lines

        trlog(.info, "APP", "日志文件：\(Log.shared.logFileURL?.path ?? "不可用")")
        if let openError = Log.shared.openError {
            trlog(.error, "APP", "日志文件不可写：\(openError)")
        }
        for line in Storage.resolutionLog {
            trlog(.info, "APP", "存储：\(line)")
        }
        trlog(.info, "APP", "录音目录：\(Storage.recordingsDirectory.path)")

        // A previous run that died leaves its reason on disk; surface it as the first
        // lines of this session so "复制全部日志" carries it without the Files app.
        if let previousCrash = CrashGuard.consumePreviousCrash() {
            trlog(.error, "CRASH", "===== 上次运行崩溃，记录如下 =====")
            for line in previousCrash.split(separator: "\n", omittingEmptySubsequences: false) {
                trlog(.error, "CRASH", String(line))
            }
            trlog(.error, "CRASH", "===== 崩溃记录结束 =====")
        }

        tapAvailability = (NSClassFromString("ATAudioTap") != nil && NSClassFromString("ATAudioTapDescription") != nil)
            ? "可用" : "不可用（缺少私有类）"

        let probe = CallWatcher.probe()
        coreTelephonyStatus = probe.available ? "可用（\(probe.detail)）" : "不可用（\(probe.detail)）"
        audioProcessStatus = AudioProcessProbe.isAvailable ? "探测中" : "不可用（AudioObjectGetPropertyData 未找到）"

        trlog(.info, "APP", "MyCallRec 启动；私有 tap \(tapAvailability)；激活音频会话=\(activatesAudioSession)")
        trlog(.info, "CT", "CoreTelephony \(coreTelephonyStatus)")
        trlog(.info, "AUDIO", "CoreAudio 进程对象 API：\(audioProcessStatus)")

        // Entitlements are the first thing to check when a tap or a key does nothing, and
        // "复制全部日志" is the easiest way to get them off the device.
        let entitlements = Diagnostics.entitlementReport()
        var missing: [String] = []
        for key in Diagnostics.expectedEntitlements {
            let value = entitlements[key] ?? "未知"
            if value == "缺失" { missing.append(key) }
            trlog(.info, "ENT", "\(key) = \(value)")
        }
        trlog(.info, "ENT", "缺失 \(missing.count)/\(Diagnostics.expectedEntitlements.count)："
              + (missing.isEmpty ? "无" : missing.joined(separator: ", ")))

        refreshAudioProcesses()
        startTicker()
    }

    /// Installs every trigger whose switch is on.
    ///
    /// The switches default to on, so this must run at launch: previously only the
    /// toggle's setter called the installers, which left the UI showing "on" with
    /// nothing actually installed — the log showed no "通话监听已启动" and no
    /// "音量键监听已启动" line, and no trigger could ever fire.
    ///
    /// The volume-key monitor needs a key window for its hidden MPVolumeView, so the
    /// view calls this from `onAppear` rather than from `init`.
    func startEnabledTriggers() {
        guard !triggersStarted else {
            volumeMonitor?.retryVolumeViewIfNeeded()
            return
        }
        triggersStarted = true
        trlog(.info, "APP", "装配触发源：通话=\(watchCalls) 应用=\(watchApps) 音量键=\(watchVolumeKeys)")

        if watchCalls { startCallWatcher() }
        if watchApps { startAudioUseWatcher(); startNowPlayingWatcher() }
        if watchVolumeKeys { installKeyMonitor() }
        updateKeepAlive()
    }

    static func configureAudioSession(activate: Bool = true) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            if activate {
                try session.setActive(true)
                trlog(.info, "AUDIO", "音频会话已激活：\(session.category.rawValue)")
            } else {
                // Rely on com.apple.coreaudio.CanRecordWithoutSessionActivation instead.
                // Deactivate as well: an active play-and-record session coexists with
                // the tap queue, and this switch is the lever if the tap refuses to
                // build while the session is up.
                try? session.setActive(false, options: [.notifyOthersOnDeactivation])
                trlog(.info, "AUDIO", "音频会话已停用（仅设置分类），避免影响被录音的应用")
            }
        } catch {
            trlog(.error, "AUDIO", "音频会话配置失败：\(error)")
        }
    }

    // MARK: - Audio processes

    /// Bundle identifiers the application-audio trigger watches.
    var watchedIdentifiers: [String] {
        watchedBundleIDs
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Refreshes the pid list shown in the UI. The HAL probe reports its own failure
    /// once; afterwards this stays at debug level so the three-second ticker cannot
    /// flood the log.
    func refreshAudioProcesses() {
        let probed = AudioProcessProbe.processes()
        audioProcessStatus = AudioProcessProbe.statusDescription
        if !probed.isEmpty {
            audioProcesses = probed
            // Only log when the list actually changes: this runs every few seconds.
            let summary = AudioProcessProbe.describe(probed)
            if summary != lastProcessSummary {
                lastProcessSummary = summary
                trlog(.info, "AUDIO", "音频进程 \(probed.count) 个：\(summary)")
            }
            return
        }
        // Fallback: the HAL probe cannot enumerate here, so the sysctl listing still
        // gives a usable PID list for manual selection and for the tap target.
        let entries = ProcessList.interesting(from: ProcessList.running())
        audioProcesses = entries.map {
            AudioProcessInfo(objectID: 0, pid: $0.pid, bundleIdentifier: $0.name,
                             isRunning: true, isRunningInput: false, isRunningOutput: false)
        }
        let summary = entries.map { "\($0.pid):\($0.name)" }.joined(separator: " ")
        if summary != lastProcessSummary {
            lastProcessSummary = summary
            trlog(.info, "AUDIO", "sysctl 候选 \(entries.count) 个：\(summary)")
        }
    }

    /// pid of the first watched application that is running, or nil.
    private func watchedAppPID() -> Int32? {
        for identifier in watchedIdentifiers {
            if let pid = AppProcessFinder.pid(forBundleIdentifier: identifier) { return pid }
        }
        return nil
    }

    // MARK: - Recording control

    /// The manually chosen target, or nil when the choice is "automatic".
    var manualTarget: TapTarget? {
        switch targetChoice {
        case .auto: return nil
        case .microphone: return .microphone
        case .systemAudio: return .systemAudio
        case .speaker: return .speaker
        case .process:
            guard let pid = Int32(customPID.trimmingCharacters(in: .whitespaces)), pid > 0 else { return nil }
            return .process(pid)
        case .appProcess:
            guard let info = audioProcesses.first(where: { $0.isRunningInput }) else { return nil }
            return .process(info.pid)
        }
    }

    /// True while any kind of call is up: a telephony call seen by CoreTelephony, or a
    /// CallKit/VoIP call seen by AudioUseWatcher (WeChat and friends).
    var callActive: Bool { callWants || voipCallActive }

    /// The target the next recording should use. This is the default rule the app is
    /// meant to follow:
    ///   * a call is up          -> the call audio (the tapped app for a VoIP call, the
    ///                              system mix for a telephony call)
    ///   * no call               -> the microphone
    /// A manual choice (targetChoice != .auto) only applies when no call is up, so
    /// "automatic" behaves the way a call recorder is expected to.
    func effectiveTarget() -> TapTarget {
        if appWants {
            // A watched app is up: tap its own audio, which is where the call audio lives.
            if let pid = appWantedPID { return .process(pid) }
            // The signal came from somewhere we could not resolve; the system mix is a
            // better guess than the microphone.
            return .systemAudio
        }
        if callActive { return .systemAudio }
        if let manual = manualTarget { return manual }
        return .microphone
    }

    private func startRecording(prefix: String, target: TapTarget, trigger: RecordTrigger) {
        guard recorder == nil else {
            trlog(.info, "REC", "已在录音中，忽略来自「\(trigger.rawValue)」的启动请求")
            return
        }
        let url = library.newRecordingURL(prefix: prefix)
        do {
            // The microphone sentinel is mono upstream (cli/call-recorder.mm); the call and
            // system taps are stereo. Asking for stereo from the microphone tap can come
            // back empty on some builds.
            let channels: UInt32 = target == .microphone ? 1 : 2
            let created = try TapRecorder(target: target, sampleRate: 44100, channels: channels, fileURL: url)
            try created.start()
            recorder = created
            isRecording = true
            elapsed = 0
            packets = 0
            peak = 0
            maxPeak = 0
            lastLoggedSecond = -1
            currentFile = url.lastPathComponent
            recordingTargetSnapshot = target
            runningTriggerSnapshot = trigger
            activeCallInfo = latestCall
            trlog(.info, "REC", "开始录音（\(trigger.rawValue)）target=\(target.label) 声道=\(channels)")
            trlog(.info, "REC", "文件：\(url.path)")
        } catch {
            trlog(.error, "REC", "开始录音失败（\(trigger.rawValue)）：\(error)")
            recorder = nil
            isRecording = false
            if trigger == .volumeKey { VolumeKeyMonitor.feedback(pulses: 3) }
        }
    }

    private func stopRecording(reason: String) {
        guard let running = recorder else { return }
        running.stop()
        trlog(.info, "REC", String(format: "停止录音（%@）：%.2f 秒 / %llu 包 / 峰值 %.3f",
                                   reason, running.secondsRecorded, running.packetsWritten,
                                   running.maxPeakAmplitude))
        if running.packetsWritten == 0 {
            trlog(.error, "REC", "0 个音频包：多为权限不足或目标无音频（receivedFirstBuffer=\(running.receivedFirstBuffer)）")
        } else if running.maxPeakAmplitude < 0.0005 {
            trlog(.warn, "REC", "全程近乎静音（峰值 \(running.maxPeakAmplitude)）：tap 目标可能不对")
        }
        // A sidecar next to the audio file records what produced it: the trigger, the tap
        // target, the call, and the measured quality. The analysed target keeps a manifest
        // for the same reason; this is the small version.
        let meta = RecordingMeta(trigger: runningTriggerSnapshot.rawValue,
                                 target: recordingTargetSnapshot?.label ?? running.targetLabel,
                                 call: activeCallInfo,
                                 startedAt: running.startedAt,
                                 seconds: running.secondsRecorded,
                                 packets: running.packetsWritten,
                                 peak: running.maxPeakAmplitude,
                                 silent: running.maxPeakAmplitude < 0.0005)
        library.writeMeta(meta, for: running.fileURL)
        recorder = nil
        isRecording = false
        currentFile = "-"
        recordingTargetSnapshot = nil
        runningTriggerSnapshot = .manual
        activeCallInfo = nil
        library.refresh()
    }

    /// Starts or stops the recorder so that it runs exactly while a source wants it.
    private func reevaluate() {
        var wants = manualWants || callWants || appWants
        if autoMutedUntilSourcesEnd, !manualWants {
            wants = false
        }

        let target = effectiveTarget()

        // A call can begin or end while a recording is already running. The tap target
        // cannot change under a live queue, so the only correct move is to close the file
        // and start a new one on the new target.
        if wants, recorder != nil, let snapshot = recordingTargetSnapshot, snapshot != target {
            trlog(.info, "REC", "录音目标变化 \(snapshot.label) -> \(target.label)，重开文件")
            stopRecording(reason: "目标变化")
        }

        if wants, recorder == nil {
            let trigger = intendedTrigger()
            let prefix = trigger == .app ? "app"
                : (trigger == .call ? "call" : (trigger == .volumeKey ? "key" : "rec"))
            startRecording(prefix: prefix, target: target, trigger: trigger)
        } else if !wants, recorder != nil {
            stopRecording(reason: "来源全部结束")
        }

        if !callWants, !appWants, !manualWants {
            autoMutedUntilSourcesEnd = false
        }
    }

    /// The trigger that best describes why a recording is wanted right now.
    private func intendedTrigger() -> RecordTrigger {
        if appWants { return .app }
        if callActive { return .call }
        return manualTrigger
    }

    // MARK: - Triggers

    func toggleManualRecording() {
        if isRecording, manualWants {
            manualWants = false
            trlog(.info, "REC", "手动停止")
        } else {
            manualWants = true
            manualTrigger = .manual
            autoMutedUntilSourcesEnd = false
            trlog(.info, "REC", "手动开始（目标 \(effectiveTarget().label)）")
        }
        reevaluate()
    }

    func toggleWatchCalls() {
        watchCalls.toggle()
        if watchCalls {
            startCallWatcher()
        } else {
            watcher?.stop()
            watcher = nil
            callWants = false
            trlog(.info, "CT", "已停止通话监听")
            reevaluate()
        }
        updateKeepAlive()
    }

    private func startCallWatcher() {
        guard watcher == nil else { return }
        let observer = CallWatcher()
        guard observer.start(handler: { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }) else {
            trlog(.error, "CT", "通话监听启动失败：\(observer.statusDetail)")
            coreTelephonyStatus = "不可用（\(observer.statusDetail)）"
            watchCalls = false
            return
        }
        watcher = observer
        coreTelephonyStatus = "可用（\(observer.statusDetail)）"
        trlog(.info, "CT", "通话监听已启动")
    }

    func toggleWatchApps() {
        watchApps.toggle()
        trlog(.info, "APP", "应用音频自动录音：\(watchApps ? "开" : "关")，监听 \(watchedIdentifiers)")
        if watchApps {
            startAudioUseWatcher()
        } else {
            audioUseWatcher?.stop()
            audioUseWatcher = nil
            nowPlayingWatcher?.stop()
            nowPlayingWatcher = nil
            nowPlayingClient = nil
            nowPlayingStatus = "未监听"
            appWants = false
            appWantedPID = nil
            activeAudioUseSignals.removeAll()
            voipCallActive = false
            appAudioStatus = "已关闭"
            reevaluate()
        }
        updateKeepAlive()
    }

    /// Subscribes to the audio-session and CallKit signals that a non-telephony call
    /// produces. Returns false and reports why when it cannot be installed.
    @discardableResult
    private func startAudioUseWatcher() -> Bool {
        guard audioUseWatcher == nil else { return true }
        let watcher = AudioUseWatcher()
        watcher.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleAudioUse(event) }
        }
        guard watcher.start() else {
            trlog(.error, "APP", "应用音频监听启动失败：\(watcher.statusDetail)")
            watchApps = false
            appAudioStatus = "启动失败"
            return false
        }
        audioUseWatcher = watcher
        appAudioStatus = watcher.statusDetail
        trlog(.info, "APP", "应用音频监听已启动（\(watcher.statusDetail)）")
        return true
    }

    /// One audio-signal event. The signal only says "another app is using audio now";
    /// the tap target and the per-recording evidence are reported by the recorder.
    ///
    /// CallKit is authoritative for a VoIP call. The interruption and secondary-audio
    /// signals are generic, so they only start a recording when a watched app can actually
    /// be resolved — otherwise any app that plays a video would start one.
    private func handleAudioUse(_ event: AudioUseEvent) {
        switch event {
        case .started(let kind, let detail):
            trlog(.info, "APP", "\(kind.rawValue)：开始（\(detail)）")
            guard watchApps else { return }
            appIdleTicks = 0
            autoMutedUntilSourcesEnd = false
            if kind == .callKit { voipCallActive = true }

            // The configured Bundle ID match is the first try; the MediaRemote now-playing
            // app is the same second source the analysed daemon uses, so a call can be
            // found from the audio it is producing without configuration.
            var resolvedPID = watchedAppPID()
            if resolvedPID == nil, let playing = nowPlayingClient, playing.isPlaying,
               kind == .callKit || watchedIdentifiers.contains(playing.bundleIdentifier.lowercased()) {
                resolvedPID = playing.pid
                trlog(.info, "APP", "Bundle ID 未匹配，改用正在播放的 App："
                      + "\(playing.bundleIdentifier) pid \(playing.pid)")
            }

            guard let pid = resolvedPID else {
                if kind == .callKit {
                    activeAudioUseSignals.insert(kind.rawValue)
                    appWants = true
                    appWantedPID = nil
                    trlog(.info, "APP", "CallKit 通话接通，但未匹配到 App：回退到系统音频")
                    reevaluate()
                } else {
                    trlog(.info, "APP", "\(kind.rawValue) 来自未监听的 App，且未匹配到 Bundle ID，忽略")
                }
                return
            }

            activeAudioUseSignals.insert(kind.rawValue)
            if appWants, appWantedPID == pid { return }
            if recorder != nil, appWantedPID != pid { stopRecording(reason: "目标进程变化") }
            appWants = true
            appWantedPID = pid
            trlog(.info, "APP", "应用音频触发录音；目标 pid \(pid)")
            reevaluate()
        case .ended(let kind, let detail):
            trlog(.info, "APP", "\(kind.rawValue)：结束（\(detail)）")
            activeAudioUseSignals.remove(kind.rawValue)
            if kind == .callKit { voipCallActive = false }
            guard appWants, activeAudioUseSignals.isEmpty else { reevaluate(); return }
            appWants = false
            appWantedPID = nil
            appIdleTicks = 0
            reevaluate()
        }
    }

    /// Mirrors the analysed daemon's setupMediaRemoteObservers: learn which application is
    /// producing audio right now, so its pid can be used as the tap target.
    @discardableResult
    private func startNowPlayingWatcher() -> Bool {
        guard nowPlayingWatcher == nil else { return true }
        let watcher = NowPlayingWatcher()
        watcher.onClientChanged = { [weak self] client in
            Task { @MainActor in self?.handleNowPlaying(client) }
        }
        guard watcher.start() else {
            nowPlayingStatus = "启动失败（\(watcher.statusDetail)）"
            return false
        }
        nowPlayingWatcher = watcher
        nowPlayingStatus = watcher.statusDetail
        return true
    }

    private func handleNowPlaying(_ client: NowPlayingWatcher.Client?) {
        nowPlayingClient = client
        guard let client else {
            nowPlayingStatus = "无"
            return
        }
        nowPlayingStatus = "\(client.displayName) pid \(client.pid)"

        // If a call is up but the target was not identified yet, the now-playing app is it.
        if watchApps, appWants, appWantedPID == nil, callActive || !activeAudioUseSignals.isEmpty {
            appWantedPID = client.pid
            trlog(.info, "APP", "用正在播放的 App 作为 tap 目标：pid \(client.pid) [\(client.bundleIdentifier)]")
            reevaluate()
        }
    }

    func toggleHideIcon() {
        hideIcon.toggle()
        let identifier = Bundle.main.bundleIdentifier ?? "com.example.mycallrec"
        let outcome = IconVisibility.setVisible(!hideIcon, bundleIdentifier: identifier)
        trlog(.info, "ICON", "隐藏图标=\(hideIcon)；\(outcome)")
        if hideIcon {
            trlog(.warn, "ICON", "恢复入口：Safari 打开 mycallrec:// ，或从 TrollStore 已安装列表启动")
        }
    }

    func applyAudioSessionSetting() {
        Self.configureAudioSession(activate: activatesAudioSession)
    }

    func toggleWatchVolumeKeys() {
        watchVolumeKeys.toggle()
        if watchVolumeKeys {
            installKeyMonitor()
        } else {
            stopKeyMonitor()
        }
        updateKeepAlive()
    }

    /// Builds the key-event path: the shared detector plus, when it exists, the real HID
    /// source, and the volume-delta fallback behind it.
    private func installKeyMonitor() {
        if let volumeMonitor {
            volumeMonitor.retryVolumeViewIfNeeded()
            return
        }

        let detector = keyDetector
        detector.reset()
        detector.onPress = { name in trlog(.info, "KEY", "按键事件：\(name)") }
        detector.onCombo = { [weak self] description in
            Task { @MainActor in self?.handleVolumeCombo(description) }
        }

        // Primary source: the real button transitions. Its presses are deduplicated
        // against the fallback by the shared detector.
        var hid: HIDKeyMonitor?
        if useHIDKeyEvents {
            let candidate = HIDKeyMonitor()
            candidate.onPress = { [weak detector] direction, source in
                detector?.press(direction, source: source)
            }
            if candidate.start() {
                hid = candidate
                hidMonitor = candidate
            }
        }

        // Fallback source: the volume-delta sampler. It stays installed so the trigger
        // still works if the HID client never delivers an event; it goes quiet as soon as
        // HID proves it is alive.
        let monitor = VolumeKeyMonitor(detector: detector)
        monitor.hidIsPrimary = { [weak hid] in hid?.hasReceivedVolumeEvent ?? false }
        monitor.start(suppressHUD: keySuppressesHUD, restoreVolume: true)
        volumeMonitor = monitor

        keyStatus = hidMonitor == nil ? "音量采样后备（IOHID 不可用）" : "IOHID 事件 + 采样后备"
        trlog(.info, "KEY", "按键触发就绪：真实事件源=\(hidMonitor != nil ? "IOHID" : "音量采样")")
    }

    private func stopKeyMonitor() {
        hidMonitor?.stop()
        hidMonitor = nil
        volumeMonitor?.stop()
        volumeMonitor = nil
        keyDetector.reset()
        keyStatus = "未启用"
        trlog(.info, "KEY", "音量键监听已停止")
    }

    /// Rebuilds the key-event path after a setting changed. Exposed for the view.
    func restartKeyMonitor() {
        guard watchVolumeKeys else { return }
        stopKeyMonitor()
        installKeyMonitor()
    }

    /// Keeps the process alive in the background while any trigger is enabled. Without it
    /// the app is suspended and no trigger can fire.
    func updateKeepAlive() {
        let wanted = keepAliveInBackground && (watchCalls || watchApps || watchVolumeKeys)
        if wanted, keepAlive == nil {
            let alive = BackgroundKeepAlive()
            if alive.start() {
                keepAlive = alive
            }
        } else if !wanted, keepAlive != nil {
            keepAlive?.stop()
            keepAlive = nil
        }
    }

    func applyKeepAliveSetting() {
        updateKeepAlive()
    }

    private func handleVolumeCombo(_ description: String) {
        if recorder != nil {
            // A key stop is authoritative: auto sources stay muted until they end once.
            manualWants = false
            autoMutedUntilSourcesEnd = true
            trlog(.info, "KEY", "按键停止录音（\(description)）")
            stopRecording(reason: "物理按键")
            VolumeKeyMonitor.feedback(pulses: 2)
        } else {
            manualWants = true
            manualTrigger = .volumeKey
            autoMutedUntilSourcesEnd = false
            trlog(.info, "KEY", "按键开始录音（\(description)），目标 \(effectiveTarget().label)")
            reevaluate()
            VolumeKeyMonitor.feedback(pulses: 1)
        }
    }

    private func handle(_ event: CallEvent) {
        callStateText = event.state.label
        if event.address != nil || event.displayName != nil || event.uniqueIdentifier != nil {
            latestCall = CallInfo(address: event.address,
                                  name: event.displayName,
                                  type: event.callType,
                                  outgoing: event.isOutgoing,
                                  state: event.state.label)
        }
        trlog(.info, "CT", "通话事件 \(event.state.label) 号码=\(event.address ?? "-") 名称=\(event.displayName ?? "-") "
              + "类型=\(event.callType ?? "-") 去电=\(event.isOutgoing.map { $0 ? "是" : "否" } ?? "-") 并发=\(event.activeCallCount)")

        guard watchCalls else { return }

        if event.state == .answered {
            callWants = true
            autoMutedUntilSourcesEnd = false
            reevaluate()
            return
        }

        let ended = event.state.isTerminal || (event.state == .unknown && event.activeCallCount == 0)
        if ended, callWants {
            callWants = false
            trlog(.info, "CT", "通话结束，移除通话录音来源")
            reevaluate()
        }
    }

    // MARK: - Periodic evaluation

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in model.tick() }
        }
    }

    private func tick() {
        tickCount += 1

        // Every 30 s, so a "keys do nothing" report tells us whether IOHID ever delivered
        // anything and whether the sampler fallback is installed.
        if watchVolumeKeys, tickCount % 30 == 0 {
            let hid = hidMonitor
            trlog(.info, "KEY", "按键状态：IOHID 事件 \(hid?.eventCount ?? 0) 个，"
                  + "收到音量事件=\((hid?.hasReceivedVolumeEvent ?? false) ? "是" : "否")，"
                  + "采样后备=\(volumeMonitor != nil ? "已安装" : "无")")
        }

        if let running = recorder {
            elapsed = running.secondsRecorded
            packets = running.packetsWritten
            peak = running.peakAmplitude
            maxPeak = running.maxPeakAmplitude
            let second = Int(elapsed)
            if second != lastLoggedSecond, second % 2 == 0 {
                lastLoggedSecond = second
                trlog(.info, "REC", String(format: "录制中 %.0f 秒 / %llu 包 / 峰值 %.3f", elapsed,
                                           packets, maxPeak))
            }
        }

        guard tickCount % 3 == 0 else { return }

        // The trigger itself is event-driven (see AudioUseWatcher). This only guards
        // against the tapped application disappearing without an end signal.
        if appWants, let pid = appWantedPID, !AppProcessFinder.isAlive(pid) {
            trlog(.warn, "APP", "目标进程 pid \(pid) 已退出，结束应用音频录音")
            appWants = false
            appWantedPID = nil
            appIdleTicks = 0
            reevaluate()
        }

        refreshAudioProcesses()
    }

    /// Collects a full snapshot — entitlements, tap capability, audio process table and,
    /// when not already recording, a three second system-audio tap test — and copies it
    /// to the clipboard together with the run log.
    func runDiagnostics(includeSelfTest: Bool) {
        var selfTest = includeSelfTest
        if selfTest, recorder != nil {
            selfTest = false
            trlog(.warn, "APP", "正在录音，跳过 tap 自检")
        }
        trlog(.info, "APP", "开始收集诊断快照（tap 自检=\(selfTest)）")
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = Diagnostics.collect(includeTapSelfTest: selfTest)
            DispatchQueue.main.async {
                UIPasteboard.general.string = snapshot.text
                trlog(.info, "APP", "诊断快照已复制到剪贴板（\(snapshot.text.count) 字符）；原始 JSON 在 Documents/logs/")
            }
        }
    }

    func copyLogToPasteboard() {
        UIPasteboard.general.string = Log.shared.transcript()
        trlog(.info, "APP", "日志已复制到剪贴板（\(Log.shared.lines.count) 行）")
    }

    func clearLog() {
        Log.shared.markSessionStart()
        logLines.removeAll()
        trlog(.info, "APP", "日志已清空")
    }
}

/// Row layout that works on iOS 15 as well (LabeledContent is iOS 16+).
struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var playing: URL?
    @State private var player: AVAudioPlayer?

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("状态")) {
                    InfoRow(title: "通话", value: model.callStateText)
                    InfoRow(title: "CoreTelephony", value: model.coreTelephonyStatus)
                    InfoRow(title: "私有 tap", value: model.tapAvailability)
                    InfoRow(title: "音频进程枚举(诊断)", value: model.audioProcessStatus)
                    InfoRow(title: "应用音频监听", value: model.appAudioStatus)
                    InfoRow(title: "正在播放音频", value: model.nowPlayingStatus)
                    InfoRow(title: "按键事件源", value: model.keyStatus)
                    InfoRow(title: "当前目标", value: model.effectiveTarget().label)
                    InfoRow(title: "当前文件", value: model.currentFile)
                    InfoRow(title: "时长", value: String(format: "%.1f 秒", model.elapsed))
                    InfoRow(title: "音频包", value: "\(model.packets)")
                    InfoRow(title: "峰值", value: String(format: "%.3f（最大 %.3f）", model.peak, model.maxPeak))
                }

                Section(header: Text("录音")) {
                    Picker("录音目标", selection: $model.targetChoice) {
                        ForEach(TargetChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    if model.targetChoice == .process {
                        TextField("PID", text: $model.customPID).keyboardType(.numberPad)
                    }
                    if model.targetChoice == .auto {
                        Text("默认：通话中抓通话音频，未通话时抓麦克风。上面的手动目标仅在未通话时生效。")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Button(model.isRecording && model.currentFile != "-" ? "停止录制" : "开始录制") {
                        model.toggleManualRecording()
                    }
                    .foregroundColor(model.isRecording ? .red : .blue)
                }

                Section(header: Text("自动触发")) {
                    Toggle("通话自动录制", isOn: Binding(get: { model.watchCalls },
                                                       set: { _ in model.toggleWatchCalls() }))
                    Toggle("应用音频自动录制", isOn: Binding(get: { model.watchApps },
                                                          set: { _ in model.toggleWatchApps() }))
                    TextField("应用 Bundle ID（逗号分隔）", text: $model.watchedBundleIDs)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Text("触发信号：CallKit 通话 / 音频中断 / 次要音频。CallKit 通话一定会触发；音频中断与次要音频只在能按 Bundle ID 匹配到监听的 App 时触发，避免任意 App 放音频就开始录。")
                        .font(.caption2).foregroundColor(.secondary)
                    Toggle("音量键触发", isOn: Binding(get: { model.watchVolumeKeys },
                                                     set: { _ in model.toggleWatchVolumeKeys() }))
                    Toggle("后台保持存活", isOn: Binding(get: { model.keepAliveInBackground },
                                                     set: { newValue in
                                                         model.keepAliveInBackground = newValue
                                                         model.applyKeepAliveSetting()
                                                     }))
                    Text("循环播放一段静音音频，避免切到其他 App 后本进程被挂起、收不到按键与通话事件。目标软件用守护进程达到同样效果。")
                        .font(.caption2).foregroundColor(.secondary)
                    Toggle("使用 IOHID 真实按键事件", isOn: Binding(get: { model.useHIDKeyEvents },
                                                          set: { newValue in
                                                              model.useHIDKeyEvents = newValue
                                                              model.restartKeyMonitor()
                                                          }))
                    Text("优先订阅系统级真实按键事件（可识别同时按下的组合）。若某些系统上按键异常，可关掉改用音量采样。")
                        .font(.caption2).foregroundColor(.secondary)
                    Toggle("按键不显示音量 HUD", isOn: $model.keySuppressesHUD)
                    Text("打开后会插入一个屏幕外的音量控件来压掉系统音量提示。若打开后音量键失去反应，请关掉它——那个控件会接管音量键。")
                        .font(.caption2).foregroundColor(.secondary)
                    Toggle("激活音频会话", isOn: Binding(get: { model.activatesAudioSession },
                                                      set: { newValue in
                                                          model.activatesAudioSession = newValue
                                                          model.applyAudioSessionSetting()
                                                      }))
                    Text("若录音时对方听不到你、或微信音频异常，把它关掉（依赖 CanRecordWithoutSessionActivation 权限）。")
                        .font(.caption).foregroundColor(.secondary)
                    Text("触发方式：同时按音量+ 与音量-（0.8 秒内先后按下即可），或音量-／音量+ 双击。开始震 1 下，停止震 2 下。")
                        .font(.caption).foregroundColor(.secondary)
                    Toggle("隐藏桌面图标", isOn: Binding(get: { model.hideIcon },
                                                       set: { _ in model.toggleHideIcon() }))
                    Text("实验功能：需要 SpringBoard 的图标状态接口。若设备上不支持，日志（ICON）会写明尝试过哪些入口且不会改动图标。恢复方式：Safari 打开 mycallrec:// 或从 TrollStore 列表启动。")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section(header: Text("音频进程（\(model.audioProcesses.count)）")) {
                    Button("刷新音频进程") { model.refreshAudioProcesses() }
                    ForEach(model.audioProcesses) { info in
                        VStack(alignment: .leading) {
                            Text("\(info.pid) · \(info.displayName)").font(.footnote)
                            Text(flags(for: info)).font(.caption2).foregroundColor(.secondary)
                        }
                        .onTapGesture {
                            model.customPID = "\(info.pid)"
                            model.targetChoice = .process
                        }
                    }
                }

                Section(header: Text("录音文件（\(model.library.recordings.count)）")) {
                    if model.library.recordings.isEmpty { Text("暂无录音").foregroundColor(.secondary) }
                    ForEach(model.library.recordings) { recording in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(recording.name).font(.footnote)
                                Text(String(format: "%.0f KB · %@", Double(recording.size) / 1024,
                                            DateFormatter.localizedString(from: recording.modified,
                                                                          dateStyle: .short,
                                                                          timeStyle: .short)))
                                    .font(.caption2).foregroundColor(.secondary)
                                if let meta = recording.meta {
                                    Text(metaLine(meta)).font(.caption2).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button(playing == recording.url ? "停止" : "播放") {
                                if playing == recording.url {
                                    player?.stop(); player = nil; playing = nil
                                } else if let created = try? AVAudioPlayer(contentsOf: recording.url) {
                                    created.prepareToPlay(); created.play(); player = created
                                    playing = recording.url
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete { indexSet in
                        indexSet.map { model.library.recordings[$0] }.forEach(model.library.delete)
                    }
                }

                Section(header: Text("诊断")) {
                    Button("自检并复制（含 3 秒 tap 测试）") { model.runDiagnostics(includeSelfTest: true) }
                    Button("仅复制状态（不做 tap 测试）") { model.runDiagnostics(includeSelfTest: false) }
                    Text("快照包含：TrollStore 实际授予的 entitlements、私有 tap 选择子、CoreTelephony 结果、音频进程全表、音频会话状态，外加运行日志。粘贴给我即可。")
                        .font(.caption2).foregroundColor(.secondary)
                }

                Section(header: Text("日志")) {
                    Button("复制全部日志") { model.copyLogToPasteboard() }
                    Button("分享日志文件") {
                        trlog(.info, "APP", "弹出日志分享面板")
                        LogSharing.present(items: Log.shared.shareableFiles())
                    }
                    Button("清空日志") { model.clearLog() }
                    Text("日志文件：\(Log.shared.logFileURL?.path ?? "不可用")")
                        .font(.caption2).foregroundColor(.secondary)
                    Text("若 App 闪退，重新打开后「复制全部日志」里会带上崩溃原因（含异常名与调用栈）。")
                        .font(.caption2).foregroundColor(.secondary)
                    ForEach(model.logLines, id: \.self) { line in
                        Text(line).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.grouped)
            .navigationTitle("MyCallRec")
            .toolbar {
                Button("刷新") { model.library.refresh() }
            }
        }
        // Installing the volume-key monitor needs a key window for its hidden
        // MPVolumeView, so the triggers are assembled here rather than in init().
        .onAppear { model.startEnabledTriggers() }
    }

    /// One line summarising a recording's sidecar, shown under its name.
    private func metaLine(_ meta: RecordingMeta) -> String {
        var parts = ["触发:\(meta.trigger)", "目标:\(meta.target)"]
        if let call = meta.call {
            let who = call.name ?? call.address ?? "未知号码"
            let direction = call.outgoing.map { $0 ? "去电" : "来电" } ?? ""
            parts.append("通话:\(who)\(direction.isEmpty ? "" : "·\(direction)")")
        }
        if meta.silent { parts.append("近乎静音") }
        return parts.joined(separator: " · ")
    }

    private func flags(for info: AudioProcessInfo) -> String {
        var parts: [String] = []
        if info.isRunning { parts.append("运行中") }
        if info.isRunningInput { parts.append("输入(采集)") }
        if info.isRunningOutput { parts.append("输出(播放)") }
        return parts.isEmpty ? "空闲" : parts.joined(separator: " · ")
    }
}
