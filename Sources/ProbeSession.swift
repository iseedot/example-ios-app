//
//  ProbeSession.swift
//  MyCallRec — one-shot capture test.
//
//  The 2026-10-17 device runs left one question unanswered: which private tap target
//  actually carries a telephone call and a WeChat call on this build. Nothing can be
//  queried from the system, so the only way to answer it is to measure: this session
//  cycles through every candidate target in fixed slices and reports the peak level,
//  the frame count and the context each slice ran in.
//
//  It also records a timeline of the public signals (route changes, interruption,
//  secondary-audio hint, CallKit) with an offset in seconds, because the open question
//  for WeChat is whether *any* public signal marks its answer and hangup.
//
//  Measured facts only: no conclusion is drawn beyond "this target produced sound in
//  this context". TrollRecorder's own on-disk evidence is attached separately by
//  PeerEvidence, which is the only way to learn the exact target it used.
//

import Foundation
import AVFAudio
import CallKit
import UIKit

/// One measured slice: one tap target, run for a few seconds, with what was true then.
struct ProbeSample {
    let round: Int
    let slice: Int
    let offset: Double
    let target: String
    let channels: UInt32
    let peak: Float
    let frames: UInt64
    let seconds: Double
    let firstBuffer: Bool
    let queueFormat: String
    let tapDescription: String
    /// Extra per-slice detail, e.g. each side's level for a dual slice.
    let note: String?
    let error: String?
    let routeOut: String
    let routeIn: String
    let otherAudio: Bool
    let silenced: Bool
    let callCount: Int32?
    let callKitCalls: Int
    let callKitConnected: Int
    let wechatPID: Int32?
    let mediaServerPID: Int32?
    let fileName: String?
}

/// Where the report ended up, plus its text.
struct ProbeResult {
    let text: String
    let url: URL?
}

/// One candidate capture for a slice.
private enum ProbeCandidate: Equatable {
    case single(TapTarget)
    case dual

    var label: String {
        switch self {
        case .single(let target): return target.label
        case .dual: return "mic+speaker（双路）"
        }
    }
}

/// Everything measured while one slice was starting.
private struct ProbeContext {
    let routeOut: String
    let routeIn: String
    let otherAudio: Bool
    let silenced: Bool
    let callCount: Int32?
    let callKitCalls: Int
    let callKitConnected: Int
    let wechatPID: Int32?
    let mediaServerPID: Int32?
}

final class ProbeSession: NSObject, CXCallObserverDelegate {
    /// Slice length. Two seconds fits one full round into a ten second call, and is still
    /// long enough that a slow first buffer shows up as "no first buffer" instead of a
    /// silent-looking zero.
    static let sliceSeconds: Double = 2.0
    /// Hard stop so a forgotten session cannot record forever.
    static let maximumSlices = 180

    private(set) var isRunning = false
    private(set) var samples: [ProbeSample] = []
    private(set) var timeline: [String] = []

    private var started = Date()
    private var round = 1
    private var sliceInRound = 0
    private var slicesDone = 0
    private var recorder: (any RecordingEngine)?
    /// Set during a dual slice, so the report can show what each side measured.
    private var dualRecorder: DualRecorder?
    private var currentCandidate: ProbeCandidate = .single(.speaker)
    private var currentChannels: UInt32 = 2
    private var sliceStarted = Date()
    private var context = ProbeContext(routeOut: "-", routeIn: "-", otherAudio: false, silenced: false,
                                       callCount: nil, callKitCalls: 0, callKitConnected: 0,
                                       wechatPID: nil, mediaServerPID: nil)
    private var timer: Timer?
    private var stamp = ""
    private var directory: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    private var header = ""
    private var callWatcher: CallWatcher?
    private var callObserver: CXCallObserver?
    private var tokens: [NSObjectProtocol] = []
    private var cachedMediaServerPID: Int32?
    private var cachedMediaServerAt = Date.distantPast
    /// The watched app's pid is resolved at most every 15 s: a miss rescans the process
    /// table twice, and this runs every two seconds for the whole session.
    private var cachedWeChatPID: Int32?
    private var cachedWeChatAt = Date.distantPast

    var onStatus: ((String) -> Void)?
    var onFinish: ((ProbeResult) -> Void)?

