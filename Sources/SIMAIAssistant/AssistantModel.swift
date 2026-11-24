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
    @Published var useEmbeddedVoiceBrowser =
        UserDefaults.standard.object(forKey: "SIMAI_EMBEDDED_VOICE_MODE") as? Bool ?? true
    @Published var embeddedVoiceCaptureActive = false
    @Published var embeddedVoiceStatus = "内嵌 ChatGPT Voice 未启用；登录后将通过 WebKit 验证麦克风采集"
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
    private var monitorSelectionIsAutomatic = false
    @Published var selectedVoiceMonitorOutputID = "" {
        didSet {
            // A temporary Bluetooth/HDMI disconnect must NOT overwrite the
            // user's saved physical monitor UID with a fallback speaker.
            if !monitorSelectionIsAutomatic && !selectedVoiceMonitorOutputID.isEmpty {
                AudioInspector.saveMonitorSelection(selectedVoiceMonitorOutputID)
            }
        }
    }
    /// Prefer route isolation inside our WKWebView. Do not globally replace
    /// the Mac speaker when the user is watching videos or using other apps.
    @Published var isolatedChatGPTOutputEnabled =
        UserDefaults.standard.object(forKey: "SIMAI_ISOLATED_WEB_OUTPUT") as? Bool ?? true
    @Published var automaticGPTOutputEnabled =
        UserDefaults.standard.object(forKey: "SIMAI_AUTO_GPT_OUTPUT") as? Bool ?? true
    @Published var automaticGPTOutputStatus = "自动虚拟音频路由待命；GPT 输入 BlackHole 2ch、输出 BlackHole 16ch"
    @Published var blackHoleInstallerBusy = false
    @Published var blackHoleInstallerStatus = "检测 BlackHole 2ch / 16ch 状态后可直接获取官方安装程序，无需 Homebrew"
    @Published var aiReplyMonitorEnabled = false
    @Published var allowCallerMonitorDuringAI =
        UserDefaults.standard.bool(forKey: "SIMAI_MIX_CALLER_AND_GPT_LOCAL")
    @Published var aiReplyToPhoneEnabled = false
    @Published var aiReplyReturnStatus = "尚未启动 GPT 回复监听"
    @Published var aiReplyReceivedFrames = 0
    @Published var aiReplyMonitorDropped = 0
    @Published var aiReplyUplinkUnderflow = 0
    @Published var aiReplyPeakRMS = 0.0
    private var warnedSilentGPTReturn = false
    private var ranBlackHoleInputProbe = false
    @Published var blackHoleActualInputStatus = "尚未验证 BlackHole 2ch 输入回环"
    @Published var liveVoiceRxFrames = 0
    private var livePhysicalRenderFrames = 0
    private var liveVirtualRenderFrames = 0
    private var liveDownlinkPeakRMS = 0.0
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

    let version = "0.4.31"
    let buildNumber = "48"
    private let logger = Logger(subsystem: "com.simai.assistant", category: "diagnostics")
    private let logs: LogStore
    private var audioInspector = AudioInspector()
    private let voiceOutputRouter = AutoVoiceOutputRouter()
    private let voiceInputRouter = AutoVoiceInputRouter()
    let embeddedVoiceBrowser = EmbeddedChatGPTVoiceBrowser()
    private var embeddedVoiceWindow: NSWindow?
    private var embeddedVoiceWindowOpenedByUser = false

    /// Application-owned browser window. Unlike the old Dashboard.onReceive,
    /// this stays available while the diagnostics window is closed or a
    /// video is playing full-screen. Only manual opens activate the Mac app.
    func showEmbeddedVoiceWindow(activate: Bool = true) {
        if activate { embeddedVoiceWindowOpenedByUser = true }
        let window: NSWindow
        if let existing = embeddedVoiceWindow {
            window = existing
        } else {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            created.title = "ChatGPT Voice · 内嵌浏览器"
            created.isReleasedWhenClosed = false
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            created.contentView = NSHostingView(rootView:
                EmbeddedChatGPTVoiceWindow(browser: embeddedVoiceBrowser)
                    .environmentObject(self))
            created.center()
            embeddedVoiceWindow = created
            window = created
        }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            // Do not steal focus from the video player; WebKit still has a
            // live, on-screen NSView for the Voice start button and WebRTC.
            window.orderFront(nil)
        }
        embeddedVoiceBrowser.loadIfNeeded()
        prepareAutomaticGPTInput()
    }

    func hideEmbeddedVoiceWindow(force: Bool = false) {
        // User-opened login/debug pages survive ringing timeouts. However,
        // a real auto-answered phone call must always close its Voice window
        // when the PSTN audio stream ends, even if that window was previously
        // opened manually. Hiding BEFORE releasing WebKit prevents the old
        // visible white-page regression.
        guard force || !embeddedVoiceWindowOpenedByUser else { return }
        embeddedVoiceWindow?.orderOut(nil)
        if force { embeddedVoiceWindowOpenedByUser = false }
    }

    /// End only a call that SIM AI actually auto-answered. This is a local
    /// safety shutdown; it never sends a blind Android end-call command and
    /// never clears ChatGPT cookies or other user login data.
    private func endAutoAnsweredVoiceBrowser(reason: String) {
        guard useEmbeddedVoiceBrowser else { return }
        voiceStopCheckGeneration += 1
        incomingVoicePending = false
        incomingVoiceDeadline = nil
        incomingPreflightPassed = false
        incomingVoiceBlockedUntilIdle = true
        autoVoiceCaptureObserved = false
        automaticAnswerAcknowledged = false
        automaticAnswerRequested = false
        resumeAIForwardAfterVoicePause = false
        resumeAIForwardAfterIsolationRestored = false
        resumeAIForwardAfterMicrophoneRestored = false
        voiceSessionPrepared = false
        autoStartedWebVoiceForRing = false
        hideEmbeddedVoiceWindow(force: true)
        embeddedVoiceBrowser.releaseForIdle()
        log(.info, .audio, "已在手机通话结束后关闭自动 Voice 网页及麦克风",
            details: ["reason": reason])
    }
    private let microphoneProbe = MicrophoneLevelProbe()
    private var voiceStream: PhoneAudioStream?
    private var autoCallState = AutoCallStateMachine()
    private var autoCallAudioRequested = false
    private var incomingVoicePending = false
    /// The current ringing session owns this WebKit Voice page even if the
    /// Android answer response was lost. It is safe to close on real IDLE.
    private var autoStartedWebVoiceForRing = false
    // Hand-answered calls may still route PCM, but may NEVER gain the
    // automatic-hangup authority reserved for acknowledged AI answers.
    private var observedRingingSession = ""
    private var observedRingingSequence = 0
    private var manualPickupFromTrackedRing = false
    private var manualPickupPCMStarts = 0
    private var manualPickupPCMRetryAfter = Date.distantPast
    private var incomingVoiceBlockedUntilIdle = false
    private var incomingPreflightRunning = false
    private var incomingPreflightPassed = false
    private var incomingVoiceDeadline: Date?
    private var previousObservedPhoneState = ""
    // A hang-up is permitted only for this app's acknowledged auto-answer.
    // The Android service independently checks its current session/sequence.
    private var automaticAnswerRequested = false
    private var automaticAnswerAcknowledged = false
    private var automaticAnswerSession = ""
    private var automaticOffhookSequence = 0
    private var autoVoiceCaptureObserved = false
    private var voiceStopCheckGeneration = 0
    private var autoHangupBusy = false
    private var autoHangupAttempted = false
    private var resumeAIForwardAfterVoicePause = false
    private var resumeAIForwardAfterIsolationRestored = false
    private var resumeAIForwardAfterMicrophoneRestored = false
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
    private var lastAndroidAnswerPermission: Bool?
    private var orderedAnswerReplyAvailable = false
    private var lastAndroidAnswerDiagnostic = ""
    private var nextHTTPRecoveryAttempt = Date.distantPast
    private var bridgeRetryAfter = Date.distantPast
    private var bridgeConsecutiveFailures = 0
    private var adbTransientMissingScans = 0
    private var nextBridgeForwardAttempt = Date.distantPast
    private var lastDefaultOutputID = ""
    private var lastObservedAudioRouteAt = Date.distantPast
    private var nextPhoneMonitorWakeAt = Date.distantPast
    private var initialPhoneMonitorWarmup = false
    private var startupBridgeGraceUntil = Date().addingTimeInterval(30)
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
        // v0.4.20 migrates once from the old global-output mode to video-
        // safe isolated output. Respect subsequent explicit user changes.
        if !UserDefaults.standard.bool(forKey: "SIMAI_OUTPUT_SAFETY_MIGRATED_0420") {
            UserDefaults.standard.set(true, forKey: "SIMAI_ISOLATED_WEB_OUTPUT")
            UserDefaults.standard.set(true, forKey: "SIMAI_OUTPUT_SAFETY_MIGRATED_0420")
            isolatedChatGPTOutputEnabled = true
            log(.info, .audio, "已升级到视频安全隔离模式：不再自动切换系统默认扬声器")
        }

        let recoveredOutput = voiceOutputRouter.recoverPreviousSession()
        let recoveredInput = voiceInputRouter.recoverPreviousSession()
        if recoveredOutput == "ROUTE_RESTORED" || recoveredInput == "INPUT_RESTORED" {
            // Update the cached start-up defaults after crash recovery.
            audioInspector = AudioInspector()
        }
        if recoveredOutput != "ROUTE_NOT_OWNED" || recoveredInput != "INPUT_NOT_OWNED" {
            automaticGPTOutputStatus = "已检查上次异常结束的音频输入／输出，并尝试恢复"
            log(.info, .audio, "自动虚拟音频设备启动恢复",
                details: ["inputCode": recoveredInput, "outputCode": recoveredOutput])
        }
        embeddedVoiceBrowser.setIsolatedAudioOutputEnabled(isolatedChatGPTOutputEnabled)
        embeddedVoiceBrowser.onIsolatedMicrophoneChange = { [weak self] ready in
            guard let self, self.useEmbeddedVoiceBrowser else { return }
            if ready {
                self.log(.info, .audio, "已核验 ChatGPT 实际使用 BlackHole 2ch 输入")
                if self.resumeAIForwardAfterMicrophoneRestored &&
                   self.liveVoiceActive && self.livePhoneState == "OFFHOOK" &&
                   self.automaticAnswerAcknowledged &&
                   self.aiReplyMonitorEnabled &&
                   self.embeddedVoiceBrowser.isolatedOutputReady &&
                   self.isSystemOutputSafeForIsolatedReturn() {
                    self.resumeAIForwardAfterMicrophoneRestored = false
                    self.setAIReplyToPhone(true)
                }
                if self.incomingVoicePending && self.embeddedVoiceBrowser.microphoneActive &&
                   (!self.isolatedChatGPTOutputEnabled ||
                    self.embeddedVoiceBrowser.isolatedOutputReady) {
                    self.onEmbeddedVoiceCapture(true)
                }
            } else if self.isolatedChatGPTOutputEnabled &&
                      self.aiReplyToPhoneEnabled {
                self.resumeAIForwardAfterMicrophoneRestored = true
                self.setAIReplyToPhone(false)
                self.log(.warn, .audio, "ChatGPT 麦克风路由未验证，暂停电话 AI 回传",
                         details: ["reason": "GPT_INPUT_DEVICE_NOT_VERIFIED"])
            }
        }
        embeddedVoiceBrowser.onIsolatedOutputChange = { [weak self] ready in
            guard let self else { return }
            if ready {
                self.automaticGPTOutputStatus =
                    "ChatGPT 网页已配置独立输出到 BlackHole 16ch；视频保持原路"
                if self.incomingVoicePending && self.embeddedVoiceBrowser.microphoneActive &&
                   self.embeddedVoiceBrowser.isolatedMicrophoneReady {
                    self.onEmbeddedVoiceCapture(true)
                }
                if self.resumeAIForwardAfterIsolationRestored &&
                   self.liveVoiceActive && self.livePhoneState == "OFFHOOK" &&
                   self.aiReplyMonitorEnabled && self.embeddedVoiceBrowser.microphoneActive &&
                   self.embeddedVoiceBrowser.isolatedMicrophoneReady &&
                   self.isSystemOutputSafeForIsolatedReturn() {
                    self.resumeAIForwardAfterIsolationRestored = false
                    self.setAIReplyToPhone(true)
                }
            } else if self.isolatedChatGPTOutputEnabled {
                if self.aiReplyToPhoneEnabled {
                    self.resumeAIForwardAfterIsolationRestored = true
                    self.setAIReplyToPhone(false)
                    self.log(.warn, .audio,
                        "网页隔离音频路由丢失，已暂停 GPT 电话回传",
                        details: ["reason": "ISOLATED_ROUTE_LOST"])
                }
                self.automaticGPTOutputStatus =
                    "网页隔离尚未就绪；视频不会进入电话，上行回传已安全暂停"
            }
        }
        embeddedVoiceBrowser.onMicrophoneChange = { [weak self] active in
            self?.onEmbeddedVoiceCapture(active)
        }
        embeddedVoiceBrowser.onDiagnostic = { [weak self] code in
            guard let self else { return }
            self.log(.info, .audio, "内嵌 ChatGPT Voice 页面事件",
                     details: ["event": code])
        }
        refresh()
        startLiveSyncTimer()
        // Load the signed-in page ahead of calls without starting Voice or
        // opening the window. This avoids spending 10-15 ringing seconds on
        // navigation. Actual voice recording still requires ring/preflight.
        if autoCallEnabled && useEmbeddedVoiceBrowser {
            embeddedVoiceBrowser.loadIfNeeded()
            log(.info, .audio, "自动值守已预载 ChatGPT 登录页面（未开启麦克风）",
                details: ["stage": "VOICE_PAGE_PREWARMED_IDLE"])
        }
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
        // A playback device can change while watching video (Bluetooth,
        // HDMI, AirPlay). CoreAudio numeric IDs are not stable. Prefer the
        // saved physical hardware UID, otherwise use a real output device
        // with an actual stream. Never select a microphone as the monitor.
        if let newOutput = audio.devices.first(where: { $0.isDefaultOutput })?.id {
            if !lastDefaultOutputID.isEmpty && newOutput != lastDefaultOutputID {
                log(.info, .audio, "检测到 macOS 外部默认输出设备变化（本应用未修改）",
                    details: ["reason": "SYSTEM_DEFAULT_OUTPUT_CHANGED_EXTERNALLY"])
            }
            lastDefaultOutputID = newOutput
        }
        if let recommended = AudioInspector.recommendedMonitorOutput(
            from: audio, previousID: selectedVoiceMonitorOutputID
        ), recommended != selectedVoiceMonitorOutputID {
            monitorSelectionIsAutomatic = true
            selectedVoiceMonitorOutputID = recommended
            monitorSelectionIsAutomatic = false
            log(.info, .audio, "已自动恢复有效的 Mac 通话监听设备",
                details: ["selection": "PHYSICAL_OUTPUT_UID_OR_FALLBACK"])
        }
        if audio.microphonePermission == "已拒绝" {
            log(.warn, .audio, "麦克风权限被拒绝", code: .microphoneDenied)
        }
    }


    /// Enable only after the owner chooses to sign in to chatgpt.com in
    /// the app. Voice launches are UI experiments, not an official API.
    func setEmbeddedVoiceBrowserEnabled(_ enabled: Bool) {
        useEmbeddedVoiceBrowser = enabled
        UserDefaults.standard.set(enabled, forKey: "SIMAI_EMBEDDED_VOICE_MODE")
        if enabled {
            embeddedVoiceStatus = "轻量待命：只在手动打开或来电时加载 ChatGPT 网页"
        } else {
            incomingVoicePending = false
            incomingVoiceDeadline = nil
            embeddedVoiceBrowser.releaseForIdle()
            embeddedVoiceCaptureActive = false
            voiceSessionPrepared = false
            autoCallState.reset()
            if aiReplyToPhoneEnabled { stopGPTTwoWayPhoneBridge() }
            if !liveVoiceActive { restoreAutomaticGPTOutput(forceInput: true) }
            embeddedVoiceStatus = "内嵌模式已关闭；不控制浏览器或其网站登录状态"
        }
    }

    func setEmbeddedVoiceAutoStart(_ enabled: Bool) {
        embeddedVoiceBrowser.setAutomaticVoiceButton(enabled)
        embeddedVoiceStatus = enabled
            ? "自动启动实验已开启，网页加载后可尝试识别 Voice 按钮"
            : "自动点击已关闭，可在窗口中手动点击 Voice"
    }

    func tryStartEmbeddedVoice() {
        guard useEmbeddedVoiceBrowser else {
            embeddedVoiceStatus = "请先启用内嵌 ChatGPT Voice 模式"
            return
        }
        refresh()
        guard prepareAutomaticGPTOutput() else {
            embeddedVoiceStatus = "虚拟麦克风或扬声器未就绪；没有点击网页 Voice"
            return
        }
        embeddedVoiceBrowser.attemptVoiceStart()
    }

    private func onEmbeddedVoiceCapture(_ active: Bool) {
        embeddedVoiceCaptureActive = active
        guard useEmbeddedVoiceBrowser else { return }
        if active {
            voiceStopCheckGeneration += 1
            if automaticAnswerAcknowledged { autoVoiceCaptureObserved = true }
            if resumeAIForwardAfterVoicePause &&
               automaticAnswerAcknowledged && livePhoneState == "OFFHOOK" &&
               liveVoiceActive && aiReplyMonitorEnabled &&
               embeddedVoiceBrowser.isolatedMicrophoneReady &&
               (!isolatedChatGPTOutputEnabled ||
                embeddedVoiceBrowser.isolatedOutputReady) {
                resumeAIForwardAfterVoicePause = false
                setAIReplyToPhone(true)
                log(.info, .audio, "Voice 恢复采集，恢复已授权的 GPT 电话回传")
            }
            embeddedVoiceStatus = "WebKit 已采集麦克风；电话实测才能确认 GPT 听懂语音"
            if incomingVoicePending && incomingPreflightPassed &&
               embeddedVoiceBrowser.isolatedMicrophoneReady &&
               (!isolatedChatGPTOutputEnabled ||
                embeddedVoiceBrowser.isolatedOutputReady) &&
               (livePhoneState == "RINGING" ||
                (livePhoneState == "OFFHOOK" && manualPickupFromTrackedRing)) &&
               !incomingVoiceBlockedUntilIdle {
                setVoiceSessionPrepared(true)
                if voiceSessionPrepared {
                    incomingVoicePending = false
                    incomingVoiceDeadline = nil
                    log(.info, .audio, "来电 Voice 与音频 HAL 预检已就绪",
                        details: ["stage": "VOICE_CAPTURE_READY_AFTER_PREFLIGHT"])
                    reactToAutomaticCallState(livePhoneState)
                }
            }
        } else {
            if automaticAnswerAcknowledged && autoVoiceCaptureObserved &&
               livePhoneState == "OFFHOOK" {
                // Mute the PSTN uplink immediately while WebKit is not
                // capturing, so unrelated desktop audio cannot leak during
                // the grace period. Restore only if the same Voice resumes.
                if aiReplyToPhoneEnabled {
                    resumeAIForwardAfterVoicePause = true
                    setAIReplyToPhone(false)
                }
                // A 4-second grace period avoids treating a temporary mute,
                // capture pause or WebKit hiccup as an ended Voice session.
                voiceSessionPrepared = false
                if embeddedVoiceBrowser.voiceSessionActuallyEnded {
                    scheduleAutomaticHangupAfterVoiceEnds()
                    embeddedVoiceStatus = "Voice 已结束，确认 4 秒后请求手机挂断"
                } else {
                    voiceStopCheckGeneration += 1
                    embeddedVoiceStatus = "Voice 麦克风暂时静音；不会误挂电话"
                }
                return
            }
            if voiceSessionPrepared || aiReplyToPhoneEnabled {
                log(.warn, .audio, "Voice 采集停止，撤销自动接听及 GPT 回传",
                    details: ["reason": "VOICE_CAPTURE_LOST"])
            }
            embeddedVoiceStatus = "Voice 麦克风未采集；自动接听未就绪"
            voiceSessionPrepared = false
            autoCallState.reset()
            if aiReplyToPhoneEnabled { stopGPTTwoWayPhoneBridge() }
            if !liveVoiceActive && !incomingVoicePending {
                restoreAutomaticGPTOutput(forceInput: true)
            }
        }
    }

    private func checkIsolatedReturnSafety() {
        guard useEmbeddedVoiceBrowser && isolatedChatGPTOutputEnabled &&
              (liveVoiceActive || liveVoiceStarting) else { return }
        if !isSystemOutputSafeForIsolatedReturn() && aiReplyToPhoneEnabled {
            resumeAIForwardAfterIsolationRestored = false
            setAIReplyToPhone(false)
            log(.warn, .audio, "系统默认输出变为虚拟/聚合设备，已暂停电话 GPT 回传",
                details: ["reason": "VIDEO_AUDIO_LEAK_GUARD"])
        }
    }

    private func checkEmbeddedVoiceHealth() {
        guard useEmbeddedVoiceBrowser else { return }
        // Never auto-start Voice merely because a WebKit page is loaded at idle.
        guard incomingVoicePending else {
            if liveVoiceActive || (automaticAnswerAcknowledged &&
                                   livePhoneState == "OFFHOOK") {
                // ChatGPT can recreate its WebRTC/audio elements AFTER the
                // call connects. Keep validating both the microphone and
                // remote sound sink for the entire call, not only at startup.
                embeddedVoiceBrowser.checkMicrophoneCapture()
                embeddedVoiceBrowser.checkActualMicrophoneRouting()
                if isolatedChatGPTOutputEnabled {
                    embeddedVoiceBrowser.routeCurrentVoiceAudioIfNeeded()
                }
            }
            return
        }
        if livePhoneState != "RINGING" &&
           !(livePhoneState == "OFFHOOK" && manualPickupFromTrackedRing) {
            // ADB may disconnect during a ringing session. Do not leave
            // a live browser or virtual audio route running indefinitely.
            incomingVoicePending = false
            incomingVoiceBlockedUntilIdle = true
            incomingPreflightPassed = false
            incomingVoiceDeadline = nil
            embeddedVoiceBrowser.preservePageAfterCall(reason: "RINGING_LOST")
            restoreAutomaticGPTOutput(forceInput: true)
            log(.warn, .audio, "来电监听中断，保留 ChatGPT 页面并放弃本次接听",
                details: ["reason": "VOICE_RINGING_STATE_LOST"])
            return
        }
        if let deadline = incomingVoiceDeadline, Date() >= deadline {
            incomingVoicePending = false
            incomingVoiceBlockedUntilIdle = true
            incomingPreflightPassed = false
            voiceSessionPrepared = false
            embeddedVoiceStatus = "Voice 启动超时：本次来电不自动接听"
            log(.warn, .audio, "按需启动 Voice 超时，放弃本次接听",
                details: ["reason": "ON_DEMAND_VOICE_TIMEOUT"])
            embeddedVoiceBrowser.preservePageAfterCall(reason: "TIMEOUT")
            restoreAutomaticGPTOutput(forceInput: true)
            return
        }
        guard incomingPreflightPassed else { return }
        embeddedVoiceBrowser.healthCheck { [weak self] in
            guard let self else { return false }
            return self.incomingVoicePending && self.incomingPreflightPassed &&
                   (self.livePhoneState == "RINGING" ||
                    (self.livePhoneState == "OFFHOOK" &&
                     self.manualPickupFromTrackedRing))
        }
        embeddedVoiceBrowser.checkMicrophoneCapture()
    }

    /// While a call rings, first verify the HAL output can actually render
    /// PCM on both the physical monitor and BlackHole 2ch. Only then load
    /// the official Voice page and attempt to start its Voice UI.
    private func beginOnDemandVoiceForRinging() {
        guard autoCallEnabled && useEmbeddedVoiceBrowser,
              !incomingVoicePending && !incomingVoiceBlockedUntilIdle,
              !incomingPreflightRunning && !voiceSessionPrepared else { return }
        refresh()
        let problems = automaticVoiceReadinessIssues()
        if !problems.isEmpty {
            incomingVoiceBlockedUntilIdle = true
            autoCallStatus = "本次未自动接听：" + problems.joined(separator: "；")
            return
        }
        guard prepareAutomaticGPTOutput() else {
            incomingVoiceBlockedUntilIdle = true
            autoCallStatus = "本次未自动接听：虚拟音频路由准备失败"
            return
        }
        incomingVoicePending = true
        incomingVoiceDeadline = Date().addingTimeInterval(25)
        incomingPreflightRunning = true
        incomingPreflightPassed = false
        autoCallStatus = "检测到来电：正在验证声音输出，然后启动 Voice"
        let monitor = UInt32(selectedVoiceMonitorOutputID)
        Task.detached(priority: .userInitiated) { [weak self] in
            let code = PhoneAudioStream.preflightOutputs(physicalOutputID: monitor)
            await MainActor.run {
                guard let self else { return }
                self.incomingPreflightRunning = false
                guard self.incomingVoicePending else { return }
                guard self.livePhoneState == "RINGING" ||
                    (self.livePhoneState == "OFFHOOK" &&
                     self.manualPickupFromTrackedRing) else {
                    self.incomingVoicePending = false
                    self.restoreAutomaticGPTOutput(forceInput: true)
                    return
                }
                guard code == "PREFLIGHT_OK" else {
                    self.incomingVoicePending = false
                    self.incomingVoiceBlockedUntilIdle = true
                    self.voiceSessionPrepared = false
                    self.autoCallStatus = "未接听：音频实际渲染预检失败"
                    self.log(.warn, .audio, "来电前音频输出预检失败",
                             details: ["reason": code])
                    self.restoreAutomaticGPTOutput(forceInput: true)
                    return
                }
                self.incomingPreflightPassed = true
                self.autoCallStatus = "音频预检成功：正在加载网页并启动 Voice"
                // Ownership begins when we start the ring-triggered page,
                // not only after the unreliable HTTP /call/answer returns.
                self.autoStartedWebVoiceForRing = true
                self.showEmbeddedVoiceWindow(activate: false)
                self.checkEmbeddedVoiceHealth()
            }
        }
    }

    /// This setting only arms an already running official Voice session.
    /// There is no official ChatGPT Plus API for unattended voice creation.
    func setIsolatedChatGPTOutputEnabled(_ enabled: Bool) {
        guard !liveVoiceActive && !liveVoiceStarting &&
              !incomingVoicePending else {
            automaticGPTOutputStatus = "当前通话运行中，请通话结束后切换声音隔离模式"
            return
        }
        isolatedChatGPTOutputEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "SIMAI_ISOLATED_WEB_OUTPUT")
        embeddedVoiceBrowser.setIsolatedAudioOutputEnabled(enabled)
        if enabled {
            // This program owned the legacy default route: restore it now.
            // Video, music and desktop sounds must continue on their own
            // system-selected speaker.
            _ = voiceOutputRouter.restore()
        }
        automaticGPTOutputStatus = enabled
            ? "独立音频模式：仅 ChatGPT 网页输出到 BlackHole 16ch，不改系统扬声器"
            : "传统全局模式：可能连视频声音一起切入 BlackHole，仅供兼容测试"
    }

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
            restoreAutomaticGPTOutput(forceInput: true)
            automaticGPTOutputStatus = "自动切换已关闭；不再修改系统输入和输出"
        } else {
            automaticGPTOutputStatus = "自动切换待命：GPT 麦克风 BlackHole 2ch、输出 BlackHole 16ch"
        }
    }

    /// Switch only after the user arms an existing official Voice session.
    /// This changes the OS default microphone; a browser with a pinned
    /// per-site microphone may not follow until the user changes it once.
    @discardableResult
    private func prepareAutomaticGPTInput() -> Bool {
        guard automaticGPTOutputEnabled else { return true }
        let code = voiceInputRouter.activate()
        switch code {
        case "INPUT_ACTIVE", "INPUT_ALREADY_MANAGED", "INPUT_ALREADY_SELECTED":
            automaticGPTOutputStatus = "GPT 默认麦克风已准备为 BlackHole 2ch；网页是否实际使用需在 Voice 中确认"
            if code == "INPUT_ACTIVE" {
                log(.info, .audio, "已将 macOS 默认麦克风切至 BlackHole 2ch",
                    details: ["routeCode": code])
            }
            return true
        default:
            automaticGPTOutputStatus = "GPT 虚拟麦克风配置失败（" + code + "）"
            log(.warn, .audio, "BlackHole 2ch 自动输入路由失败",
                details: ["reason": code])
            return false
        }
    }

    /// Safety: while we are capturing BlackHole 16ch for the caller,
    /// the system default output must NOT be BlackHole or a multi-output
    /// aggregate containing it. Otherwise a playing video could leak into
    /// the PSTN even if the ChatGPT webpage also has a per-page sink.
    private func isSystemOutputSafeForIsolatedReturn() -> Bool {
        let current = AudioInspector().inspect().devices.first(where: {
            $0.isDefaultOutput
        })
        guard let current else { return false }
        let name = current.displayName
        return !name.localizedCaseInsensitiveContains("BlackHole") &&
               !name.localizedCaseInsensitiveContains("aggregate") &&
               !name.localizedCaseInsensitiveContains("multi-output")
    }

    /// Configure both the OS microphone and output, fail closed when either
    /// side cannot be changed. No UI automation of official ChatGPT Voice.
    @discardableResult
    private func prepareAutomaticGPTOutput() -> Bool {
        guard automaticGPTOutputEnabled else {
            automaticGPTOutputStatus = "自动切换已关闭；GPT 输入和输出必须手动配置"
            return true
        }
        guard prepareAutomaticGPTInput() else { return false }
        if useEmbeddedVoiceBrowser && isolatedChatGPTOutputEnabled {
            refresh()
            guard isSystemOutputSafeForIsolatedReturn() else {
                automaticGPTOutputStatus =
                    "为防视频声音进入电话：系统默认输出必须是实际耳机／扬声器，不能是 BlackHole／聚合设备"
                log(.warn, .audio, "网页隔离模式拒绝不安全的系统默认声音输出",
                    details: ["reason": "ISOLATED_SYSTEM_OUTPUT_UNSAFE"])
                return false
            }
            guard AudioInspector.isUsableMonitorOutput(selectedVoiceMonitorOutputID) else {
                automaticGPTOutputStatus = "找不到有效耳机／扬声器；无法安全监听隔离的 GPT 声音"
                log(.warn, .audio, "独立 GPT 音频路由缺少有效监听设备",
                    details: ["reason": "ISOLATED_MONITOR_OUTPUT_UNAVAILABLE"])
                return false
            }
            // Do NOT switch macOS default output. The embedded browser must
            // independently route its actual remote audio element via
            // WebKit setSinkId. Until the route is confirmed, auto-answer
            // is blocked and unrelated video audio stays out of the phone.
            automaticGPTOutputStatus = embeddedVoiceBrowser.isolatedOutputReady
                ? "GPT 独立输出已准备；视频保留原声卡"
                : "视频安全隔离待验证；等待 ChatGPT 网页单独连接 BlackHole 16ch"
            return true
        }
        let code = voiceOutputRouter.activate(physicalMonitorID: selectedVoiceMonitorOutputID)
        switch code {
        case "ROUTE_ACTIVE", "ROUTE_ALREADY_MANAGED", "ROUTE_ALREADY_VIRTUAL_MANUAL":
            refresh()
            automaticGPTOutputStatus = "默认麦克风 BlackHole 2ch、播放输出 BlackHole 16ch 已准备；网页实际设备仍需确认"
            log(.info, .audio, "电话 GPT 虚拟麦克风与播放输出已配置",
                details: ["input": "BLACKHOLE_2CH", "outputRouteCode": code])
            return true
        default:
            automaticGPTOutputStatus = "GPT 默认输出切换失败（" + code + "），已阻止自动接听"
            log(.warn, .audio, "GPT 输出路由不可用", details: ["reason": code])
            // Avoid leaving a virtual mic in use unless still armed.
            if !voiceSessionPrepared { _ = voiceInputRouter.restore() }
            return false
        }
    }

    /// In isolated Voice mode the Mac's system output is NEVER changed by
    /// call start/end. Hold the virtual default mic while auto-attendant is
    /// enabled, instead of flipping between physical and virtual microphones
    /// on every RINGING -> IDLE. A user disable/quit explicitly restores it.
    func restoreAutomaticGPTOutput(forceInput: Bool = false,
                                   userRequested: Bool = false) {
        let isolated = isolatedChatGPTOutputEnabled && useEmbeddedVoiceBrowser
        let outputCode = isolated && !userRequested
            ? "ROUTE_ISOLATED_UNTOUCHED" : voiceOutputRouter.restore()
        let holdMic = isolated && autoCallEnabled && automaticGPTOutputEnabled &&
            !userRequested
        let inputCode = holdMic ? "INPUT_HELD_FOR_AUTO_STANDBY"
            : (forceInput || !voiceSessionPrepared || userRequested)
                ? voiceInputRouter.restore() : "INPUT_KEPT_FOR_ARMED_VOICE"
        if outputCode == "ROUTE_RESTORED" || inputCode == "INPUT_RESTORED" {
            automaticGPTOutputStatus = "已恢复程序管理的声音设备"
            refresh()
        } else if outputCode == "ROUTE_USER_CHANGED_OUTPUT" || inputCode == "INPUT_USER_CHANGED" {
            automaticGPTOutputStatus = "检测到你已自行修改输入或输出，已保留该选择"
            refresh()
        } else if outputCode != "ROUTE_NOT_OWNED" && outputCode != "ROUTE_ISOLATED_UNTOUCHED" ||
                  !["INPUT_NOT_OWNED", "INPUT_KEPT_FOR_ARMED_VOICE",
                    "INPUT_HELD_FOR_AUTO_STANDBY"].contains(inputCode) {
            automaticGPTOutputStatus = "音频设备恢复状态：" + outputCode + "／" + inputCode
            refresh()
        }
        if !["ROUTE_NOT_OWNED", "ROUTE_ISOLATED_UNTOUCHED"].contains(outputCode) ||
           !["INPUT_NOT_OWNED", "INPUT_KEPT_FOR_ARMED_VOICE",
             "INPUT_HELD_FOR_AUTO_STANDBY"].contains(inputCode) {
            log(.info, .audio, "自动虚拟音频设备结束或回收",
                details: ["inputCode": inputCode, "outputCode": outputCode])
        }
    }

    func shutdownForAppExit() {
        // Closing the app must stop forwarding caller audio before changing
        // the global sound device. Also closes scrcpy as before.
        // ADB forwards survive Mac process exit in the adb server. Release
        // only our own dynamic port synchronously before termination.
        bridgeTimer?.invalidate()
        bridgeTimer = nil
        if let link = bridgeLink {
            ADBInspector.closeBridge(at: selectedADBPath, link: link)
            bridgeLink = nil
        }
        if liveVoiceStarting || liveVoiceActive { stopLiveVoice() }
        if aiReplyToPhoneEnabled || aiReplyMonitorEnabled || chatGPTVoiceRouteEnabled {
            stopGPTTwoWayPhoneBridge()
        }
        voiceSessionPrepared = false
        embeddedVoiceBrowser.releaseForIdle()
        hideEmbeddedVoiceWindow()
        restoreAutomaticGPTOutput(forceInput: true, userRequested: true)
        closePhoneScreenControl()
    }

    /// A brief WebKit capture interruption must not hang up a caller.
    /// Android independently verifies both the originating bridge session
    /// and the exact OFFHOOK sequence before accepting the hang-up request.
    private func scheduleAutomaticHangupAfterVoiceEnds() {
        guard automaticAnswerAcknowledged && autoVoiceCaptureObserved &&
              livePhoneState == "OFFHOOK" &&
              embeddedVoiceBrowser.voiceSessionActuallyEnded &&
              !autoHangupAttempted else { return }
        voiceStopCheckGeneration += 1
        let generation = voiceStopCheckGeneration
        autoCallStatus = "Voice 已停止采集；正在确认是否结束电话（4 秒保护）"
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self else { return }
            guard self.voiceStopCheckGeneration == generation,
                  self.automaticAnswerAcknowledged,
                  self.livePhoneState == "OFFHOOK" else { return }
            // Synchronize once; Voice could have resumed during this pause.
            self.embeddedVoiceBrowser.checkMicrophoneCapture()
            guard self.voiceStopCheckGeneration == generation,
                  !self.embeddedVoiceCaptureActive,
                  self.embeddedVoiceBrowser.voiceSessionActuallyEnded else { return }
            self.requestAutomaticHangup(reason: "VOICE_CAPTURE_ENDED")
        }
    }

    private func requestAutomaticHangup(reason: String) {
        guard automaticAnswerAcknowledged && !autoHangupBusy &&
              !autoHangupAttempted && livePhoneState == "OFFHOOK",
              automaticOffhookSequence > 0 &&
              !automaticAnswerSession.isEmpty &&
              bridgeCursor.session == automaticAnswerSession else {
            return
        }
        autoHangupBusy = true
        autoHangupAttempted = true
        let expectedSession = automaticAnswerSession
        let expectedSequence = automaticOffhookSequence
        let adb = selectedADBPath
        let existingLink = bridgeLink
        autoCallStatus = "Voice 已结束，正在请求手机挂断自动接听的电话……"
        log(.info, .call, "已触发 Voice 自动挂断保护",
            details: ["trigger": reason, "guard": "AUTO_ANSWER_SESSION_SEQUENCE"])
        Task { [weak self] in
            guard let self else { return }
            var link = existingLink
            var temporary = false
            if link == nil {
                let opened = await Task.detached(priority: .utility) {
                    ADBInspector.openBridge(at: adb)
                }.value
                link = opened.link
                temporary = link != nil
            }
            defer {
                if temporary, let link {
                    Task.detached(priority: .utility) {
                        ADBInspector.closeBridge(at: adb, link: link)
                    }
                }
                self.autoHangupBusy = false
            }
            // Never send a termination request for a call which has already
            // changed on Mac, or after losing its original Android session.
            guard self.automaticAnswerAcknowledged,
                  self.livePhoneState == "OFFHOOK",
                  self.automaticAnswerSession == expectedSession,
                  self.automaticOffhookSequence == expectedSequence,
                  let link,
                  let url = URL(string: "http://127.0.0.1:\(link.localPort)/call/hangup") else {
                self.autoCallStatus = "自动挂断已取消：手机通话或连接状态已改变"
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(link.token, forHTTPHeaderField: "X-SIMAI-Token")
            request.setValue(expectedSession, forHTTPHeaderField: "X-SIMAI-Expected-Session")
            request.setValue(String(expectedSequence), forHTTPHeaderField: "X-SIMAI-Expected-Sequence")
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            var result = "HANGUP_HTTP_UNAVAILABLE"
            do {
                let (body, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                if status == 200 && json?["result"] as? String == "hangup_requested" {
                    result = "HANGUP_REQUESTED"
                } else if status == 404 {
                    // Existing v0.3.5 installations remain supported, with
                    // an extra fresh, sequence-checked ADB snapshot guard.
                    result = await Task.detached(priority: .userInitiated) {
                        ADBInspector.guardedLegacyHangup(
                            at: adb, expectedSession: expectedSession,
                            expectedSequence: expectedSequence)
                    }.value
                } else {
                    result = "HANGUP_HTTP_\(status)"
                }
            } catch {
                // Do not send an unverified key event after an ambiguous
                // timeout: Android may have already ended the call.
                result = "HANGUP_HTTP_TIMEOUT_OR_DISCONNECTED"
            }
            self.log(result == "HANGUP_REQUESTED" ||
                     result == "ENDCALL_KEY_SENT_UNCONFIRMED" ? .info : .warn,
                     .call, "手机端 Voice 自动挂断结果",
                     details: ["result": result, "trigger": reason])
            if result == "HANGUP_REQUESTED" ||
               result == "ENDCALL_KEY_SENT_UNCONFIRMED" {
                self.autoCallStatus = "已向手机发送挂断请求，等待 Android 确认 IDLE"
                if self.liveVoiceActive || self.liveVoiceStarting {
                    self.stopLiveVoice()
                } else {
                    self.pollLiveBridge()
                }
            } else {
                self.autoCallStatus = "Voice 已结束，但自动挂断未成功；请在手机上手动挂断"
            }
        }
    }

    func setAutoCallEnabled(_ enabled: Bool) {
        autoCallEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "SIMAI_AUTO_CALL")
        if !enabled {
            voiceStopCheckGeneration += 1
            automaticAnswerRequested = false
            automaticAnswerAcknowledged = false
            automaticAnswerSession = ""
            automaticOffhookSequence = 0
            autoVoiceCaptureObserved = false
            resumeAIForwardAfterVoicePause = false
            resumeAIForwardAfterIsolationRestored = false
            resumeAIForwardAfterMicrophoneRestored = false
            autoCallState.reset()
            voiceSessionPrepared = false
            incomingVoicePending = false
            incomingVoiceBlockedUntilIdle = true
            embeddedVoiceBrowser.preservePageAfterCall(reason: "IDLE")
            hideEmbeddedVoiceWindow()
            stopGPTTwoWayPhoneBridge()
            restoreAutomaticGPTOutput(forceInput: true)
            autoCallStatus = "自动接听已关闭；不会接听后续来电"
        } else {
            autoCallStatus = "自动接听已启用；请确认官方 Voice 正在运行，才能开始无人点击的来电处理"
        }
    }

    func setVoiceSessionPrepared(_ prepared: Bool) {
        if prepared && useEmbeddedVoiceBrowser &&
           (!embeddedVoiceBrowser.microphoneActive ||
            !embeddedVoiceBrowser.isolatedMicrophoneReady ||
            !incomingPreflightPassed ||
            !(livePhoneState == "RINGING" ||
              (livePhoneState == "OFFHOOK" && manualPickupFromTrackedRing))) {
            voiceSessionPrepared = false
            autoCallStatus = "等待响铃、音频预检及 WebKit 麦克风采集全部通过"
            return
        }
        if prepared { refresh() }
        voiceSessionPrepared = prepared
        if prepared {
            let problems = automaticVoiceReadinessIssues()
            if problems.isEmpty && prepareAutomaticGPTInput() {
                autoCallStatus = "已预备自动来电：下一通响铃将自动接听并建立音频（官方 Voice 会话仍需保持运行）"
            } else {
                voiceSessionPrepared = false
                autoCallStatus = problems.isEmpty
                    ? "虚拟麦克风未准备好，已暂停自动接听"
                    : "暂不能自动接听：" + problems.joined(separator: "；")
            }
        } else {
            autoCallState.reset()
            if !liveVoiceActive { restoreAutomaticGPTOutput(forceInput: true) }
            autoCallStatus = "已撤销自动接听预备状态；未结束当前通话，但不接听新来电"
        }
    }

    private func automaticVoiceReadinessIssues() -> [String] {
        var problems: [String] = []
        if !liveSyncEnabled { problems.append("请打开电话状态同步") }
        if !automaticGPTOutputEnabled {
            problems.append("无人值守必须开启 GPT 自动音频配置")
        }
        if !embeddedAudioProbeAvailable { problems.append("缺少电话 PCM Helper") }
        if !audio.devices.contains(where: { $0.displayName.caseInsensitiveCompare("BlackHole 2ch") == .orderedSame }) {
            problems.append("缺少 BlackHole 2ch")
        }
        if !audio.devices.contains(where: { $0.displayName.caseInsensitiveCompare("BlackHole 16ch") == .orderedSame }) {
            problems.append("缺少 BlackHole 16ch")
        }
        if !AudioInspector.isUsableMonitorOutput(selectedVoiceMonitorOutputID) {
            problems.append("未找到有效的物理监听输出")
        }
        return problems
    }

    /// Route a manually picked-up, observed call only after Voice has real
    /// isolated input/output. Unlike AI-answer success this grants NO hangup
    /// capability, even if the AI voice session subsequently stops.
    private func tryStartTrackedManualPickupAudio() {
        guard manualPickupFromTrackedRing && autoCallEnabled &&
              livePhoneState == "OFFHOOK" && voiceSessionPrepared &&
              embeddedVoiceCaptureActive &&
              embeddedVoiceBrowser.isolatedMicrophoneReady &&
              (!isolatedChatGPTOutputEnabled ||
               embeddedVoiceBrowser.isolatedOutputReady) &&
              !liveVoiceStarting && !liveVoiceActive && !adbInstalling &&
              !audioProbeBusy && !autoCallAudioRequested &&
              manualPickupPCMStarts < 2 &&
              Date() >= manualPickupPCMRetryAfter else { return }
        manualPickupPCMStarts += 1
        manualPickupPCMRetryAfter = Date().addingTimeInterval(12)
        autoCallAudioRequested = true
        autoCallStatus = "手机已手动接通同一来电；正在自动建立电话 PCM 和 GPT 音频"
        log(.info, .audio, "手机手动接听后自动启动 GPT 电话音频",
            details: ["reason": "TRACKED_MANUAL_PICKUP_PCM"])
        startLiveVoice()
    }

    private func reactToAutomaticCallState(_ state: String) {
        let newIdle = state == "IDLE" && previousObservedPhoneState != "IDLE" &&
                      !previousObservedPhoneState.isEmpty
        previousObservedPhoneState = state
        if state == "RINGING" && !voiceSessionPrepared {
            beginOnDemandVoiceForRinging()
        }
        if newIdle {
            // A phone can report IDLE before the audio stream's end callback.
            // Close only sessions our app acknowledged as auto-answered;
            // a manually opened ChatGPT tab is otherwise left alone.
            if AutoCallVoiceShutdownPolicy.closeOnPhoneIdle(
                autoAnswerAcknowledged: automaticAnswerAcknowledged,
                voiceStartedForRinging: autoStartedWebVoiceForRing
            ) {
                endAutoAnsweredVoiceBrowser(reason: "PHONE_IDLED")
            }
            // Reset the auto-answer guard as soon as the Android service
            // reports IDLE. Never carry termination authority into a later call.
            voiceStopCheckGeneration += 1
            automaticAnswerRequested = false
            automaticAnswerAcknowledged = false
            automaticAnswerSession = ""
            automaticOffhookSequence = 0
            autoVoiceCaptureObserved = false
            autoHangupBusy = false
            autoHangupAttempted = false
            resumeAIForwardAfterVoicePause = false
            resumeAIForwardAfterIsolationRestored = false
            resumeAIForwardAfterMicrophoneRestored = false
            incomingVoicePending = false
            observedRingingSession = ""
            observedRingingSequence = 0
            manualPickupFromTrackedRing = false
            manualPickupPCMStarts = 0
            manualPickupPCMRetryAfter = .distantPast
            incomingPreflightRunning = false
            incomingPreflightPassed = false
            incomingVoiceBlockedUntilIdle = false
            incomingVoiceDeadline = nil
            voiceSessionPrepared = false
            if useEmbeddedVoiceBrowser && embeddedVoiceBrowser.loaded {
                // The live auto-answered Voice page was already closed above.
                // Only preserve login/debug pages unrelated to auto-answer.
                embeddedVoiceBrowser.preservePageAfterCall(reason: "IDLE")
                hideEmbeddedVoiceWindow()
            }
            if liveVoiceActive || liveVoiceStarting {
                stopLiveVoice()
            } else {
                restoreAutomaticGPTOutput(forceInput: true)
            }
            // Keep only the official web page warm; no idle microphone,
            // PSTN audio or GPT reply forwarding is activated.
            if autoCallEnabled && useEmbeddedVoiceBrowser {
                embeddedVoiceBrowser.loadIfNeeded()
            }
            autoCallStatus = "空闲已预载页面 · 来电时再启动 Voice"
        } else if state == "OFFHOOK" && automaticAnswerAcknowledged &&
                  bridgeCursor.session == automaticAnswerSession {
            automaticOffhookSequence = bridgeCursor.lastSequence
            if !embeddedVoiceCaptureActive && autoVoiceCaptureObserved &&
               embeddedVoiceBrowser.voiceSessionActuallyEnded {
                scheduleAutomaticHangupAfterVoiceEnds()
            }
        }
        if ManualPickupPolicy.isSameTrackedCall(
            state: state, session: bridgeCursor.session,
            sequence: bridgeCursor.lastSequence,
            ringSession: observedRingingSession,
            ringSequence: observedRingingSequence,
            automationEnabled: autoCallEnabled,
            voiceStartedForRing: autoStartedWebVoiceForRing || incomingVoicePending,
            automaticAnswerAcknowledged: automaticAnswerAcknowledged
        ) && !manualPickupFromTrackedRing {
            manualPickupFromTrackedRing = true
            autoCallStatus = "手机已手动接听，正在完成 Voice 并建立 PCM"
            log(.info, .call, "识别到当前来电由手机手动接听",
                details: ["stage": "MANUAL_PICKUP_SAME_RING"])
        }
        // Do not cancel an in-progress Voice startup just because the user
        // answered that same ring before the browser was ready.
        if state == "OFFHOOK" && incomingVoicePending && !voiceSessionPrepared &&
           !manualPickupFromTrackedRing {
            incomingVoicePending = false
            incomingVoiceBlockedUntilIdle = true
            incomingVoiceDeadline = nil
            autoCallStatus = "通话来源未匹配本次响铃；不会连接 GPT 电话音频"
        }
        // Fail closed if the official Voice UI was not pre-armed this session.
        // Checking for virtual devices cannot prove that ChatGPT is listening.
        let browserReady = VoiceAudioIsolationPolicy.browserReady(
            embedded: useEmbeddedVoiceBrowser,
            microphoneCapturing: embeddedVoiceCaptureActive,
            isolatedMicrophoneVerified: embeddedVoiceBrowser.isolatedMicrophoneReady,
            isolationEnabled: isolatedChatGPTOutputEnabled,
            isolatedMediaRouted: embeddedVoiceBrowser.isolatedOutputReady
        )
        let armed = autoCallEnabled && voiceSessionPrepared && browserReady &&
            automaticVoiceReadinessIssues().isEmpty && !adbInstalling &&
            !audioProbeBusy && (state != "OFFHOOK" || automaticAnswerAcknowledged)
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
            answerIncomingPhoneCall(automatic: true)
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
        if state == "OFFHOOK" {
            tryStartTrackedManualPickupAudio()
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
                self?.checkEmbeddedVoiceHealth()
                self?.checkIsolatedReturnSafety()
            }
        }
        // Never race two independent "adb devices" launches on startup.
        // Bridge connection begins once the initial authorized-device scan
        // returns, after the Android monitor gets one bounded warm-up.
        if autoADBDetectionEnabled {
            autoInspectADBIfNeeded(force: true)
        } else {
            pollLiveBridge()
        }
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
                // One failed adb devices scan commonly happens while the
                // shell/PCM helper is busy. Do NOT treat a single empty scan
                // as a disconnect or tear down an existing forward.
                if connected { self.adbTransientMissingScans = 0 }
                else { self.adbTransientMissingScans += 1 }
                let stableConnected = connected ||
                    (self.adbWasAuthorized && self.adbTransientMissingScans < 3)
                let reconnected = !self.adbWasAuthorized && stableConnected
                self.adbWasAuthorized = stableConnected
                if reconnected && self.liveSyncEnabled && self.bridgeLink == nil {
                    self.resetBridgeRetry()
                    self.beginInitialPhoneMonitorWarmup()
                } else if !stableConnected && self.liveSyncEnabled {
                    self.liveBridgeStatus = "ADB 暂时不可用，保留已有连接并自动重试"
                }
            }
        }
    }

    /// One startup wake-up is cheaper than opening the HTTP port, waiting for
    /// a timeout, then rebuilding the forward. The helper refuses to override
    /// the user's explicit "stop listening" preference on Android.
    private func beginInitialPhoneMonitorWarmup() {
        guard !initialPhoneMonitorWarmup, bridgeLink == nil,
              liveSyncEnabled, !adbInstalling else { return }
        initialPhoneMonitorWarmup = true
        liveBridgeStatus = "检测到已授权手机，正在恢复电话监听服务……"
        let adb = selectedADBPath
        let generation = bridgeGeneration
        Task.detached(priority: .utility) { [weak self] in
            let code = ADBInspector.wakePhoneMonitorIfDesired(at: adb)
            if ["PHONE_MONITOR_WAKE_REQUESTED",
                "PHONE_MONITOR_ACTIVITY_WAKE_REQUESTED"].contains(code) {
                // Android needs a brief moment to initialize its persistent
                // snapshot and loopback listener before the first Mac poll.
                Thread.sleep(forTimeInterval: 0.5)
            }
            await MainActor.run {
                guard let self else { return }
                self.initialPhoneMonitorWarmup = false
                guard generation == self.bridgeGeneration,
                      self.liveSyncEnabled else { return }
                self.nextPhoneMonitorWakeAt = Date().addingTimeInterval(90)
                let requested = ["PHONE_MONITOR_WAKE_REQUESTED",
                                 "PHONE_MONITOR_ACTIVITY_WAKE_REQUESTED"].contains(code)
                self.log(requested ? .info : .warn,
                         .call, "手机电话监听启动预热",
                         details: ["recovery": code])
                self.liveBridgeStatus = code == "PHONE_MONITOR_USER_DISABLED"
                    ? "手机端明确停止监听；请在 Companion 中手动开启"
                    : "手机监听预热完成，正在自动同步状态……"
                self.bridgeRetryAfter = .distantPast
                self.pollLiveBridge()
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
        nextBridgeForwardAttempt = .distantPast
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

    /// When the Android foreground monitor is stale, request a bounded,
    /// permission-preserving wake instead of waiting for a user to reopen it.
    /// The Companion's explicit "stop listening" preference is respected.
    private func schedulePhoneMonitorWakeIfNeeded(reason: String) {
        guard ["SNAPSHOT_INVALID_OR_STALE", "SNAPSHOT_UNAVAILABLE"].contains(reason),
              liveSyncEnabled, !adbInstalling,
              Date() >= nextPhoneMonitorWakeAt else { return }
        // Repeated background FGS wake requests can be rejected by vivo.
        // Avoid hammering ADB and triggering more competing adb commands.
        nextPhoneMonitorWakeAt = Date().addingTimeInterval(90)
        let adb = selectedADBPath
        Task.detached(priority: .utility) { [weak self] in
            let code = ADBInspector.wakePhoneMonitorIfDesired(at: adb)
            await MainActor.run {
                guard let self, self.liveSyncEnabled else { return }
                let requested = ["PHONE_MONITOR_WAKE_REQUESTED",
                                 "PHONE_MONITOR_ACTIVITY_WAKE_REQUESTED"].contains(code)
                self.log(requested ? .info : .warn,
                         .call, "已检查 Android 电话监听服务自动恢复",
                         details: ["recovery": code])
                if requested {
                    // ADB remains authorized. Prefer fresh file snapshots
                    // while the phone's HTTP listener is starting.
                    self.resetBridgeRetry()
                    self.bridgeUsingFileFallback = true
                    self.nextHTTPRecoveryAttempt = Date().addingTimeInterval(12)
                    self.pollLiveBridge()
                }
            }
        }
    }

    private func noteBridgeFailure(code: String, domain: String) {
        bridgeConsecutiveFailures += 1
        let delay = Int(BridgeRetryPolicy.delay(after: bridgeConsecutiveFailures))
        bridgeRetryAfter = Date().addingTimeInterval(TimeInterval(delay))
        let isStartup = Date() < startupBridgeGraceUntil &&
            bridgeConsecutiveFailures <= 5
        liveBridgeStatus = isStartup
            ? "手机启动同步中 · 正在自动恢复电话监听（无需手动重连）"
            : "连接中断，将在约 \(delay) 秒后自动重试"
        // One warning per outage, then sparse checkpoints. Avoid dozens of
        // redundant JSONL entries when the phone's ADB tunnel remains unreachable.
        if bridgeConsecutiveFailures == 1 || bridgeConsecutiveFailures % 8 == 0 {
            log(isStartup ? .info : .warn, .call,
                isStartup ? "ADB 电话状态启动阶段正在重试" : "ADB 电话状态桥接连接中断",
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
        if snapshot.state == "RINGING" &&
           (observedRingingSession != snapshot.session ||
            observedRingingSequence != snapshot.seq) {
            observedRingingSession = snapshot.session
            observedRingingSequence = snapshot.seq
            manualPickupFromTrackedRing = false
            manualPickupPCMStarts = 0
            manualPickupPCMRetryAfter = .distantPast
        }
        if snapshot.state == "IDLE" &&
           received.contains(where: { $0.state == "OFFHOOK" }) {
            log(.warn, .call, "接通与挂机事件延迟到同一轮才收到，已经错过可用的电话 PCM 时间窗",
                details: ["diagnosis": "OFFHOOK_IDLED_BEFORE_POLL"])
        }
        livePhoneState = snapshot.state
        liveBridgeLastSync = Date()
        if let granted = snapshot.answerPermissionGranted,
           lastAndroidAnswerPermission != granted {
            lastAndroidAnswerPermission = granted
            log(granted ? .info : .warn, .call,
                granted ? "Android 已确认授予接听电话权限" : "Android 未授予接听电话权限",
                details: ["diagnosis": granted ? "ANSWER_PERMISSION_GRANTED" : "ANSWER_PERMISSION_MISSING"])
        }
        orderedAnswerReplyAvailable = snapshot.orderedAnswerReplyAvailable == true
        if let result = snapshot.privateAnswerResult,
           let transport = snapshot.lastAnswerTransport,
           let seq = snapshot.privateAnswerSequence, seq > 0 {
            let key = "\(snapshot.session)|\(seq)|\(transport)|\(result)"
            if key != lastAndroidAnswerDiagnostic {
                lastAndroidAnswerDiagnostic = key
                log(.info, .call, "Android 端接听执行阶段",
                    details: ["result": result, "transport": transport, "sequence": "\(seq)"])
            }
        }
        if let real = snapshot.realPhoneState, real != "UNKNOWN",
           real != snapshot.state,
           snapshot.realPhoneStateAt.map({ stamp in
               guard let updated = snapshot.updatedAt else { return false }
               return stamp > 0 && updated >= stamp && updated - stamp < 4000
           }) ?? true {
            log(.warn, .call, "手机实际通话状态与缓存事件不一致",
                details: ["diagnosis": "TELEPHONY_CALLBACK_DELAYED",
                          "actual": real, "cache": snapshot.state])
        }
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
        startupBridgeGraceUntil = .distantPast
        liveBridgeStatus = source == "ADB_FILE"
            ? "已连接 · ADB 私有状态快照（HTTP 备用）"
            : "已连接 · ADB HTTP 自动同步"
    }

    private func pollPrivateSnapshot(generation: Int) {
        let adb = selectedADBPath
        let authorizedSerial = bridgeLink?.serial
        Task.detached(priority: .utility) { [weak self] in
            let result = ADBInspector.readPrivateStateSnapshot(
                at: adb, authorizedSerial: authorizedSerial)
            await MainActor.run {
                guard let self else { return }
                guard self.liveSyncEnabled, generation == self.bridgeGeneration else { return }
                self.bridgeBusy = false
                if let snapshot = result.snapshot {
                    self.applyBridgeSnapshot(snapshot, source: "ADB_FILE")
                    self.bridgeUsingFileFallback = true
                } else {
                    // Keep polling the private file during Android startup.
                    // Alternating to HTTP after every stale snapshot added
                    // another timeout and made the UI look disconnected.
                    self.bridgeUsingFileFallback = true
                    // An HTTP retry should happen occasionally, not after
                    // every stale file attempt. Preserve the established ADB
                    // forward and debounce failed file reads.
                    if self.nextHTTPRecoveryAttempt <= Date() {
                        self.nextHTTPRecoveryAttempt = Date().addingTimeInterval(35)
                    }
                    self.schedulePhoneMonitorWakeIfNeeded(reason: result.reason)
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
              !initialPhoneMonitorWarmup,
              !(adbChecking && !adbWasAuthorized && bridgeLink == nil),
              Date() >= bridgeRetryAfter else { return }
        bridgeBusy = true
        if bridgeUsingFileFallback && Date() < nextHTTPRecoveryAttempt {
            pollPrivateSnapshot(generation: bridgeGeneration)
            return
        }
        if let link = bridgeLink {
            let generation = bridgeGeneration
            // The cursor establishes an initial baseline so history from a
            // recovering phone is never misreported as live transitions.
            let since = bridgeCursor.lastSequence
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
                    // HTTP GET timed out on vivo once a real ring started.
                    // Prefer the established private-file reader for the
                    // rest of this ring and for its OFFHOOK transition.
                    let callPending = snapshot.state == "RINGING" ||
                        snapshot.state == "OFFHOOK"
                    self.bridgeUsingFileFallback = callPending
                    self.nextHTTPRecoveryAttempt = callPending
                        ? Date().addingTimeInterval(75) : .distantPast
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
                        ADBInspector.readPrivateStateSnapshot(
                            at: adb, authorizedSerial: link.serial)
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
                        self.bridgeUsingFileFallback = true
                        self.nextHTTPRecoveryAttempt = Date().addingTimeInterval(35)
                        self.schedulePhoneMonitorWakeIfNeeded(reason: fallback.reason)
                        self.noteBridgeFailure(code: fallback.reason, domain: "SIMAI.ADBFile")
                        self.livePhoneState = "未连接"
                        if self.bridgeConsecutiveFailures == 4 {
                            self.inspectBridgeHealth()
                        }
                        // Preserve a valid ADB forward if only the Android
                        // listener or its snapshot is stale. Reopening the
                        // tunnel repeatedly delayed recovery in real logs.
                        if self.bridgeConsecutiveFailures >= 5 &&
                           self.adbTransientMissingScans >= 3 &&
                           ["ADB_NOT_READY", "ADB_ENUMERATION_FAILED",
                            "ADB_ENUMERATION_TIMEOUT"].contains(fallback.reason) {
                            self.closeLiveBridge()
                        }
                    }
                }
                self.bridgeBusy = false
            }
        } else {
            // Preserve scarce ADB slots. The original app could repeatedly
            // run port forwarding while Android was restoring its service.
            guard Date() >= nextBridgeForwardAttempt else {
                bridgeBusy = false
                return
            }
            nextBridgeForwardAttempt = Date().addingTimeInterval(12)
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
                    // On first connect, read the private snapshot immediately.
                    // Waiting for an HTTP request to time out made startup
                    // take over a minute when Android's listener was asleep.
                    self.bridgeUsingFileFallback = true
                    self.nextHTTPRecoveryAttempt = Date().addingTimeInterval(10)
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
        warnedSilentGPTReturn = false
        ranBlackHoleInputProbe = false
        blackHoleActualInputStatus = "正在等待实际电话下行 PCM"
        liveVoiceRxFrames = 0
        livePhysicalRenderFrames = 0
        liveVirtualRenderFrames = 0
        liveDownlinkPeakRMS = 0
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
                              let txLate, let micBufferedMs, let voiceRouteDropped,
                              let monitorRendered, let virtualRendered):
                    self.liveVoiceRxFrames = received
                    self.liveVoiceTxFrames = sent
                    self.liveVoiceDropFrames = dropped
                    self.liveVoiceMicUnderflows = micUnderflows
                    self.liveVoiceMicOverflows = micOverflows
                    self.liveVoiceUplinkLateFrames = txLate
                    self.liveVoiceMicBufferedMs = micBufferedMs
                    self.chatGPTVoiceRouteDropped = voiceRouteDropped
                    self.livePhysicalRenderFrames = monitorRendered
                    self.liveVirtualRenderFrames = virtualRendered
                case .downlinkSignal(let peakRMS):
                    self.liveDownlinkPeakRMS = peakRMS
                case .aiReturnMetrics(let captured, let monitorDropped, let uplinkUnderflow, let peakRMS):
                    self.aiReplyReceivedFrames = captured
                    self.aiReplyMonitorDropped = monitorDropped
                    self.aiReplyUplinkUnderflow = uplinkUnderflow
                    self.aiReplyPeakRMS = peakRMS
                    if !self.warnedSilentGPTReturn && captured >= 350 &&
                       peakRMS < 0.001 && self.liveDownlinkPeakRMS > 0.01 &&
                       self.chatGPTVoiceRouteEnabled {
                        self.warnedSilentGPTReturn = true
                        self.aiReplyReturnStatus =
                            "电话声音已到 BlackHole 2ch，但 GPT 回复仍完全静音；请检查 Voice 是否识别语音或是否实际输出到 BlackHole 16ch"
                        self.log(.warn, .audio, "检测到真实电话下行但 GPT 返回通道持续静音",
                            details: ["reason": "GPT_ZERO_RETURN_WITH_PHONE_AUDIO"])
                    // Verify the driver only when Voice remains silent
                    // despite sustained non-silent phone PCM. Opening a second
                    // macOS capture client on every healthy call is unnecessary.
                        // HAL output being pulled does NOT prove that BlackHole's
                        // actual input has non-silent samples. Once real phone PCM
                        // flows, make one brief independent level-only check.
                        if !self.ranBlackHoleInputProbe &&
                           self.liveVoiceRxFrames >= 350 &&
                           self.liveVirtualRenderFrames >= 200 &&
                           self.embeddedVoiceCaptureActive {
                            self.ranBlackHoleInputProbe = true
                            self.log(.info, .audio, "正在核验 BlackHole 2ch 真实输入端音量",
                                details: ["diagnosis": "BLACKHOLE2_INPUT_PROBE_STARTED"])
                            Task.detached(priority: .utility) { [weak self] in
                                let report = BlackHoleInputProbe.run(duration: 2.0)
                                await MainActor.run {
                                    guard let self, self.voiceSessionID == id else { return }
                                    self.blackHoleActualInputStatus =
                                        report.code == "BLACKHOLE2_LOOPBACK_PRESENT"
                                        ? "BlackHole 2ch 输入端确认有电话 PCM，正在核验 ChatGPT 网页"
                                        : report.code == "BLACKHOLE2_LOOPBACK_SILENT"
                                                ? "BlackHole 2ch 真实输入仍静音，请检查虚拟声卡回环"
                                                : "虚拟声卡输入检测不可用：" + report.code
                                    self.log(report.code == "BLACKHOLE2_LOOPBACK_PRESENT"
                                                 ? .info : .warn, .audio,
                                        "BlackHole 2ch 实际输入端电平核验结果",
                                        details: [
                                                "diagnosis": report.code,
                                                "peakRMS": String(format: "%.5f", report.peakRMS),
                                                "sampledFrames": "\(report.sampledFrames)"
                                        ])
                                }
                            }
                        }
                    }
                case .finished(let reason):
                    // The Android PCM helper independently watches the real
                    // cellular AudioManager call mode. In the 21:53 report it
                    // closed while the Companion snapshot still said OFFHOOK;
                    // waiting only for IDLE leaves WebKit recording forever.
                    // Fail closed on a terminated auto-answered PCM stream,
                    // without attempting to hang up an uncertain phone call.
                    let closeAutoVoice = AutoCallVoiceShutdownPolicy.closeOnAudioEnd(
                        reason: reason,
                        automaticAudioSession: self.autoCallAudioRequested
                    )
                    if reason == "SESSION_LIMIT_180S" &&
                       self.automaticAnswerAcknowledged &&
                       self.livePhoneState == "OFFHOOK" {
                        // The phone must not stay connected without its PCM
                        // audio path when the Android helper reaches its cap.
                        self.requestAutomaticHangup(reason: "PCM_SESSION_LIMIT")
                    }
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
                    if self.liveVoiceRxFrames > 100 &&
                       self.liveVirtualRenderFrames == 0 {
                        self.log(.warn, .audio, "BlackHole 虚拟麦克风音频引擎未实际渲染任何 PCM",
                                 details: ["reason": "BLACKHOLE_RENDER_STALLED"])
                    }
                    if self.liveVoiceRxFrames > 100 && self.liveDownlinkPeakRMS < 0.001 {
                        self.log(.warn, .audio, "电话 PCM 已接收但未检测到明显的人声电平",
                                 details: ["reason": "PHONE_DOWNLINK_POSSIBLY_SILENT"])
                    }
                    if self.aiReplyReceivedFrames > 100 && self.aiReplyPeakRMS < 0.001 {
                        self.log(.warn, .audio, "GPT 回复采集帧存在但未检测到明显输出声音",
                                 details: ["reason": "GPT_OUTPUT_SILENT_OR_NOT_ROUTED"])
                    }
                    self.log(reason == "USER_STOPPED" ? .info : .warn, .audio,
                        "实时电话音频会话结束", details: [
                            "reason": reason, "rxFrames": "\(self.liveVoiceRxFrames)",
                            "phoneDownlinkPeakRMS": String(format: "%.5f", self.liveDownlinkPeakRMS),
                            "txFrames": "\(self.liveVoiceTxFrames)",
                            "dropped": "\(self.liveVoiceDropFrames)",
                            "micUnderflows": "\(self.liveVoiceMicUnderflows)",
                            "micOverflows": "\(self.liveVoiceMicOverflows)",
                            "uplinkLateFrames": "\(self.liveVoiceUplinkLateFrames)",
                            "micBufferedMs": "\(self.liveVoiceMicBufferedMs)",
                            "voiceRouteDropped": "\(self.chatGPTVoiceRouteDropped)",
                            "physicalRenderedFrames": "\(self.livePhysicalRenderFrames)",
                            "virtualMicRenderedFrames": "\(self.liveVirtualRenderFrames)",
                            "aiReturnCaptured": "\(self.aiReplyReceivedFrames)",
                            "aiReturnMonitorDropped": "\(self.aiReplyMonitorDropped)",
                            "aiReturnUplinkUnderflow": "\(self.aiReplyUplinkUnderflow)",
                            "aiReturnPeakRMS": String(format: "%.5f", self.aiReplyPeakRMS),
                            "handshakeAttempts": "\(self.liveVoiceHandshakeAttempts)"])
                    // Release media after the PCM stream/queues are torn
                    // down, avoiding reentrant WebKit microphone callbacks
                    // that would try to stop an already-closing audio stream.
                    if closeAutoVoice {
                        self.endAutoAnsweredVoiceBrowser(
                            reason: "AUTO_CALL_PCM_REMOTE_CLOSED")
                        self.autoCallStatus =
                            "手机通话音频已断开，已停止 GPT Voice 并关闭自动浏览器"
                    }
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

    /// The caller-to-GPT signal is never muted by this setting. It controls
    /// only whether the Mac's physical speaker plays the caller in parallel
    /// with ChatGPT's reply, which could sound like delayed echo.
    func setAllowCallerMonitorDuringAI(_ enabled: Bool) {
        allowCallerMonitorDuringAI = enabled
        UserDefaults.standard.set(enabled, forKey: "SIMAI_MIX_CALLER_AND_GPT_LOCAL")
        voiceStream?.setCallerMonitorEnabled(enabled || !aiReplyMonitorEnabled)
        log(.info, .audio, "已调整 Mac 本地双路监听",
            details: ["localCallerMonitor": enabled ? "ON" : "OFF_WHILE_AI"])
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
                voiceStream.setCallerMonitorEnabled(allowCallerMonitorDuringAI)
                aiReplyReturnStatus = allowCallerMonitorDuringAI
                    ? "正在同时监听电话与 GPT，若听到回音可关闭双路监听"
                    : "本地防回音：只监听 GPT 回复；电话对方仍正常送入 GPT"
                log(.info, .audio, "用户主动开启独立 GPT 回复监听",
                    details: ["route": "BLACKHOLE16_TO_PHYSICAL", "phoneForward": "off",
                              "callerMonitor": allowCallerMonitorDuringAI ? "ON" : "OFF"])
            } catch {
                aiReplyMonitorEnabled = false
                aiReplyToPhoneEnabled = false
                voiceStream.setCallerMonitorEnabled(true)
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
            voiceStream.setCallerMonitorEnabled(true)
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

    /// Require same Android ring before acknowledging a private-file request.
    private func recordPrivateAutomaticAnswer(expectedSession: String, expectedSequence: Int) -> Bool {
        guard bridgeCursor.session == expectedSession,
              autoStartedWebVoiceForRing || incomingVoicePending || voiceSessionPrepared,
              (livePhoneState == "RINGING" && bridgeCursor.lastSequence == expectedSequence) ||
              (livePhoneState == "OFFHOOK" && bridgeCursor.lastSequence == expectedSequence + 1)
              else { return false }
        automaticAnswerRequested = true
        automaticAnswerAcknowledged = true
        automaticAnswerSession = expectedSession
        autoVoiceCaptureObserved = autoVoiceCaptureObserved || embeddedVoiceCaptureActive
        answerCallStatus = "Android 已通过独立私有通道请求接听；正在确认 OFFHOOK"
        log(.info, .call, "Android 独立私有通道接听请求成功",
            details: ["result": "ANSWER_FALLBACK_REQUESTED"])
        if livePhoneState == "OFFHOOK" {
            automaticOffhookSequence = bridgeCursor.lastSequence
            reactToAutomaticCallState("OFFHOOK")
        }
        return true
    }

    /// User-authorized phone-answer request (manually or automatically). The Android
    /// Companion re-checks its own call state, refuses all non-ringing calls,
    /// and requires separate ANSWER_PHONE_CALLS permission.
    func answerIncomingPhoneCall(automatic: Bool = false) {
        guard !answerCallBusy && !adbInstalling, livePhoneState == "RINGING",
              !bridgeCursor.session.isEmpty, bridgeCursor.lastSequence > 0 else { return }
        if automatic {
            automaticAnswerRequested = true
            automaticAnswerAcknowledged = false
            // Preserve the ring's session ownership through HTTP failure,
            // so a later IDLE always closes Voice and releases the mic.
            automaticAnswerSession = ""
            automaticOffhookSequence = 0
            autoVoiceCaptureObserved = embeddedVoiceCaptureActive
            autoHangupAttempted = false
        }
        answerCallBusy = true
        answerCallStatus = "正在使用已授权电话桥接请求接听……"
        let expectedRingSession = bridgeCursor.session
        let expectedRingSequence = bridgeCursor.lastSequence
        let existingLink = bridgeLink
        let path = selectedADBPath
        Task { [weak self] in
            guard let self else { return }
            // On the new Companion or when status uses ADB_FILE (e.g. during vivo ringing),
            // use the local guarded shell answer directly to avoid a 3s+ HTTP timeout.
            if automatic, self.bridgeUsingFileFallback,
               let existingLink {
                self.log(.info, .call, "HTTP 状态不稳定，优先使用本地受控 Shell 接听",
                         details: ["diagnosis": "ANSWER_ORDERED_BROADCAST_FIRST"])
                let result = await Task.detached(priority: .userInitiated) {
                    ADBInspector.answerRingingViaPrivateLocalShell(
                        at: path, expectedSession: expectedRingSession,
                        expectedSequence: expectedRingSequence, expectedSerial: existingLink.serial)
                }.value
                self.log(.info, .call, "手机端广播接听回执", details: ["result": result])
                if result == "ANSWER_FALLBACK_REQUESTED" {
                    _ = self.recordPrivateAutomaticAnswer(expectedSession: expectedRingSession,
                        expectedSequence: expectedRingSequence)
                    self.answerCallBusy = false
                    return
                }
                if ["ANSWER_FALLBACK_PERMISSION_REQUIRED", "ANSWER_FALLBACK_RING_CHANGED",
                    "ANSWER_FALLBACK_WORKER_INACTIVE", "ANSWER_FALLBACK_IN_PROGRESS"].contains(result) {
                    self.automaticAnswerRequested = result == "ANSWER_FALLBACK_IN_PROGRESS"
                    self.answerCallBusy = false
                    self.answerCallStatus = "手机接听状态：" + result
                    return
                }
            }
            // Regression correction from the verified v0.4.21 path: never
            // reuse a potentially stale/blocked polling TCP forward to answer
            // a cellular call. Create a distinct authenticated ADB forward.
            let dedicated = await Task.detached(priority: .userInitiated) {
                ADBInspector.openBridge(at: path)
            }.value.link
            let temporaryLink = dedicated
            guard let link = dedicated ?? existingLink else {
                if automatic { self.automaticAnswerRequested = false }
                self.answerCallBusy = false
                self.answerCallStatus = "无法连接手机电话监听服务；请确认 Companion 已启动且只有一台已授权手机"
                self.log(.warn, .system, "手动接听未建立手机桥接",
                         details: ["reason": "MANUAL_ANSWER_BRIDGE_UNAVAILABLE"])
                return
            }
            self.log(.info, .call, "已选择接听专用 ADB 转发通道",
                     details: ["diagnosis": dedicated == nil
                        ? "ANSWER_SHARED_BRIDGE_ONLY" : "ANSWER_DEDICATED_BRIDGE"])
            defer {
                // Shared status polling keeps its separate forward. This
                // temporary answer-only forward is always removed after use.
                if let disposable = temporaryLink {
                    Task.detached(priority: .utility) {
                        ADBInspector.closeBridge(at: path, link: disposable)
                    }
                }
                self.answerCallBusy = false
            }
            guard let url = URL(string: "http://127.0.0.1:\(link.localPort)/call/answer") else {
                self.answerCallStatus = "本地接听请求地址无效"
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(link.token, forHTTPHeaderField: "X-SIMAI-Token")
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            request.setValue(expectedRingSession, forHTTPHeaderField: "X-SIMAI-Expected-Session")
            request.setValue(String(expectedRingSequence), forHTTPHeaderField: "X-SIMAI-Expected-Sequence")
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            config.timeoutIntervalForRequest = 3
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            // Restore the successfully tested v0.4.21 order:
            // 1. a fresh authenticated ADB HTTP answer request;
            // 2. independent guarded Android fallback only if the fresh
            // transport fails and the same ring is still active.
            // A file fallback can consume an entire ringtone window while
            // emitting NO_ACK; never run it *before* this HTTP call.
            self.log(.info, .call, "尝试已验证的 HTTP 直接接听路径",
                     details: ["diagnosis": "ANSWER_HTTP_FIRST"])
            do {
                let (body, response) = try await session.data(for: request)
                let http = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Only these fixed status codes are interpreted. Never log
                // raw server responses, phone identifiers, or bearer tokens.
                let parsed = (try? JSONSerialization.jsonObject(with: body))
                    as? [String: Any]
                if http == 200 && parsed?["result"] as? String == "answer_requested" {
                    if automatic && self.bridgeCursor.session == expectedRingSession &&
                       ((self.livePhoneState == "RINGING" && self.bridgeCursor.lastSequence == expectedRingSequence) ||
                        (self.livePhoneState == "OFFHOOK" && self.bridgeCursor.lastSequence == expectedRingSequence + 1)) {
                        self.automaticAnswerAcknowledged = true
                        self.automaticAnswerSession = self.bridgeCursor.session
                        self.autoVoiceCaptureObserved =
                            self.autoVoiceCaptureObserved || self.embeddedVoiceCaptureActive
                        if self.livePhoneState == "OFFHOOK" {
                            self.automaticOffhookSequence = self.bridgeCursor.lastSequence
                            if !self.embeddedVoiceCaptureActive &&
                               self.autoVoiceCaptureObserved &&
                               self.embeddedVoiceBrowser.voiceSessionActuallyEnded {
                                self.scheduleAutomaticHangupAfterVoiceEnds()
                            }
                        }
                    }
                    self.answerCallStatus = "已向 Android 发出接听请求；请确认手机状态转为 OFFHOOK，再启动 GPT 音频"
                    self.log(.info, .system, "用户主动请求接听当前响铃电话",
                             details: ["result": "ANSWER_REQUESTED"])
                } else {
                    if automatic { self.automaticAnswerRequested = http == 202 }
                    switch http {
                    case 202:
                        self.answerCallStatus = "手机端接听 API 仍在执行，等待 OFFHOOK，不重复接听"
                    case 403:
                        self.answerCallStatus = "手机拒绝接听：请在 Companion 授权「接听电话」"
                    case 404:
                        self.answerCallStatus = "手机 Companion 不支持电话接听接口，请通过一键更新安装内置最新版"
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
                // The direct fresh-forward HTTP command failed. Only now try
                // a single session/sequence-guarded Android-local fallback.
                // Never send arbitrary headset keys or answer another ring.
                if automatic && !expectedRingSession.isEmpty &&
                   expectedRingSequence > 0 {
                    let result = await Task.detached(priority: .userInitiated) {
                        ADBInspector.answerRingingViaPrivateLocalShell(
                            at: path, expectedSession: expectedRingSession,
                            expectedSequence: expectedRingSequence,
                            expectedSerial: link.serial)
                    }.value
                    if result == "ANSWER_FALLBACK_REQUESTED" &&
                       self.recordPrivateAutomaticAnswer(expectedSession: expectedRingSession, expectedSequence: expectedRingSequence) {
                        return
                    }
                    self.automaticAnswerRequested = false
                    self.answerCallStatus = result == "ANSWER_FALLBACK_PERMISSION_REQUIRED"
                        ? "Android 未授予接听电话权限；请在手机 Companion 中允许电话权限"
                        : result == "ANSWER_FALLBACK_WORKER_INACTIVE"
                            ? "Android 私有接听服务未运行；需要恢复手机端监听服务"
                            : result == "ANSWER_FALLBACK_RING_CHANGED"
                                ? "这通来电已结束或改变，安全取消迟到的接听命令"
                                : "接听转发失败，Android 本机路径也未确认；本次未自动接听"
                    self.log(.warn, .call, "电话接听双路径失败",
                             details: ["reason": "MANUAL_ANSWER_TIMEOUT",
                                       "fallback": result,
                                       "httpErrorDomain": (error as NSError).domain,
                                       "httpErrorCode": "\((error as NSError).code)",
                                       "transport": self.bridgeUsingFileFallback ? "ADB_FILE" : "ADB_HTTP"])
                } else {
                    if automatic { self.automaticAnswerRequested = false }
                    self.answerCallStatus =
                        "手机接听接口超时或连接中断；请核对手机当前状态"
                    self.log(.warn, .system, "人工接听请求网络失败",
                             details: ["reason": "MANUAL_ANSWER_TIMEOUT"])
                }
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


    /// Embedded APK metadata is generated from Android build.gradle.kts
    /// during packaging and validated against the actual APK in CI.
    var embeddedAPKVersionLabel: String {
        guard let path = Bundle.main.resourceURL?
                .appendingPathComponent("SIMAI-Companion-version.txt"),
              let text = try? String(contentsOf: path, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return "版本未知（安装包未带版本元数据）" }
        return text
    }

    @Published var installedCompanionVersion = "尚未查询"

    func inspectInstalledCompanionVersion() {
        let adb = selectedADBPath
        Task.detached(priority: .utility) { [weak self] in
            let version = ADBInspector.installedCompanionVersion(at: adb)
            await MainActor.run {
                self?.installedCompanionVersion = version
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
        // An explicit one-click user action grants only Android phone
        // state + answer/hangup via the already authorized single ADB phone.
        // If the OEM blocks this, the Companion offers Android's own consent
        // dialog. Never request SMS or erase existing app data.
        adbInstalling = true
        apkInstallStatus = "正在安装内置最新版并配置电话状态＋接听／挂断权限；如 vivo 要求系统确认，请在手机上确认……"
        let adb = selectedADBPath
        log(.info, .system, "用户确认开始安装或覆盖 Android 伴侣 APK",
            details: ["bundleVersion": embeddedAPKVersionLabel,
                      "scope": "PHONE_STATUS_AND_ANSWER_HANGUP"])
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = ADBInspector.install(at: adb, apk: resource)
            await MainActor.run {
                guard let self else { return }
                self.adbInstalling = false
                self.apkInstallStatus = outcome.status
                if outcome.succeeded { self.inspectInstalledCompanionVersion() }
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
