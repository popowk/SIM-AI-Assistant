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
    @Published var liveSyncEnabled = UserDefaults.standard.object(forKey: "SIMAI_LIVE_SYNC") as? Bool ?? true
    @Published var liveBridgeStatus = "正在检查 ADB 连接"
    @Published var livePhoneState = "未连接"
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

    let version = "0.4.2"
    let buildNumber = "19"
    private let logger = Logger(subsystem: "com.simai.assistant", category: "diagnostics")
    private let logs: LogStore
    private let audioInspector = AudioInspector()
    private let microphoneProbe = MicrophoneLevelProbe()
    private var voiceStream: PhoneAudioStream?
    private var voiceSessionID = ""
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
        audio = audioInspector.inspect()
        if audio.microphonePermission == "已拒绝" {
            log(.warn, .audio, "麦克风权限被拒绝", code: .microphoneDenied)
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
        feishuSyncStatus = "正在使用已授权的 ADB 通道同步到手机……"
        let knownLink = bridgeLink
        let path = selectedADBPath
        Task { [weak self] in
            guard let self else { return }
            let link: ADBBridgeLink?
            let temporary: Bool
            if let knownLink {
                link = knownLink
                temporary = false
            } else {
                // A manual sync can establish its own authenticated forward,
                // even when automatic call-state polling is disabled.
                let attempt = await Task.detached(priority: .utility) {
                    ADBInspector.openBridge(at: path)
                }.value
                link = attempt.link
                temporary = true
            }
            guard let link else {
                self.feishuSyncBusy = false
                self.feishuSyncStatus = "Mac 已保存；同步失败：请确认唯一已授权手机、伴侣 App 电话状态监听已启动"
                self.log(.warn, .system, "飞书设置未同步：ADB 桥接暂不可用")
                return
            }
            defer {
                if temporary {
                    let disposable = link
                    Task.detached(priority: .utility) {
                        ADBInspector.closeBridge(at: path, link: disposable)
                    }
                }
                self.feishuSyncBusy = false
            }
            do {
                let payload = try JSONSerialization.data(withJSONObject: [
                    "webhook": saved.webhook,
                    "secret": saved.signingSecret,
                    "enabled": saved.enabled
                ])
                guard let url = URL(string: "http://127.0.0.1:\(link.localPort)/sms/config")
                else { throw NSError(domain: "SIMAI.Feishu", code: 2) }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = payload
                request.timeoutInterval = 8
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("application/json; charset=utf-8",
                                 forHTTPHeaderField: "Content-Type")
                request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
                request.setValue(link.token, forHTTPHeaderField: "X-SIMAI-Token")
                let session = URLSession(configuration: .ephemeral)
                defer { session.invalidateAndCancel() }
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let status = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      status["ok"] as? Bool == true,
                      status["configured"] as? Bool == true else {
                    self.feishuSyncStatus = "已保存 Mac，但手机拒绝设置：检查 Companion 是否为最新版"
                    self.log(.warn, .system, "飞书设置同步被手机拒绝（不含任何凭证）")
                    return
                }
                let permission = status["smsPermissionGranted"] as? Bool ?? false
                let enabled = status["enabled"] as? Bool ?? false
                self.feishuSyncStatus = permission
                    ? (enabled ? "已同步手机，短信权限已授权，自动转发开启"
                               : "已同步手机，短信自动转发已关闭")
                    : "已同步手机，但手机尚未授权接收短信；请在 Companion 内手动授权"
                self.log(.info, .system, "飞书短信设置已同步到已授权手机",
                         details: ["permissionGranted": "\(permission)",
                                   "forwardEnabled": "\(enabled)"])
            } catch {
                self.feishuSyncStatus = "已安全保存 Mac，手机同步未成功；请检查 ADB、手机监听服务后重试"
                self.log(.warn, .system, "飞书设置同步失败（不记录地址、密钥或请求内容）")
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
            guard let physicalID = UInt32(selectedVoiceMonitorOutputID) else {
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

    func stopLiveVoice() {
        guard liveVoiceStarting || liveVoiceActive else { return }
        liveVoiceMicrophoneEnabled = false
        chatGPTVoiceRouteEnabled = false
        aiReplyMonitorEnabled = false
        aiReplyToPhoneEnabled = false
        liveVoiceStatus = "正在停止并释放电话音频通道……"
        voiceStream?.stop()
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
            details: ["version": "0.2.1"])
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