    // MARK: - Lifecycle

    func start(in directory: URL) {
        guard !isRunning else { return }
        self.directory = directory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        stamp = formatter.string(from: Date())
        started = Date()
        samples.removeAll()
        timeline.removeAll()
        round = 1
        sliceInRound = 0
        slicesDone = 0
        cachedMediaServerPID = nil
        cachedMediaServerAt = .distantPast
        cachedWeChatPID = nil
        cachedWeChatAt = .distantPast
        isRunning = true

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        header = Diagnostics.collect(includeTapSelfTest: false).text
        installObservers()

        // A dedicated CoreTelephony observer: the live call count is what labels a slice
        // "during a telephone call", and it must not depend on the user's trigger settings.
        let watcher = CallWatcher()
        if watcher.start(handler: { _ in }) {
            callWatcher = watcher
        } else {
            trlog(.warn, "PROBE", "核心电话观察者启动失败：\(watcher.statusDetail)（通话计数将不可用）")
        }

        appendTimeline("开始采集（每 \(Int(Self.sliceSeconds)) 秒换一个目标）")
        trlog(.info, "PROBE", "开始测试采集：每 \(Int(Self.sliceSeconds)) 秒换一个目标，目录 \(directory.path)")

        // Common mode so the slice still advances while the UI is tracking a touch.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        beginSlice()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        endSlice()
        removeObservers()
        callWatcher?.stop()
        callWatcher = nil
        appendTimeline("停止采集（共 \(samples.count) 段）")
        let report = buildReport()
        let url = write(report)
        trlog(.info, "PROBE", "测试采集结束：\(samples.count) 段，报告 \(url?.lastPathComponent ?? "未写入")")
        onFinish?(ProbeResult(text: report, url: url))
    }

    private func tick() {
        guard isRunning else { return }
        if Date().timeIntervalSince(sliceStarted) < Self.sliceSeconds { return }
        endSlice()
        guard isRunning else { return }
        sliceInRound += 1
        slicesDone += 1
        if slicesDone >= Self.maximumSlices {
            trlog(.warn, "PROBE", "达到最大段数 \(Self.maximumSlices)，自动停止")
            stop()
            return
        }
        beginSlice()
    }

    // MARK: - Slices

    private func beginSlice() {
        guard isRunning else { return }
        let list = candidates()
        if list.isEmpty {
            trlog(.error, "PROBE", "没有可选目标，停止")
            stop()
            return
        }
        let candidate = list[sliceInRound % list.count]
        if sliceInRound > 0, sliceInRound % list.count == 0 { round += 1 }
        sliceInRound = sliceInRound % list.count
        currentCandidate = candidate
        currentChannels = candidate == .single(.microphone) ? 1 : 2
        context = snapshotContext()
        sliceStarted = Date()
        dualRecorder = nil

        let name = "probe-\(stamp)-r\(round)s\(sliceInRound + 1)-\(fileLabel(candidate)).m4a"
        let url = directory.appendingPathComponent(name)
        // The session is never activated: production does not activate it either, and
        // activation is what made the microphone fail while a telephone call was up.
        trCreateRecordingSession(activate: false)

        do {
            let created: any RecordingEngine
            switch candidate {
            case .dual:
                let dual = try DualRecorder(directory: directory,
                                            baseName: "probe-\(stamp)-r\(round)s\(sliceInRound + 1)-dual",
                                            compress: true)
                dualRecorder = dual
                created = dual
            case .single(let target):
                let single = try TapRecorder(target: target, sampleRate: 44100, channels: currentChannels,
                                             fileURL: url, bypassTap: target == .microphone, compress: true)
                try single.start()
                created = single
            }
            recorder = created
        } catch {
            // Record the failure as a sample: "this target cannot even be created" is a
            // result too, and the report has to distinguish it from "created, but silent".
            samples.append(ProbeSample(round: round, slice: sliceInRound + 1,
                                       offset: Date().timeIntervalSince(started),
                                       target: candidate.label, channels: currentChannels,
                                       peak: 0, frames: 0, seconds: 0, firstBuffer: false,
                                       queueFormat: "-", tapDescription: "-", note: nil,
                                       error: "\(error)", routeOut: context.routeOut,
                                       routeIn: context.routeIn, otherAudio: context.otherAudio,
                                       silenced: context.silenced, callCount: context.callCount,
                                       callKitCalls: context.callKitCalls,
                                       callKitConnected: context.callKitConnected,
                                       wechatPID: context.wechatPID,
                                       mediaServerPID: context.mediaServerPID,
                                       fileName: nil))
            trlog(.error, "PROBE", "目标 \(candidate.label) 创建失败：\(error)")
            reportStatus()
            return
        }

        trlog(.info, "PROBE", "第 \(round) 轮第 \(sliceInRound + 1) 段：\(candidate.label) 声道=\(currentChannels) "
              + "通话=\(context.callCount.map(String.init) ?? "-") CallKit=\(context.callKitCalls)/\(context.callKitConnected) "
              + "otherAudio=\(context.otherAudio) secondaryHint=\(context.silenced) "
              + "微信pid=\(context.wechatPID.map(String.init) ?? "-")")
        reportStatus()
    }

