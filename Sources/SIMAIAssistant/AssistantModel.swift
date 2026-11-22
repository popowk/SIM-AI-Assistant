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
    @Published var observingPhone = false
    @Published var phoneObservationStatus = "尚未开始"
    @Published var phoneObservationElapsed = 0
    @Published var adbStatus = "未检测 ADB"
    @Published var adbChecking = false
    @Published var adbInstalling = false
    @Published var apkInstallStatus = "尚未安装伴侣 APK"
    @Published var liveSyncEnabled = UserDefaults.standard.object(forKey: "SIMAI_LIVE_SYNC") as? Bool ?? true
    @Published var liveBridgeStatus = "正在检查 USB 连接"
    @Published var livePhoneState = "未连接"
    @Published var liveCallEvents: [String] = []
    @Published var selectedADBPath = UserDefaults.standard.string(forKey: "SIMAI_ADB_PATH") ?? ""
    @Published var cleanupPreviewText = ""
    @Published var isAudioTestRunning = false
    @Published var alertText: String?
    @Published var reproductionNotes = ""
    @Published var exportOpen = false

    let version = "0.1.4"
    let buildNumber = "5"
    private let logger = Logger(subsystem: "com.simai.assistant", category: "diagnostics")
    private let logs: LogStore
    private let audioInspector = AudioInspector()
    private let microphoneProbe = MicrophoneLevelProbe()
    private let loopbackProbe = LocalLoopbackProbe()
    private var phoneTimer: Timer?
    private var phoneObservationStartedAt: Date?
    private var phoneLastFingerprint = ""
    private var phoneObservationChanges = 0
    private var bridgeTimer: Timer?
    private var bridgeLink: ADBBridgeLink?
    private var bridgeBusy = false
    private var bridgeSession = ""
    private var bridgeSequence = 0
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
        startLiveSyncTimer()
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
            log(.info, .bluetooth, "蓝牙设备名未匹配 vivo S9e；ADB/APK 方案不依赖蓝牙配对")
        } else {
            log(.info, .bluetooth, "已发现 vivo 蓝牙配对候选；本项目不接管 HFP 蓝牙控制器")
        }
        if audio.microphonePermission == "已拒绝" {
            log(.warn, .audio, "麦克风权限被拒绝", code: .microphoneDenied)
        }
    }


    /// Observes only local Bluetooth and CoreAudio state (not real phone calls).
    func startPhoneObservation() {
        guard !observingPhone else { return }
        sessionID = "phone-\(UUID().uuidString)"
        observingPhone = true
        phoneObservationElapsed = 0
        phoneObservationChanges = 0
        phoneObservationStartedAt = Date()
        bluetooth = BluetoothInspector.inspect()
        audio = audioInspector.inspect()
        phoneLastFingerprint = phoneFingerprint(bluetooth, audio)
        phoneObservationStatus = "观察中；请使用另一部电话拨打 vivo S9e"
        log(.info, .call, "开始 60 秒真实来电只读观察；不会录音或控制手机",
            details: ["pairedBT": "\(bluetooth.devices.count)",
                      "connectedBT": "\(bluetooth.devices.filter(\.connected).count)",
                      "audioCount": "\(audio.devices.count)"])
        phoneTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickPhoneObservation() }
        }
    }
    func markPhoneRinging() {
        guard observingPhone else { return }
        log(.info, .call, "人工标记手机正在响铃（不是自动检测）",
            details: ["elapsedSeconds": "\(phoneObservationElapsed)"])
    }
    func stopPhoneObservation() {
        guard observingPhone else { return }
        observingPhone = false
        phoneTimer?.invalidate()
        phoneTimer = nil
        phoneObservationStartedAt = nil
        phoneObservationStatus = "结束：\(phoneObservationChanges) 次设备变化；HFP/SCO 未验证"
        log(.info, .call, "真实来电观察结束；无状态变化不等于不支持 HFP",
            details: ["elapsedSeconds": "\(phoneObservationElapsed)",
                      "changeCount": "\(phoneObservationChanges)"])
    }
    private func tickPhoneObservation() {
        guard observingPhone else { return }
        phoneObservationElapsed = Int(Date().timeIntervalSince(phoneObservationStartedAt ?? Date()))
        let nextBT = BluetoothInspector.inspect()
        let nextAudio = audioInspector.inspect()
        let fingerprint = phoneFingerprint(nextBT, nextAudio)
        if fingerprint != phoneLastFingerprint {
            phoneObservationChanges += 1
            log(.info, .call, "观察到设备变化（不代表已获得电话音频）",
                details: ["elapsedSeconds": "\(phoneObservationElapsed)",
                          "connectedBT": "\(nextBT.devices.filter(\.connected).count)",
                          "vivoCandidateConnected": "\(nextBT.devices.contains { $0.targetCandidate && $0.connected })",
                          "audioDevices": "\(nextAudio.devices.count)",
                          "defaultInputChanged": "\(nextAudio.devices.first(where: { $0.isDefaultInput })?.id != audio.devices.first(where: { $0.isDefaultInput })?.id)",
                          "defaultOutputChanged": "\(nextAudio.devices.first(where: { $0.isDefaultOutput })?.id != audio.devices.first(where: { $0.isDefaultOutput })?.id)"])
        }
        phoneLastFingerprint = fingerprint
        bluetooth = nextBT
        audio = nextAudio
        if phoneObservationElapsed >= 60 { stopPhoneObservation() }
    }
    private func phoneFingerprint(_ bt: BluetoothSnapshot, _ au: AudioSnapshot) -> String {
        // IDs are never written to diagnostic logs; only compared in memory.
        let bonds = bt.devices.map { "\($0.id):\($0.connected)" }.sorted().joined(separator: "|")
        let sound = au.devices.map {
            "\($0.id):\($0.sampleRate ?? 0):\($0.isDefaultInput):\($0.isDefaultOutput)"
        }.sorted().joined(separator: "|")
        return bonds + "||" + sound
    }



    // Phone events are received from the user-authorized Android APK over USB ADB,
    // never from Mac Bluetooth and never from a cellular audio channel.
    private func startLiveSyncTimer() {
        guard bridgeTimer == nil else { return }
        bridgeTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollLiveBridge() }
        }
        pollLiveBridge()
    }

    func setLiveSyncEnabled(_ value: Bool) {
        liveSyncEnabled = value
        UserDefaults.standard.set(value, forKey: "SIMAI_LIVE_SYNC")
        if value {
            liveBridgeStatus = "正在连接手机"
            pollLiveBridge()
        } else {
            closeLiveBridge()
            liveBridgeStatus = "已关闭自动同步"
            livePhoneState = "未连接"
        }
    }

    func reconnectLiveBridge() {
        closeLiveBridge()
        liveBridgeStatus = "正在重连……"
        if liveSyncEnabled { pollLiveBridge() }
    }

    private func closeLiveBridge() {
        if let link = bridgeLink {
            let selected = selectedADBPath
            Task.detached(priority: .utility) {
                ADBInspector.closeBridge(at: selected, link: link)
            }
        }
        bridgeLink = nil
        bridgeSession = ""
        bridgeSequence = 0
    }

    private func pollLiveBridge() {
        guard liveSyncEnabled, !adbInstalling, !bridgeBusy else { return }
        bridgeBusy = true
        if let link = bridgeLink {
            let since = bridgeSequence
            Task { [weak self] in
                guard let self else { return }
                var request = URLRequest(url: URL(
                    string: "http://127.0.0.1:\(link.localPort)/events?since=\(since)")!)
                request.httpMethod = "GET"
                request.timeoutInterval = 3.0
                request.setValue(link.token, forHTTPHeaderField: "X-SIMAI-Token")
                request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw NSError(domain: "SIMAI.ADBBridge", code: 403)
                    }
                    let snapshot = try JSONDecoder().decode(PhoneBridgeSnapshot.self, from: data)
                    guard snapshot.schema == 1, snapshot.running,
                          ["IDLE", "RINGING", "OFFHOOK"].contains(snapshot.state) else {
                        throw NSError(domain: "SIMAI.ADBBridge", code: 422)
                    }
                    if self.bridgeSession != snapshot.session {
                        self.bridgeSession = snapshot.session
                        self.bridgeSequence = 0
                        self.liveCallEvents.removeAll()
                        self.log(.info, .call, "Android 电话状态桥接会话已建立",
                                 details: ["bridgeSchema": "1"])
                    }
                    for event in snapshot.newEvents(after: self.bridgeSequence) {
                        let displayTime = Date(timeIntervalSince1970: Double(event.at) / 1000)
                            .formatted(date: .omitted, time: .standard)
                        self.liveCallEvents.insert("\(displayTime) · \(event.state)", at: 0)
                        self.liveCallEvents = Array(self.liveCallEvents.prefix(16))
                        self.log(.info, .call, "收到 Android 实时电话状态",
                                 details: ["state": event.state, "sequence": "\(event.seq)",
                                           "source": "USB_ADB"])
                        self.bridgeSequence = max(self.bridgeSequence, event.seq)
                    }
                    // A bounded Android history may skip earlier events; keep the cursor moving.
                    self.bridgeSequence = max(self.bridgeSequence, snapshot.seq)
                    self.livePhoneState = snapshot.state
                    self.liveBridgeStatus = "已连接 · USB ADB 自动同步"
                } catch {
                    self.liveBridgeStatus = "连接中断，准备自动重连（请确认手机监听已开启）"
                    self.livePhoneState = "未连接"
                    self.closeLiveBridge()
                }
                self.bridgeBusy = false
            }
        } else {
            let path = selectedADBPath
            Task { [weak self] in
                let result = await Task.detached(priority: .utility) {
                    ADBInspector.openBridge(at: path)
                }.value
                guard let self else { return }
                self.bridgeBusy = false
                if let link = result.link {
                    self.bridgeLink = link
                    self.bridgeSession = ""
                    self.bridgeSequence = 0
                    self.liveBridgeStatus = result.message
                    self.log(.info, .call, "ADB USB 端口转发连接建立（未读取设备序列号）")
                    self.pollLiveBridge()
                } else if self.liveBridgeStatus != result.message {
                    self.liveBridgeStatus = result.message
                }
            }
        }
    }

    func prepareLogCleanup(days: Int) -> Bool {
        do {
            let preview = try (days == 0
                ? logs.previewAllLogs()
                : logs.previewCleanup(olderThanDays: days))
            let size = ByteCountFormatter.string(fromByteCount: preview.totalBytes, countStyle: .file)
            cleanupPreviewText = days == 0
                ? "将删除全部 \(preview.fileCount) 个应用日志文件（包括今天），共 \(size)。"
                : "将删除 \(preview.fileCount) 个旧日志文件，共 \(size)。今天及最近 \(days) 天的日志保留。"
            return true
        } catch {
            alertText = "无法计算旧日志清理范围：\((error as NSError).localizedDescription)"
            return false
        }
    }

    func cleanOldLogs(days: Int) {
        do {
            let deleted = try (days == 0
                ? logs.clearAllLogs()
                : logs.cleanup(olderThanDays: days))
            events = (try? logs.readRecent(limit: 150)) ?? []
            lastError = events.first(where: { $0.level == .error })
            cleanupPreviewText = "已清理 \(deleted.fileCount) 个应用日志文件"
            if days == 0 {
                // Do not immediately recreate an events-*.jsonl file after a clear-all.
                logger.info("用户主动清空本应用全部本地 JSONL 日志（系统 OSLog 不可由应用删除）")
                alertText = "已清空本应用全部 \(deleted.fileCount) 个 JSONL 日志文件（含今天）。macOS 系统 OSLog 不在清理范围。"
            } else {
                log(.info, .diagnostic, "用户手动清理旧日志",
                    details: ["retentionDays": "\(days)",
                              "removedFiles": "\(deleted.fileCount)",
                              "removedBytes": "\(deleted.totalBytes)"])
                alertText = "已清理 \(deleted.fileCount) 个旧日志文件；最近 \(days) 天仍保留。"
            }
        } catch {
            log(.error, .diagnostic, "手动清理旧日志失败",
                details: ["errorCode": "\((error as NSError).code)"])
            alertText = "清理旧日志失败，请检查日志文件夹权限。"
        }
    }

    func inspectADB() {
        guard !adbChecking else { return }
        adbChecking = true
        adbStatus = "检测 ADB 中……"
        let selectedPath = selectedADBPath
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = ADBInspector.inspect(at: selectedPath)
            await MainActor.run {
                guard let self else { return }
                self.adbChecking = false
                self.adbStatus = result.status
                self.log(.info, .system, "Android ADB 自检完成（不读取设备序列号和电话音频）",
                    details: ["adbInstalled": "\(result.installed)",
                              "authorizedCount": "\(result.authorized)",
                              "unauthorizedCount": "\(result.unauthorized)",
                              "offlineCount": "\(result.offline)"])
            }
        }
    }


    var embeddedAPKAvailable: Bool {
        guard let bundle = Bundle.main.resourceURL else { return false }
        return FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("SIMAI-Companion.apk").path)
    }

    func selectADB() {
        let panel = NSOpenPanel()
        panel.title = "选择 Android SDK platform-tools 文件夹中的 adb"
        panel.message = "请选中 adb 可执行文件，而不是文件夹。路径只保存在本机偏好设置中。"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "使用此 adb"
        if panel.runModal() == .OK, let url = panel.url {
            guard url.lastPathComponent == "adb",
                  FileManager.default.isExecutableFile(atPath: url.path) else {
                alertText = "所选文件必须是可执行的 adb，请选择 platform-tools/adb。"
                return
            }
            closeLiveBridge()
            selectedADBPath = url.path
            UserDefaults.standard.set(url.path, forKey: "SIMAI_ADB_PATH")
            log(.info, .system, "用户手动设置 ADB 路径（路径不写入诊断日志）")
            inspectADB()
            pollLiveBridge()
        }
    }

    func resetADBSelection() {
        closeLiveBridge()
        selectedADBPath = ""
        UserDefaults.standard.removeObject(forKey: "SIMAI_ADB_PATH")
        log(.info, .system, "ADB 切换为自动路径检测")
        inspectADB()
        pollLiveBridge()
    }

    func installAndroidCompanion() {
        guard !adbInstalling else { return }
        guard let resource = Bundle.main.resourceURL?.appendingPathComponent("SIMAI-Companion.apk"),
              FileManager.default.fileExists(atPath: resource.path) else {
            alertText = "当前 App 未包含 Android 伴侣 APK；请下载 GitHub 最新完整测试包。"
            return
        }
        closeLiveBridge()
        adbInstalling = true
        apkInstallStatus = "正在通过 ADB 安装/覆盖手机应用……"
        let adb = selectedADBPath
        log(.info, .system, "用户确认开始安装或覆盖 Android 伴侣 APK",
            details: ["version": "0.2.0"])
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = ADBInspector.install(at: adb, apk: resource)
            await MainActor.run {
                guard let self else { return }
                self.adbInstalling = false
                self.apkInstallStatus = outcome.status
                self.log(outcome.succeeded ? .info : .warn, .system,
                    outcome.succeeded ? "Android APK 安装成功" : "Android APK 安装失败",
                    details: ["success": "\(outcome.succeeded)"])
                self.alertText = outcome.status
                self.inspectADB()
                self.pollLiveBridge()
            }
        }
    }


    /// Separate opt-in action because uninstall permanently removes companion app data.
    func reinstallAndroidCompanionAfterConfirmation() {
        guard !adbInstalling else { return }
        guard let apk = Bundle.main.resourceURL?.appendingPathComponent("SIMAI-Companion.apk"),
              FileManager.default.fileExists(atPath: apk.path) else {
            alertText = "未找到内置 APK"
            return
        }
        closeLiveBridge()
        adbInstalling = true
        apkInstallStatus = "已确认清空旧版伴侣数据，正在重新安装……"
        let adbPath = selectedADBPath
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = ADBInspector.reinstallAfterSignatureChange(at: adbPath, apk: apk)
            await MainActor.run {
                guard let self else { return }
                self.adbInstalling = false
                self.apkInstallStatus = outcome.status
                self.alertText = outcome.status
                self.log(outcome.succeeded ? .info : .warn, .system,
                         "用户确认的 Android 伴侣重装操作结束",
                         details: ["success": "\(outcome.succeeded)"])
                self.inspectADB()
                self.pollLiveBridge()
            }
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
