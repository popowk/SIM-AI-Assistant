#if os(macOS)
import Foundation
import SIMAICore

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

struct ADBHealthReport {
    let transport: String
    let shell: String
    let forward: String
    let reason: String
    let code: String // Constant diagnostic category, never a serial or IP.
}

struct ADBSnapshotResult {
    let snapshot: PhoneBridgeSnapshot?
    let reason: String // fixed safe diagnostic code
}

struct ADBBridgeLink {
    let serial: String        // Only in memory, never logged or exported.
    let token: String         // Private app token, never logged or exported.
    let localPort: Int
}

struct ADBBridgeResult {
    let link: ADBBridgeLink?
    let message: String
}

struct AndroidAudioProbeResult {
    let succeeded: Bool
    let action: String
    let status: String
    let fields: [String: String]
}

/// Supported actions are fixed at compile time. Never accept raw shell commands from UI.
enum AndroidAudioProbeAction: String {
    case info, downlink, uplink
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


    /// Requires exactly one authorized device and a running, user-started companion service.
    /// Reopens a previously authorized wireless ADB transport when it drops out
    /// of `adb devices`. The endpoint is the IP:port reported by ADB, not a
    /// phone serial, and is never included in logs or exported diagnostics.
    /// A revoked authorization or disabled Wi-Fi debugging still needs user action.
    static func openBridge(at selected: String?) -> ADBBridgeResult {
        guard let adb = executable(at: selected) else {
            return .init(link: nil, message: "ADB 不可用；请重新选择可执行文件")
        }
        let devices: [(serial: String, state: String)]
        switch run(adb, args: ["devices"], timeout: 12) {
        case .completed(0, let output): devices = parseDevices(output)
        default: return .init(link: nil, message: "ADB 无法列出授权手机，将自动重试")
        }
        var authorized = devices.filter { $0.state == "device" }
        if authorized.isEmpty,
           let saved = UserDefaults.standard.string(forKey: "SIMAI_LAST_AUTHORIZED_WIFI_ADB"),
           BridgeRetryPolicy.validWirelessEndpoint(saved) {
            // Never use a general adb kill-server/reconnect command: it would
            // disrupt unrelated development devices. Reconnect this one endpoint.
            _ = run(adb, args: ["connect", saved], timeout: 8)
            if case .completed(0, let refreshed) = run(adb, args: ["devices"], timeout: 12) {
                authorized = parseDevices(refreshed).filter { $0.state == "device" }
            }
        }
        guard authorized.count == 1 else {
            return .init(link: nil, message: authorized.count > 1
                ? "检测到多台已授权设备；为避免误连，请仅保留一台"
                : "未发现已授权手机；将自动重试。若手机重启或无线调试关闭，请重新启用/授权")
        }
        let serial = authorized[0].serial
        if BridgeRetryPolicy.validWirelessEndpoint(serial) {
            // Store only a previously authorized network endpoint to allow
            // automatic ADB reconnection after Mac app restarts.
            UserDefaults.standard.set(serial, forKey: "SIMAI_LAST_AUTHORIZED_WIFI_ADB")
        }
        let token: String
        switch run(adb, args: ["-s", serial, "shell", "run-as",
                               "com.popowk.simai.companion", "cat", "files/bridge-token"], timeout: 8) {
        case .completed(0, let output):
            let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count == 64, value.unicodeScalars.allSatisfy({
                ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0))
            }) else {
                return .init(link: nil, message: "手机端通信凭证无效，请启动伴侣电话监听")
            }
            token = value
        default:
            return .init(link: nil, message: "手机监听服务未启动或 ADB 无法读取凭证；将继续自动尝试")
        }
        switch run(adb, args: ["-s", serial, "forward", "tcp:0", "tcp:18764"], timeout: 8) {
        case .completed(0, let output):
            let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let port = Int(value), (1024...65535).contains(port) else {
                return .init(link: nil, message: "ADB 未返回有效的转发端口；将自动重试")
            }
            return .init(link: ADBBridgeLink(serial: serial, token: token, localPort: port),
                         message: "ADB 状态转发已建立，正在接收手机事件")
        default:
            return .init(link: nil, message: "ADB 端口转发失败，将自动重试；检查手机无线调试是否开启")
        }
    }

    /// Diagnoses three separate layers without exporting a serial, IP,
    /// authentication token, phone number or raw adb output:
    /// 1) ADB authorization, 2) ability to execute shell, 3) port forward.
    /// The phone status HTTP response is checked independently by the Model.
    static func inspectBridgeHealth(at selected: String?, link: ADBBridgeLink?) -> ADBHealthReport {
        guard let adb = executable(at: selected) else {
            return .init(transport: "未找到 adb", shell: "未检测",
                         forward: "未检测", reason: "请检查 adb 路径",
                         code: "ADB_MISSING")
        }
        let devices: [(serial: String, state: String)]
        switch run(adb, args: ["devices"], timeout: 8) {
        case .completed(0, let output):
            devices = parseDevices(output)
        case .timedOut:
            return .init(transport: "查询超时", shell: "未检测", forward: "未检测",
                         reason: "ADB 服务没有及时响应", code: "ADB_LIST_TIMEOUT")
        default:
            return .init(transport: "ADB 查询失败", shell: "未检测", forward: "未检测",
                         reason: "ADB 无法列出设备", code: "ADB_LIST_FAILED")
        }
        let authorized = devices.filter { $0.state == "device" }
        let target: String?
        if let serial = link?.serial, devices.contains(where: { $0.serial == serial && $0.state == "device" }) {
            target = serial
        } else if authorized.count == 1 {
            target = authorized[0].serial
        } else {
            target = nil
        }
        guard let serial = target else {
            let offline = devices.contains { $0.state == "offline" }
            let unauthorized = devices.contains { $0.state == "unauthorized" }
            return .init(transport: unauthorized ? "未授权" : offline ? "设备离线" : "未发现唯一已授权设备",
                         shell: "未检测", forward: "未检测",
                         reason: unauthorized ? "请在手机解锁后允许该 Mac 调试；无法自动代替授权"
                               : "可能是无线调试关闭、Wi-Fi 中断或 OEM 锁屏限制",
                         code: unauthorized ? "ADB_UNAUTHORIZED" : offline ? "ADB_OFFLINE" : "ADB_NOT_READY")
        }

        // ADB reports "device" even on some systems where a lock-screen
        // shell RPC is suspended. Verify that an actual benign command runs.
        switch run(adb, args: ["-s", serial, "shell", "echo", "SIMAI_HEALTH_OK"], timeout: 6) {
        case .completed(0, let value) where value.contains("SIMAI_HEALTH_OK"):
            break
        case .timedOut:
            return .init(transport: "ADB 已授权", shell: "命令超时", forward: "未检测",
                         reason: "ADB 枚举正常，但锁屏时 shell 可能被挂起",
                         code: "ADB_SHELL_TIMEOUT")
        default:
            return .init(transport: "ADB 已授权", shell: "命令失败", forward: "未检测",
                         reason: "手机尚不能执行 shell 命令",
                         code: "ADB_SHELL_FAILED")
        }

        // "forward --list" contains the device serial. Compare in memory
        // and do not expose any of its raw output.
        guard let link else {
            return .init(transport: "ADB 已授权", shell: "命令正常", forward: "尚未建立",
                         reason: "手机 Shell 在线；请检查 Companion 状态桥接",
                         code: "ADB_READY_NO_BRIDGE")
        }
        switch run(adb, args: ["-s", serial, "forward", "--list"], timeout: 6) {
        case .completed(0, let result):
            let mapped = result.split(whereSeparator: \.isNewline).contains {
                $0.contains("tcp:\(link.localPort)") && $0.contains("tcp:18764")
            }
            return .init(transport: "ADB 已授权", shell: "命令正常",
                         forward: mapped ? "映射存在" : "映射丢失",
                         reason: mapped ? "ADB 与端口映射正常；手机本地状态服务可能休眠或无响应"
                                        : "端口映射已丢失，应用会自动重新建立",
                         code: mapped ? "PHONE_SERVICE_TIMEOUT" : "ADB_FORWARD_MISSING")
        default:
            return .init(transport: "ADB 已授权", shell: "命令正常", forward: "无法查询",
                         reason: "ADB 可执行命令，但无法检查端口映射",
                         code: "ADB_FORWARD_QUERY_FAILED")
        }
    }

    /// Read a bounded, atomic JSON state snapshot from the already authorized
    /// Companion's private files. No HTTP, no ADB port forward, no raw output
    /// written to logs. Requires the debug APK's run-as access.
    static func readPrivateStateSnapshot(at selected: String?) -> ADBSnapshotResult {
        func failure(_ reason: String) -> ADBSnapshotResult {
            .init(snapshot: nil, reason: reason)
        }
        guard let adb = executable(at: selected) else { return failure("ADB_MISSING") }
        let devices: [(serial: String, state: String)]
        switch run(adb, args: ["devices"], timeout: 7) {
        case .completed(0, let raw): devices = parseDevices(raw)
        case .timedOut: return failure("ADB_ENUMERATION_TIMEOUT")
        default: return failure("ADB_ENUMERATION_FAILED")
        }
        let authorized = devices.filter { $0.state == "device" }
        guard authorized.count == 1 else { return failure("ADB_NOT_READY") }
        let serial = authorized[0].serial
        switch run(adb, args: ["-s", serial, "shell", "run-as",
                               "com.popowk.simai.companion", "cat",
                               "files/bridge-snapshot.json"], timeout: 7) {
        case .completed(0, let output):
            guard output.utf8.count < 32_768,
                  let data = output.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(PhoneBridgeSnapshot.self, from: data),
                  decoded.schema == 1, decoded.running,
                  decoded.events.count <= 64,
                  ["IDLE", "RINGING", "OFFHOOK"].contains(decoded.state),
                  decoded.isFresh(referenceMilliseconds: Int64(Date().timeIntervalSince1970 * 1000))
            else { return failure("SNAPSHOT_INVALID_OR_STALE") }
            return .init(snapshot: decoded, reason: "ADB_FILE_OK")
        case .completed: return failure("SNAPSHOT_UNAVAILABLE")
        case .timedOut: return failure("ADB_FILE_TIMEOUT")
        case .launchFailed: return failure("ADB_LAUNCH_FAILED")
        }
    }

    static func closeBridge(at selected: String?, link: ADBBridgeLink) {
        guard let adb = executable(at: selected) else { return }
        _ = run(adb, args: ["-s", link.serial, "forward", "--remove",
                           "tcp:\(link.localPort)"], timeout: 5)
    }

    /// Explicit one-time recovery for Android debug signing changes.
    /// This NEVER runs as a fallback from normal install, only after separate UI confirmation.
    static func reinstallAfterSignatureChange(at selected: String?, apk: URL) -> ADBInstallOutcome {
        guard let adb = executable(at: selected) else {
            return .init(succeeded: false, status: "ADB 不可用")
        }
        guard FileManager.default.fileExists(atPath: apk.path),
              apk.pathExtension.lowercased() == "apk" else {
            return .init(succeeded: false, status: "内置 APK 不存在")
        }
        let devices: [(serial: String, state: String)]
        switch run(adb, args: ["devices"], timeout: 12) {
        case .completed(0, let output): devices = parseDevices(output)
        default: return .init(succeeded: false, status: "无法读取 ADB 设备列表")
        }
        let authorized = devices.filter { $0.state == "device" }
        guard authorized.count == 1 else {
            return .init(succeeded: false, status: "重装要求恰好 1 台已授权手机")
        }
        let serial = authorized[0].serial
        switch run(adb, args: ["-s", serial, "uninstall",
                               "com.popowk.simai.companion"], timeout: 30) {
        case .completed(0, let output) where output.contains("Success"):
            return install(at: selected, apk: apk)
        default:
            return .init(succeeded: false, status: "卸载旧测试版失败；未继续安装。请检查手机提示。")
        }
    }


    static func runAudioProbe(at selected: String?, jar: URL,
                              action: AndroidAudioProbeAction) -> AndroidAudioProbeResult {
        func failed(_ detail: String) -> AndroidAudioProbeResult {
            .init(succeeded: false, action: action.rawValue, status: detail, fields: [:])
        }
        guard let adb = executable(at: selected) else { return failed("未找到 ADB 可执行文件") }
        guard jar.pathExtension.lowercased() == "jar",
              FileManager.default.fileExists(atPath: jar.path) else {
            return failed("测试版没有内置 Android 音频诊断助手，请重新安装完整 Mac 包")
        }
        let devices: [(serial: String, state: String)]
        switch run(adb, args: ["devices"], timeout: 12) {
        case .completed(0, let output): devices = parseDevices(output)
        default: return failed("ADB 无法列出手机，请检查已配对的 USB / 无线 ADB")
        }
        let ready = devices.filter { $0.state == "device" }
        guard ready.count == 1 else {
            return failed("必须且只能有一台授权中的 Android 手机，当前 \(ready.count) 台")
        }
        let serial = ready[0].serial // only in memory; not logged or exported
        let remote = "/data/local/tmp/simai-audio-probe.jar"
        switch run(adb, args: ["-s", serial, "push", jar.path, remote], timeout: 25) {
        case .completed(0, _): break
        case .timedOut: return failed("ADB 推送诊断程序超时")
        default: return failed("ADB 推送诊断程序失败；请确认手机授权和存储空间")
        }
        let shell = "CLASSPATH=\(remote) app_process / dev.popowk.simai.probe.Main \(action.rawValue)"
        let result = run(adb, args: ["-s", serial, "shell", shell],
                         timeout: action == .downlink ? 24 : 17)
        switch result {
        case .completed(let code, let output):
            // Read *only* whitelisted diagnostic key/value lines from the helper;
            // any OEM stack trace or serial from adb is intentionally discarded.
            let allowed: Set<String> = ["status", "error", "android", "shell", "audioMode",
                "telephonyOutput", "pstnInterceptable", "downlink", "uplink",
                "frames", "peak", "rms", "result", "written", "route", "stage",
                "uplinkManagerApi", "legacyCallRedirectApi"]
            var fields: [String: String] = [:]
            for line in output.split(whereSeparator: \.isNewline) {
                guard line.hasPrefix("SIMAI ") else { continue }
                let kv = line.dropFirst(6).split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let key = String(kv[0])
                let value = String(kv[1])
                guard allowed.contains(key), value.count <= 64,
                      value.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace }) else { continue }
                fields[key] = value
            }
            if fields["status"] == "ok" && code == 0 {
                return .init(succeeded: true, action: action.rawValue,
                             status: "Android Helper 已执行；仍需实机确认双向声音", fields: fields)
            }
            let error = fields["error"] ?? "HELPER_EXIT_\(code)"
            return .init(succeeded: false, action: action.rawValue,
                         status: "手机音频测试失败（\(error)，阶段：\(fields["stage"] ?? "unknown")）；已保存匿名错误码", fields: fields)
        case .timedOut: return failed("手机音频诊断超时，已终止 ADB 命令")
        case .launchFailed: return failed("无法启动 ADB 音频测试命令")
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
