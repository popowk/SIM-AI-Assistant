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
        Button("刷新 Mac 音频设备") { model.refresh() }
        Divider()
        Text("v0.3.4 · 双向 PCM 实时预览")
        Button("退出 SIM AI Assistant") { NSApp.terminate(nil) }
    }
}
#endif
