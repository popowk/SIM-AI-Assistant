#if os(macOS)
import SwiftUI
import AppKit
import SIMAICore

struct DashboardView: View {
    @EnvironmentObject private var model: AssistantModel

    @State private var previewExport = false
    @State private var cleanupDays = 0
    @State private var showPhoneDiagnostics = false
    @State private var confirmLogCleanup = false
    @State private var confirmAPKReset = false
    @State private var showFeishuWebhook = false
    @State private var requestedBlackHoleChannels = 16
    @State private var confirmBlackHoleDownload = false
    @State private var showAdvancedTools = false
    @State private var showFeishuSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusBar
                callControlPanel
                if !model.localReceptionEnabled { quickSetupPanel }
                adbPanel
                DisclosureGroup("飞书 Webhook 配置", isExpanded: $showFeishuSettings) {
                    feishuPanel
                        .padding(.top, 8)
                }
                .font(.subheadline)
                DisclosureGroup("诊断中心与日志导出", isExpanded: $showAdvancedTools) {
                    VStack(alignment: .leading, spacing: 14) {
                        diagnosticPanel
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
                footer
            }
            .padding(22)
        }
        .frame(minWidth: 720, minHeight: 560)
        .confirmationDialog("下载官方 BlackHole 安装包？", isPresented: $confirmBlackHoleDownload,
                            titleVisibility: .visible) {
            Button("确认下载并打开安装包（\(requestedBlackHoleChannels)ch）") {
                model.openOfficialBlackHoleInstaller(channels: requestedBlackHoleChannels)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从 Existential Audio 官方 GitHub Releases 下载 BlackHole \(requestedBlackHoleChannels)ch 安装包至 Downloads 目录并自动运行安装器。")
        }
        .confirmationDialog("确定清空旧版数据并重新安装？", isPresented: $confirmAPKReset,
                            titleVisibility: .visible) {
            Button("确认卸载并重新安装", role: .destructive) {
                model.reinstallAndroidCompanionAfterConfirmation()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("仅针对 SIM AI Companion。此操作会通过 ADB 卸载 APK（清除应用私有数据和权限）并重装。重装后请在手机上确认系统授权。")
        }
        .confirmationDialog("确认清理应用日志？", isPresented: $confirmLogCleanup, titleVisibility: .visible) {
            Button(cleanupDays == 0 ? "确认清空全部日志" : "确认清理旧日志", role: .destructive) {
                model.cleanOldLogs(days: cleanupDays)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.cleanupPreviewText)
        }
        .sheet(isPresented: $showPhoneDiagnostics) {
            VStack(alignment: .leading, spacing: 12) {
                Text("手机端诊断日志").font(.headline)
                Text(model.phoneDiagnosticsStatus).font(.caption)
                ScrollView {
                    Text(model.phoneDiagnosticsPreview).font(.caption.monospaced())
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("重新读取") { model.readPhoneDiagnostics() }.disabled(model.phoneDiagnosticsCollecting)
                    Spacer()
                    Button("关闭") { showPhoneDiagnostics = false }
                }
            }.padding(20).frame(width: 680, height: 480)
        }
        .sheet(isPresented: $previewExport) {
            ExportPreviewView()
                .environmentObject(model)
        }
        .alert("运行提示", isPresented: Binding(
            get: { model.alertText != nil },
            set: { if !$0 { model.alertText = nil } }
        )) {
            Button("确定", role: .cancel) { model.alertText = nil }
        } message: {
            Text(model.alertText ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SIM AI Assistant").font(.title2.bold())
                Text(model.localReceptionEnabled ? "AI 电话自动值守 · 本地离线接待 · v0.4.50" : "AI 电话自动值守 · 全双工音频 · v0.4.50")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.refresh()
                model.inspectADB()
            } label: {
                Label("重新自检", systemImage: "arrow.clockwise")
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            statusPill(
                title: "电话状态",
                value: model.livePhoneState,
                symbol: model.livePhoneState == "OFFHOOK" ? "phone.fill" : (model.livePhoneState == "RINGING" ? "phone.arrow.down.left.fill" : "phone"),
                tint: model.livePhoneState == "OFFHOOK" ? .green : (model.livePhoneState == "RINGING" ? .orange : .secondary)
            )
            statusPill(
                title: "传输通道",
                value: model.connectionTransport == "WIFI_DIRECT" ? "Wi-Fi 局域网直连" : (model.connectionTransport == "ADB_HTTP" ? "USB 数据线 (ADB)" : (model.connectionTransport == "ADB_FILE" ? "ADB 快照备用" : "未连接")),
                symbol: model.connectionTransport == "WIFI_DIRECT" ? "wifi" : (model.connectionTransport == "ADB_HTTP" ? "cable.connector" : "wifi.slash"),
                tint: model.connectionTransport == "WIFI_DIRECT" ? .green : (model.connectionTransport == "ADB_HTTP" ? .blue : .secondary)
            )
            if model.isShizukuReady {
                statusPill(
                    title: "特权引擎",
                    value: "Shizuku 就绪",
                    symbol: "bolt.shield.fill",
                    tint: .green
                )
            }
            statusPill(
                title: "手机连接",
                value: model.liveSyncEnabled ? (model.adbBridgeHealthChecking ? "检测中…" : model.liveBridgeStatus) : "已暂停",
                symbol: "network",
                tint: model.liveSyncEnabled ? .primary : .secondary
            )
            let have2 = model.audio.devices.contains { $0.displayName.caseInsensitiveCompare("BlackHole 2ch") == .orderedSame }
            let have16 = model.audio.devices.contains { $0.displayName.caseInsensitiveCompare("BlackHole 16ch") == .orderedSame }
            statusPill(
                title: "虚拟声卡",
                value: (have2 && have16) ? "2ch + 16ch 正常" : "声卡缺失",
                symbol: "waveform",
                tint: (have2 && have16) ? .green : .orange
            )
        }
    }

    private func statusPill(title: String, value: String, symbol: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 通话控制与自动值守
    private var callControlPanel: some View {
        panel("通话控制与自动值守", symbol: "phone.badge.waveform") {
            // 实时电话操作区
            callStateBanner

            Divider()

            // 自动值守选项
            VStack(alignment: .leading, spacing: 10) {
                Toggle("自动接听来电", isOn: Binding(
                    get: { model.autoCallEnabled },
                    set: { model.setAutoCallEnabled($0) }
                ))
                Toggle("本地轻量接待（离线，不使用 GPT / BlackHole）", isOn: Binding(
                    get: { model.localReceptionEnabled },
                    set: { model.setLocalReceptionEnabled($0) }
                ))
                .disabled(model.liveVoiceActive || model.liveVoiceStarting || model.livePhoneState == "RINGING" || model.livePhoneState == "OFFHOOK")
                HStack {
                    Button(model.localModelDownloading ? "正在下载模型…" : "下载 / 校验本地模型") {
                        model.downloadLocalModel()
                    }.disabled(model.localModelDownloading || model.localReceptionPreparing || model.liveVoiceActive || model.liveVoiceStarting || model.livePhoneState == "RINGING" || model.livePhoneState == "OFFHOOK")
                    Text(model.localModelStatus).font(.caption)
                }
                Stepper(value: $model.silenceHangupSeconds, in: 0...60, step: 5) {
                    Text(model.silenceHangupSeconds == 0 ? "静默挂机：关闭" : "静默挂机：\(model.silenceHangupSeconds) 秒")
                }.disabled(model.liveVoiceActive || model.liveVoiceStarting || model.livePhoneState == "RINGING" || model.livePhoneState == "OFFHOOK")
                Text("按来电 PCM 电平判断静默（实验功能），仅自动接听的通话生效。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.localReceptionEnabled || model.localFallbackEnabled {
                    DisclosureGroup("审核本地自动播放话术") {
                        Text(model.localSpeechReview).font(.caption).textSelection(.enabled)
                        Button(model.localSpeechApproved ? "撤回全部本地话术授权" : "确认以上全部话术，允许本地自动播报") {
                            if model.localSpeechApproved { model.revokeLocalSpeechApproval() } else { model.approveLocalSpeech() }
                        }.disabled(model.liveVoiceActive || model.liveVoiceStarting || model.livePhoneState == "RINGING" || model.livePhoneState == "OFFHOOK")
                        Text(model.localSpeechApproved ? "已审核；修改话术后需重新确认" : "未审核；禁止本地接听及自动接管").font(.caption)
                    }
                }
                if !model.localReceptionEnabled {
                    DisclosureGroup("GPT 接待话术") {
                        TextEditor(text: $model.gptReceptionPrompt).frame(minHeight: 90)
                        Button("复制话术至剪贴板") { model.copyGPTReceptionPrompt() }
                        Text("本地保存；首次设置或修改后，请粘贴到官方 ChatGPT 的个性化设置或接待对话。程序不保证网页自动加载提示词。").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("GPT 失败时使用本地备用接待", isOn: Binding(
                        get: { model.localFallbackEnabled }, set: { model.setLocalFallbackEnabled($0) }))
                        .disabled(model.liveVoiceActive || model.liveVoiceStarting || model.livePhoneState == "RINGING" || model.livePhoneState == "OFFHOOK")
                    Toggle("GPT 通话使用本地录音 / 来电者转写", isOn: Binding(
                        get: { model.gptCaptureEnabled }, set: { model.setGPTCaptureEnabled($0) }))
                        .disabled(model.liveVoiceActive || model.liveVoiceStarting || model.livePhoneState == "RINGING" || model.livePhoneState == "OFFHOOK")
                    if model.localFallbackEnabled || model.gptCaptureEnabled {
                        Text(model.localReceptionStatus).font(.caption)
                        Button("准备 / 重新自检备用模型") { model.prepareLocalReception() }
                            .disabled(model.localReceptionPreparing || model.localModelDownloading || model.liveVoiceActive || model.liveVoiceStarting || model.livePhoneState == "RINGING" || model.livePhoneState == "OFFHOOK")
                    }
                    if model.localFallbackEnabled || model.gptCaptureEnabled {
                        Toggle("保存本地双向录音", isOn: $model.localRecordAudio)
                            .disabled(model.liveVoiceActive || model.liveVoiceStarting || model.livePhoneState == "RINGING" || model.livePhoneState == "OFFHOOK")
                        Toggle("挂断后推送来电者识别文字", isOn: $model.localSendTranscript)
                            .disabled(model.liveVoiceActive || model.liveVoiceStarting || model.livePhoneState == "RINGING" || model.livePhoneState == "OFFHOOK")
                        if model.callCaptureAwaitingApproval && model.liveVoiceActive {
                            Button(model.callCaptureApproved ? "撤回本次录音及推送授权" : "已告知来电者并获得同意，开始本次录音 / 转写") {
                                model.setCurrentCallCaptureApproval(!model.callCaptureApproved)
                            }
                        }
                        HStack {
                            Button("打开录音目录") { model.openLocalRecordings() }
                            Text(model.localCaptureStatus).font(.caption)
                        }
                    }
                }
                if model.localReceptionEnabled {
                    Text(model.localReceptionStatus).font(.caption)
                    TextField("本地接待开场话术", text: $model.localGreeting)
                    TextField("本地接待结束话术", text: $model.localGoodbye)
                    Text("修改后点击准备 / 重新自检并确认话术。").font(.caption).foregroundStyle(.secondary)
                    Toggle("保存本地双向录音和识别文字", isOn: $model.localRecordAudio)
                        .disabled(model.livePhoneState == "RINGING" || model.livePhoneState == "OFFHOOK" || model.liveVoiceActive || model.liveVoiceStarting)
                    Toggle("挂断后通过已配置的飞书 Webhook 推送文字", isOn: $model.localSendTranscript)
                        .disabled(model.livePhoneState == "RINGING" || model.livePhoneState == "OFFHOOK" || model.liveVoiceActive || model.liveVoiceStarting)
                    if model.callCaptureAwaitingApproval && model.liveVoiceActive {
                        Button(model.callCaptureApproved ? "撤回本次录音及推送授权" : "已获得来电者同意，开始本次保存 / 转写") {
                            model.setCurrentCallCaptureApproval(!model.callCaptureApproved)
                        }
                    }
                    HStack {
                        Button("打开录音目录") { model.openLocalRecordings() }
                        Text(model.localCaptureStatus).font(.caption)
                    }
                    Button(model.localReceptionPreparing ? "正在准备…" : "准备 / 重新自检本地模型") {
                        model.prepareLocalReception()
                    }.disabled(model.localReceptionPreparing || model.liveVoiceActive || model.liveVoiceStarting || model.livePhoneState == "RINGING" || model.livePhoneState == "OFFHOOK")
                    Text("中文 Zipformer INT8 + 固定业务逻辑 + 系统中文语音。半双工，播报结束后再说话。未开启保存/推送时，识别文字仅保留在内存中。测试前请确保对方知情同意。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.localReceptionText.isEmpty {
                        Text("本次通话识别（仅本机）").font(.caption.bold())
                        Text(model.localReceptionText.joined(separator: "\n"))
                            .font(.caption).textSelection(.enabled)
                    }
                } else {
                Toggle("自动调度 GPT 麦克风与系统音频路由", isOn: Binding(
                    get: { model.automaticGPTOutputEnabled },
                    set: { model.setAutomaticGPTOutputEnabled($0) }
                ))
                Toggle("使用内嵌 ChatGPT Voice（推荐：自动启动与唤醒）", isOn: Binding(
                    get: { model.useEmbeddedVoiceBrowser },
                    set: { model.setEmbeddedVoiceBrowserEnabled($0) }
                ))
                if model.useEmbeddedVoiceBrowser {
                    HStack(spacing: 16) {
                        Toggle("网页麦克风：始终允许", isOn: Binding(
                            get: { model.embeddedVoiceBrowser.alwaysAllowOfficialMicrophone },
                            set: { model.embeddedVoiceBrowser.setAlwaysAllowOfficialMicrophone($0) }
                        ))
                        Toggle("视频兼容：仅隔离 ChatGPT 声音", isOn: Binding(
                            get: { model.isolatedChatGPTOutputEnabled },
                            set: { model.setIsolatedChatGPTOutputEnabled($0) }
                        ))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                }
                }
            }

            Divider()

            // 快捷控制按钮组
            if !model.localReceptionEnabled {
            HStack(spacing: 12) {
                Button {
                    model.setEmbeddedVoiceBrowserEnabled(true)
                    model.showEmbeddedVoiceWindow(activate: true)
                } label: {
                    Label("打开 ChatGPT Voice 窗口", systemImage: "macwindow")
                }
                .buttonStyle(.borderedProminent)

                if model.useEmbeddedVoiceBrowser {
                    Button("测试启动 Voice") { model.tryStartEmbeddedVoice() }
                        .buttonStyle(.bordered)
                }

                Button("恢复 Mac 原声音输出") {
                    model.restoreAutomaticGPTOutput(forceInput: true, userRequested: true)
                }
                .buttonStyle(.bordered)

                if model.voiceSessionPrepared || model.aiReplyToPhoneEnabled {
                    Button("停止值守会话") {
                        model.setVoiceSessionPrepared(false)
                        model.stopGPTTwoWayPhoneBridge()
                    }
                    .buttonStyle(.bordered)
                }
            }

            } else if model.liveVoiceActive || model.liveVoiceStarting {
                Button("停止本地接待（不自动挂断）") { model.stopLiveVoice() }
                    .buttonStyle(.bordered)
            }

            // 状态详情
            HStack {
                Text(model.autoCallStatus)
                    .font(.caption.weight(.medium))
                Spacer()
                if model.liveVoiceActive {
                    Text("通话中 · 下行: \(model.liveVoiceRxFrames) 帧 · 上行: \(model.liveVoiceTxFrames) 帧")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var callStateBanner: some View {
        if model.livePhoneState == "OFFHOOK" {
            HStack {
                Label("正在通话中 (OFFHOOK)", systemImage: "phone.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer()
                if model.liveVoiceActive {
                    Button("停止音频中转") {
                        model.stopGPTTwoWayPhoneBridge()
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) {
                    model.hangupCurrentCall()
                } label: {
                    Label("挂断电话", systemImage: "phone.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(12)
            .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        } else if model.livePhoneState == "RINGING" {
            HStack {
                Label("来电响铃中……", systemImage: "phone.arrow.down.left.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                Button {
                    model.answerIncomingPhoneCall()
                } label: {
                    Label("接听电话", systemImage: "phone.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button(role: .destructive) {
                    model.hangupCurrentCall()
                } label: {
                    Label("挂断 / 拒接", systemImage: "phone.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        } else {
            HStack {
                Label("待机就绪 (IDLE)", systemImage: "phone.badge.checkmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("有来电时将按设定自动接听并接通 ChatGPT Voice")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - 设备与基础配置
    private var quickSetupPanel: some View {
        panel("音频设备与基础配置", symbol: "speaker.wave.2") {
            let have2 = model.audio.devices.contains { $0.displayName.caseInsensitiveCompare("BlackHole 2ch") == .orderedSame }
            let have16 = model.audio.devices.contains { $0.displayName.caseInsensitiveCompare("BlackHole 16ch") == .orderedSame }

            HStack(spacing: 24) {
                Label("虚拟麦克风 2ch：\(have2 ? "正常" : "缺失")",
                      systemImage: have2 ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(have2 ? .green : .orange)
                Label("虚拟扬声器 16ch：\(have16 ? "正常" : "缺失")",
                      systemImage: have16 ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(have16 ? .green : .orange)
                Spacer()
                if !have2 {
                    Button("安装 2ch") {
                        requestedBlackHoleChannels = 2
                        confirmBlackHoleDownload = true
                    }
                    .buttonStyle(.bordered)
                }
                if !have16 {
                    Button("安装 16ch") {
                        requestedBlackHoleChannels = 16
                        confirmBlackHoleDownload = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .font(.caption)

            Picker("Mac 监听耳机 / 扬声器", selection: $model.selectedVoiceMonitorOutputID) {
                Text("请选择真实耳机或扬声器").tag("")
                ForEach(model.audio.devices.filter {
                    !$0.displayName.localizedCaseInsensitiveContains("BlackHole") &&
                    !$0.displayName.localizedCaseInsensitiveContains("aggregate") &&
                    !$0.displayName.localizedCaseInsensitiveContains("multi-output")
                }, id: \.id) { device in
                    Text(device.displayName).tag(device.id)
                }
            }
            .disabled(model.aiReplyMonitorEnabled)

            HStack(spacing: 12) {
                Button("刷新设备与连接") {
                    model.refresh()
                    model.inspectADB()
                }
                .disabled(model.adbChecking)

                Button("安装 / 更新 Companion APK") {
                    model.installAndroidCompanion()
                }
                .disabled(model.adbInstalling || !model.embeddedAPKAvailable)

                Button("打开手机权限设置") {
                    model.openPhonePermissionSettings()
                }

                Button("麦克风电平测试") {
                    model.runMicrophoneTest()
                }
                .disabled(model.isAudioTestRunning)
            }
            .buttonStyle(.bordered)

            Text("手机端：\(model.liveBridgeStatus) · 伴侣版本：\(model.embeddedAPKVersionLabel)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 飞书短信配置
    private var feishuPanel: some View {
        panel("飞书 Webhook · 短信自动转发", symbol: "message.badge") {
            HStack {
                if showFeishuWebhook {
                    TextField("https://open.feishu.cn/open-apis/bot/v2/hook/…",
                              text: $model.feishuWebhookDraft)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("粘贴飞书自定义机器人 Webhook 地址",
                                text: $model.feishuWebhookDraft)
                        .textFieldStyle(.roundedBorder)
                }
                Button(showFeishuWebhook ? "隐藏" : "显示") {
                    showFeishuWebhook.toggle()
                }
                .buttonStyle(.borderless)
            }

            SecureField("飞书机器人签名密钥（可选，未设置加签留空）",
                        text: $model.feishuSigningSecretDraft)
                .textFieldStyle(.roundedBorder)

            Toggle("自动转发手机新短信（含验证码）", isOn: $model.feishuForwardEnabled)

            HStack {
                Button("保存到 Mac 并同步手机") { model.saveFeishuSettings() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.feishuSyncBusy)
                Button("重新同步") { model.syncFeishuSettings() }
                    .disabled(!model.feishuSavedOnMac || model.feishuSyncBusy)
                    .buttonStyle(.bordered)
            }

            if model.feishuSyncBusy {
                ProgressView("正在通过 ADB 同步设置……").controlSize(.small)
            }
            Text(model.feishuSyncStatus)
                .font(.caption.weight(.medium))
        }
    }

    // MARK: - 手机连接与高级维护 (Wi-Fi 局域网直连 + ADB)
    private var adbPanel: some View {
        panel("Android · 手机连接与维护", symbol: "network") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("电话连接方式", selection: Binding(get: { model.useShizukuWiFi }, set: { model.selectPhoneTransport($0) })) {
                    Text("USB ADB").tag(false)
                    Text("Shizuku Wi-Fi").tag(true)
                }.pickerStyle(.segmented)
                    .disabled(model.liveVoiceActive || model.liveVoiceStarting || model.answerCallBusy || model.livePhoneState == "RINGING" || model.livePhoneState == "OFFHOOK")
                if model.useShizukuWiFi {
                    TextField("手机局域网 IPv4 地址", text: $model.wifiHost)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.liveVoiceActive || model.liveVoiceStarting || model.livePhoneState == "RINGING" || model.livePhoneState == "OFFHOOK")
                    SecureField("Companion 安全 Wi-Fi 配对码", text: $model.wifiPairingDraft)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("保存配对") { model.saveWiFiPairing() }
                        Button("测试安全连接") { model.testWiFiConnection() }.disabled(model.wifiPingTesting)
                        Button("清除配对") { model.clearWiFiPairing() }
                    }
                    Text(model.wifiPairStatus).font(.caption)
                    Text(model.shizukuAudioReady ? "Shizuku 音频已就绪" : "Shizuku 音频尚未就绪")
                        .foregroundStyle(model.shizukuAudioReady ? .green : .secondary)
                        .font(.caption)
                    if !model.wifiPingStatus.isEmpty { Text(model.wifiPingStatus).font(.caption) }
                    Text("手机端启动 Shizuku 并授权 Companion，点击「启用 Shizuku Wi-Fi / 显示配对码」。Mac 无需 ADB 配对。证书和配对码仅保存在本机钥匙串。")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("USB ADB 继续使用原有状态、接听和 PCM 音频 Helper；不依赖 Shizuku。").font(.caption)
                }
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))

            Divider()

            HStack {
                Text(model.selectedADBPath.isEmpty ? "ADB：自动搜索" : "ADB：\(model.selectedADBPath)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("重启 ADB 服务") { model.restartADB() }
                Button("选择 adb") { model.selectADB() }
                if !model.selectedADBPath.isEmpty {
                    Button("恢复自动") { model.resetADBSelection() }
                }
                Button("诊断连接层") { model.inspectBridgeHealth() }
                    .disabled(model.adbBridgeHealthChecking || model.adbInstalling)
            }
            .buttonStyle(.bordered)

            Toggle("自动识别已连接手机", isOn: Binding(
                get: { model.autoADBDetectionEnabled },
                set: { model.setAutoADBDetectionEnabled($0) }
            ))

            Text("连接健康度：ADB \(model.adbTransportHealth) · Shell \(model.adbShellHealth) · 端口 \(model.adbForwardHealth)")
                .font(.caption).foregroundStyle(.secondary)
            if !model.adbBridgeHealthDetail.isEmpty {
                Text(model.adbBridgeHealthDetail)
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("重新安装 Companion APK") {
                    confirmAPKReset = true
                }
                .buttonStyle(.bordered)
                .disabled(model.adbInstalling || !model.embeddedAPKAvailable)

                Button(model.shizukuLaunching ? "正在启动 Shizuku…" : "启动手机 Shizuku 特权") {
                    model.launchShizukuOnPhone()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.shizukuLaunching)

                Spacer()
                if !model.shizukuStatusMessage.isEmpty {
                    Text(model.shizukuStatusMessage)
                        .font(.caption)
                } else {
                    Text(model.apkInstallStatus)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 诊断中心
    private var diagnosticPanel: some View {
        panel("诊断中心与日志", symbol: "waveform.path.ecg.rectangle") {
            HStack {
                Text("本地 JSONL 格式 · 仅保存在本地")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("查看日志目录") { model.openLogFolder() }
                Button("读取手机日志") { showPhoneDiagnostics = true; model.readPhoneDiagnostics() }
                    .disabled(model.phoneDiagnosticsCollecting || model.liveVoiceActive || model.liveVoiceStarting)
                Button(model.phoneDiagnosticsCollecting ? "读取手机日志中…" : "一键导出诊断包") { previewExport = true }
                    .buttonStyle(.borderedProminent).disabled(model.phoneDiagnosticsCollecting)
            }

            Text(model.phoneDiagnosticsStatus).font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("清理范围", selection: $cleanupDays) {
                    Text("全部日志").tag(0)
                    Text("保留最近 1 天").tag(1)
                    Text("保留最近 7 天").tag(7)
                    Text("保留最近 14 天").tag(14)
                }
                .frame(width: 160)
                Button(cleanupDays == 0 ? "清空全部日志" : "清理旧日志") {
                    if model.prepareLogCleanup(days: cleanupDays) {
                        confirmLogCleanup = true
                    }
                }.disabled(model.phoneDiagnosticsCollecting)
                Text("当前会话：\(model.sessionID)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("SIM AI Assistant · 通话语音与短信桥接")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("v0.4.50 (Build 67)").font(.caption.monospaced())
        }
    }

    private func panel<Content: View>(_ title: String, symbol: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ExportPreviewView: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("脱敏诊断包预览").font(.title3.bold())
            Text("同时读取已授权手机的专用日志及电源、屏幕和休眠状态；断开时仍可导出，并注明读取失败。不包含录音、号码、短信或凭据。")
                .foregroundStyle(.secondary)
            Text("app-info.json · system-info.json · audio-devices.json · events.jsonl · errors.log · reproduce.txt · android-diagnostics.json")
                .font(.caption.monospaced()).textSelection(.enabled)
            Text("近几条日志预览").font(.subheadline.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(model.events.prefix(8)) { item in
                        Text("\(item.level.rawValue) · \(item.code ?? item.module.rawValue) · \(item.message)")
                            .font(.caption.monospaced())
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 135)
            Text("可选：补充复现步骤")
                .font(.subheadline.bold())
            TextEditor(text: $model.reproductionNotes)
                .font(.body).frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.3)))
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("确认并保存 ZIP") {
                    dismiss()
                    DispatchQueue.main.async { model.exportDiagnostics() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 600, height: 500)
    }
}
#endif
