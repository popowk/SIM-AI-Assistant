#if os(macOS)
import Foundation
import AppKit
import AVFoundation
import OSLog
import SwiftUI
import SIMAICore

@MainActor
final class AssistantModel: ObservableObject {
    @Published var audio = AudioSnapshot()
    @Published var events: [DiagnosticEvent] = []
    @Published var probeStatus = "尚未测试"
    @Published var adbStatus = "未检测 ADB"
    @Published var adbChecking = false
    @Published var autoADBDetectionEnabled =
        UserDefaults.standard.object(forKey: "SIMAI_AUTO_ADB") as? Bool ?? true
    @Published var adbDiscoveryDescription = "自动识别中"
    @Published var lastADBScanAt: Date?
    @Published var adbInstalling = false
    @Published var apkInstallStatus = "尚未安装伴侣 APK"
    @Published var screenControlStatus = "尚未打开手机屏幕（需要本机安装 scrcpy）"
    @Published var screenControlStarting = false
    @Published var screenControlRunning = false
    @Published var liveSyncEnabled = UserDefaults.standard.object(forKey: "SIMAI_LIVE_SYNC") as? Bool ?? true
    @Published var liveBridgeStatus = "正在检查 ADB 连接"
    @Published var livePhoneState = "未连接"
    @Published var answerCallBusy = false
    @Published var answerCallStatus = "尚未请求接听；需手机授予「接听电话」权限"
    @Published var autoCallEnabled =
        UserDefaults.standard.object(forKey: "SIMAI_AUTO_CALL") as? Bool ?? true
    @Published var voiceSessionPrepared = false
    @Published var autoCallStatus = "自动接听已设为默认，但需要先准备可用的语音会话，避免来电被接起后无人回答"
    @Published var liveBridgeLastSync: Date?
    @Published var adbTransportHealth = "尚未检查"
    @Published var adbShellHealth = "尚未检查"
    @Published var adbForwardHealth = "尚未检查"
    @Published var adbBridgeHealthDetail = "锁屏后可点击「诊断连接层」"
    @Published var adbBridgeHealthChecking = false
    @Published var liveCallEvents: [String] = []
    @Published var audioProbeBusy = false
    @Published var audioProbeStatus = "尚未测试真实电话音频"
    @Published var audioProbeFacts: [String] = []
    @Published var audioProbeToneSent = false
    @Published var audioProbeRemoteConfirmed = false
    @Published var liveVoiceStatus = "尚未开始实时语音桥接"
    @Published var liveVoiceStarting = false
    @Published var liveVoiceActive = false
    @Published var liveVoiceMicrophoneEnabled = false
    @Published var chatGPTVoiceRouteEnabled = false
    @Published var chatGPTVoiceRouteStatus = "尚未开启（仅将电话下行送入 ChatGPT）"
    @Published var chatGPTVoiceRouteDropped = 0
    @Published var selectedVoiceMonitorOutputID = ""
    @Published var automaticGPTOutputEnabled =
        UserDefaults.standard.object(forKey: "SIMAI_AUTO_GPT_OUTPUT") as? Bool ?? true
    @Published var automaticGPTOutputStatus = "自动输出路由已待命；仅在 GPT 电话会话需要时切至 BlackHole 16ch"
    @Published var blackHoleInstallerBusy = false
    @Published var blackHoleInstallerStatus = "检测 BlackHole 2ch / 16ch 状态后可直接获取官方安装程序，无需 Homebrew"
    @Published var aiReplyMonitorEnabled = false
    @Published var aiReplyToPhoneEnabled = false
    @Published var aiReplyReturnStatus = "尚未启动 GPT 回复监听"
    @Published var aiReplyReceivedFrames = 0
    @Published var aiReplyMonitorDropped = 0
    @Published var aiReplyUplinkUnderflow = 0
    @Published var aiReplyPeakRMS = 0.0
    @Published var liveVoiceRxFrames = 0
    @Published var liveVoiceTxFrames = 0
    @Published var liveVoiceDropFrames = 0
    @Published var liveVoiceMicUnderflows = 0
    @Published var liveVoiceMicOverflows = 0
    @Published var liveVoiceUplinkLateFrames = 0
    @Published var liveVoiceMicBufferedMs = 0
    @Published var liveVoiceHandshakeAttempts = 0
    @Published var feishuWebhookDraft = ""
    @Published var feishuSigningSecretDraft = ""
    @Published var feishuForwardEnabled = true
    @Published var feishuSavedOnMac = false
    @Published var feishuSyncBusy = false
    @Published var feishuSyncStatus = "尚未配置飞书 Webhook"
    @Published var selectedADBPath = UserDefaults.standard.string(forKey: "SIMAI_ADB_PATH") ?? ""
    @Published var cleanupPreviewText = ""
    @Published var isAudioTestRunning = false
    @Published var alertText: String?
    @Published var reproductionNotes = ""
    @Published var exportOpen = false

    let version = "0.4.11"
    let buildNumber = "28"
    private let logger = Logger(subsystem: "com.simai.assistant", category: "diagnostics")
    private let logs: LogStore
    private var audioInspector = AudioInspector()
    private let voiceOutputRouter = AutoVoiceOutputRouter()
    private let microphoneProbe = MicrophoneLevelProbe()
    private var voiceStream: PhoneAudioStream?
    private var autoCallState = AutoCallStateMachine()
    private var autoCallAudioRequested = false
    private var screenControlProcess: Process?
    private var voiceSessionID = ""
    private var pendingBlackHoleInstallChannels: Int?
    private var bridgeTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var nextADBScanAt = Date.distantPast
    private var adbScanGeneration = 0
    private var adbScanSignature = ""
    private var adbWasAuthorized = false
    private var bridgeLink: ADBBridgeLink?
    private var bridgeBusy = false
    private var bridgeCursor = PhoneBridgeCursor()
    private var bridgeGeneration = 0
    private var bridgeUsingFileFallback = false
    private var nextHTTPRecoveryAttempt = Date.distantPast
    private var bridgeRetryAfter = Date.distantPast
    private var bridgeConsecutiveFailures = 0
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
        if let saved = FeishuWebhookStore.load() {
            feishuWebhookDraft = saved.webhook
            feishuSigningSecretDraft = saved.signingSecret
            feishuForwardEnabled = saved.enabled
            feishuSavedOnMac = true
            feishuSyncStatus = "已从 Mac 钥匙串读取配置；如手机尚未同步，请点击同步"
        }
        log(.info, .system, "程序启动，诊断日志已初始化")
        let recoveredOutput = voiceOutputRouter.recoverPreviousSession()
        if recoveredOutput == "ROUTE_RESTORED" {
            // AudioInspector was initialized before recovery. Refresh its
            // captured defaults so the older manual-recovery button cannot
            // accidentally restore a stale BlackHole default on this launch.
            audioInspector = AudioInspector()
        }
        if recoveredOutput != "ROUTE_NOT_OWNED" {
            automaticGPTOutputStatus = recoveredOutput == "ROUTE_RESTORED"
                ? "已恢复上一次异常退出前的 Mac 声音输出"
                : "启动时检查了遗留的自动输出路由：" + recoveredOutput
            log(.info, .audio, "自动音频输出启动恢复",
                details: ["routeCode": recoveredOutput])
        }
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

    /// Download the vendor's unmodified .pkg after user confirmation.
    /// The macOS Installer—not this application—requests administrator
    /// approval. No silent installation or privileged shell command.
    func openOfficialBlackHoleInstaller(channels: Int) {
        guard !blackHoleInstallerBusy, channels == 2 || channels == 16 else { return }
        refresh()
        if audio.devices.contains(where: {
            $0.displayName.caseInsensitiveCompare("BlackHole \(channels)ch") == .orderedSame
        }) {
            blackHoleInstallerStatus = "BlackHole \(channels)ch 已安装，无需重复安装"
            return
        }
        blackHoleInstallerBusy = true
        blackHoleInstallerStatus = "正在从开发者官网下载并验证 BlackHole \(channels)ch 官方安装包……"
        log(.info, .audio, "用户主动获取 BlackHole 官方安装程序",
            details: ["channels": "\(channels)"])
        Task { [weak self] in
            do {
                let file = try await OfficialBlackHoleInstaller.prepareOfficialInstaller(channels: channels)
                guard let self else { return }
                self.blackHoleInstallerBusy = false
                if NSWorkspace.shared.open(file) {
                    self.pendingBlackHoleInstallChannels = channels
                    self.blackHoleInstallerStatus = "BlackHole \(channels)ch 安装器已打开。请完成 macOS 管理员授权；程序会自动检测安装结果，可能仍需重启 Mac。"
                } else {
                    self.blackHoleInstallerStatus = "安装包已通过校验但系统安装器未打开。请检查 macOS 安全提示并重试。"
                }
            } catch {
                guard let self else { return }
                self.blackHoleInstallerBusy = false
                let reason: String
                if case OfficialBlackHoleInstaller.Failure.checksumMismatch = error {
                    reason = "官方安装包 SHA-256 不匹配；已拒绝安装。请检查官网是否更新了版本"
                } else if case OfficialBlackHoleInstaller.Failure.invalidResponse = error {
                    reason = "官网返回了无效下载响应"
                } else if case OfficialBlackHoleInstaller.Failure.oversizedFile = error {
                    reason = "官网文件大小异常，已拒绝安装"
                } else {
                    reason = "下载或访问安装包失败；请检查网络、官方网页与磁盘空间"
                }
                self.blackHoleInstallerStatus = reason
                self.log(.warn, .audio, "BlackHole 官方安装程序未能准备",
                    details: ["channels": "\(channels)", "category": "OFFICIAL_PKG_SETUP_FAILED"])
            }
        }
    }

