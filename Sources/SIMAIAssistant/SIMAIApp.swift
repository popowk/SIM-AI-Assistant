#if os(macOS)
import SwiftUI
import AppKit

@main
struct SIMAIApp: App {
    @StateObject private var model = AssistantModel()

    var body: some Scene {
        MenuBarExtra("SIM AI", systemImage: "phone.connection") {
            MenuBarCommands().environmentObject(model)
        }
        Window("SIM AI Assistant · 诊断中心", id: "dashboard") {
            DashboardView().environmentObject(model)
        }
        .defaultSize(width: 900, height: 720)
    }
}

private struct MenuBarCommands: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AssistantModel

    var body: some View {
        Button("打开诊断中心") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "dashboard")
        }
        Divider()
        Button("刷新蓝牙与音频状态") { model.refresh() }
        Button("模拟一通来电") { model.simulateCall() }
        Button("打开 ChatGPT 官方网页") { model.openChatGPT() }
        Divider()
        Text("v0.1.0 · 真实 HFP 尚未连接")
        Button("退出 SIM AI Assistant") { NSApp.terminate(nil) }
    }
}
#endif
