#if os(macOS)
import SwiftUI
import AppKit
import SIMAICore

struct DashboardView: View {
    @EnvironmentObject private var model: AssistantModel

    @State private var previewExport = false
    @State private var confirmDownlink = false
    @State private var confirmUplink = false
    @State private var confirmLiveVoice = false
    @State private var confirmLiveMic = false
    @State private var confirmManualAnswer = false
    @State private var confirmGPTTwoWay = false
    @State private var confirmChatGPTInput = false
    @State private var confirmAIReplyMonitor = false
    @State private var confirmAIReplyToPhone = false
    @State private var cleanupDays = 7
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
                phoneAnswerPanel
                quickSetupPanel
                DisclosureGroup("飞书短信配置", isExpanded: $showFeishuSettings) {
                    feishuPanel
                        .padding(.top, 8)
                }
                .font(.subheadline)
                DisclosureGroup("高级维护与诊断日志", isExpanded: $showAdvancedTools) {
                    VStack(alignment: .leading, spacing: 14) {
                        adbPanel
                        diagnosticPanel
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
                footer
            }
            .padding(22)
        }
        .frame(minWidth: 740, minHeight: 540)

        .confirmationDialog("测试通话下行音频？", isPresented: $confirmDownlink, titleVisibility: .visible) {
            Button("已取得同意，开始 2 秒下行电平测试") {
                model.runPhoneAudioProbe(.downlink)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先与同意参与测试的另一方接通真实电话，让对方持续说话。即使 Mac 状态同步暂时显示 IDLE/未连接也可测试，Android 端会再次确认正在通话。本测试只测量电话下行 PCM 峰值与 RMS，不录音、不传输语音。")
        }
        .confirmationDialog("向真实电话发送低音量测试音？", isPresented: $confirmUplink, titleVisibility: .visible) {
            Button("双方已同意，发送约 1 秒测试音") {
                model.runPhoneAudioProbe(.uplink)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("必须是双方同意的测试电话，先接通并确认对方知晓即将听到两声测试音。即使 Mac 电话状态暂时未同步，Android 端仍会核实通话已接通；否则拒绝发送测试音。成功写入不代表对方一定听见。")
        }
        .confirmationDialog("开始真实电话双向音频桥接？", isPresented: $confirmLiveVoice,
                            titleVisibility: .visible) {
            Button("双方已同意，开始实时预览（最多 3 分钟）") { model.startLiveVoice() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("先接通已同意参与测试的运营商电话，并告知对方语音将通过 Mac 参与。接通后点击开始。Mac 将实时播放对方声音；麦克风默认静音，需要再次手动开启。通话 PCM 仅在内存中转发，不保存录音。建议佩戴耳机，避免回声。")
        }
        .confirmationDialog("确认人工接听当前真实来电？",
                            isPresented: $confirmManualAnswer,
                            titleVisibility: .visible) {
            Button("确认，接听当前响铃电话") { model.answerIncomingPhoneCall() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作仅在手机实际响铃且 Android 已授权接听电话时发出一次接听请求。并不会自动启动 GPT Voice、录音、自动转接或向对方播放 AI 声音。请确保后续通话中对方知情同意。")
        }
        .confirmationDialog("将 GPT 语音实时转发到真实电话？",
                            isPresented: $confirmGPTTwoWay,
                            titleVisibility: .visible) {
            Button("双方已知情同意，开启 GPT 双向语音") {
                model.enableGPTTwoWayPhoneBridge()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请确保你已在官方 ChatGPT Voice 中手动开始语音会话：输入 BlackHole 2ch、输出 BlackHole 16ch，且电话双方均同意让 AI 参与。确认后会把电话对方声音传给 ChatGPT，再把 BlackHole 16ch 的全部声音送回电话，并自动静音 Mac 麦克风。若 16ch 是系统输出，其他应用或通知声音也可能被送到电话；请先关闭通知。可随时立即停止。")
        }
        .confirmationDialog("开启 Mac 麦克风向电话传输声音？", isPresented: $confirmLiveMic,
                            titleVisibility: .visible) {
            Button("双方已同意，开启 Mac 麦克风") { model.setLiveVoiceMicrophone(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("开启后，Mac 当前默认麦克风采集的声音会经 ADB 送入这通运营商电话。请佩戴耳机防止回声。随时可关闭麦克风或停止整条音频通道，不会保存原始语音。")
        }
        .confirmationDialog("将真实电话声音送入 ChatGPT Voice？",
                            isPresented: $confirmChatGPTInput, titleVisibility: .visible) {
            Button("对方已知情同意，开启单向虚拟麦克风") {
                model.setChatGPTVoiceRoute(true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("电话下行将经 BlackHole 2ch 送入你自行开启的 ChatGPT Voice。ChatGPT 会处理收到的语音，请先获得通话另一方明确同意。AI 回复仍只在 Mac 播放，不会自动送回手机；SIM AI Assistant 不存储原始音频。随时可关闭路由或停止电话连接。")
        }
        .confirmationDialog("开启 GPT 回复音频监听？",
                            isPresented: $confirmAIReplyMonitor, titleVisibility: .visible) {
            Button("确认监听（仅耳机，不发送给电话）") { model.setAIReplyMonitor(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先将 ChatGPT 的输出设置为 BlackHole 16ch，并在 SIM AI Assistant 中选择真实耳机/扬声器。此操作仅将 BlackHole 16ch 的音频实时播放到选定耳机，默认不发送到电话。若系统输出也使用 BlackHole 16ch，其它应用声音也可能进入此通道，请静音其它应用。")
        }
        .confirmationDialog("将 GPT 回复声音发送给真实电话对方？",
                            isPresented: $confirmAIReplyToPhone, titleVisibility: .visible) {
            Button("通话双方已同意，开启 AI 回复回传") { model.setAIReplyToPhone(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会把 BlackHole 16ch 中播放的声音发送到运营商电话，并自动关闭 Mac 麦克风。请确认对方明确知道语音由 AI 生成、已同意接收，而且 BlackHole 16ch 只有 ChatGPT 输出。若它是系统默认输出，通知音或其他应用声音也可能被发送。可随时点击立即关闭回传。")
        }
        .confirmationDialog("确认清理本应用日志？", isPresented: $confirmLogCleanup,
                            titleVisibility: .visible) {
            Button(cleanupDays == 0 ? "清空全部日志" : "删除旧日志", role: .destructive) { model.cleanOldLogs(days: cleanupDays) }
            Button("取消", role: .cancel) { }
        } message: {
            Text(model.cleanupPreviewText + "\n操作不可撤销，仅影响 SIM AI Assistant 的历史 JSONL 日志，不清除系统 OSLog。")
        }
        .confirmationDialog("获取 BlackHole 官方虚拟音频驱动？",
                            isPresented: $confirmBlackHoleDownload,
                            titleVisibility: .visible) {
            Button("从官网下载并打开 macOS 安装器") {
                model.openOfficialBlackHoleInstaller(channels: requestedBlackHoleChannels)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从 Existential Audio 官网直接获取 BlackHole \(requestedBlackHoleChannels)ch 0.7.1 安装包，检查固定 SHA-256。该第三方驱动不随 SIM AI Assistant 分发。下载并校验完成后会打开 macOS 系统安装器；需要你在系统中批准安装，可能需要管理员密码和重启电脑。不使用 Homebrew，也不静默安装驱动。")
        }
        .confirmationDialog("要删除旧版 Android 伴侣 App 的全部数据并重装吗？",
                            isPresented: $confirmAPKReset, titleVisibility: .visible) {
            Button("清空旧版伴侣数据并重装", role: .destructive) {
                model.reinstallAndroidCompanionAfterConfirmation()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("仅针对 SIM AI Companion。此操作会通过 ADB 卸载 APK（清除应用私有数据和权限）并重装；如已安装 scrcpy，会在 Mac 弹出手机窗口供你手动确认系统提示。仅在签名不一致时使用。")
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
                Text("自动接听 · 内嵌 GPT Voice · V0.4.23")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refresh() } label: { Label("重新自检", systemImage: "arrow.clockwise") }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            statusPill(title: "电话状态", value: model.livePhoneState, symbol: "phone.arrow.down.left")
            statusPill(title: "手机连接", value: model.liveSyncEnabled ? "ADB 自动同步" : "已暂停",
                       symbol: "network")
            statusPill(title: "GPT 虚拟设备",
                       value: model.audio.devices.contains(where: {
                           $0.displayName.caseInsensitiveCompare("BlackHole 2ch") == .orderedSame
                       }) && model.audio.devices.contains(where: {
                           $0.displayName.caseInsensitiveCompare("BlackHole 16ch") == .orderedSame
                       }) ? "2ch + 16ch 已安装" : "需要安装虚拟声卡",
                       symbol: "waveform")
        }
    }

    private func statusPill(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private var adbPanel: some View {
        panel("Android · ADB / APK 管理", symbol: "cable.connector") {
            Text(model.selectedADBPath.isEmpty ? "ADB 路径：自动搜索" : "ADB 路径：\(model.selectedADBPath)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            HStack {
                Button("手动选择 adb") { model.selectADB() }
                Button("恢复自动检测") { model.resetADBSelection() }
                    .disabled(model.selectedADBPath.isEmpty)
            }
            .buttonStyle(.bordered)
            Toggle("自动识别 ADB 和已授权手机", isOn: Binding(
                get: { model.autoADBDetectionEnabled },
                set: { model.setAutoADBDetectionEnabled($0) }
            ))
            HStack {
                Button("立即检测 ADB") { model.inspectADB() }
                    .disabled(model.adbChecking || model.adbInstalling)
                Button("官方 Platform-Tools") {
                    if let url = URL(string: "https://developer.android.com/tools/releases/platform-tools") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Text(model.adbStatus).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("ADB 来源：\(model.adbDiscoveryDescription)")
                if let checked = model.lastADBScanAt {
                    Text("最近检测：\(checked.formatted(date: .omitted, time: .standard))")
                }
                if model.adbChecking { ProgressView().controlSize(.mini) }
            }
            .font(.caption).foregroundStyle(.secondary)
            Text("自动识别默认开启：手机接入 USB、恢复已授权无线 ADB 或 Mac 唤醒后，会自动检测并尝试恢复来电状态；有多台设备时不会猜测选择。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("手机屏幕操作 · 在 Mac 上点安装/权限提示")
                .font(.headline)
            HStack {
                Button {
                    model.openPhoneScreenControl()
                } label: {
                    Label(model.screenControlStarting ? "正在连接屏幕…" : "打开手机屏幕控制",
                          systemImage: "iphone.gen3.radiowaves.left.and.right")
                }
                .disabled(model.screenControlStarting || model.screenControlRunning)
                Button("关闭屏幕控制") { model.closePhoneScreenControl() }
                    .disabled(!model.screenControlRunning)
                Button("打开手机权限设置") { model.openPhonePermissionSettings() }
                    .disabled(model.screenControlStarting)
                if model.screenControlStarting { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.bordered)
            Text(model.screenControlStatus)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("复制 scrcpy 安装命令") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install scrcpy", forType: .string)
                }
                Button("scrcpy 官方安装指南") {
                    if let url = URL(string: "https://github.com/Genymobile/scrcpy/blob/master/doc/macos.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .buttonStyle(.link)
            Text("首次 USB 调试仍由手机系统授权。点击“一键安装最新版并开启电话权限”后会申请电话状态和接听／挂断两项权限；系统仍可能要求你在 vivo 上确认。短信权限和飞书配置分别管理。")
                .font(.caption).foregroundStyle(.orange)
            Divider()
            Text("内置 APK：\(model.embeddedAPKAvailable ? "SIM AI Companion " + model.embeddedAPKVersionLabel : "当前构建未包含")")
                .font(.caption)
            Text(model.embeddedAPKSigningStatus)
                .font(.caption)
                .foregroundStyle(.orange)
            Button {
                model.installAndroidCompanion()
            } label: {
                Label(model.adbInstalling ? "正在安装和授权…" : "一键安装最新版并开启电话权限",
                      systemImage: "square.and.arrow.down")
            }
            .disabled(model.adbInstalling || !model.embeddedAPKAvailable)
            .buttonStyle(.borderedProminent)
            Text("此操作仅用于唯一已授权的手机：安装／覆盖内置 APK，并通过你授权的 ADB 尝试配置电话状态读取、接听和挂断权限。不申请短信权限，不卸载旧版；若 vivo 阻止自动授权，仍以系统弹窗为准。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("手机端版本：\(model.installedCompanionVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                Button("查询手机版本") { model.inspectInstalledCompanionVersion() }
                    .font(.caption)
            }
            Text(model.apkInstallStatus).font(.caption).foregroundStyle(.secondary)
            Button("签名不一致？确认清空后自动重装并初始化") { confirmAPKReset = true }
                .disabled(model.adbInstalling || !model.embeddedAPKAvailable)
                .font(.caption)
                .foregroundStyle(.orange)
            Divider()
            Toggle("来电状态自动连接、断线重试与锁屏备用同步", isOn: Binding(
                get: { model.liveSyncEnabled },
                set: { model.setLiveSyncEnabled($0) }
            ))
            HStack {
                Text("连接：\(model.liveBridgeStatus)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重新连接") { model.reconnectLiveBridge() }
                    .disabled(!model.liveSyncEnabled)
            }
            if let lastSync = model.liveBridgeLastSync {
                Text("最近成功同步：\(lastSync.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("诊断连接层（锁屏时也能检测）") { model.inspectBridgeHealth() }
                    .disabled(model.adbBridgeHealthChecking || model.adbInstalling)
                if model.adbBridgeHealthChecking {
                    ProgressView().controlSize(.small)
                }
            }
            Text("ADB 授权：\(model.adbTransportHealth) · Shell：\(model.adbShellHealth) · 端口：\(model.adbForwardHealth)")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.adbBridgeHealthDetail).font(.caption).foregroundStyle(.secondary)
            Text("ADB 状态、Shell 响应与 Companion 电话事件服务分别诊断。锁屏时服务受限不等于撤销 ADB 授权；如果无线调试被系统关闭，仍需在手机上重新启用。")
                .font(.caption).foregroundStyle(.secondary)
            Text("新版 Companion 将电话状态、Mac 接听及挂断权限合并为一次开启，不再出现独立的“授权 Mac 控制接听与结束电话”按钮；系统拒绝授权时须按 Android 提示操作。")
                .font(.caption).foregroundStyle(.secondary)
            Text("实时电话状态：\(model.livePhoneState)")
                .font(.headline)
                .foregroundStyle(model.livePhoneState == "RINGING" ? .orange : .primary)
            ForEach(model.liveCallEvents.prefix(8), id: \.self) { item in
                Text(item).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text("通过已授权的 USB 或无线 ADB 读取匿名来电事件；不使用 HFP。请确保手机 APK 已启动电话监听。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var phoneAnswerPanel: some View {
        panel("AI 电话自动值守", symbol: "phone.arrow.up.right") {
            Toggle("自动接听电话", isOn: Binding(
                get: { model.autoCallEnabled },
                set: { model.setAutoCallEnabled($0) }
            ))
            Toggle("自动配置 GPT 输入及音频路由", isOn: Binding(
                get: { model.automaticGPTOutputEnabled },
                set: { model.setAutomaticGPTOutputEnabled($0) }
            ))
            Toggle("内嵌 ChatGPT Voice（网页登录后可实验性自动启动）", isOn: Binding(
                get: { model.useEmbeddedVoiceBrowser },
                set: { model.setEmbeddedVoiceBrowserEnabled($0) }
            ))
            Toggle("ChatGPT 网页麦克风：始终允许（仅官方站点）", isOn: Binding(
                get: { model.embeddedVoiceBrowser.alwaysAllowOfficialMicrophone },
                set: { model.embeddedVoiceBrowser.setAlwaysAllowOfficialMicrophone($0) }
            ))
            .font(.headline)
            Text("这是内嵌浏览器的网站权限设置：开启后网页不再反复询问麦克风，关闭后每次询问。macOS 系统隐私权限仍需单独授权。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("视频兼容：只隔离 ChatGPT 声音（不切换 Mac 总输出）", isOn: Binding(
                get: { model.isolatedChatGPTOutputEnabled },
                set: { model.setIsolatedChatGPTOutputEnabled($0) }
            ))
            .font(.headline)
            Text(model.isolatedChatGPTOutputEnabled
                ? "默认开启。视频和其他软件保持原有声音输出；ChatGPT 网页单独连接 BlackHole 16ch。只有网页确认独立输出后才自动接听，无法验证就不接听。"
                : "传统模式会修改 Mac 总输出，播放中的视频也可能进入电话通道；仅用于设备兼容性测试。")
                .font(.caption).foregroundStyle(.secondary)
            if model.isolatedChatGPTOutputEnabled {
                Label(model.embeddedVoiceBrowser.isolatedMicrophoneReady
                        ? "已验证 GPT 使用 BlackHole 2ch 采集电话声音"
                        : "GPT 虚拟麦克风尚未验证",
                      systemImage: model.embeddedVoiceBrowser.isolatedMicrophoneReady
                          ? "mic.fill" : "mic.slash")
                    .font(.caption)
                Text(model.embeddedVoiceBrowser.isolatedMicrophoneStatus)
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.livePhoneState == "OFFHOOK" && model.liveVoiceActive
                     ? model.embeddedVoiceBrowser.microphoneSignalStatus
                     : "未接通电话或 PCM 未建立，网页麦克风静音属于预期；接通后再检测实际声音")
                    .font(.caption).foregroundStyle(.secondary)
                Text("虚拟声卡真实输入：\(model.blackHoleActualInputStatus)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.embeddedVoiceBrowser.webRTPSignalStatus)
                    .font(.caption).foregroundStyle(.secondary)
                Label(model.embeddedVoiceBrowser.isolatedOutputReady
                        ? "网页独立音频已配置" : "网页独立音频待就绪",
                      systemImage: model.embeddedVoiceBrowser.isolatedOutputReady
                          ? "checkmark.shield" : "speaker.slash")
                    .font(.caption)
                Text(model.embeddedVoiceBrowser.isolatedOutputStatus)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Mac 同时监听来电者与 GPT（关闭可减少回音）", isOn: Binding(
                get: { model.allowCallerMonitorDuringAI },
                set: { model.setAllowCallerMonitorDuringAI($0) }
            ))
            Text("安全模式须同时验证 GPT 实际从 BlackHole 2ch 录音、网页回复独立输出到 BlackHole 16ch，才会自动接听。自动值守期间保留虚拟输入，通话间不反复恢复；其他应用的系统扬声器不由本程序切换。")
                .font(.caption).foregroundStyle(.secondary)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("打开内嵌 ChatGPT 登录与 Voice") {
                    model.setEmbeddedVoiceBrowserEnabled(true)
                    model.showEmbeddedVoiceWindow(activate: true)
                }
                .buttonStyle(.borderedProminent)
                if model.useEmbeddedVoiceBrowser {
                    Button("尝试启动 Voice") { model.tryStartEmbeddedVoice() }
                        .buttonStyle(.bordered)
                    Label(model.embeddedVoiceCaptureActive ? "网页麦克风正在采集" : "网页麦克风未激活",
                          systemImage: model.embeddedVoiceCaptureActive
                              ? "mic.fill" : "mic.slash")
                        .font(.caption)
                }
            }
            if model.useEmbeddedVoiceBrowser {
                Text(model.embeddedVoiceStatus)
                    .font(.caption.weight(.medium))
                Text("建议开启视频兼容隔离模式：视频保留原声卡，ChatGPT 仅通过独立 WebKit 声音元素输出到 BlackHole；网页无法提供隔离能力时不自动接听。")
                    .font(.caption).foregroundStyle(.secondary)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if !model.useEmbeddedVoiceBrowser {
                    Button(model.voiceSessionPrepared ? "Voice 会话已预备" : "确认外部 ChatGPT Voice 已启动") {
                        model.setVoiceSessionPrepared(true)
                    }
                    .disabled(model.voiceSessionPrepared || !model.autoCallEnabled)
                    .buttonStyle(.borderedProminent)
                }
                Button("停止自动值守") {
                    model.setVoiceSessionPrepared(false)
                    model.stopGPTTwoWayPhoneBridge()
                }
                .disabled(!model.voiceSessionPrepared && !model.aiReplyToPhoneEnabled)
                .buttonStyle(.bordered)
                Button("打开 ChatGPT Voice") {
                    if let url = URL(string: "https://chatgpt.com/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
            Text(model.autoCallStatus).font(.subheadline.weight(.medium))
            Text(model.automaticGPTOutputStatus)
                .font(.caption).foregroundStyle(.secondary)
            if model.liveVoiceActive {
                Text("正在通话 · \(model.liveVoiceStatus)")
                    .font(.caption.weight(.medium))
                Button("立即停止 GPT 声音回传") { model.stopGPTTwoWayPhoneBridge() }
                    .buttonStyle(.borderedProminent)
            }
            Text("电话对方 → BlackHole 2ch → GPT；GPT 回复 → BlackHole 16ch → 电话。首次登录、系统麦克风授权及网页选择独立音频设备可能需要人工。内嵌浏览器不读取登录凭证或对话内容。")
                .font(.caption).foregroundStyle(.secondary)
            Text("来电最多等待 25 秒建立 Voice；未准备好时不接听，也不会清空 ChatGPT 网页。通话结束保留登录页面，手动打开的窗口不自动隐藏。仅显式关闭内嵌模式或退出时才释放网页。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var quickSetupPanel: some View {
        panel("设备与首次配置", symbol: "checkmark.shield") {
            let have2 = model.audio.devices.contains {
                $0.displayName.caseInsensitiveCompare("BlackHole 2ch") == .orderedSame
            }
            let have16 = model.audio.devices.contains {
                $0.displayName.caseInsensitiveCompare("BlackHole 16ch") == .orderedSame
            }
            HStack {
                Label("虚拟麦克风 2ch：\(have2 ? "已安装" : "缺失")",
                      systemImage: have2 ? "checkmark.circle.fill" : "exclamationmark.circle")
                Spacer()
                Label("虚拟输出 16ch：\(have16 ? "已安装" : "缺失")",
                      systemImage: have16 ? "checkmark.circle.fill" : "exclamationmark.circle")
            }
            .font(.caption)
            if !have2 || !have16 {
                HStack {
                    if !have2 {
                        Button("安装 BlackHole 2ch") {
                            requestedBlackHoleChannels = 2
                            confirmBlackHoleDownload = true
                        }
                    }
                    if !have16 {
                        Button("安装 BlackHole 16ch") {
                            requestedBlackHoleChannels = 16
                            confirmBlackHoleDownload = true
                        }
                    }
                    if model.blackHoleInstallerBusy { ProgressView().controlSize(.small) }
                }
                .disabled(model.blackHoleInstallerBusy)
                .buttonStyle(.bordered)
                Text(model.blackHoleInstallerStatus)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("通话监听耳机／扬声器（自动恢复设备）", selection: $model.selectedVoiceMonitorOutputID) {
                Text("请选择真实输出设备").tag("")
                ForEach(model.audio.devices.filter {
                    !$0.displayName.localizedCaseInsensitiveContains("BlackHole") &&
                    !$0.displayName.localizedCaseInsensitiveContains("aggregate") &&
                    !$0.displayName.localizedCaseInsensitiveContains("multi-output")
                }, id: \.id) { device in
                    Text(device.displayName).tag(device.id)
                }
            }
            .disabled(model.aiReplyMonitorEnabled)
            HStack {
                Button("检查设备") { model.refresh(); model.inspectADB() }
                    .disabled(model.adbChecking)
                Button("一键更新手机 Companion") { model.installAndroidCompanion() }
                    .disabled(model.adbInstalling || !model.embeddedAPKAvailable)
                Button("打开手机控制") { model.openPhoneScreenControl() }
                    .disabled(model.screenControlStarting)
                Button("恢复 Mac 原声音设备") {
                    model.setVoiceSessionPrepared(false)
                    model.restoreAutomaticGPTOutput(forceInput: true, userRequested: true)
                }
            }
            .buttonStyle(.bordered)
            Text("手机：\(model.liveBridgeStatus) · 飞书：\(model.feishuSavedOnMac ? "Mac 已保存配置" : "未保存配置")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var feishuPanel: some View {
        panel("飞书 Webhook · Mac 设置与手机同步", symbol: "message.badge") {
            Text("在 Mac 填写保存后，通过唯一已授权手机的 ADB 专用同步通道下发配置，无需手机电话状态监听服务。Mac 保存于钥匙串，手机收到新短信时独立转发。")
                .font(.caption).foregroundStyle(.secondary)
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
                Button(showFeishuWebhook ? "隐藏地址" : "显示地址") {
                    showFeishuWebhook.toggle()
                }
                .buttonStyle(.bordered)
            }
            SecureField("飞书安全设置中的签名密钥（可选，留空会清除原有签名）",
                        text: $model.feishuSigningSecretDraft)
                .textFieldStyle(.roundedBorder)
            Toggle("自动转发手机新短信（默认开启；包括短信全文和验证码）",
                   isOn: $model.feishuForwardEnabled)
            HStack {
                Button("保存到 Mac 并同步手机") { model.saveFeishuSettings() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.feishuSyncBusy)
                Button("重新同步已保存配置") { model.syncFeishuSettings() }
                    .disabled(!model.feishuSavedOnMac || model.feishuSyncBusy)
                    .buttonStyle(.bordered)
            }
            if model.feishuSyncBusy {
                ProgressView("正在通过 ADB 同步飞书设置……").controlSize(.small)
            }
            Text(model.feishuSyncStatus)
                .font(.caption.weight(.medium))
            Text("重要：保存到 Mac 不等于手机配置成功。手机需安装包含飞书功能的 Companion，并单独授权 RECEIVE_SMS；电话助手的一键授权不会额外开启短信权限。")
                .font(.caption).foregroundStyle(.secondary)
            Text("完整验证码会进入所选飞书群，请只使用自己管理、成员受限的群。Webhook 与密钥不会写入诊断日志、GitHub 或 ADB 命令参数。")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var phoneAudioPanel: some View {
        panel("第一阶段 · 联通真实通话音频兼容性", symbol: "waveform.badge.mic") {
            Text("仅测试 Android 13 shell 音频能力，不录音、不中转声音、不启用 GPT 或自动接听。")
                .font(.caption).foregroundStyle(.secondary)
            Text("音频 Helper：\(model.embeddedAudioProbeAvailable ? "已内置" : "未内置")")
                .font(.caption)
            HStack {
                Button("1 · 检测音频接口") { model.runPhoneAudioProbe(.info) }
                Button("2 · 测试通话下行") { confirmDownlink = true }
                Button("3 · 测试通话上行音") { confirmUplink = true }
            }
            .buttonStyle(.bordered)
            .disabled(model.audioProbeBusy || model.adbInstalling || !model.embeddedAudioProbeAvailable)
            Text("已解除 Mac 状态同步限制：即使显示 IDLE 或未连接，也可在真实电话接通后点击测试。Android 会再次检查通话状态。")
                .font(.caption).foregroundStyle(.secondary)
            if model.audioProbeBusy {
                ProgressView("手机音频检测进行中……").controlSize(.small)
            }
            Text(model.audioProbeStatus)
                .font(.subheadline.weight(.medium))
            if model.audioProbeToneSent {
                HStack {
                    Button("对方已确认听到测试音") { model.confirmRemoteHeardTone() }
                        .disabled(model.audioProbeRemoteConfirmed)
                    Text(model.audioProbeRemoteConfirmed ? "已记录人工确认" : "等待实际通话对方确认")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.audioProbeFacts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.audioProbeFacts, id: \.self) { fact in
                        Text(fact).font(.caption.monospaced())
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("下行非零 PCM ≠ 已证明对方声音可用；上行 AudioTrack 写入成功 ≠ 已确认对方听见。请在双方同意的真实电话中逐项验证，所有结果均写入匿名诊断日志。")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var liveVoicePanel: some View {
        panel("第二阶段 · 真实电话双向语音（V0.4.1）", symbol: "waveform") {
            Text("手动启动 · 16 kHz 单声道 PCM · 每帧 20 ms · 单次最多 3 分钟。音频通过独立 ADB 转发通道，不使用电话状态 HTTP 服务。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("开始实时通话音频") { confirmLiveVoice = true }
                    .disabled(model.liveVoiceStarting || model.liveVoiceActive ||
                              model.adbInstalling || model.audioProbeBusy ||
                              !model.embeddedAudioProbeAvailable)
                    .buttonStyle(.borderedProminent)
                Button("立即停止") { model.stopLiveVoice() }
                    .disabled(!model.liveVoiceStarting && !model.liveVoiceActive)
                    .buttonStyle(.bordered)
            }
            HStack {
                Button(model.liveVoiceMicrophoneEnabled ? "静音 Mac 麦克风" : "开启 Mac 麦克风") {
                    if model.liveVoiceMicrophoneEnabled {
                        model.setLiveVoiceMicrophone(false)
                    } else {
                        confirmLiveMic = true
                    }
                }
                .disabled(!model.liveVoiceActive)
                .buttonStyle(.bordered)
                if model.liveVoiceMicrophoneEnabled {
                    Label("麦克风正在向电话发送语音", systemImage: "mic.fill")
                        .foregroundStyle(.orange).font(.caption)
                } else {
                    Label("Mac 麦克风默认静音", systemImage: "mic.slash")
                        .foregroundStyle(.secondary).font(.caption)
                }
            }
            if model.liveVoiceStarting { ProgressView("正在建立实时音频连接……").controlSize(.small) }
            Text(model.liveVoiceStatus).font(.subheadline.weight(.medium))
            Text("下行接收：\(model.liveVoiceRxFrames) 帧 · 上行发送：\(model.liveVoiceTxFrames) 帧 · Mac 播放丢帧：\(model.liveVoiceDropFrames)")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("麦克风欠载：\(model.liveVoiceMicUnderflows) 帧 · 缓冲溢出：\(model.liveVoiceMicOverflows) 次 · 上行发送延迟：\(model.liveVoiceUplinkLateFrames) 帧")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("Mac 麦克风缓冲：\(model.liveVoiceMicBufferedMs) ms（上限约 240 ms；静音时不计欠载）")
                .font(.caption).foregroundStyle(.secondary)
            Text("音频启动握手尝试：\(model.liveVoiceHandshakeAttempts) 次")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("音质诊断：麦克风欠载表示采样跟不上发送；上行发送延迟表示 ADB 写入或调度延迟；播放丢帧仅统计 Mac 下行。若仍卡顿，请停止并导出匿名诊断日志。")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var chatGPTVoicePanel: some View {
        panel("第三阶段 · ChatGPT Plus Voice 输入（V0.4.1）",
              symbol: "waveform.path") {
            Text("仅将电话下行送至 BlackHole 2ch 虚拟麦克风。ChatGPT Voice 需要你在官方界面手动开启；AI 回复不会自动传入电话，不使用任何付费 API 或第三方 OAuth。")
                .font(.caption).foregroundStyle(.secondary)
            let ready = model.audio.devices.contains {
                $0.displayName.caseInsensitiveCompare("BlackHole 2ch") == .orderedSame
            }
            Text(ready ? "虚拟麦克风：已找到 BlackHole 2ch" :
                         "虚拟麦克风：缺少 BlackHole 2ch，请先安装并点击“重新自检”")
                .font(.caption)
                .foregroundStyle(ready ? .green : .orange)
            HStack {
                Button("打开 ChatGPT Voice") {
                    if let url = URL(string: "https://chatgpt.com/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                Button(model.chatGPTVoiceRouteEnabled ? "断开 ChatGPT 输入" :
                       "将电话声音送入 ChatGPT") {
                    if model.chatGPTVoiceRouteEnabled {
                        model.setChatGPTVoiceRoute(false)
                    } else {
                        confirmChatGPTInput = true
                    }
                }
                .disabled(!model.liveVoiceActive || (!ready && !model.chatGPTVoiceRouteEnabled))
                .buttonStyle(.borderedProminent)
            }
            Text(model.chatGPTVoiceRouteStatus)
                .font(.subheadline.weight(.medium))
            Text("BlackHole 2ch 输入回环：\(model.blackHoleActualInputStatus)")
                .font(.caption).foregroundStyle(.secondary)
            Text("虚拟麦克风播放丢帧：\(model.chatGPTVoiceRouteDropped) 帧")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("操作：① 安装 BlackHole 2ch；② 保持 Mac 默认输出为耳机；③ 在浏览器打开官方 ChatGPT Voice，选择 BlackHole 2ch 作为输入；④ 在双方同意的通话中建立 PCM，再点击上方路由按钮。")
                .font(.caption).foregroundStyle(.secondary)
            Text("注意：此版不发送 AI 语音给电话对方，不进行自动接听，不修改 macOS 默认设备，不抓取 ChatGPT 登录或会话。关闭音频连接将自动停用路由。")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var aiReplyPanel: some View {
        panel("第四阶段 · GPT 回复监听与人工回传（V0.4.1 实验）",
              symbol: "headphones") {
            Text("BlackHole 2ch 传电话给 GPT；独立的 BlackHole 16ch 接收 GPT 回复。先在 Mac 耳机监听，只有二次授权才把回复送给电话对方。")
                .font(.caption).foregroundStyle(.secondary)
            let blackHoleReturnReady = model.audio.devices.contains {
                $0.displayName.caseInsensitiveCompare("BlackHole 16ch") == .orderedSame
            }
            Text(blackHoleReturnReady ? "独立回复输入：已找到 BlackHole 16ch" :
                    "独立回复输入：缺少 BlackHole 16ch（可通过 brew install blackhole-16ch 安装）")
                .font(.caption)
                .foregroundStyle(blackHoleReturnReady ? .green : .orange)
            let blackHole2Ready = model.audio.devices.contains {
                $0.displayName.caseInsensitiveCompare("BlackHole 2ch") == .orderedSame
            }
            if !blackHoleReturnReady || !blackHole2Ready {
                HStack {
                    if !blackHoleReturnReady {
                        Button("一键安装 BlackHole 16ch") {
                            requestedBlackHoleChannels = 16
                            confirmBlackHoleDownload = true
                        }
                        .disabled(model.blackHoleInstallerBusy)
                        .buttonStyle(.borderedProminent)
                    }
                    if !blackHole2Ready {
                        Button("安装 BlackHole 2ch") {
                            requestedBlackHoleChannels = 2
                            confirmBlackHoleDownload = true
                        }
                        .disabled(model.blackHoleInstallerBusy)
                        .buttonStyle(.bordered)
                    }
                    Button("开发者官网") {
                        if let url = URL(string: "https://existential.audio/blackhole/") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
                if model.blackHoleInstallerBusy {
                    ProgressView("下载与校验官方安装包……").controlSize(.small)
                }
                Text(model.blackHoleInstallerStatus)
                    .font(.caption).foregroundStyle(.secondary)
                Text("安装包不包含在软件内：点击按钮后直接从开发者官网下载并校验，随后由 macOS 安装器进行系统授权。安装完成后可能需要重启。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Mac 真实耳机/扬声器", selection: $model.selectedVoiceMonitorOutputID) {
                Text("请先选择输出设备").tag("")
                ForEach(model.audio.devices.filter { device in
                    !device.displayName.localizedCaseInsensitiveContains("BlackHole") &&
                    !device.displayName.localizedCaseInsensitiveContains("aggregate") &&
                    !device.displayName.localizedCaseInsensitiveContains("multi-output")
                }, id: \.id) { device in
                    Text(device.displayName).tag(device.id)
                }
            }
            .disabled(model.aiReplyMonitorEnabled)
            Text(model.isolatedChatGPTOutputEnabled
                ? "视频兼容模式下，本机默认扬声器不切换。通话耳机按硬件 UID 保存，蓝牙/显示器重新连接会自动重选；ChatGPT 独立使用 BlackHole 16ch。"
                : "传统全局模式仅供兼容测试：会切换 Mac 默认声音到 BlackHole 16ch，可能将视频一起路由到电话；请勿在播放视频时使用。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("开始在耳机监听 GPT") { confirmAIReplyMonitor = true }
                    .disabled(!blackHoleReturnReady || !model.liveVoiceActive ||
                              model.aiReplyMonitorEnabled || model.selectedVoiceMonitorOutputID.isEmpty)
                Button("停止监听") { model.setAIReplyMonitor(false) }
                    .disabled(!model.aiReplyMonitorEnabled)
            }
            .buttonStyle(.bordered)
            HStack {
                Button("人工授权：将 GPT 回复发给电话") { confirmAIReplyToPhone = true }
                    .disabled(!model.aiReplyMonitorEnabled || model.aiReplyToPhoneEnabled)
                Button("立即关闭 AI 电话回传") { model.setAIReplyToPhone(false) }
                    .disabled(!model.aiReplyToPhoneEnabled)
            }
            .buttonStyle(.borderedProminent)
            Text(model.aiReplyReturnStatus).font(.subheadline.weight(.medium))
            Text("AI 回复采集：\(model.aiReplyReceivedFrames) 帧 · 峰值 RMS：\(String(format: "%.5f", model.aiReplyPeakRMS)) · 耳机播放丢帧：\(model.aiReplyMonitorDropped) 帧 · 电话上行欠载：\(model.aiReplyUplinkUnderflow) 帧")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("测试顺序：先正常播放一段 GPT 回复并确认 Mac 耳机听得见，再在双方同意的测试电话里开启人工回传，并让对方确认能否听清；不要同时打开 Mac 麦克风与 AI 回传。")
                .font(.caption).foregroundStyle(.secondary)
            Text("重要：Mac 默认输出指向 BlackHole 16ch 时，其它应用与通知声音也可能被回传到电话。请关闭通知和无关声音；程序不会自动启动官方 ChatGPT Voice。")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var audioPanel: some View {
        panel("CoreAudio 音频检测", symbol: "waveform.path") {
            Text("麦克风权限：\(model.audio.microphonePermission)")
            Text("BlackHole：\(model.audio.blackHoleDetected ? "已发现" : "未发现（非必需）")")
            ForEach(model.audio.devices) { device in
                HStack(spacing: 5) {
                    if device.isDefaultInput { Image(systemName: "mic.fill") }
                    if device.isDefaultOutput { Image(systemName: "speaker.wave.2.fill") }
                    Text(device.displayName).lineLimit(1)
                    Spacer()
                    if let sampleRate = device.sampleRate {
                        Text("\(Int(sampleRate)) Hz").foregroundStyle(.secondary)
                    }
                }.font(.caption)
            }
            HStack {
                Button("麦克风电平测试") { model.runMicrophoneTest() }
                    .disabled(model.isAudioTestRunning)
                Button("扬声器试听") { model.playSpeakerBeep() }
            }
            Text(model.probeStatus).font(.caption).foregroundStyle(.secondary)
            Button("恢复启动时默认音频设备") { model.restoreAudio() }
                .font(.caption)
            Text("此处仅检测 Mac 本地音频设备，与手机的联通电话音频分开。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var diagnosticPanel: some View {
        panel("诊断中心", symbol: "waveform.path.ecg.rectangle") {
            HStack {
                Text("保留 14 天 · 容量上限 50 MB · 本地 JSONL + OSLog")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("查看日志目录") { model.openLogFolder() }
                Button("一键导出诊断包") { previewExport = true }
                    .buttonStyle(.borderedProminent)
            }

            HStack {
                Picker("保留范围", selection: $cleanupDays) {
                    Text("最近 1 天").tag(1)
                    Text("最近 7 天").tag(7)
                    Text("最近 14 天").tag(14)
                    Text("全部日志（含今天）").tag(0)
                }
                .frame(width: 185)
                Button(cleanupDays == 0 ? "清空全部日志" : "清理旧日志") {
                    if model.prepareLogCleanup(days: cleanupDays) {
                        confirmLogCleanup = true
                    }
                }
                Text(cleanupDays == 0 ? "删除本应用所有 JSONL 日志（包括今天）；不删除 macOS 系统 OSLog。" : "保留今天及所选天数的本地日志；系统 OSLog 不在清理范围内。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("当前会话：\(model.sessionID)")
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("原有逐帧电平、上行欠载、BlackHole 路由和 ADB 事件全部保留在本地 JSONL 日志中；正常使用无需查看详细数据。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text("已验证上行提示音；实时双向通话与 Mac 下行听辨待实机验证。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("0.4.14 (31)").font(.caption.monospaced())
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
            Text("将打包以下文件（不会自动上传或包含录音）。设备名称与标识符在导出文件中使用序号替代。")
                .foregroundStyle(.secondary)
            Text("app-info.json · system-info.json · audio-devices.json · events.jsonl · errors.log · reproduce.txt · crash-reports/README.txt")
                .font(.caption.monospaced()).textSelection(.enabled)
            Text("设备预览：Mac 音频设备 \(model.audio.devices.count) 台，真实设备名不写入 ZIP。")
                .font(.caption)
            Text("近几条日志预览").font(.subheadline.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(model.events.prefix(8)) { item in
                        Text("\(item.level.rawValue) · \(item.code ?? item.module.rawValue) · \(item.message)")
                            .font(.caption.monospaced())
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 135)
            Text("可选：补充复现步骤（仅导出时写入 reproduce.txt）")
                .font(.subheadline.bold())
            TextEditor(text: $model.reproductionNotes)
                .font(.body).frame(height: 85)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.3)))
            Text("请不要在复现说明中粘贴通话全文、真实姓名、账号密码等敏感内容。导出会再次执行规则脱敏，但不能保证覆盖任意自由文本。")
                .font(.caption).foregroundStyle(.orange)
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
        .frame(width: 640, height: 560)
    }
}
#endif