    private func refreshPendingBlackHoleInstall() {
        guard let channels = pendingBlackHoleInstallChannels else { return }
        let snapshot = audioInspector.inspect()
        guard snapshot.devices.contains(where: {
            $0.displayName.caseInsensitiveCompare("BlackHole \(channels)ch") == .orderedSame
        }) else { return }
        pendingBlackHoleInstallChannels = nil
        audio = snapshot
        blackHoleInstallerStatus = "BlackHole \(channels)ch 已被 macOS 识别，可直接使用自动声音路由"
        log(.info, .audio, "已检测到新安装的虚拟音频设备",
            details: ["channels": "\(channels)"])
    }

    func refresh() {
        audio = audioInspector.inspect()
        // Choose an already active real output device by default, if one
        // exists. Never change the macOS system output or select BlackHole.
        if selectedVoiceMonitorOutputID.isEmpty,
           let output = audio.devices.first(where: {
               $0.isDefaultOutput &&
               !$0.displayName.localizedCaseInsensitiveContains("BlackHole") &&
               !$0.displayName.localizedCaseInsensitiveContains("aggregate") &&
               !$0.displayName.localizedCaseInsensitiveContains("multi-output")
           }) {
            selectedVoiceMonitorOutputID = output.id
        }
        if audio.microphonePermission == "已拒绝" {
            log(.warn, .audio, "麦克风权限被拒绝", code: .microphoneDenied)
        }
    }


