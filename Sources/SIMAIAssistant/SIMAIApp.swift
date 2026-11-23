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
        Button("打开手机屏幕（ADB）") {
            model.openPhoneScreenControl()
        }
        Divider()
        Text("v0.4.8 · GPT 人工接听与双向语音")
        Button("退出 SIM AI Assistant") {
            model.closePhoneScreenControl()
            NSApp.terminate(nil)
        }
    }
}
#endif
