//
//  MyCallRecApp.swift
//  MyCallRec — a minimal, self-built call recorder used as the Phase 1 test harness.
//
//  It records the microphone, the system audio tap, or the audio of a chosen process,
//  and can start and stop automatically around a telephone call. Everything runs in
//  process; there is no daemon yet.
//

import SwiftUI
import AVFoundation
import AVFAudio

@main
struct MyCallRecApp: App {
    @StateObject private var model = AppModel()

    init() {
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
    case microphone = "麦克风"
    case systemAudio = "系统音频"
    case speaker = "扬声器"
    case process = "指定 PID"

    var id: String { rawValue }

    var tapTarget: TapTarget {
        switch self {
        case .microphone: return .microphone
        case .systemAudio: return .systemAudio
        case .speaker: return .speaker
        case .process: return .process(0)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var logLines: [String] = []
    @Published var isRecording = false
    @Published var autoRecord = false
    @Published var targetChoice: TargetChoice = .systemAudio
    @Published var customPID: String = ""
    @Published var callStateText: String = "无"
    @Published var elapsed: Double = 0
    @Published var packets: UInt64 = 0
    @Published var processes: [ProcessEntry] = []
    @Published var tapAvailability: String = "未检测"
    @Published var currentFile: String = "-"

    let library = RecordingLibrary()

    private var recorder: TapRecorder?
    private var watcher: CallWatcher?
    private var ticker: Timer?

    init() {
        tapAvailability = (NSClassFromString("ATAudioTap") != nil && NSClassFromString("ATAudioTapDescription") != nil)
            ? "可用" : "不可用（缺少私有类）"
        appendLog("MyCallRec 启动；tap \(tapAvailability)；CallTelephony \(CallWatcher.isAvailable ? "可用" : "不可用")")
    }

    static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
        try? session.setActive(true)
    }

    func appendLog(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logLines.insert("[\(stamp)] \(line)", at: 0)
        if logLines.count > 300 { logLines.removeLast(logLines.count - 300) }
    }

    var resolvedTarget: TapTarget? {
        if targetChoice == .process {
            guard let pid = Int32(customPID.trimmingCharacters(in: .whitespaces)), pid > 0 else { return nil }
            return .process(pid)
        }
        return targetChoice.tapTarget
    }

    func startRecording(prefix: String = "rec") {
        guard recorder == nil else { return }
        guard let target = resolvedTarget else {
            appendLog("目标无效：请输入有效的 PID")
            return
        }
        let url = library.newRecordingURL(prefix: prefix)
        do {
            let created = try TapRecorder(target: target, sampleRate: 44100, channels: 2, fileURL: url)
            try created.start()
            recorder = created
            isRecording = true
            elapsed = 0
            packets = 0
            currentFile = url.lastPathComponent
            appendLog("开始录制 target=\(target.label) -> \(url.path)")
            startTicker()
        } catch {
            appendLog("开始录制失败：\(error)")
            recorder = nil
            isRecording = false
        }
    }

    func stopRecording() {
        guard let running = recorder else { return }
        running.stop()
        appendLog(String(format: "停止录制：%.2f 秒 / %llu 包", running.secondsRecorded, running.packetsWritten))
        if running.packetsWritten == 0 {
            appendLog("警告：0 个音频包 —— 通常是权限不足（entitlement）或该目标没有音频输出")
        }
        recorder = nil
        isRecording = false
        stopTicker()
        library.refresh()
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in
                guard let running = model.recorder else { return }
                model.elapsed = running.secondsRecorded
                model.packets = running.packetsWritten
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    func toggleAutoRecord() {
        if autoRecord, let watcher {
            watcher.stop()
            self.watcher = nil
            appendLog("已停止通话监听")
            autoRecord = false
            return
        }
        let observer = CallWatcher()
        guard observer.start(handler: { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }) else {
            appendLog("通话监听启动失败")
            return
        }
        watcher = observer
        autoRecord = true
        appendLog("已开始通话监听：接听后自动录制，挂断自动停止")
    }

    private func handle(_ event: CallEvent) {
        let names: [CallState: String] = [.unknown: "未知", .answered: "已接通", .droppedInterrupted: "中断",
                                         .outgoingInitiated: "去电呼叫中", .incoming: "来电", .incomingEnded: "来电结束"]
        callStateText = names[event.state] ?? "状态 \(event.state.rawValue)"
        if !(event.address ?? "").isEmpty || event.displayName != nil {
            appendLog("通话事件 \(callStateText) 号码=\(event.address ?? "-") 名称=\(event.displayName ?? "-")")
        }
        if event.state == .answered, recorder == nil {
            startRecording(prefix: "call")
        } else if event.state != .answered, recorder != nil, isRecording {
            stopRecording()
        }
    }

    func refreshProcesses() {
        let all = ProcessList.running()
        processes = ProcessList.interesting(from: all).isEmpty ? all : ProcessList.interesting(from: all)
        appendLog("进程列表：共 \(all.count) 个，显示 \(processes.count) 个")
    }
}

/// Row layout that works on iOS 15 as well (LabeledContent is iOS 16+).
struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var playing: URL?
    @State private var player: AVAudioPlayer?
    @State private var showingProcesses = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("状态")) {
                    InfoRow(title: "通话", value: model.callStateText)
                    InfoRow(title: "私有 tap", value: model.tapAvailability)
                    InfoRow(title: "当前文件", value: model.currentFile)
                    InfoRow(title: "时长", value: String(format: "%.1f 秒", model.elapsed))
                    InfoRow(title: "音频包", value: "\(model.packets)")
                }

                Section(header: Text("录音")) {
                    Picker("Target", selection: $model.targetChoice) {
                        ForEach(TargetChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    if model.targetChoice == .process {
                        HStack {
                            TextField("PID", text: $model.customPID)
                                .keyboardType(.numberPad)
                            Button("进程列表") {
                                model.refreshProcesses()
                                showingProcesses = true
                            }
                        }
                    }
                    Toggle("接听后自动录制", isOn: Binding(
                        get: { model.autoRecord },
                        set: { _ in model.toggleAutoRecord() }))
                    Button(model.isRecording ? "停止录制" : "开始录制") {
                        if model.isRecording {
                            model.stopRecording()
                        } else {
                            model.startRecording()
                        }
                    }
                    .foregroundColor(model.isRecording ? .red : .blue)
                }

                Section(header: Text("录音文件（\(model.library.recordings.count)）")) {
                    if model.library.recordings.isEmpty {
                        Text("暂无录音").foregroundColor(.secondary)
                    }
                    ForEach(model.library.recordings) { recording in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(recording.name).font(.footnote)
                                Text(String(format: "%.0f KB · %@", Double(recording.size) / 1024,
                                            DateFormatter.localizedString(from: recording.modified,
                                                                          dateStyle: .short,
                                                                          timeStyle: .short)))
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(playing == recording.url ? "停止" : "播放") {
                                if playing == recording.url {
                                    player?.stop()
                                    player = nil
                                    playing = nil
                                } else if let created = try? AVAudioPlayer(contentsOf: recording.url) {
                                    created.prepareToPlay()
                                    created.play()
                                    player = created
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

                Section(header: Text("日志")) {
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
        .sheet(isPresented: $showingProcesses) {
            NavigationView {
                List(model.processes) { entry in
                    Button {
                        model.customPID = "\(entry.pid)"
                        showingProcesses = false
                    } label: {
                        VStack(alignment: .leading) {
                            Text("\(entry.pid) · \(entry.name)").font(.footnote)
                            Text(entry.path).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                .navigationTitle("选择进程")
                .toolbar {
                    Button("完成") { showingProcesses = false }
                }
            }
        }
    }
}