    /// This setting only arms an already running official Voice session.
    /// There is no official ChatGPT Plus API for unattended voice creation.
    func setAutomaticGPTOutputEnabled(_ enabled: Bool) {
        automaticGPTOutputEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "SIMAI_AUTO_GPT_OUTPUT")
        if !enabled {
            // Preserve safe isolation if a call is already active: stop AI
            // uplink BEFORE returning desktop sound to a physical device.
            if aiReplyToPhoneEnabled || aiReplyMonitorEnabled || chatGPTVoiceRouteEnabled {
                stopGPTTwoWayPhoneBridge()
            } else {
                restoreAutomaticGPTOutput()
            }
            automaticGPTOutputStatus = "自动切换已关闭；不再修改系统默认输出"
        } else {
            automaticGPTOutputStatus = "自动切换已待命；下次已授权的电话会话将使用 BlackHole 16ch"
        }
    }

    /// This is a global macOS output change, so only do it during a
    /// user-authorized AI call. Does not start or verify ChatGPT Voice.
    @discardableResult
    private func prepareAutomaticGPTOutput() -> Bool {
        guard automaticGPTOutputEnabled else {
            automaticGPTOutputStatus = "自动切换已关闭；请自行配置 ChatGPT 语音输出"
            return true
        }
        let code = voiceOutputRouter.activate(physicalMonitorID: selectedVoiceMonitorOutputID)
        switch code {
        case "ROUTE_ACTIVE", "ROUTE_ALREADY_MANAGED":
            refresh()
            automaticGPTOutputStatus = "已自动将 Mac 输出切换至 BlackHole 16ch，通话结束后恢复"
            log(.info, .audio, "GPT 电话自动音频输出已切换",
                details: ["routeCode": code])
            return true
        case "ROUTE_ALREADY_VIRTUAL_MANUAL":
            automaticGPTOutputStatus = "BlackHole 16ch 已由用户选中；未修改系统设置"
            return true
        default:
            automaticGPTOutputStatus = "自动音频输出切换失败（" + code + "），不会自动接听或回传"
            log(.warn, .audio, "自动输出路由不可用",
                details: ["reason": code])
            return false
        }
    }

    func restoreAutomaticGPTOutput() {
        let code = voiceOutputRouter.restore()
        switch code {
        case "ROUTE_RESTORED":
            automaticGPTOutputStatus = "已自动恢复 Mac 原来的真实耳机／扬声器"
            refresh()
        case "ROUTE_NOT_OWNED":
            break
        case "ROUTE_USER_CHANGED_OUTPUT":
            automaticGPTOutputStatus = "检测到你已手动切换输出；保留你选定的新设备"
            refresh()
        default:
            automaticGPTOutputStatus = "音频输出恢复结果：" + code
            refresh()
        }
        if code != "ROUTE_NOT_OWNED" {
            log(.info, .audio, "自动音频输出结束或回收",
                details: ["routeCode": code])
        }
    }

    func shutdownForAppExit() {
        // Closing the app must stop forwarding caller audio before changing
        // the global sound device. Also closes scrcpy as before.
        if liveVoiceStarting || liveVoiceActive { stopLiveVoice() }
        if aiReplyToPhoneEnabled || aiReplyMonitorEnabled || chatGPTVoiceRouteEnabled {
            stopGPTTwoWayPhoneBridge()
        }
        restoreAutomaticGPTOutput()
        closePhoneScreenControl()
    }

    func setAutoCallEnabled(_ enabled: Bool) {
        autoCallEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "SIMAI_AUTO_CALL")
        if !enabled {
            autoCallState.reset()
            voiceSessionPrepared = false
            stopGPTTwoWayPhoneBridge()
            autoCallStatus = "自动接听已关闭；不会接听后续来电"
        } else {
            autoCallStatus = "自动接听已启用；请确认官方 Voice 正在运行，才能开始无人点击的来电处理"
        }
    }

    func setVoiceSessionPrepared(_ prepared: Bool) {
        if prepared { refresh() }
        voiceSessionPrepared = prepared
        if prepared {
            let problems = automaticVoiceReadinessIssues()
            if problems.isEmpty {
                autoCallStatus = "已预备自动来电：下一通响铃将自动接听并建立音频（官方 Voice 会话仍需保持运行）"
            } else {
                voiceSessionPrepared = false
                autoCallStatus = "暂不能自动接听：" + problems.joined(separator: "；")
            }
        } else {
            autoCallState.reset()
            if !liveVoiceActive { restoreAutomaticGPTOutput() }
            autoCallStatus = "已撤销自动接听预备状态；未结束当前通话，但不接听新来电"
        }
    }

    private func automaticVoiceReadinessIssues() -> [String] {
        var problems: [String] = []
        if !liveSyncEnabled { problems.append("请打开电话状态同步") }
        if !embeddedAudioProbeAvailable { problems.append("缺少电话 PCM Helper") }
        if !audio.devices.contains(where: { $0.displayName.caseInsensitiveCompare("BlackHole 2ch") == .orderedSame }) {
            problems.append("缺少 BlackHole 2ch")
        }
        if !audio.devices.contains(where: { $0.displayName.caseInsensitiveCompare("BlackHole 16ch") == .orderedSame }) {
            problems.append("缺少 BlackHole 16ch")
        }
        if selectedVoiceMonitorOutputID.isEmpty { problems.append("未选择实际监听耳机") }
        return problems
    }

    private func reactToAutomaticCallState(_ state: String) {
        // Recover after failed/aborted RINGING attempts with no PCM session.
        if state == "IDLE", !liveVoiceActive && !liveVoiceStarting {
            restoreAutomaticGPTOutput()
        }
        // Fail closed if the official Voice UI was not pre-armed this session.
        // Checking for virtual devices cannot prove that ChatGPT is listening.
        let armed = autoCallEnabled && voiceSessionPrepared &&
            automaticVoiceReadinessIssues().isEmpty && !adbInstalling &&
            !audioProbeBusy
        let action = autoCallState.update(state: state, armed: armed)
        switch action {
        case .answerIncoming:
            // If virtual output cannot be safely established, do not answer
            // a real call with no AI voice path ready.
            guard prepareAutomaticGPTOutput() else {
                voiceSessionPrepared = false
                autoCallState.reset()
                autoCallStatus = "音频输出准备失败，已暂停自动值守并避免空接电话"
                return
            }
            autoCallStatus = "检测到响铃，音频输出已准备，正在自动请求 Android 接听……"
            log(.info, .call, "自动来电检测启动接听", details: ["state": "RINGING"])
            answerIncomingPhoneCall()
        case .openCallAudio:
            guard !liveVoiceStarting && !liveVoiceActive else { return }
            autoCallAudioRequested = true
            autoCallStatus = "电话已接通，自动建立双向 PCM 和 GPT 路由……"
            startLiveVoice()
        case .stopCallAudio:
            autoCallAudioRequested = false
            autoCallStatus = "电话结束，自动释放音频并恢复 Mac 输出"
            stopLiveVoice()
            restoreAutomaticGPTOutput()
        case .none:
            break
        }
    }

    // Phone events are received from the user-authorized Android APK over ADB,
    // never from Mac Bluetooth and never from a cellular audio channel.
    private func startLiveSyncTimer() {
        guard bridgeTimer == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recoverAfterMacWake() }
        }
        bridgeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.autoInspectADBIfNeeded()
                self?.pollLiveBridge()
                self?.refreshPendingBlackHoleInstall()
            }
        }
        autoInspectADBIfNeeded(force: true)
        pollLiveBridge()
    }

    func setAutoADBDetectionEnabled(_ enabled: Bool) {
        autoADBDetectionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "SIMAI_AUTO_ADB")
        if enabled {
            nextADBScanAt = .distantPast
            autoInspectADBIfNeeded(force: true)
        }
    }

    private func recoverAfterMacWake() {
        nextADBScanAt = .distantPast
        let stale = liveBridgeLastSync.map { Date().timeIntervalSince($0) > 20 } ?? true
        if stale && liveSyncEnabled {
            closeLiveBridge()
            resetBridgeRetry()
            livePhoneState = "未连接"
            liveBridgeStatus = "Mac 唤醒，正在自动检测并恢复来电状态……"
            log(.info, .call, "Mac 唤醒，重建可能过期的电话状态通道")
        }
        autoInspectADBIfNeeded(force: true)
        if liveSyncEnabled { pollLiveBridge() }
    }

    /// Read-only automatic discovery. Never polls or pushes audio, changes
    /// Android permissions or connects to multiple devices. Rate limits are
    /// deliberately long while live calls are streaming.
    private func autoInspectADBIfNeeded(force: Bool = false) {
        guard autoADBDetectionEnabled, !adbChecking, !adbInstalling,
              !liveVoiceStarting, !liveVoiceActive,
              force || Date() >= nextADBScanAt else { return }
        adbChecking = true
        let path = selectedADBPath
        let scanGeneration = adbScanGeneration
        nextADBScanAt = Date().addingTimeInterval(12)
        Task.detached(priority: .utility) { [weak self] in
            let found = ADBInspector.inspect(at: path)
            let description = ADBInspector.discoveryLabel(at: path)
            await MainActor.run {
                guard let self else { return }
                guard scanGeneration == self.adbScanGeneration,
                      path == self.selectedADBPath else { return }
                self.adbChecking = false
                self.adbStatus = found.status
                self.adbDiscoveryDescription = description
                self.lastADBScanAt = Date()
                let connected = found.authorized == 1
                self.nextADBScanAt = Date().addingTimeInterval(
                    BridgeRetryPolicy.adbScanInterval(
                        authorizedDevices: found.authorized,
                        recentlySynced: self.liveBridgeLastSync.map {
                            Date().timeIntervalSince($0) <= 15
                        } ?? false))
                let signature = "\(found.installed)/\(found.authorized)/\(found.unauthorized)/\(found.offline)/\(description)"
                if signature != self.adbScanSignature {
                    self.adbScanSignature = signature
                    self.log(connected ? .info : .warn, .system,
                             "自动识别 Android ADB 状态变化",
                             details: ["installed": "\(found.installed)",
                                       "authorized": "\(found.authorized)",
                                       "unauthorized": "\(found.unauthorized)",
                                       "offline": "\(found.offline)",
                                       "source": description])
                }
                let reconnected = !self.adbWasAuthorized && connected
                self.adbWasAuthorized = connected
                if reconnected && self.liveSyncEnabled && self.bridgeLink == nil {
                    self.resetBridgeRetry()
                    self.liveBridgeStatus = "自动发现已授权手机，正在恢复来电状态……"
                    self.pollLiveBridge()
                }
            }
        }
    }

    func setLiveSyncEnabled(_ value: Bool) {
        liveSyncEnabled = value
        UserDefaults.standard.set(value, forKey: "SIMAI_LIVE_SYNC")
        if value {
            resetBridgeRetry()
            liveBridgeStatus = "正在连接手机"
            pollLiveBridge()
        } else {
            closeLiveBridge()
            liveBridgeStatus = "已关闭自动同步"
            livePhoneState = "未连接"
        }
    }

    /// Save locally in macOS Keychain, never in UserDefaults or diagnostics.
    /// Forwarding cannot begin until the user separately grants RECEIVE_SMS
    /// on Android. If the phone is connected, also attempt an explicit sync.
    func saveFeishuSettings() {
        let value = FeishuWebhookSettings(
            webhook: feishuWebhookDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            signingSecret: feishuSigningSecretDraft,
            enabled: feishuForwardEnabled)
        guard FeishuWebhookSettings.validWebhook(value.webhook),
              value.signingSecret.utf8.count <= 256 else {
            feishuSyncStatus = "地址格式无效：仅接受飞书官方机器人 HTTPS Webhook"
            return
        }
        do {
            try FeishuWebhookStore.save(value)
            feishuSavedOnMac = true
            feishuWebhookDraft = value.webhook
            feishuSyncStatus = "已安全保存到 Mac 钥匙串；正在尝试同步手机"
            log(.info, .system, "用户已在 Mac 钥匙串保存飞书短信设置（不记录凭证）")
            syncFeishuSettings()
        } catch {
            feishuSyncStatus = "Mac 钥匙串保存失败，请检查钥匙串访问权限"
            log(.warn, .system, "Mac 钥匙串无法保存飞书设置（仅错误类别）")
        }
    }

    func syncFeishuSettings() {
        guard !feishuSyncBusy, !adbInstalling,
              !liveVoiceActive, !liveVoiceStarting else {
            feishuSyncStatus = "电话音频或安装任务正在使用 ADB，请结束后重试同步"
            return
        }
        guard let saved = FeishuWebhookStore.load() else {
            feishuSyncStatus = "Mac 尚无已保存的 Webhook，请先保存"
            return
        }
        feishuSyncBusy = true
        feishuSyncStatus = "正在检查唯一已授权手机，并通过 ADB 安全下发配置……"
        let path = selectedADBPath
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                ADBInspector.syncFeishuSettings(at: path, settings: saved)
            }.value
            guard let self else { return }
            self.feishuSyncBusy = false
            if result.succeeded {
                self.feishuSyncStatus = "配置已写入手机私有目录；打开 Companion 或收到下一条短信时自动导入。短信权限仍需手机授权。"
                self.log(.info, .system, "飞书设置已安全下发到唯一已授权手机",
                         details: ["syncStage": result.code])
            } else {
                let guidance: String
                switch result.code {
                case "ADB_MISSING":
                    guidance = "Mac 未发现 ADB，请在上方选择 adb 可执行文件"
                case "ADB_UNAUTHORIZED":
                    guidance = "手机 USB 调试尚未授权，请解锁手机并允许此 Mac"
                case "ADB_NO_AUTHORIZED_PHONE":
                    guidance = "未找到已授权手机，请检查 USB 或无线 ADB"
                case "ADB_MULTIPLE_AUTHORIZED_PHONES":
                    guidance = "连接了多台已授权手机；为防止配置发错设备，请只保留一台"
                case "ANDROID_COMPANION_UPDATE_REQUIRED":
                    guidance = "手机 Companion 版本太旧，请安装 V0.3.2 后重新同步"
                case "ANDROID_COMPANION_NOT_FOUND":
                    guidance = "手机上未发现 Companion，请先安装新版 Android APK"
                case "ANDROID_COMPANION_VERSION_UNKNOWN":
                    guidance = "无法确认手机 Companion 版本，请重新连接后检测"
                case "ADB_CONFIG_RUN_AS_FAILED":
                    guidance = "手机拒绝应用私有目录写入；确认新版 Companion 为调试包、ADB Shell 可用"
                case "ADB_DEVICES_TIMEOUT", "ANDROID_PACKAGE_QUERY_TIMEOUT",
                     "ADB_CONFIG_WRITE_TIMEOUT":
                    guidance = "ADB 响应超时；手机解锁后重试并检查锁屏省电限制"
                case "ADB_CONFIG_STDIN_FAILED", "ADB_CONFIG_PROCESS_LAUNCH":
                    guidance = "ADB 安全写入进程失败；检查 Mac 的 ADB 和文件权限"
                default:
                    guidance = "同步失败，请导出脱敏诊断包查看错误类别"
                }
                self.feishuSyncStatus = "Mac 已保存；手机未同步：\(guidance)"
                self.log(.warn, .system, "飞书设置未能下发手机",
                         details: ["reason": result.code])
            }
        }
    }

    func reconnectLiveBridge() {
        resetBridgeRetry()
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
        bridgeBusy = false
        bridgeUsingFileFallback = false
        nextHTTPRecoveryAttempt = .distantPast
        bridgeGeneration += 1
        // Preserve cursor on temporary USB disconnect to avoid replaying old call events.
    }

    /// One quick, non-invasive diagnostic. Does not modify Android state or
    /// restart global ADB, and does not expose raw device identifiers.
    func inspectBridgeHealth() {
        guard !adbBridgeHealthChecking && !adbInstalling else { return }
        adbBridgeHealthChecking = true
        let adb = selectedADBPath
        let link = bridgeLink
        let generation = bridgeGeneration
        Task.detached(priority: .utility) { [weak self] in
            let report = ADBInspector.inspectBridgeHealth(at: adb, link: link)
            await MainActor.run {
                guard let self else { return }
                self.adbBridgeHealthChecking = false
                guard generation == self.bridgeGeneration else { return }
                self.adbTransportHealth = report.transport
                self.adbShellHealth = report.shell
                self.adbForwardHealth = report.forward
                self.adbBridgeHealthDetail = report.reason
                self.log(report.code == "PHONE_SERVICE_TIMEOUT" ? .warn : .info,
                         .call, "已检查 ADB / Shell / 状态端口健康",
                         details: ["diagnosis": report.code,
                                   "transport": report.transport,
                                   "shell": report.shell,
                                   "forward": report.forward])
            }
        }
    }

    private func resetBridgeRetry() {
        bridgeRetryAfter = .distantPast
        bridgeConsecutiveFailures = 0
    }

    private func noteBridgeFailure(code: String, domain: String) {
        bridgeConsecutiveFailures += 1
        let delay = Int(BridgeRetryPolicy.delay(after: bridgeConsecutiveFailures))
        bridgeRetryAfter = Date().addingTimeInterval(TimeInterval(delay))
        liveBridgeStatus = "连接中断，将在约 \(delay) 秒后重试（可手动重新连接）"
        // One warning per outage, then sparse checkpoints. Avoid dozens of
        // redundant JSONL entries when the phone's ADB tunnel remains unreachable.
        if bridgeConsecutiveFailures == 1 || bridgeConsecutiveFailures % 8 == 0 {
            log(.warn, .call, "ADB 电话状态桥接连接中断",
                details: ["errorDomain": domain, "errorCode": code,
                          "retrySeconds": "\(delay)", "failures": "\(bridgeConsecutiveFailures)"])
        }
    }

    /// Existing phone-event decoder is shared by HTTP and shell-file paths,
    /// so there is exactly one state cursor across transport switches.
    private func applyBridgeSnapshot(_ snapshot: PhoneBridgeSnapshot, source: String) {
        let priorSession = bridgeCursor.session
        let received = bridgeCursor.consume(snapshot)
        if priorSession != bridgeCursor.session {
            liveCallEvents.removeAll()
            log(.info, .call, "Android 电话状态桥接会话已建立",
                details: ["bridgeSchema": "1", "newSession": "true"])
        }
        for event in received {
            let displayTime = Date(timeIntervalSince1970: Double(event.at) / 1000)
                .formatted(date: .omitted, time: .standard)
            liveCallEvents.insert("\(displayTime) · \(event.state)", at: 0)
            liveCallEvents = Array(liveCallEvents.prefix(16))
            log(.info, .call, "收到 Android 实时电话状态",
                details: ["state": event.state, "sequence": "\(event.seq)",
                          "source": source])
        }
        livePhoneState = snapshot.state
        liveBridgeLastSync = Date()
        reactToAutomaticCallState(snapshot.state)
        adbTransportHealth = "ADB 已授权"
        adbShellHealth = "命令正常"
        adbForwardHealth = source == "ADB_FILE" ? "HTTP 备用路径" : "工作正常"
        adbBridgeHealthDetail = source == "ADB_FILE"
            ? "HTTP 连接暂不可靠，已使用 ADB 私有状态快照"
            : "HTTP 状态桥接已恢复"
        if bridgeConsecutiveFailures > 0 {
            log(.info, .call, "ADB 电话状态同步已恢复",
                details: ["failedAttempts": "\(bridgeConsecutiveFailures)",
                          "transport": source])
        }
        resetBridgeRetry()
        liveBridgeStatus = source == "ADB_FILE"
            ? "已连接 · ADB 私有状态快照（HTTP 备用）"
            : "已连接 · ADB HTTP 自动同步"
    }

    private func pollPrivateSnapshot(generation: Int) {
        let adb = selectedADBPath
        Task.detached(priority: .utility) { [weak self] in
            let result = ADBInspector.readPrivateStateSnapshot(at: adb)
            await MainActor.run {
                guard let self else { return }
                guard self.liveSyncEnabled, generation == self.bridgeGeneration else { return }
                self.bridgeBusy = false
                if let snapshot = result.snapshot {
                    self.applyBridgeSnapshot(snapshot, source: "ADB_FILE")
                    self.bridgeUsingFileFallback = true
                } else {
                    self.bridgeUsingFileFallback = false
                    self.noteBridgeFailure(code: result.reason, domain: "SIMAI.ADBFile")
                    self.livePhoneState = "未连接"
                }
            }
        }
    }

    private func pollLiveBridge() {
        // Realtime PCM has priority over noncritical ADB status polling.
        // The Android audio helper independently detects call hang-up.
        // Resume state sync after the explicit audio preview ends.
        guard !liveVoiceStarting, !liveVoiceActive,
              liveSyncEnabled, !adbInstalling, !bridgeBusy,
              Date() >= bridgeRetryAfter else { return }
        bridgeBusy = true
        if bridgeUsingFileFallback && Date() < nextHTTPRecoveryAttempt {
            pollPrivateSnapshot(generation: bridgeGeneration)
            return
        }
        if let link = bridgeLink {
            let generation = bridgeGeneration
            // Android retains at most 64 events. Fetch the bounded history so a freshly
            // restarted Android session is not missed when its sequence starts from 1.
            // PhoneBridgeCursor filters all duplicate events on the Mac.
            let since = 0
            Task { [weak self] in
                guard let self else { return }
                var request = URLRequest(url: URL(
                    string: "http://127.0.0.1:\(link.localPort)/events?since=\(since)")!)
                request.httpMethod = "GET"
                request.timeoutInterval = 6.0
                request.setValue(link.token, forHTTPHeaderField: "X-SIMAI-Token")
                request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard self.liveSyncEnabled, generation == self.bridgeGeneration else {
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        throw NSError(domain: "SIMAI.ADBBridge.HTTP", code: status)
                    }
                    let snapshot = try JSONDecoder().decode(PhoneBridgeSnapshot.self, from: data)
                    guard snapshot.schema == 1, snapshot.running,
                          ["IDLE", "RINGING", "OFFHOOK"].contains(snapshot.state) else {
                        throw NSError(domain: "SIMAI.ADBBridge", code: 422)
                    }
                    self.applyBridgeSnapshot(snapshot, source: "ADB_HTTP")
                    self.bridgeUsingFileFallback = false
                    self.nextHTTPRecoveryAttempt = .distantPast
                } catch {
                    guard self.liveSyncEnabled, generation == self.bridgeGeneration else {
                        return
                    }
                    let nsError = error as NSError
                    let adb = self.selectedADBPath
                    // HTTP can stall while an authorized ADB shell still works.
                    // Try the private state file before tearing down a valid
                    // port forward. This bypasses the HTTP socket only.
                    let fallback = await Task.detached(priority: .utility) {
                        ADBInspector.readPrivateStateSnapshot(at: adb)
                    }.value
                    guard self.liveSyncEnabled, generation == self.bridgeGeneration else {
                        return
                    }
                    if let snapshot = fallback.snapshot {
                        if !self.bridgeUsingFileFallback {
                            self.log(.warn, .call, "电话状态 HTTP 暂不可用，切换到 ADB 快照",
                                     details: ["httpErrorCode": "\(nsError.code)",
                                               "fallback": "ADB_FILE"])
                        }
                        self.bridgeUsingFileFallback = true
                        self.nextHTTPRecoveryAttempt = Date().addingTimeInterval(20)
                        self.applyBridgeSnapshot(snapshot, source: "ADB_FILE")
                    } else {
                        self.noteBridgeFailure(code: fallback.reason, domain: "SIMAI.ADBFile")
                        self.livePhoneState = "未连接"
                        if self.bridgeConsecutiveFailures == 1 { self.inspectBridgeHealth() }
                        if self.bridgeConsecutiveFailures >= 2 { self.closeLiveBridge() }
                    }
                }
                self.bridgeBusy = false
            }
        } else {
            let path = selectedADBPath
            let generation = bridgeGeneration
            Task { [weak self] in
                let result = await Task.detached(priority: .utility) {
                    ADBInspector.openBridge(at: path)
                }.value
                guard let self else { return }
                guard self.liveSyncEnabled, generation == self.bridgeGeneration else {
                    if let link = result.link {
                        Task.detached(priority: .utility) {
                            ADBInspector.closeBridge(at: path, link: link)
                        }
                    }
                    return
                }
                self.bridgeBusy = false
                if let link = result.link {
                    self.bridgeLink = link
                    self.adbStatus = "ADB 已自动识别 1 台已授权手机"
                    self.adbDiscoveryDescription = ADBInspector.discoveryLabel(at: path)
                    self.adbWasAuthorized = true
                    // Keep the previous Android session and sequence across ADB port changes.
                    self.liveBridgeStatus = result.message
                    if self.bridgeConsecutiveFailures == 0 {
                        self.log(.info, .call, "ADB 端口转发连接建立（未读取设备序列号）")
                    }
                    self.pollLiveBridge()
                } else {
                    if self.bridgeConsecutiveFailures == 0 { self.inspectBridgeHealth() }
                    self.noteBridgeFailure(code: "ADB_UNAVAILABLE", domain: "SIMAI.ADB")
                    self.liveBridgeStatus = "\(result.message)；自动重连已退避"
                }
            }
        }
    }


    var embeddedAudioProbeAvailable: Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        return FileManager.default.fileExists(
            atPath: resources.appendingPathComponent("SIMAI-Audio-Probe.jar").path)
    }

    /// Non-invasive check may run at any time. Actual audio tests are only
    /// triggered by separate, informed consent dialogs and a connected call.
    /// Starts an independent TCP-over-ADB audio transport. No dependency on
    /// Mac's potentially stale OFFHOOK event; Android checks its real call mode.
    /// Must only be invoked following the user's explicit two-party consent.
    func startLiveVoice() {
        guard !liveVoiceStarting, !liveVoiceActive, !adbInstalling,
              !audioProbeBusy else { return }
        guard let jar = Bundle.main.resourceURL?.appendingPathComponent("SIMAI-Audio-Probe.jar"),
              FileManager.default.fileExists(atPath: jar.path) else {
            alertText = "未找到 Android 电话音频 Helper，请重新安装完整 Mac 包。"
            return
        }
        let id = UUID().uuidString
        voiceSessionID = id
        liveVoiceStatus = "准备建立 16 kHz 双向 PCM 通道……"
        liveVoiceStarting = true
        liveVoiceActive = false
        liveVoiceMicrophoneEnabled = false
        chatGPTVoiceRouteEnabled = false
        chatGPTVoiceRouteStatus = "尚未开启（需要先建立电话音频）"
        chatGPTVoiceRouteDropped = 0
        aiReplyMonitorEnabled = false
        aiReplyToPhoneEnabled = false
        aiReplyReturnStatus = "连接电话音频后可开启 GPT 回复监听"
        aiReplyReceivedFrames = 0
        aiReplyMonitorDropped = 0
        aiReplyUplinkUnderflow = 0
        aiReplyPeakRMS = 0
        liveVoiceRxFrames = 0
        liveVoiceTxFrames = 0
        liveVoiceDropFrames = 0
        liveVoiceMicUnderflows = 0
        liveVoiceMicOverflows = 0
        liveVoiceUplinkLateFrames = 0
        liveVoiceMicBufferedMs = 0
        liveVoiceHandshakeAttempts = 0
        log(.info, .audio, "用户确认开始实时电话音频预览",
            details: ["mode": "manual", "mic": "muted", "maxDurationSeconds": "180"])
        let stream = PhoneAudioStream(physicalMonitorOutput: UInt32(selectedVoiceMonitorOutputID)) { [weak self] update in
            Task { @MainActor in
                guard let self, self.voiceSessionID == id else { return }
                switch update {
                case .status(let message):
                    self.liveVoiceStatus = message
                case .handshakeAttempts(let count):
                    self.liveVoiceHandshakeAttempts = count
                case .active:
                    self.liveVoiceActive = true
                    self.liveVoiceStarting = false
                    self.liveVoiceStatus = "实时播放电话下行中 · 麦克风默认静音"
                    if self.autoCallAudioRequested {
                        self.enableGPTTwoWayPhoneBridge()
                        self.autoCallStatus = self.aiReplyToPhoneEnabled
                            ? "自动电话路由已开启；当前仍依赖事先启动的 ChatGPT Voice 会话"
                            : "PCM 已启动，但 GPT 回传未就绪；已保持电话上行静音，需检查音频配置"
                        if !self.aiReplyToPhoneEnabled {
                            self.log(.warn, .audio, "自动通话路由失败并保持上行静音",
                                     details: ["reason": "GPT_RETURN_NOT_READY"])
                        }
                    }
                    self.log(.info, .audio, "ADB 双向 PCM 通道已建立",
                        details: ["sampleRate": "16000", "channels": "1", "frameMs": "20"])
                case .metrics(let received, let sent, let dropped,
                              let micUnderflows, let micOverflows,
                              let txLate, let micBufferedMs, let voiceRouteDropped):
                    self.liveVoiceRxFrames = received
                    self.liveVoiceTxFrames = sent
                    self.liveVoiceDropFrames = dropped
                    self.liveVoiceMicUnderflows = micUnderflows
                    self.liveVoiceMicOverflows = micOverflows
                    self.liveVoiceUplinkLateFrames = txLate
                    self.liveVoiceMicBufferedMs = micBufferedMs
                    self.chatGPTVoiceRouteDropped = voiceRouteDropped
                case .aiReturnMetrics(let captured, let monitorDropped, let uplinkUnderflow, let peakRMS):
                    self.aiReplyReceivedFrames = captured
                    self.aiReplyMonitorDropped = monitorDropped
                    self.aiReplyUplinkUnderflow = uplinkUnderflow
                    self.aiReplyPeakRMS = peakRMS
                case .finished(let reason):
                    if self.autoCallAudioRequested {
                        self.autoCallStatus = "自动电话音频已停止：" + reason
                        self.autoCallAudioRequested = false
                    }
                    self.liveVoiceStarting = false
                    self.liveVoiceActive = false
                    self.liveVoiceMicrophoneEnabled = false
                    self.chatGPTVoiceRouteEnabled = false
                    self.chatGPTVoiceRouteStatus = "电话已结束，虚拟麦克风已停止"
                    self.aiReplyMonitorEnabled = false
                    self.aiReplyToPhoneEnabled = false
                    self.aiReplyReturnStatus = "电话音频已结束，GPT 回复路由已释放"
                    self.liveVoiceStatus = "实时语音已停止（\(reason)）"
                    self.voiceStream = nil
                    // The Android helper also enforces a 180s session timeout,
                    // so restore global sound output even without an IDLE event.
                    self.restoreAutomaticGPTOutput()
                    // Resume anonymous call-state synchronization without
                    // rebuilding the ADB connection unnecessarily.
                    self.pollLiveBridge()
                    self.log(reason == "USER_STOPPED" ? .info : .warn, .audio,
                        "实时电话音频会话结束", details: [
                            "reason": reason, "rxFrames": "\(self.liveVoiceRxFrames)",
                            "txFrames": "\(self.liveVoiceTxFrames)",
                            "dropped": "\(self.liveVoiceDropFrames)",
                            "micUnderflows": "\(self.liveVoiceMicUnderflows)",
                            "micOverflows": "\(self.liveVoiceMicOverflows)",
                            "uplinkLateFrames": "\(self.liveVoiceUplinkLateFrames)",
                            "micBufferedMs": "\(self.liveVoiceMicBufferedMs)",
                            "voiceRouteDropped": "\(self.chatGPTVoiceRouteDropped)",
                            "aiReturnCaptured": "\(self.aiReplyReceivedFrames)",
                            "aiReturnMonitorDropped": "\(self.aiReplyMonitorDropped)",
                            "aiReturnUplinkUnderflow": "\(self.aiReplyUplinkUnderflow)",
                            "aiReturnPeakRMS": String(format: "%.5f", self.aiReplyPeakRMS),
                            "handshakeAttempts": "\(self.liveVoiceHandshakeAttempts)"])
                }
            }
        }
        voiceStream = stream
        stream.start(adb: selectedADBPath, jar: jar)
    }

    /// Local, opt-in PCM routing to BlackHole 2ch, without any ChatGPT API.
    /// ChatGPT output remains on Mac; no automated voice replies to caller.
    func setChatGPTVoiceRoute(_ enabled: Bool) {
        guard liveVoiceActive, let voiceStream else { return }
        do {
            try voiceStream.setChatGPTInputRouting(enabled)
            chatGPTVoiceRouteEnabled = enabled
            chatGPTVoiceRouteStatus = enabled
                ? "电话下行已输出至 BlackHole 2ch；请在 ChatGPT Voice 中选择此麦克风"
                : "已断开 BlackHole 虚拟麦克风"
            log(.info, .audio, enabled
                ? "用户主动将电话下行送入 ChatGPT 虚拟麦克风"
                : "用户主动断开 ChatGPT 虚拟麦克风",
                details: ["route": enabled ? "PHONE_TO_BLACKHOLE" : "OFF"])
        } catch {
            chatGPTVoiceRouteEnabled = false
            chatGPTVoiceRouteStatus = "路由失败：请检查 BlackHole 2ch 安装及音频设备权限"
            log(.warn, .audio, "ChatGPT 虚拟麦克风路由初始化失败",
                details: ["route": "PHONE_TO_BLACKHOLE", "status": "ROUTE_UNAVAILABLE"])
        }
    }

    /// ChatGPT must output to BlackHole 16ch. Mac speakers/headphones are
    /// chosen separately and never replaced by a virtual device.
    func setAIReplyMonitor(_ enabled: Bool) {
        guard liveVoiceActive, let voiceStream else { return }
        if enabled {
            guard prepareAutomaticGPTOutput() else {
                aiReplyReturnStatus = "无法自动切换 BlackHole 16ch，未开启监听"
                return
            }
            guard let physicalID = UInt32(selectedVoiceMonitorOutputID) else {
                restoreAutomaticGPTOutput()
                aiReplyReturnStatus = "请先选择真实耳机/扬声器作为监听设备"
                return
            }
            do {
                try voiceStream.setAIReplyMonitoring(true, physicalOutputID: physicalID)
                aiReplyMonitorEnabled = true
                aiReplyToPhoneEnabled = false
                aiReplyReturnStatus = "监听已开启：GPT 输出 BlackHole 16ch → Mac 选定耳机，电话回传仍关闭"
                log(.info, .audio, "用户主动开启独立 GPT 回复监听",
                    details: ["route": "BLACKHOLE16_TO_PHYSICAL", "phoneForward": "off"])
            } catch {
                aiReplyMonitorEnabled = false
                aiReplyToPhoneEnabled = false
                restoreAutomaticGPTOutput()
                aiReplyReturnStatus = "监听启动失败，请核对 BlackHole 16ch 和输出设备；失败细节请导出诊断"
                let ns = error as NSError
                // LiveAudioFailure only contains predefined internal reason codes,
                // not device names, paths, secrets, or captured audio.
                let reason = String(describing: error)
                log(.warn, .audio, "GPT 回复监听初始化失败",
                    details: ["category": "AI_RETURN_MONITOR", "errorDomain": ns.domain,
                              "errorCode": "\(ns.code)",
                              "failure": reason.prefix(80).description])
            }
        } else {
            do { try voiceStream.setAIReplyMonitoring(false) } catch {}
            aiReplyMonitorEnabled = false
            aiReplyToPhoneEnabled = false
            restoreAutomaticGPTOutput()
            aiReplyReturnStatus = "已关闭 GPT 回复监听及电话回传"
            log(.info, .audio, "用户关闭 GPT 回复监听与电话回传",
                details: ["route": "AI_RETURN_OFF"])
        }
    }

    /// Second distinct opt-in required before any captured AI audio can
    /// enter the PSTN. Disabling restores silence rather than re-enabling mic.
    func setAIReplyToPhone(_ enabled: Bool) {
        guard liveVoiceActive, let voiceStream else { return }
        do {
            try voiceStream.setAIReplyToPhone(enabled)
            aiReplyToPhoneEnabled = enabled
            if enabled {
                liveVoiceMicrophoneEnabled = false
            }
            aiReplyReturnStatus = enabled
                ? "GPT 回复已人工授权发送到电话；Mac 麦克风已静音，可立即关闭回传"
                : "GPT 回复仅供 Mac 耳机监听，电话回传关闭"
            log(.info, .audio, enabled
                ? "用户主动授权 GPT 音频回传运营商电话"
                : "用户立即关闭 GPT 音频回传运营商电话",
                details: ["phoneForward": enabled ? "on" : "off"])
        } catch {
            aiReplyToPhoneEnabled = false
            aiReplyReturnStatus = "GPT 电话回传未启动，请先开启监听并确认音频路由"
            log(.warn, .audio, "GPT 电话回传未启动",
                details: ["category": "AI_RETURN_TO_PHONE"])
        }
    }

    /// Explicit confirmation in UI is required every session. This does not
    /// create/start a ChatGPT Voice conversation, bypass its microphone prompt
    /// or automatically answer calls. User first verifies the official Voice
    /// session is open with BlackHole 2ch input / 16ch output.
    func enableGPTTwoWayPhoneBridge() {
        guard liveVoiceActive, voiceStream != nil else {
            aiReplyReturnStatus = "请先接听真实电话，并建立实时通话音频"
            return
        }
        guard !aiReplyToPhoneEnabled else { return }
        guard prepareAutomaticGPTOutput() else {
            aiReplyReturnStatus = "无法自动配置 BlackHole 16ch，已保持电话回传关闭"
            return
        }
        setChatGPTVoiceRoute(true)
        guard chatGPTVoiceRouteEnabled else {
            restoreAutomaticGPTOutput()
            aiReplyReturnStatus = "GPT 双向桥接未启动：电话→BlackHole 2ch 路由失败"
            return
        }
        setAIReplyMonitor(true)
        guard aiReplyMonitorEnabled else {
            setChatGPTVoiceRoute(false)
            restoreAutomaticGPTOutput()
            aiReplyReturnStatus = "GPT 双向桥接未启动：BlackHole 16ch 或物理耳机监听不可用"
            return
        }
        setAIReplyToPhone(true)
        guard aiReplyToPhoneEnabled else {
            setAIReplyMonitor(false)
            setChatGPTVoiceRoute(false)
            restoreAutomaticGPTOutput()
            aiReplyReturnStatus = "GPT 双向桥接未启动：已恢复全部关闭状态"
            return
        }
        aiReplyReturnStatus = "GPT 双向电话桥接已人工开启；正在转发 Voice 输出，可随时一键停止"
        log(.info, .audio, "用户确认开启双向 GPT 电话语音路由",
            details: ["mode": "MANUAL_CONSENT_GATED_BRIDGE"])
    }

    func stopGPTTwoWayPhoneBridge() {
        if aiReplyToPhoneEnabled { setAIReplyToPhone(false) }
        if aiReplyMonitorEnabled { setAIReplyMonitor(false) }
        if chatGPTVoiceRouteEnabled { setChatGPTVoiceRoute(false) }
        restoreAutomaticGPTOutput()
        aiReplyReturnStatus = "GPT 双向电话桥接已全部停止，电话上行恢复静音"
        log(.info, .audio, "用户立即停止双向 GPT 电话音频",
            details: ["mode": "ALL_GPT_ROUTES_OFF"])
    }

    func stopLiveVoice() {
        guard liveVoiceStarting || liveVoiceActive else {
            restoreAutomaticGPTOutput()
            return
        }
        liveVoiceMicrophoneEnabled = false
        chatGPTVoiceRouteEnabled = false
        aiReplyMonitorEnabled = false
        aiReplyToPhoneEnabled = false
        liveVoiceStatus = "正在停止并释放电话音频通道……"
        voiceStream?.stop()
        restoreAutomaticGPTOutput()
    }

    func setLiveVoiceMicrophone(_ enabled: Bool) {
        guard liveVoiceActive, let voiceStream else { return }
        guard enabled else {
            do { try voiceStream.setMicrophone(false) } catch { }
            liveVoiceMicrophoneEnabled = false
            liveVoiceStatus = "电话下行实时播放中 · Mac 麦克风已静音"
            log(.info, .audio, "用户关闭 Mac 电话上行麦克风")
            return
        }

        func enable() {
            guard self.liveVoiceActive, let voiceStream = self.voiceStream else { return }
            do {
                try voiceStream.setMicrophone(true)
                self.liveVoiceMicrophoneEnabled = true
                self.liveVoiceStatus = "双向实时语音已开启（建议佩戴耳机防止回声）"
                self.log(.info, .audio, "用户主动开启 Mac 实时通话麦克风")
            } catch {
                self.liveVoiceMicrophoneEnabled = false
                self.liveVoiceStatus = "Mac 麦克风启动失败，请检查输入设备及权限"
                let err = error as NSError
                self.log(.warn, .audio, "实时通话麦克风无法启动",
                    details: ["errorDomain": err.domain, "errorCode": "\(err.code)"])
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: enable()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.setLiveVoiceMicrophone(true) }
                    else { self.handleMicDenied() }
                }
            }
        default: handleMicDenied()
        }
    }

    /// Explicit user-initiated real-call answer request only. The Android
    /// Companion re-checks its own call state, refuses all non-ringing calls,
    /// and requires separate ANSWER_PHONE_CALLS permission.
    func answerIncomingPhoneCall() {
        guard !answerCallBusy && !adbInstalling else { return }
        answerCallBusy = true
        answerCallStatus = "正在安全检查 ADB 和手机响铃状态……"
        let path = selectedADBPath
        Task { [weak self] in
            guard let self else { return }
            let attempt = await Task.detached(priority: .userInitiated) {
                ADBInspector.openBridge(at: path)
            }.value
            guard let link = attempt.link else {
                self.answerCallBusy = false
                self.answerCallStatus = "无法连接手机电话监听服务；请确认 Companion 已启动且只有一台已授权手机"
                self.log(.warn, .system, "手动接听未建立手机桥接",
                         details: ["reason": "MANUAL_ANSWER_BRIDGE_UNAVAILABLE"])
                return
            }
            defer {
                let disposable = link
                Task.detached(priority: .utility) {
                    ADBInspector.closeBridge(at: path, link: disposable)
                }
                self.answerCallBusy = false
            }
            guard let url = URL(string: "http://127.0.0.1:\(link.localPort)/call/answer") else {
                self.answerCallStatus = "本地接听请求地址无效"
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 6
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(link.token, forHTTPHeaderField: "X-SIMAI-Token")
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 6
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            do {
                let (body, response) = try await session.data(for: request)
                let http = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Only these fixed status codes are interpreted. Never log
                // raw server responses, phone identifiers, or bearer tokens.
                let parsed = (try? JSONSerialization.jsonObject(with: body))
                    as? [String: Any]
                if http == 200 && parsed?["result"] as? String == "answer_requested" {
                    self.answerCallStatus = "已向 Android 发出接听请求；请确认手机状态转为 OFFHOOK，再启动 GPT 音频"
                    self.log(.info, .system, "用户主动请求接听当前响铃电话",
                             details: ["result": "ANSWER_REQUESTED"])
                } else {
                    switch http {
                    case 403:
                        self.answerCallStatus = "手机拒绝接听：请在 Companion 授权「接听电话」"
                    case 404:
                        self.answerCallStatus = "手机 Companion 版本过旧，请更新至 V0.3.5"
                    case 409:
                        self.answerCallStatus = "手机当前并未响铃；不会接听其它通话"
                    case 503:
                        self.answerCallStatus = "手机系统暂不允许外部接听，请使用 scrcpy 手动点击接听"
                    default:
                        self.answerCallStatus = "接听请求未成功；请使用手机屏幕控制检查通话状态"
                    }
                    self.log(.warn, .system, "Android 拒绝接听请求",
                             details: ["reason": "MANUAL_ANSWER_REJECTED",
                                       "http": "\(http)"])
                }
            } catch {
                self.answerCallStatus = "手机接听接口超时或连接中断；请检查手机界面，避免重复接听"
                self.log(.warn, .system, "人工接听请求网络失败",
                         details: ["reason": "MANUAL_ANSWER_TIMEOUT"])
            }
        }
    }

    func runPhoneAudioProbe(_ action: AndroidAudioProbeAction) {
        guard !audioProbeBusy && !adbInstalling && !liveVoiceActive && !liveVoiceStarting else { return }
        // Mac call-state notifications are best-effort and may arrive late when
        // the ADB event tunnel reconnects. Do not gate a real-call test on them.
        // Android's requireInCall() is the authoritative safety check.
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("SIMAI-Audio-Probe.jar"),
              FileManager.default.fileExists(atPath: path.path) else {
            alertText = "此 Mac 安装包没有包含音频兼容性助手。请下载最新完整版本。"
            return
        }
        let adb = selectedADBPath
        audioProbeBusy = true
        audioProbeStatus = action == .info ? "检查 Android 13 音频能力……"
            : action == .downlink ? "正在测量电话下行电平，约 2 秒（不录音）……"
            : "准备播放一段低音量测试音（约 1 秒）……"
        if action == .uplink {
            audioProbeToneSent = false
            audioProbeRemoteConfirmed = false
        }
        log(.info, .audio, "用户主动启动 Android 电话音频测试",
            details: ["action": action.rawValue, "stage": "begin",
                      "macCallState": livePhoneState])
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = ADBInspector.runAudioProbe(at: adb, jar: path, action: action)
            await MainActor.run {
                guard let self else { return }
                self.audioProbeBusy = false
                self.audioProbeFacts = report.fields.sorted(by: { $0.key < $1.key })
                    .map { "\($0.key) = \($0.value)" }
                self.audioProbeStatus = report.status
                if report.succeeded {
                    switch action {
                    case .info:
                        self.audioProbeStatus = "能力检查完成。是否能真正双向收发，还需通话实测。"
                    case .downlink:
                        let peak = report.fields["peak"] ?? "unknown"
                        let frames = report.fields["frames"] ?? "0"
                        self.audioProbeStatus = "下行读取 \(frames) 个样本，峰值 \(peak)。非零不等于已证明对方语音可用。"
                    case .uplink:
                        self.audioProbeToneSent = report.fields["result"] == "TONE_SENT_UNCONFIRMED"
                        self.audioProbeStatus = self.audioProbeToneSent
                            ? "已尝试写入测试音。请询问对方是否听到；写入成功不代表成功注入通话。"
                            : "测试音未完成，需要检查诊断结果。"
                    }
                }
                self.log(report.succeeded ? .info : .warn, .audio,
                         "Android 电话音频诊断执行结束",
                         details: ["action": action.rawValue,
                                   "ok": "\(report.succeeded)",
                                   "status": report.fields["status"] ?? "no_status",
                                   "error": report.fields["error"] ?? "none",
                                   "result": report.fields["result"] ?? "none",
                                   "peak": report.fields["peak"] ?? "n/a",
                                   "rms": report.fields["rms"] ?? "n/a",
                                   "frames": report.fields["frames"] ?? "n/a",
                                   "pstnInterceptable": report.fields["pstnInterceptable"] ?? "unknown",
                                   "uplinkManagerApi": report.fields["uplinkManagerApi"] ?? "unknown",
                                   "route": report.fields["route"] ?? "none",
                                   "stage": report.fields["stage"] ?? "none"])
            }
        }
    }

    func confirmRemoteHeardTone() {
        guard audioProbeToneSent else { return }
        audioProbeRemoteConfirmed = true
        audioProbeStatus = "对方已人工确认听到测试音；上行语音注入需要在后续版本进一步验证稳定性。"
        log(.info, .audio, "通话对方人工确认听到上行测试音（非自动检测）",
            details: ["method": "manual_confirmation"])
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
        let generation = adbScanGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = ADBInspector.inspect(at: selectedPath)
            let description = ADBInspector.discoveryLabel(at: selectedPath)
            await MainActor.run {
                guard let self else { return }
                guard generation == self.adbScanGeneration,
                      selectedPath == self.selectedADBPath else { return }
                self.adbChecking = false
                self.adbStatus = result.status
                self.adbDiscoveryDescription = description
                self.lastADBScanAt = Date()
                self.adbWasAuthorized = result.authorized == 1
                self.adbScanSignature = "\(result.installed)/\(result.authorized)/\(result.unauthorized)/\(result.offline)/\(description)"
                self.nextADBScanAt = Date().addingTimeInterval(
                    BridgeRetryPolicy.adbScanInterval(authorizedDevices: result.authorized,
                                                       recentlySynced: false))
                if result.authorized == 1 && self.liveSyncEnabled && self.bridgeLink == nil {
                    self.resetBridgeRetry()
                    self.pollLiveBridge()
                }
                self.log(.info, .system, "Android ADB 自检完成（不读取设备序列号和电话音频）",
                    details: ["adbInstalled": "\(result.installed)",
                              "authorizedCount": "\(result.authorized)",
                              "unauthorizedCount": "\(result.unauthorized)",
                              "offlineCount": "\(result.offline)"])
            }
        }
    }


    var embeddedAPKSigningStatus: String {
        guard let resource = Bundle.main.resourceURL?
                .appendingPathComponent("SIMAI-Android-Signing.txt"),
              let data = try? String(contentsOf: resource, encoding: .utf8) else {
            return "签名来源未知；升级前请确认新旧 APK 签名一致"
        }
        switch data.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "STABLE_SECRET_SIGNING":
            return "固定签名构建：同一证书的后续升级可保留应用数据"
        case "EPHEMERAL_DEBUG_SIGNING":
            return "临时 Debug 签名：可能无法覆盖旧版，遇到不兼容绝不自动清空数据"
        default:
            return "签名状态无法验证；请勿仅为升级而直接清空手机数据"
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
            resetBridgeRetry()
            adbScanGeneration += 1
            adbChecking = false
            nextADBScanAt = .distantPast
            selectedADBPath = url.path
            UserDefaults.standard.set(url.path, forKey: "SIMAI_ADB_PATH")
            log(.info, .system, "用户手动设置 ADB 路径（路径不写入诊断日志）")
            autoInspectADBIfNeeded(force: true)
            pollLiveBridge()
        }
    }

    func resetADBSelection() {
        closeLiveBridge()
        resetBridgeRetry()
        adbScanGeneration += 1
        adbChecking = false
        nextADBScanAt = .distantPast
        selectedADBPath = ""
        UserDefaults.standard.removeObject(forKey: "SIMAI_ADB_PATH")
        log(.info, .system, "ADB 切换为自动路径检测")
        autoInspectADBIfNeeded(force: true)
        pollLiveBridge()
    }

    /// User-controlled scrcpy mirroring; no OCR or automated taps are
    /// performed. Permission dialogs are completed explicitly in the mirror.
    func openPhoneScreenControl() {
        guard !screenControlRunning, !screenControlStarting else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        screenControlStarting = true
        screenControlStatus = "正在确认 scrcpy 与唯一已授权的 ADB 手机……"
        let adb = selectedADBPath
        Task.detached(priority: .userInitiated) { [weak self] in
            let prepared = ADBInspector.prepareScreenControl(at: adb)
            await MainActor.run {
                guard let self else { return }
                self.screenControlStarting = false
                guard prepared.code == "SCREEN_READY",
                      let scrcpy = prepared.scrcpy,
                      let selectedADB = prepared.adb,
                      let serial = prepared.serial else {
                    let status: String
                    switch prepared.code {
                    case "SCREEN_SCRCPY_MISSING":
                        status = "未检测到 scrcpy。请先在 Mac 运行 brew install scrcpy（不自动安装第三方工具）。"
                    case "SCREEN_ADB_MISSING":
                        status = "未找到 adb；请先在 ADB 管理区设置有效路径"
                    case "SCREEN_ADB_UNAUTHORIZED":
                        status = "手机尚未授权 USB 调试；首次配对需在手机上确认，之后才能远程控制"
                    case "SCREEN_MULTIPLE_DEVICES":
                        status = "检测到多台已授权手机，为避免误操作请只连接目标手机"
                    case "SCREEN_DEVICE_NOT_READY":
                        status = "尚未检测到已授权的在线手机，请确认 USB / 无线 ADB"
                    case "SCREEN_ADB_TIMEOUT":
                        status = "ADB 设备检测超时；解锁手机并检查连接后再试"
                    default:
                        status = "无法启动屏幕控制，请检查 ADB 和 scrcpy 是否正常"
                    }
                    self.screenControlStatus = status
                    self.log(.warn, .system, "ADB 手机屏幕控制未能启动",
                             details: ["reason": prepared.code])
                    return
                }

                let process = Process()
                process.executableURL = scrcpy
                process.arguments = [
                    "--serial", serial,
                    "--no-audio", "--max-size=1024", "--max-fps=30",
                    "--window-title=SIM AI 手机屏幕（用户手动操作）"
                ]
                var environment = ProcessInfo.processInfo.environment
                // Honor the same ADB executable used for installation and
                // never log the device serial or the spawned command line.
                environment["ADB"] = selectedADB.path
                environment["PATH"] = selectedADB.deletingLastPathComponent().path + ":" +
                    (environment["PATH"] ?? "/usr/bin:/bin")
                process.environment = environment
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { [weak self] finished in
                    Task { @MainActor in
                        guard let self, self.screenControlProcess === finished else { return }
                        self.screenControlProcess = nil
                        self.screenControlRunning = false
                        self.screenControlStatus = finished.terminationStatus == 0
                            ? "手机屏幕窗口已关闭"
                            : "手机屏幕连接中断或被系统拒绝；请检查 USB 调试与 vivo 安全设置"
                        self.log(.info, .system, "手机屏幕控制会话结束",
                                 details: ["reason": "SCREEN_SESSION_ENDED"])
                    }
                }
                do {
                    try process.run()
                    self.screenControlProcess = process
                    self.screenControlRunning = true
                    self.screenControlStatus = "已打开手机屏幕：使用 Mac 鼠标处理安装、权限及设置提示；不会自动点击授权"
                    self.log(.info, .system, "用户主动打开手机屏幕控制",
                             details: ["route": "SCRCPY_AUTHORIZED_SINGLE_DEVICE"])
                } catch {
                    self.screenControlStatus = "无法启动 scrcpy；检查是否已安装以及 Mac 执行权限"
                    self.log(.warn, .system, "scrcpy 进程启动失败",
                             details: ["reason": "SCREEN_PROCESS_LAUNCH_FAILED"])
                }
            }
        }
    }

    func openPhonePermissionSettings() {
        // Display scrcpy for the user's own approval. Never approve system
        // dialogs by scripted taps or platform privilege escalation.
        openPhoneScreenControl()
        let path = selectedADBPath
        Task.detached(priority: .utility) { [weak self] in
            let outcome = ADBInspector.openCompanionSettings(at: path)
            await MainActor.run {
                guard let self else { return }
                self.screenControlStatus = outcome.status
                self.log(outcome.succeeded ? .info : .warn, .system,
                         "用户要求打开手机应用系统权限页面",
                         details: ["success": "\(outcome.succeeded)"])
            }
        }
    }

    func closePhoneScreenControl() {
        let process = screenControlProcess
        screenControlProcess = nil
        screenControlRunning = false
        screenControlStatus = "已主动关闭手机屏幕控制"
        if let process, process.isRunning { process.terminate() }
        log(.info, .system, "用户关闭手机屏幕控制",
            details: ["reason": "SCREEN_USER_STOPPED"])
    }

    func installAndroidCompanion() {
        guard !adbInstalling else { return }
        guard let resource = Bundle.main.resourceURL?.appendingPathComponent("SIMAI-Companion.apk"),
              FileManager.default.fileExists(atPath: resource.path) else {
            alertText = "当前 App 未包含 Android 伴侣 APK；请下载 GitHub 最新完整测试包。"
            return
        }
        closeLiveBridge()
        // Open the control window before ADB install can block on an OEM
        // confirmation. The user still makes all permission decisions.
        openPhoneScreenControl()
        adbInstalling = true
        apkInstallStatus = "正在安装；如手机要求确认，请在 Mac 打开的手机屏幕窗口中手动操作……"
        let adb = selectedADBPath
        log(.info, .system, "用户确认开始安装或覆盖 Android 伴侣 APK",
            details: ["version": "0.3.5"])
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = ADBInspector.install(at: adb, apk: resource)
            await MainActor.run {
                guard let self else { return }
                self.adbInstalling = false
                self.apkInstallStatus = outcome.status
                self.log(outcome.succeeded ? .info : .warn, .system,
                    outcome.succeeded ? "Android APK 安装成功" : "Android APK 安装失败",
                    details: ["success": "\(outcome.succeeded)",
                              "reason": outcome.status])
                self.alertText = outcome.status
                self.inspectADB()
                if outcome.succeeded && FeishuWebhookStore.load() != nil {
                    self.feishuSyncStatus = "手机 APK 已安装，正在自动恢复飞书配置……"
                    self.syncFeishuSettings()
                }
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
        openPhoneScreenControl()
        adbInstalling = true
        apkInstallStatus = "已确认清空旧版数据，正在重装；如有系统提示请在 Mac 手机窗口手动确认……"
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
                if outcome.succeeded && FeishuWebhookStore.load() != nil {
                    self.feishuSyncStatus = "手机应用清理重装完成，正在从 Mac 钥匙串恢复飞书配置……"
                    self.syncFeishuSettings()
                }
                self.pollLiveBridge()
            }
        }
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

    func playSpeakerBeep() {
        NSSound.beep()
        log(.info, .audio, "用户触发扬声器试听提示音（非电话链路）")
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
        let context = ExportContext(system: system, audio: audio,
            sessionID: sessionID, recentError: lastError, callState: livePhoneState,
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
