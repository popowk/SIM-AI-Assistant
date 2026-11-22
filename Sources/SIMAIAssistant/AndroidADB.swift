#if os(macOS)
import Foundation

struct ADBInspection {
    let installed: Bool
    let authorized: Int
    let unauthorized: Int
    let offline: Int
    let status: String
}

struct ADBInstallOutcome {
    let succeeded: Bool
    let status: String
}

enum ADBInspector {
    private enum CommandResult {
        case completed(Int32, String)
        case timedOut
        case launchFailed
    }

    /// Explicitly selected executable takes priority over PATH and common installations.
    static func executable(at selected: String?) -> URL? {
        let manager = FileManager.default
        if let selected, !selected.isEmpty {
            return manager.isExecutableFile(atPath: selected) ? URL(fileURLWithPath: selected) : nil
        }
        let home = manager.homeDirectoryForCurrentUser
        let paths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            home.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { String($0) + "/adb" }
        return paths.first(where: { manager.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }

    static func inspect(at selected: String? = nil) -> ADBInspection {
        guard let executable = executable(at: selected) else {
            let message = (selected?.isEmpty == false)
                ? "所选 ADB 路径无效或无执行权限；请重新选择 adb 文件"
                : "未自动找到 adb；请手动选择 Android SDK platform-tools/adb"
            return ADBInspection(installed: false, authorized: 0, unauthorized: 0,
                                 offline: 0, status: message)
        }
        switch run(executable, args: ["devices"], timeout: 15) {
        case .completed(0, let output):
            let items = parseDevices(output)
            let authorized = items.filter { $0.state == "device" }.count
            let unauthorized = items.filter { $0.state == "unauthorized" }.count
            let offline = items.filter { $0.state == "offline" }.count
            let status: String
            if authorized > 0 {
                status = "ADB 已授权 \(authorized) 台；安装时必须只连接一台已授权设备"
            } else if unauthorized > 0 {
                status = "发现 \(unauthorized) 台未授权设备；请在 vivo 手机上允许 USB 调试"
            } else if offline > 0 {
                status = "发现 \(offline) 台离线设备；请检查数据线与 USB 调试"
            } else {
                status = "ADB 可以运行，但未发现已授权的安卓设备"
            }
            return ADBInspection(installed: true, authorized: authorized,
                                 unauthorized: unauthorized, offline: offline, status: status)
        case .completed(let code, _):
            return ADBInspection(installed: true, authorized: 0, unauthorized: 0,
                                 offline: 0, status: "ADB 设备查询失败，退出码 \(code)")
        case .timedOut:
            return ADBInspection(installed: true, authorized: 0, unauthorized: 0,
                                 offline: 0, status: "ADB 查询超过 15 秒，已停止")
        case .launchFailed:
            return ADBInspection(installed: true, authorized: 0, unauthorized: 0,
                                 offline: 0, status: "ADB 启动失败；请确认文件权限")
        }
    }

    static func install(at selected: String?, apk: URL) -> ADBInstallOutcome {
        guard let executable = executable(at: selected) else {
            return .init(succeeded: false, status: "请先手动选择有效的 adb 可执行文件")
        }
        guard apk.pathExtension.lowercased() == "apk",
              FileManager.default.fileExists(atPath: apk.path) else {
            return .init(succeeded: false, status: "安装包不存在或扩展名不是 APK；请使用内置伴侣 APK")
        }
        let devices: [(serial: String, state: String)]
        switch run(executable, args: ["devices"], timeout: 15) {
        case .completed(0, let output):
            devices = parseDevices(output)
        case .completed:
            return .init(succeeded: false, status: "查询手机列表失败；请重新连接 USB")
        case .timedOut:
            return .init(succeeded: false, status: "查询手机超时")
        case .launchFailed:
            return .init(succeeded: false, status: "ADB 启动失败")
        }
        let authorized = devices.filter { $0.state == "device" }
        guard authorized.count == 1 else {
            return .init(succeeded: false, status: "需要恰好一台已授权的 Android 手机，当前为 \(authorized.count) 台；不会安装到未确认的设备")
        }
        // Serial remains in memory only. Never write it to logs, UI or diagnostics.
        let serial = authorized[0].serial
        switch run(executable, args: ["-s", serial, "install", "-r", apk.path], timeout: 150) {
        case .completed(0, let output) where output.contains("Success"):
            let launch = run(executable, args: ["-s", serial, "shell", "am", "start",
                "-n", "com.popowk.simai.companion/.MainActivity"], timeout: 12)
            let launched: Bool
            if case .completed(0, _) = launch { launched = true } else { launched = false }
            return .init(succeeded: true,
                status: launched
                    ? "APK 安装/覆盖成功，已尝试打开手机端伴侣 App。请在手机上授予电话状态权限。"
                    : "APK 安装/覆盖成功；自动启动失败，请在手机桌面手动打开 SIM AI Companion。")
        case .completed(_, let output) where output.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE"):
            return .init(succeeded: false,
                status: "覆盖失败：新旧 APK 的签名不一致。没有卸载旧版本，也没有清除数据；请配置固定签名后重新构建。")
        case .completed(_, let output) where output.contains("INSTALL_FAILED_VERSION_DOWNGRADE"):
            return .init(succeeded: false,
                status: "覆盖失败：目标 APK 版本低于已安装版本，未执行降级或卸载。")
        case .completed(_, let output) where output.contains("INSTALL_FAILED_USER_RESTRICTED"):
            return .init(succeeded: false,
                status: "安卓系统拒绝通过 USB 安装。请检查 vivo 的 USB 安装确认与开发者选项。")
        case .completed(let code, _):
            return .init(succeeded: false,
                status: "ADB 安装失败（退出码 \(code)）。请查看手机屏幕的安装授权提示，旧 App 未被主动卸载。")
        case .timedOut:
            return .init(succeeded: false,
                status: "安装等待超过 150 秒。请在手机上检查是否已显示安装结果；程序不会重试或卸载。")
        case .launchFailed:
            return .init(succeeded: false, status: "ADB 安装命令无法启动")
        }
    }

    private static func parseDevices(_ output: String) -> [(serial: String, state: String)] {
        output.split(whereSeparator: \.isNewline).compactMap { row in
            let columns = row.split(separator: "\t", maxSplits: 1)
            guard columns.count == 2 else { return nil }
            let serial = String(columns[0])
            let state = String(columns[1]).split(separator: " ").first.map(String.init) ?? ""
            guard !serial.isEmpty else { return nil }
            return (serial: serial, state: state)
        }
    }

    private static func run(_ executable: URL, args: [String], timeout: TimeInterval) -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do { try process.run() } catch { return .launchFailed }
        if completed.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            return .timedOut
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return .completed(process.terminationStatus, output)
    }
}
#endif
