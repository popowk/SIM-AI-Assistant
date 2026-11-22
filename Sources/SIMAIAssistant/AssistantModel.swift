#if os(macOS)
import Foundation
import AppKit
import AVFoundation
import OSLog
import SwiftUI
import SIMAICore

@MainActor
final class AssistantModel: ObservableObject {
    @Published var bluetooth = BluetoothSnapshot()
    @Published var audio = AudioSnapshot()
    @Published var call = CallSimulator()
    @Published var events: [DiagnosticEvent] = []
    @Published var voiceMarkedActive = false
    @Published var probeStatus = "尚未测试"
    @Published var loopbackStatus = "尚未测试"
    @Published var isAudioTestRunning = false
    @Published var alertText: String?
    @Published var reproductionNotes = ""
    @Published var exportOpen = false

    let version = "0.1.0"
    let buildNumber = "1"
    private let logger = Logger(subsystem: "com.simai.assistant", category: "diagnostics")
    private let logs: LogStore
    private let audioInspector = AudioInspector()
    private let microphoneProbe = MicrophoneLevelProbe()
    private let loopbackProbe = LocalLoopbackProbe()
    private(set) var sessionID = UUID().uuidString
    private(set) var lastError: DiagnosticEvent?

    init() {
        let appSupport = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("SIM-AI-Assistant/logs", isDirectory: true)
        if let primary = try? LogStore(directory: appSupport) {
            logs = primary
        } else {
            // Explicitly use an ephemeral fallback if the user profile is not writable.
            let emergency = FileManager.default.temporaryDirectory.appendingPathComponent("SIMAI-emergency-\(UUID().uuidString)")
            logs = try! LogStore(directory: emergency)
        }
        events = (try? logs.readRecent(limit: 100)) ?? []
        log(.info, .system, "程序启动，诊断日志已初始化")
        refresh()
    }

