#if os(macOS)
import SwiftUI
import SIMAICore

struct DashboardView: View {
    @EnvironmentObject private var model: AssistantModel
    @State private var previewExport = false
    @State private var confirmLoopback = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusBar
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        bluetoothPanel
                        callPanel
                    }
                    VStack(spacing: 16) {
                        audioPanel
                        voicePanel
                    }
                }
                diagnosticPanel
                footer
            }
            .padding(22)
        }
        .frame(minWidth: 740, minHeight: 540)
        .alert("请先连接耳机", isPresented: $confirmLoopback) {
            Button("取消", role: .cancel) { }
            Button("已连接耳机，开始测试") { model.runLocalLoopback() }
        } message: {
            Text("本机回环会把麦克风的声音以 5% 音量输出到扬声器，2 秒后自动停止。未连接耳机时可能发生啸叫；此测试不涉及真实电话 HFP/SCO。")
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
                Text("macOS 原生电话辅助与诊断 · V0.1.1 测试版")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refresh() } label: { Label("重新自检", systemImage: "arrow.clockwise") }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            statusPill(title: "蓝牙", value: model.bluetooth.scanSucceeded ? "可枚举" : "待检查",
                symbol: "antenna.radiowaves.left.and.right")
            statusPill(title: "音频", value: model.audio.devices.isEmpty ? "未发现" : "\(model.audio.devices.count) 个设备",
                symbol: "waveform")
            statusPill(title: "Voice", value: model.voiceMarkedActive ? "用户标记已启动" : "待手动启动",
                symbol: "mic")
            statusPill(title: "实体电话", value: "HFP 未验证", symbol: "phone.down")
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

    private var bluetoothPanel: some View {
        panel("蓝牙设备自检", symbol: "dot.radiowaves.left.and.right") {
            Text("已配对：\(model.bluetooth.devices.count) 台 · 已连接：\(model.bluetooth.devices.filter(\.connected).count) 台")
            if model.bluetooth.devices.isEmpty {
                Text("未列出已配对的经典蓝牙设备，请先在 macOS 蓝牙设置中配对 vivo S9e。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.bluetooth.devices) { device in
                    HStack {
                        Text(device.displayName).lineLimit(1)
                        Spacer()
                        Text(device.connected ? "已连接" : "未连接")
                            .foregroundStyle(device.connected ? Color.green : Color.secondary)
                    }
                    .font(.caption)
                }
            }
            Text("注意：配对或显示已连接，并不等于支持电话 HFP/SCO。")
                .font(.caption).foregroundStyle(.orange)
            Divider()
            Text("真实来电观察 · 60 秒").font(.subheadline.bold())
            Text("开始后使用另一部电话拨打 vivo S9e。本功能只观察设备状态，不接听、不录音。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("开始观察") { model.startPhoneObservation() }
                    .disabled(model.observingPhone)
                Button("手机已响铃（标记）") { model.markPhoneRinging() }
                    .disabled(!model.observingPhone)
                Button("停止") { model.stopPhoneObservation() }
                    .disabled(!model.observingPhone)
            }.buttonStyle(.bordered)
            Text(model.phoneObservationStatus).font(.caption).foregroundStyle(.secondary)
            if model.observingPhone {
                Text("已观察 \(model.phoneObservationElapsed)/60 秒")
                    .font(.caption.monospacedDigit())
            }

        }
    }

    private var callPanel: some View {
        panel("来电模拟器", symbol: "phone.arrow.down.left") {
            HStack {
                Text("状态：\(model.call.state.rawValue)").fontWeight(.medium)
                Spacer()
                Text("SIMULATION").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            HStack {
                Button("模拟来电") { model.simulateCall() }
                    .disabled(model.call.state == .ringing || model.call.state == .connected)
                Button("模拟接听") { model.answerSimulated() }
                    .disabled(model.call.state != .ringing)
                Button("模拟挂断") { model.hangupSimulated() }
                    .disabled(model.call.state != .ringing && model.call.state != .connected)
            }
            .buttonStyle(.bordered)
            Text("当前只测试状态机，不会接听、拨打或挂断联通 SIM 的真实来电。")
                .font(.caption).foregroundStyle(.secondary)
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
                Button("本机回环（需耳机）") { confirmLoopback = true }
                    .disabled(model.isAudioTestRunning)
            }
            Text(model.probeStatus).font(.caption).foregroundStyle(.secondary)
            Text(model.loopbackStatus).font(.caption).foregroundStyle(.secondary)
            Button("恢复启动时默认音频设备") { model.restoreAudio() }
                .font(.caption)
            Text("本机回环、电平与试听均不代表电话双向音频已通过。音频测试不会保存声音。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var voicePanel: some View {
        panel("ChatGPT Plus Voice · 人工辅助", symbol: "bubble.left.and.waveform.bubble.right") {
            Text("打开官方网页后，请在浏览器内手动点击 Voice 图标，并授权麦克风。")
                .font(.subheadline)
            Button { model.openChatGPT() } label: {
                Label("打开 chatgpt.com", systemImage: "globe")
            }
            Toggle("我已手动启动 Voice", isOn: Binding(
                get: { model.voiceMarkedActive },
                set: { model.setVoiceMarkedActive($0) }
            ))
            Text("不读取 ChatGPT 凭据，不调用 OpenAI API，不自动接入语音或路由真实电话音频。")
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
                Text("故障模拟：").font(.caption)
                ForEach(TestFault.allCases) { fault in
                    Button(fault.rawValue) { model.inject(fault) }
                        .font(.caption)
                }
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
            Text("V0.1 仅提供诊断、模拟测试与人工 Voice 启动；真实 HFP/电话控制待设备验证。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("0.1.1 (2)").font(.caption.monospaced()).foregroundStyle(.secondary)
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
            Text("app-info.json · system-info.json · bluetooth-status.json · audio-devices.json · events.jsonl · errors.log · reproduce.txt · crash-reports/README.txt")
                .font(.caption.monospaced()).textSelection(.enabled)
            Text("设备预览：蓝牙 \(model.bluetooth.devices.count) 台，音频 \(model.audio.devices.count) 台；真实设备名不写入 ZIP。")
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