    private func endSlice() {
        guard let running = recorder else { return }
        recorder = nil
        running.stop()

        // A dual slice has no single queue and no single format: report what each side
        // measured instead, which is the whole point of running the two together.
        var note: String?
        if let dual = dualRecorder {
            note = String(format: "本机=%.4f（%llu 包） 对端=%.4f（%llu 包）",
                          dual.uplink?.maxPeakAmplitude ?? 0, dual.uplink?.packetsWritten ?? 0,
                          dual.downlink?.maxPeakAmplitude ?? 0, dual.downlink?.packetsWritten ?? 0)
        }
        let detailEngine = dualRecorder?.downlink ?? (running as? TapRecorder)
        dualRecorder = nil

        let sample = ProbeSample(round: round, slice: sliceInRound + 1,
                                 offset: Date().timeIntervalSince(started),
                                 target: running.targetLabel, channels: currentChannels,
                                 peak: running.maxPeakAmplitude, frames: running.packetsWritten,
                                 seconds: running.secondsRecorded,
                                 firstBuffer: running.receivedFirstBuffer,
                                 queueFormat: detailEngine?.queueFormatDescription ?? "-",
                                 tapDescription: detailEngine?.tapDescriptionText ?? "-",
                                 note: note,
                                 error: nil, routeOut: context.routeOut, routeIn: context.routeIn,
                                 otherAudio: context.otherAudio, silenced: context.silenced,
                                 callCount: context.callCount, callKitCalls: context.callKitCalls,
                                 callKitConnected: context.callKitConnected,
                                 wechatPID: context.wechatPID, mediaServerPID: context.mediaServerPID,
                                 fileName: running.fileURL.lastPathComponent)
        samples.append(sample)
        trlog(.info, "PROBE", String(format: "段 %d 结果：%@ 峰值=%.4f 帧=%llu 首缓冲=%@ 格式=%@ 文件=%@ %@",
                                     samples.count, running.targetLabel, sample.peak, sample.frames,
                                     sample.firstBuffer ? "是" : "否", sample.queueFormat,
                                     sample.fileName ?? "-", note ?? ""))
        reportStatus()
    }

    private func reportStatus() {
        onStatus?("第 \(round) 轮 · \(currentCandidate.label) · 已完成 \(samples.count) 段")
    }

    /// Candidate captures, in the order that answers the questions first: the two sides
    /// together (the analysed target's mixer mode), then each side alone, then the app
    /// process (WeChat — measured to carry only its ringtone), then the system mix.
    /// mediaserverd was dropped: its 'qtob' binding fails with -66675 on every attempt.
    private func candidates() -> [ProbeCandidate] {
        var list: [ProbeCandidate] = [.dual, .single(.speaker), .single(.microphone)]
        if let pid = weChatPID() {
            list.append(.single(.process(pid)))
        }
        list.append(.single(.systemAudio))
        return list
    }

    private func fileLabel(_ candidate: ProbeCandidate) -> String {
        switch candidate {
        case .dual: return "dual"
        case .single(let target): return target.label.replacingOccurrences(of: ":", with: "_")
        }
    }