    var system: SystemSnapshot {
        SystemSnapshot(appVersion: version, build: buildNumber,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture)
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    func log(_ level: DiagnosticLevel, _ module: DiagnosticModule, _ message: String,
             code: SIMErrorCode? = nil, details: [String: String] = [:]) {
        let event = DiagnosticEvent(sessionID: sessionID, level: level, module: module,
            code: code?.rawValue, message: message, details: details).sanitized()
        do { try logs.append(event) }
        catch { alertText = "无法写入本地诊断日志，请检查用户目录权限。" }
        events.insert(event, at: 0)
        if events.count > 150 { events = Array(events.prefix(150)) }
        if level == .error { lastError = event }
        switch level {
        case .debug: logger.debug("\(event.message, privacy: .private)")
        case .info: logger.info("\(event.message, privacy: .private)")
        case .warn: logger.warning("\(event.message, privacy: .private)")
        case .error: logger.error("\(event.message, privacy: .private)")
        }
    }

    func refresh() {
        bluetooth = BluetoothInspector.inspect()
        audio = audioInspector.inspect()
        log(.info, .bluetooth, "蓝牙配对设备检查完成", details: ["pairedCount": "\(bluetooth.devices.count)",
            "connectedCount": "\(bluetooth.devices.filter(\.connected).count)"])
        log(.info, .audio, "CoreAudio 设备检查完成", details: ["deviceCount": "\(audio.devices.count)",
            "microphonePermission": audio.microphonePermission])
        if !bluetooth.scanSucceeded {
            log(.warn, .bluetooth, "无法取得蓝牙已配对列表", code: .bluetoothUnavailable)
        } else if !bluetooth.devices.contains(where: \.targetCandidate) {
            log(.warn, .bluetooth, "已配对设备中未识别到 vivo S9e 候选设备", code: .bluetoothNotPaired)
        } else {
            log(.warn, .bluetooth, "已配对不代表 HFP 或 SCO 验证成功", code: .bluetoothHFPUnverified)
        }
        if audio.microphonePermission == "已拒绝" {
            log(.warn, .audio, "麦克风权限被拒绝", code: .microphoneDenied)
        }
    }

    func simulateCall() {
        do {
            let transition = try call.ring()
            sessionID = transition.sessionID
            log(.info, .call, "模拟来电开始（不含真实手机号）")
        } catch { log(.warn, .call, "模拟来电状态变更失败", code: .invalidCallTransition) }
    }

    func answerSimulated() {
        do { try call.answer(); log(.info, .call, "模拟接听成功（不控制实体电话）") }
        catch { log(.warn, .call, "模拟接听失败", code: .invalidCallTransition) }
    }

    func hangupSimulated() {
        do { try call.hangup(); log(.info, .call, "模拟挂断完成（不控制实体电话）") }
        catch { log(.warn, .call, "模拟挂断失败", code: .invalidCallTransition) }
    }

    func inject(_ fault: TestFault) {
        sessionID = "test-\(UUID().uuidString.prefix(8))"
        log(.error, fault.module, fault.rawValue + "（测试注入，非真实故障）", code: fault.code,
            details: ["testMode": "true"])
        alertText = "已模拟：\(fault.rawValue)。现在可以导出诊断包验证故障定位。"
    }

    func runMicrophoneTest() {
        let state = AVCaptureDevice.authorizationStatus(for: .audio)
        switch state {
        case .authorized: startProbe()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.startProbe() }
                    else { self.handleMicDenied() }
                }
            }
        default: handleMicDenied()
        }
    }

    private func handleMicDenied() {
        probeStatus = "麦克风权限未授权"
        audio.microphonePermission = AudioInspector.microphonePermission()
        log(.error, .audio, "用户未授权麦克风输入测试", code: .microphoneDenied)
    }

    private func startProbe() {
        guard !isAudioTestRunning else { return }
        isAudioTestRunning = true
        probeStatus = "测量中（1.5 秒，不录音）"
        log(.info, .audio, "用户发起麦克风电平测试（不会保存音频）")
        microphoneProbe.run { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isAudioTestRunning = false
                switch result {
                case .success(let value):
                    self.audio.lastProbePeak = value
                    self.audio.microphonePermission = "已授权"
                    self.probeStatus = String(format: "麦克风峰值 RMS %.4f（非 HFP 验证）", value)
                    self.log(.info, .audio, "麦克风电平测试完成", details: ["peakRMS": String(format: "%.4f", value)])
                case .failure(let error):
                    self.probeStatus = "麦克风测试失败"
                    self.log(.error, .audio, "CoreAudio 测试初始化失败", code: .audioTestFailed,
                             details: ["errorDomain": (error as NSError).domain, "errorCode": "\((error as NSError).code)"])
                }
            }
        }
    }

    func runLocalLoopback() {
        guard !isAudioTestRunning else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.startLocalLoopback() }
                    else { self.handleMicDenied() }
                }
            }
        } else if status == .authorized {
            startLocalLoopback()
        } else {
            handleMicDenied()
        }
    }

    private func startLocalLoopback() {
        guard !isAudioTestRunning else { return }
        isAudioTestRunning = true
        loopbackStatus = "本机回环运行中（最长 2 秒，音量 5%）"
        log(.info, .audio, "用户发起本机麦克风到扬声器的短时回环（非电话音频）")
        loopbackProbe.run { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isAudioTestRunning = false
                switch result {
                case .success:
                    self.loopbackStatus = "本机 2 秒回环结束；请人工确认是否听见自己的声音"
                    self.log(.info, .audio, "本机回环运行结束（听感需人工确认）")
                case .failure(let error):
                    self.loopbackStatus = "本机回环启动失败"
                    self.log(.error, .audio, "本机音频回环初始化失败", code: .audioTestFailed,
                             details: ["errorDomain": (error as NSError).domain,
                                       "errorCode": "\((error as NSError).code)"])
                }
            }
        }
    }

    func playSpeakerBeep() {
        NSSound.beep()
        log(.info, .audio, "用户触发扬声器试听提示音（非电话链路）")
    }

    func openChatGPT() {
        guard let url = URL(string: "https://chatgpt.com/") else { return }
        NSWorkspace.shared.open(url)
        log(.info, .voice, "用户打开 ChatGPT 官方网页，Voice 需用户手动开启", code: .voiceManualOnly)
    }

    func setVoiceMarkedActive(_ active: Bool) {
        voiceMarkedActive = active
        log(.info, .voice, active ? "用户标记官方 Voice 已启动（人工声明）" : "用户标记官方 Voice 已结束（人工声明）")
    }

    func restoreAudio() {
        let results = audioInspector.restoreStartupDefaults()
        log(.info, .audio, "用户要求恢复应用启动时的默认音频设备", details: ["summary": results.joined(separator: "; ")])
        alertText = results.isEmpty ? "应用启动时未能读取默认设备，未更改系统设置。" : results.joined(separator: "\n")
        refresh()
    }

    func openLogFolder() {
        NSWorkspace.shared.open(logs.directory)
        log(.info, .diagnostic, "用户打开本地日志文件夹")
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = DiagnosticsExporter.suggestedFileName()
        panel.title = "保存脱敏诊断包"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let context = ExportContext(system: system, bluetooth: bluetooth, audio: audio,
            sessionID: sessionID, recentError: lastError, callState: call.state,
            userReproductionNotes: reproductionNotes)
        do {
            try DiagnosticsExporter(logs: logs).export(context: context, to: destination)
            log(.info, .diagnostic, "诊断 ZIP 已在用户选定路径生成（未上传）")
            alertText = "诊断包已生成。请先自行查看内容，再决定是否发送。"
        } catch {
            log(.error, .diagnostic, "导出诊断 ZIP 失败", code: .exportFailed,
                details: ["errorCode": "\((error as NSError).code)"])
            alertText = "诊断包导出失败，请查看日志。"
        }
    }
}
#endif
