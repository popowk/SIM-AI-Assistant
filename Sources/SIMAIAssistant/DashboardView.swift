#if os(macOS)
import SwiftUI
import AppKit
import SIMAICore

struct DashboardView: View {
    @EnvironmentObject private var model: AssistantModel
    @State private var previewExport = false
    @State private var confirmDownlink = false
    @State private var confirmUplink = false
    @State private var cleanupDays = 7
    @State private var confirmLogCleanup = false
    @State private var confirmAPKInstall = false
    @State private var confirmAPKReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusBar
                adbPanel
                phoneAudioPanel
                audioPanel
                diagnosticPanel
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
            Text("请先与同意参与测试的另一方接通真实电话，让对方持续说话。本测试只测量电话下行 PCM 峰值与 RMS，不录音、不传输语音，也不证明已分离出对方声音。")
        }
        .confirmationDialog("向真实电话发送低音量测试音？", isPresented: $confirmUplink, titleVisibility: .visible) {
            Button("双方已同意，发送约 1 秒测试音") {
                model.runPhoneAudioProbe(.uplink)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("必须是双方同意的测试电话，先接通并确认对方知晓即将听到两声测试音。程序会尝试向通话上行写入短促测试音；成功写入不代表对方一定听见。不会自动接听、不会保存声音。")
        }
        .confirmationDialog("确认清理本应用日志？", isPresented: $confirmLogCleanup,
                            titleVisibility: .visible) {
            Button(cleanupDays == 0 ? "清空全部日志" : "删除旧日志", role: .destructive) { model.cleanOldLogs(days: cleanupDays) }
            Button("取消", role: .cancel) { }
        } message: {
            Text(model.cleanupPreviewText + "\n操作不可撤销，仅影响 SIM AI Assistant 的历史 JSONL 日志，不清除系统 OSLog。")
        }
        .confirmationDialog("安装或覆盖 Android 伴侣 APK？",
                            isPresented: $confirmAPKInstall, titleVisibility: .visible) {
            Button("确认安装 / 覆盖") { model.installAndroidCompanion() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("使用所选 ADB，通过 USB 安装内置的测试 APK（adb install -r），仅作用于唯一已授权的 Android 设备。不会卸载旧应用；签名不一致时会失败并保留旧数据。")
        }
        .confirmationDialog("要删除旧版 Android 伴侣 App 的全部数据并重装吗？",
                            isPresented: $confirmAPKReset, titleVisibility: .visible) {
            Button("清空旧版伴侣数据并重装", role: .destructive) {
                model.reinstallAndroidCompanionAfterConfirmation()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("仅针对 SIM AI Companion。此操作会通过 ADB 卸载该 APK（删除其私有数据、权限、手机端历史事件），随后安装新 APK。请仅在提示签名不一致时使用；绝不自动执行。")
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
                Text("真实电话音频兼容性诊断 · V0.2.0")
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
            statusPill(title: "Mac 音频", value: "\(model.audio.devices.count) 个设备",
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
            HStack {
                Button("检测 ADB 设备") { model.inspectADB() }
                    .disabled(model.adbChecking || model.adbInstalling)
                Button("官方 Platform-Tools") {
                    if let url = URL(string: "https://developer.android.com/tools/releases/platform-tools") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Text(model.adbStatus).font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("内置 APK：\(model.embeddedAPKAvailable ? "SIM AI Companion V0.2.0" : "当前构建未包含")")
                .font(.caption)
            Button {
                confirmAPKInstall = true
            } label: {
                Label(model.adbInstalling ? "正在安装 APK…" : "一键安装 / 覆盖 APK",
                      systemImage: "square.and.arrow.down")
            }
            .disabled(model.adbInstalling || !model.embeddedAPKAvailable)
            .buttonStyle(.borderedProminent)
            Text(model.apkInstallStatus).font(.caption).foregroundStyle(.secondary)
            Button("签名不一致？清空旧版伴侣数据后重装") { confirmAPKReset = true }
                .disabled(model.adbInstalling || !model.embeddedAPKAvailable)
                .font(.caption)
                .foregroundStyle(.orange)
            Divider()
            Toggle("ADB 来电状态自动同步", isOn: Binding(
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

    private var phoneAudioPanel: some View {
        panel("第一阶段 · 联通真实通话音频兼容性", symbol: "waveform.badge.mic") {
            Text("仅测试 Android 13 shell 音频能力，不录音、不中转声音、不启用 GPT 或自动接听。")
                .font(.caption).foregroundStyle(.secondary)
            Text("音频 Helper：\(model.embeddedAudioProbeAvailable ? "已内置" : "未内置")")
                .font(.caption)
            HStack {
                Button("1 · 检测音频接口") { model.runPhoneAudioProbe(.info) }
                Button("2 · 测试通话下行") { confirmDownlink = true }
                    .disabled(model.livePhoneState != "OFFHOOK")
                Button("3 · 测试通话上行音") { confirmUplink = true }
                    .disabled(model.livePhoneState != "OFFHOOK")
            }
            .buttonStyle(.bordered)
            .disabled(model.audioProbeBusy || model.adbInstalling || !model.embeddedAudioProbeAvailable)
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
            VStack(alignment: .leading, spacing: 5) {
                ForEach(model.events.prefix(30)) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(event.timestamp.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                        Text(event.level.rawValue)
                            .foregroundStyle(event.level == .error ? Color.red : Color.secondary)
                            .frame(width: 48, alignment: .leading)
                        Text(event.code ?? event.module.rawValue)
                            .foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                        Text(event.message).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.monospaced())
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var footer: some View {
        HStack {
            Text("已验证来电状态同步；双向电话音频仍需在 vivo S9e 上实测。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("0.2.0 (7)").font(.caption.monospaced())
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