    private func weChatPID() -> Int32? {
        if Date().timeIntervalSince(cachedWeChatAt) < 15 { return cachedWeChatPID }
        cachedWeChatAt = Date()
        let pid = AppProcessFinder.pid(forBundleIdentifier: "com.tencent.xin")
        if pid != cachedWeChatPID {
            trlog(.info, "PROBE", "微信 pid=" + (pid.map(String.init) ?? "未运行"))
            cachedWeChatPID = pid
        }
        return pid
    }

    private func mediaServerPID() -> Int32? {
        if Date().timeIntervalSince(cachedMediaServerAt) < 10, let cachedMediaServerPID {
            return cachedMediaServerPID
        }
        cachedMediaServerAt = Date()
        let entry = ProcessList.snapshot(maxAge: 10).first { $0.name == "mediaserverd" }
        cachedMediaServerPID = entry?.pid
        return entry?.pid
    }

    private func snapshotContext() -> ProbeContext {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let outputs = route.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let inputs = route.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let calls = callObserver?.calls ?? []
        return ProbeContext(routeOut: outputs.isEmpty ? "-" : outputs,
                            routeIn: inputs.isEmpty ? "-" : inputs,
                            otherAudio: session.isOtherAudioPlaying,
                            silenced: session.secondaryAudioShouldBeSilencedHint,
                            callCount: callWatcher?.liveCallCount(),
                            callKitCalls: calls.count,
                            callKitConnected: calls.filter { $0.hasConnected && !$0.hasEnded }.count,
                            wechatPID: weChatPID(),
                            mediaServerPID: mediaServerPID())
    }

    // MARK: - Signals

