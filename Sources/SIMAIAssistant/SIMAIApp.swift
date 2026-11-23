#if os(macOS)
import SwiftUI
import AppKit

/// Last-resort synchronous restoration for Quit events not coming from
/// our menu-bar button (e.g. macOS application termination).
private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        _ = AutoVoiceOutputRouter().restore()
        _ = AutoVoiceInputRouter().restore()
    }
}

@main
struct SIMAIApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var model = AssistantModel()

    var body: some Scene {
        MenuBarExtra("SIM AI", systemImage: "phone.connection") {
            MenuBarCommands().environmentObject(model)
        }
        Window("SIM AI Assistant · 自动值守", id: "dashboard") {
            DashboardView().environmentObject(model)
        }
        .defaultSize(width: 900, height: 720)
        Window("ChatGPT Voice · 内嵌浏览器", id: "embedded-voice") {
            EmbeddedChatGPTVoiceWindow(browser: model.embeddedVoiceBrowser).environmentObject(model)
        }
        .defaultSize(width: 1100, height: 820)
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
        Button("内嵌 ChatGPT Voice（实验）") {
            model.setEmbeddedVoiceBrowserEnabled(true)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "embedded-voice")
        }
        Button("打开手机屏幕（ADB）") {
            model.openPhoneScreenControl()
        }
        Divider()
        Button("恢复 Mac 原声音输出") {
            model.restoreAutomaticGPTOutput()
        }
        Divider()
        Text("v0.4.16 · 按需 Voice 轻量待命")
        Button("退出 SIM AI Assistant") {
            model.shutdownForAppExit()
            NSApp.terminate(nil)
        }
    }
}
#endif