    private func installObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: session, queue: .main) { [weak self] note in
            guard let self, self.isRunning else { return }
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw).map { "\($0)" } ?? "raw=\(raw)"
            let current = AVAudioSession.sharedInstance()
            let outputs = current.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
            self.appendTimeline("路由变化 reason=\(reason) 输出=\(outputs.isEmpty ? "-" : outputs)")
        })

        tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: session, queue: .main) { [weak self] note in
            guard let self, self.isRunning else { return }
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? 0
            let type = AVAudioSession.InterruptionType(rawValue: raw).map { "\($0)" } ?? "raw=\(raw)"
            self.appendTimeline("音频中断 type=\(type)")
        })

        tokens.append(center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification,
                                        object: session, queue: .main) { [weak self] note in
            guard let self, self.isRunning else { return }
            let raw = (note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? NSNumber)?.uintValue ?? 0
            let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw).map { "\($0)" } ?? "raw=\(raw)"
            self.appendTimeline("次要音频提示 type=\(type)")
        })

        tokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                        object: session, queue: .main) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.appendTimeline("音频服务重启（mediaServicesWereReset）")
        })

        let observer = CXCallObserver()
        observer.setDelegate(self, queue: .main)
        callObserver = observer
    }

    private func removeObservers() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        callObserver?.setDelegate(nil, queue: nil)
        callObserver = nil
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        guard isRunning else { return }
        appendTimeline("CallKit 通话 去电=\(call.isOutgoing) 接通=\(call.hasConnected) "
                       + "结束=\(call.hasEnded) uuid=\(call.uuid.uuidString.prefix(8))")
    }

    private func appendTimeline(_ text: String) {
        let line = String(format: "t+%.1fs %@", Date().timeIntervalSince(started), text)
        timeline.append(line)
        trlog(.info, "PROBE", "信号：\(text)")
    }

    // MARK: - Report

    private func buildReport() -> String {
        var lines: [String] = []
        lines.append("===== MyCallRec 测试采集报告 =====")
        lines.append("生成时间: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))")
        lines.append("切片: 每 \(Int(Self.sliceSeconds)) 秒换一个目标；本次 \(samples.count) 段 / \(round) 轮")
        lines.append("文件与报告目录: \(directory.path)")
        lines.append("")
        lines.append("===== 逐段结果 =====")
        lines.append("序号 轮/段 目标               峰值    帧      首缓冲 格式                              电话 CallKit 提示 输出/输入")
        for (index, sample) in samples.enumerated() {
            let callText = sample.callCount.map { "\($0)" } ?? "-"
            let callKit = "\(sample.callKitCalls)/\(sample.callKitConnected)"
            let hint = sample.silenced ? "是" : "否"
            let route = "\(sample.routeOut)/\(sample.routeIn)"
            lines.append(String(format: "%3d  %d/%-2d %-18@ %.4f %8llu %-6@ %-32@ %-4@ %-7@ %-4@ %@",
                                index + 1, sample.round, sample.slice, sample.target as NSString,
                                sample.peak, sample.frames, (sample.firstBuffer ? "是" : "否") as NSString,
                                sample.queueFormat as NSString, callText as NSString,
                                callKit as NSString, hint as NSString, route))
            if let note = sample.note {
                lines.append("      双路：\(note)")
            }
            if let error = sample.error {
                lines.append("      创建失败: \(error)")
            }
        }

        lines.append("")
        lines.append("===== 自动判断（按上下文分组） =====")
        let groups: [(String, (ProbeSample) -> Bool)] = [
            ("电话通话中（CoreTelephony 报告有通话）", { sample in (sample.callCount ?? 0) > 0 }),
            ("CallKit 通话中（无电话通话）", { sample in (sample.callCount ?? 0) == 0 && sample.callKitConnected > 0 }),
            ("其他应用占用音频（secondaryHint=是，无电话）",
             { sample in (sample.callCount ?? 0) == 0 && sample.callKitConnected == 0 && sample.silenced }),
            ("空闲", { sample in (sample.callCount ?? 0) == 0 && sample.callKitConnected == 0 && !sample.silenced }),
        ]
        var verdicts: [String] = []
        for (title, predicate) in groups {
            let subset = samples.filter(predicate)
            guard !subset.isEmpty else { continue }
            lines.append("[\(title)] \(subset.count) 段")
            var working: [String] = []
            for target in Set(subset.map { $0.target }).sorted() {
                let hit = subset.filter { $0.target == target }
                let loud = hit.filter { $0.peak > 0.001 && $0.frames > 0 }
                let best = hit.map { $0.peak }.max() ?? 0
                let mark = loud.isEmpty ? "❌" : "✅"
                lines.append(String(format: "  %@ 目标=%@ 段=%d 有声音=%d 最大峰值=%.4f 帧合计=%llu",
                                    mark as NSString, target as NSString, hit.count, loud.count, best,
                                    hit.reduce(UInt64(0)) { $0 + $1.frames }))
                if !loud.isEmpty { working.append(target) }
            }
            if working.isEmpty {
                verdicts.append("\(title)：所有目标全程静音（0.000）")
            } else {
                verdicts.append("\(title)：可用目标 = \(working.joined(separator: ", "))")
            }
        }
        lines.append("")
        lines.append("结论:")
        if verdicts.isEmpty {
            lines.append("  没有采到任何段（测试可能没跑起来）")
        } else {
            for verdict in verdicts { lines.append("  · \(verdict)") }
        }

        // The tap description is the only thing that says what the private class actually
        // bound to, so it is listed once per target rather than per slice.
        lines.append("")
        lines.append("===== tap 实际解析结果（每目标首次出现） =====")
        var seen = Set<String>()
        for sample in samples where !seen.contains(sample.target) {
            seen.insert(sample.target)
            lines.append("目标=\(sample.target) 格式=\(sample.queueFormat)")
            lines.append("  描述=\(sample.tapDescription)")
        }

        lines.append("")
        lines.append("===== 信号时间线（本机可见的公开信号） =====")
        if timeline.isEmpty {
            lines.append("  （没有任何信号：说明这期间系统没有广播路由/中断/次要音频/CallKit 变化）")
        } else {
            for line in timeline { lines.append("  \(line)") }
        }
        lines.append("")
        lines.append("判断微信信号的方法：微信通话接听/挂断时刻，看时间线上是否出现")
        lines.append("路由变化、次要音频提示 begin/end 或 CallKit 事件；都没有则说明系统不广播，")
        lines.append("只能用属性轮询或注入 dylib。")

        lines.append("")
        lines.append("===== 采集环境快照 =====")
        lines.append(header)

        lines.append("")
        lines.append(PeerEvidence.collect())

        lines.append("")
        lines.append("===== 运行日志 =====")
        lines.append(Log.shared.transcript(includeHeader: false))
        return lines.joined(separator: "\n")
    }

    private func write(_ report: String) -> URL? {
        let url = directory.appendingPathComponent("probe-report-\(stamp).txt")
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            trlog(.error, "PROBE", "报告写入失败：\(error)")
            return nil
        }
    }
}
