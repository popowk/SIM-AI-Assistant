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

struct ADBAudioStreamSetup {
    let executable: URL
    let serial: String
    let localPort: Int
    let secret: String
}

struct ADBAudioStreamResult {
    let setup: ADBAudioStreamSetup?
    let errorCode: String
}

/// Only fixed status categories; credentials, phone serial, and request bytes
/// must never appear in diagnostics or user-visible status text.
struct ADBFeishuConfigResult {
    let succeeded: Bool
    let code: String
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
        // A moved/uninstalled manually selected adb must not permanently
        // disable automatic recovery. Fall back to known installations without
        // overwriting the user's explicit preference.
        if let selected, !selected.isEmpty,
           URL(fileURLWithPath: selected).lastPathComponent == "adb",
           manager.isExecutableFile(atPath: selected) {
            return URL(fileURLWithPath: selected)
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

    /// Open only the OS app details screen; no permission grants or security
    /// setting changes are issued by ADB. Any approval is a user tap.
    static func openCompanionSettings(at selected: String?) -> ADBInstallOutcome {
        guard let adb = executable(at: selected) else {
            return .init(succeeded: false, status: "未找到 adb")
        }
        let devices: [(serial: String, state: String)]
        switch run(adb, args: ["devices"], timeout: 12) {
        case .completed(0, let output): devices = parseDevices(output)
        case .timedOut:
            return .init(succeeded: false, status: "ADB 查询手机超时")
        default:
            return .init(succeeded: false, status: "ADB 设备查询失败")
        }
        let ready = devices.filter { $0.state == "device" }
        guard ready.count == 1 else {
            return .init(succeeded: false,
                         status: "请仅连接一台已授权的 Android 手机，再打开权限设置")
        }
        switch run(adb, args: [
            "-s", ready[0].serial, "shell", "am", "start",
            "-a", "android.settings.APPLICATION_DETAILS_SETTINGS",
            "-d", "package:com.popowk.simai.companion"
        ], timeout: 12) {
        case .completed(0, _):
            return .init(succeeded: true,
                         status: "已打开 Android 应用详情页，可在手机镜像窗口进入权限设置并手动确认")
        case .timedOut:
            return .init(succeeded: false, status: "打开应用设置超时，请检查手机锁屏与授权")
        default:
            return .init(succeeded: false,
                         status: "无法打开 Android 应用详情页；确认 Companion 已安装")
        }
    }

    static func discoveryLabel(at selected: String?) -> String {
        guard let adb = executable(at: selected) else { return "未发现可执行的 ADB" }
        let path = adb.path
        if let selected, !selected.isEmpty && selected == path { return "手动指定" }
        if path.hasPrefix("/opt/homebrew/") { return "Homebrew (Apple Silicon)" }
        if path.hasPrefix("/usr/local/") { return "Homebrew / 系统工具" }
        if path.contains("/Android/sdk/platform-tools/") { return "Android SDK" }
        return "系统 PATH"
    }

    /// Restarts ADB server to unstick daemon or reclaim occupied ports.
    @discardableResult
    static func restartADBServer(at selected: String?) -> Bool {
        guard let adb = executable(at: selected) else { return false }
        _ = run(adb, args: ["kill-server"], timeout: 6)
        _ = run(adb, args: ["start-server"], timeout: 8)
        return true
    }

    static func inspect(at selected: String? = nil, allowRestart: Bool = true) -> ADBInspection {
        guard let executable = executable(at: selected) else {
            let message = (selected?.isEmpty == false)
                ? "所选 ADB 路径无效或无执行权限；请重新选择 adb 文件"
                : "未自动找到 adb；请手动选择 Android SDK platform-tools/adb"
            return ADBInspection(installed: false, authorized: 0, unauthorized: 0,
                                 offline: 0, status: message)
        }
        var outcome = run(executable, args: ["devices"], timeout: 12)
        if case .completed(0, _) = outcome {
            // Succeeded
        } else if allowRestart {
            // If adb daemon crashed or port 5037 was blocked, attempt clean restart
            restartADBServer(at: selected)
            outcome = run(executable, args: ["devices"], timeout: 10)
        }
        switch outcome {
        case .completed(0, let output):
            let items = parseDevices(output)
            let authorized = items.filter { $0.state == "device" }.count
            let unauthorized = items.filter { $0.state == "unauthorized" }.count
            let offline = items.filter { $0.state == "offline" }.count
            let status: String
            if authorized > 0 {
                status = "ADB 已授权 \(authorized) 台；安装时必须只连接一台已授权设备"
            } else if unauthorized > 0 {
                status = "发现 \(unauthorized) 台未授权设备；请在手机上允许 USB 调试"
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
                                 offline: 0, status: "ADB 查询超过限制，请检查数据线或重启 ADB")
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
        switch run(executable, args: ["-s", serial, "install", "-r", "-g", apk.path], timeout: 150) {
        case .completed(0, let output) where output.contains("Success"):
            let packageName = "com.popowk.simai.companion"
            let permissions = [
                "android.permission.READ_PHONE_STATE",
                "android.permission.ANSWER_PHONE_CALLS",
                "android.permission.RECEIVE_SMS",
                "android.permission.POST_NOTIFICATIONS",
                "moe.shizuku.manager.permission.API_V23"
            ]
            var granted = 0
            for permission in permissions {
                switch run(executable, args: ["-s", serial, "shell", "pm",
                                              "grant", packageName, permission],
                           timeout: 6) {
                case .completed(0, _): granted += 1
                default: break
                }
            }
            // Whitelist from battery optimization so companion won't be killed in background
            _ = run(executable, args: ["-s", serial, "shell", "dumpsys", "deviceidle", "whitelist", "+\(packageName)"], timeout: 4)

            // Automatically launch Shizuku if installed on phone
            _ = launchShizuku(at: selected, serial: serial)

            let launch = run(executable, args: ["-s", serial, "shell", "am", "start",
                "-n", "com.popowk.simai.companion/.MainActivity"], timeout: 12)
            let launched: Bool
            if case .completed(0, _) = launch { launched = true } else { launched = false }
            let version = Self.installedVersionForSerial(
                executable: executable, serial: serial) ?? "版本查询未完成"
            let permissionStatus = granted >= 2
                ? "已自动授予全部系统权限（电话监听、接听、短信及后台常驻）"
                : "已配置权限；若系统提示请点击允许"
            return .init(succeeded: true,
                status: "已安装 SIM AI Companion \(version)；\(permissionStatus)；" +
                    (launched
                        ? "已启动伴侣端，电话监听自动运行。"
                        : "请打开 Companion 完成初始化。"))
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


    /// Read only fixed package-version metadata; never expose phone serials.
    private static func installedVersionForSerial(executable: URL,
                                                   serial: String) -> String? {
        switch run(executable, args: ["-s", serial, "shell", "dumpsys", "package",
                                      "com.popowk.simai.companion"], timeout: 10) {
        case .completed(0, let raw):
            // Android's versionName and versionCode come from the APK manifest.
            guard let versionMatch = raw.range(
                of: #"versionName=([A-Za-z0-9._-]+)"#,
                options: .regularExpression) else { return nil }
            let name = String(raw[versionMatch].dropFirst("versionName=".count))
            let code = raw.range(of: #"versionCode=([0-9]+)"#,
                                 options: .regularExpression).map {
                String(raw[$0].dropFirst("versionCode=".count))
            } ?? "?"
            return "v\(name) (\(code))"
        default: return nil
        }
    }

    static func installedCompanionVersion(at selected: String?) -> String {
        guard let adb = executable(at: selected) else { return "ADB 不可用" }
        let authorized: [(serial: String, state: String)]
        switch run(adb, args: ["devices"], timeout: 8) {
        case .completed(0, let raw): authorized = parseDevices(raw)
        default: return "暂时无法查询手机 APK"
        }
        let phones = authorized.filter { $0.state == "device" }
        guard phones.count == 1 else { return "需要恰好一台已授权手机" }
        return installedVersionForSerial(executable: adb, serial: phones[0].serial)
            ?? "未检测到已安装版本"
    }

    /// User-triggered direct ADB configuration sync. It intentionally does
    /// not use the phone call-state HTTP bridge: SMS handling must keep working
    /// when the phone monitor is stopped, locked, or the Mac is later unplugged.
    ///
    /// The JSON credentials are sent only through adb's stdin (NOT argv),
    /// atomically staged inside the debug APK private sandbox and consumed by
    /// the app when next opened or on the next new SMS broadcast.
    static func syncFeishuSettings(at selected: String?,
                                   settings: FeishuWebhookSettings) -> ADBFeishuConfigResult {
        func fail(_ code: String) -> ADBFeishuConfigResult {
            ADBFeishuConfigResult(succeeded: false, code: code)
        }
        guard FeishuWebhookSettings.validWebhook(settings.webhook),
              settings.signingSecret.utf8.count <= 256 else {
            return fail("FEISHU_INVALID_SETTINGS")
        }
        guard let adb = executable(at: selected) else { return fail("ADB_MISSING") }
        let devices: [(serial: String, state: String)]
        switch run(adb, args: ["devices"], timeout: 12) {
        case .completed(0, let listing):
            devices = parseDevices(listing)
        case .timedOut: return fail("ADB_DEVICES_TIMEOUT")
        default: return fail("ADB_DEVICES_FAILED")
        }
        let authorized = devices.filter { $0.state == "device" }
        guard authorized.count == 1 else {
            return fail(authorized.count == 0
                ? (devices.contains(where: { $0.state == "unauthorized" })
                    ? "ADB_UNAUTHORIZED" : "ADB_NO_AUTHORIZED_PHONE")
                : "ADB_MULTIPLE_AUTHORIZED_PHONES")
        }
        let serial = authorized[0].serial // Always private; never log.
        let appID = "com.popowk.simai.companion"

        // Prevent false success against an older Android APK which cannot
        // consume this staged format. No phone identifiers are reported.
        let version: Int?
        switch run(adb, args: ["-s", serial, "shell",
                               "dumpsys package \(appID) | grep -m 1 'versionCode='"],
                   timeout: 10) {
        case .completed(0, let output):
            if let match = output.range(of: #"versionCode=([0-9]+)"#, options: .regularExpression) {
                version = Int(output[match].dropFirst("versionCode=".count))
            } else {
                version = nil
            }
        case .timedOut: return fail("ANDROID_PACKAGE_QUERY_TIMEOUT")
        default: return fail("ANDROID_COMPANION_NOT_FOUND")
        }
        guard let version else { return fail("ANDROID_COMPANION_VERSION_UNKNOWN") }
        guard version >= 7 else { return fail("ANDROID_COMPANION_UPDATE_REQUIRED") }

        let bytes: Data
        do {
            bytes = try JSONSerialization.data(withJSONObject: [
                "webhook": settings.webhook,
                "secret": settings.signingSecret,
                "enabled": settings.enabled
            ])
        } catch { return fail("FEISHU_ENCODE_FAILED") }
        guard bytes.count < 4096 else { return fail("FEISHU_CONFIG_TOO_LARGE") }

        // Shell command is a hardcoded string; credentials are NEVER embedded
        // in Process.arguments, app logs or any diagnostic bundle. -T keeps
        // the stdin stream binary-clean instead of terminal line discipline.
        let process = Process()
        process.executableURL = adb
        process.arguments = ["-s", serial, "shell", "-T",
            "run-as \(appID) sh -c 'umask 077; mkdir -p files && cat > files/simai-feishu-sync.tmp && mv files/simai-feishu-sync.tmp files/simai-feishu-sync.json'"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = input
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch { return fail("ADB_CONFIG_PROCESS_LAUNCH") }
        do {
            try input.fileHandleForWriting.write(contentsOf: bytes)
            try input.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            return fail("ADB_CONFIG_STDIN_FAILED")
        }
        if completed.wait(timeout: .now() + 12) == .timedOut {
            if process.isRunning { process.terminate() }
            return fail("ADB_CONFIG_WRITE_TIMEOUT")
        }
        guard process.terminationStatus == 0 else {
            return fail("ADB_CONFIG_RUN_AS_FAILED")
        }
        return .init(succeeded: true, code: "ADB_PRIVATE_CONFIG_STAGED")
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
        var token: String = ""
        let tokenCheck = run(adb, args: ["-s", serial, "shell", "run-as",
                                         "com.popowk.simai.companion", "cat", "files/bridge-token"], timeout: 6)
        var tokenRaw: String?
        if case .completed(0, let output) = tokenCheck {
            tokenRaw = output
        } else {
            // Dormant companion service: wake once and re-check before returning failure
            _ = wakePhoneMonitorIfDesired(at: selected)
            Thread.sleep(forTimeInterval: 0.5)
            if case .completed(0, let retryOutput) = run(adb, args: ["-s", serial, "shell", "run-as",
                                                                     "com.popowk.simai.companion", "cat", "files/bridge-token"], timeout: 6) {
                tokenRaw = retryOutput
            }
        }
        if let raw = tokenRaw {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count == 64, value.unicodeScalars.allSatisfy({
                ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0))
            }) {
                token = value
            }
        }
        guard !token.isEmpty else {
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

    private static func answerViaSystemTelecom(
        adb: URL,
        serial: String
    ) -> Bool {
        // 1. Android 8+ official cmd telecom answer (executed with shell UID 2000, MODIFY_PHONE_STATE)
        if case .completed(0, _) = run(adb, args: ["-s", serial, "shell", "cmd", "telecom", "answer"], timeout: 3) {
            return true
        }
        // 2. Legacy telecom answer command
        if case .completed(0, _) = run(adb, args: ["-s", serial, "shell", "telecom", "answer"], timeout: 3) {
            return true
        }
        // 3. Fallback: KEYCODE_CALL (5)
        if case .completed(0, _) = run(adb, args: ["-s", serial, "shell", "input", "keyevent", "5"], timeout: 3) {
            return true
        }
        // 4. Fallback: KEYCODE_HEADSETHOOK (79)
        if case .completed(0, _) = run(adb, args: ["-s", serial, "shell", "input", "keyevent", "79"], timeout: 3) {
            return true
        }
        return false
    }

    /// Shell-only secondary transport, independently permission-gated by Android.
    /// Never trusts the adb broadcast's exit status: requires the exact ring
    /// sequence and success code from the app's private state snapshot.
    private static func answerViaGuardedADBBroadcast(
        at selected: String?,
        adb: URL,
        serial: String,
        expectedSession: String,
        expectedSequence: Int
    ) -> String {
        let command = ["-s", serial, "shell", "am", "broadcast", "--receiver-foreground",
                       "-a", "com.popowk.simai.companion.REQUEST_GUARDED_ANSWER",
                       "-n", "com.popowk.simai.companion/.AnswerCommandReceiver",
                       "--es", "session", expectedSession,
                       "--ei", "sequence", String(expectedSequence)]
        switch run(adb, args: command, timeout: 5) {
        case .completed(0, let output):
            // Only interpret fixed result strings from the permission-gated
            // explicit receiver; the command exit status alone is not ACK.
            if output.contains("data=\"SIMAI_ANSWER_REQUESTED\"") &&
               output.contains("result=1") { return "ANSWER_FALLBACK_REQUESTED" }
            let statuses: [(String, String)] = [
                ("PERMISSION_REQUIRED", "ANSWER_FALLBACK_PERMISSION_REQUIRED"),
                ("RING_CHANGED", "ANSWER_FALLBACK_RING_CHANGED"),
                ("RING_EXPIRED", "ANSWER_FALLBACK_RING_CHANGED"),
                ("MONITOR_INACTIVE", "ANSWER_FALLBACK_WORKER_INACTIVE"),
                ("ANSWER_IN_PROGRESS", "ANSWER_FALLBACK_IN_PROGRESS"),
                ("ANSWER_UNAVAILABLE", "ANSWER_FALLBACK_REJECTED")
            ]
            for (code, result) in statuses where output.contains("data=\"SIMAI_\(code)\"") {
                return result
            }
            // v0.3.12 and older do not return ordered result data.
        case .completed: return "ANSWER_FALLBACK_BROADCAST_REJECTED"
        case .timedOut: return "ANSWER_FALLBACK_BROADCAST_TIMEOUT"
        case .launchFailed: return "ANSWER_FALLBACK_ADB_LAUNCH_FAILED"
        }
        for _ in 0..<3 {
            let result = readPrivateStateSnapshot(
                at: selected, authorizedSerial: serial)
            if let snap = result.snapshot, snap.session == expectedSession {
                if snap.privateAnswerSequence == expectedSequence {
                    switch snap.privateAnswerResult {
                    case "ANSWER_REQUESTED": return "ANSWER_FALLBACK_REQUESTED"
                    case "PERMISSION_REQUIRED": return "ANSWER_FALLBACK_PERMISSION_REQUIRED"
                    case "RING_CHANGED", "NOT_RINGING": return "ANSWER_FALLBACK_RING_CHANGED"
                    case .some: return "ANSWER_FALLBACK_REJECTED"
                    case .none: break
                    }
                }
                if snap.state != "RINGING" ||
                   snap.seq != expectedSequence {
                    return "ANSWER_FALLBACK_RING_CHANGED"
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return "ANSWER_FALLBACK_BROADCAST_NO_ACK"
    }

    /// Independent Android-private one-shot answer fallback; no HTTP socket.
    /// Android validates both the current bridge session and ringing sequence.
    static func answerRingingViaPrivateLocalShell(
        at selected: String?,
        expectedSession: String,
        expectedSequence: Int,
        expectedSerial: String
    ) -> String {
        guard UUID(uuidString: expectedSession) != nil,
              expectedSequence > 0, !expectedSerial.isEmpty else {
            return "ANSWER_FALLBACK_NO_RING_GUARD"
        }
        let state = readPrivateStateSnapshot(
            at: selected, authorizedSerial: expectedSerial)
        guard let snapshot = state.snapshot else {
            return "ANSWER_FALLBACK_SNAPSHOT_UNAVAILABLE"
        }
        guard snapshot.session == expectedSession,
              snapshot.seq == expectedSequence,
              snapshot.state == "RINGING",
              snapshot.events.last(where: { $0.seq == expectedSequence })?.state == "RINGING"
        else { return "ANSWER_FALLBACK_RING_CHANGED" }
        if snapshot.answerPermissionGranted == false {
            return "ANSWER_FALLBACK_PERMISSION_REQUIRED"
        }
        guard let adb = executable(at: selected) else {
            return "ANSWER_FALLBACK_ADB_MISSING"
        }
        let devices: [(serial: String, state: String)]
        switch run(adb, args: ["devices"], timeout: 4) {
        case .completed(0, let text): devices = parseDevices(text)
        default: return "ANSWER_FALLBACK_DEVICE_CHANGED"
        }
        let authorized = devices.filter { $0.state == "device" }
        guard authorized.count == 1, authorized[0].serial == expectedSerial else {
            return "ANSWER_FALLBACK_DEVICE_CHANGED"
        }
        // APK v0.3.11 advertises this shell-only control path. Unlike the
        // former file queue, it enters the live Android service immediately.
        // Older APKs safely fall back to the existing private request file.
        if snapshot.adbBroadcastAnswerAvailable == true {
            let result = answerViaGuardedADBBroadcast(
                at: selected, adb: adb, serial: expectedSerial,
                expectedSession: expectedSession,
                expectedSequence: expectedSequence)
            if result == "ANSWER_FALLBACK_REQUESTED" {
                return result
            }
            if ["ANSWER_FALLBACK_PERMISSION_REQUIRED", "ANSWER_FALLBACK_RING_CHANGED"].contains(result) {
                return result
            }
        }
        // Direct Android system telecom answer via ADB shell.
        // shell user has MODIFY_PHONE_STATE permission, which bypasses OEM lockscreen
        // and background restrictions that block third-party app TelecomManager calls.
        if answerViaSystemTelecom(adb: adb, serial: expectedSerial) {
            return "ANSWER_FALLBACK_REQUESTED"
        }
        if snapshot.privateAnswerPollerActive == false {
            return "ANSWER_FALLBACK_WORKER_INACTIVE"
        }
        let script = "printf '%s|%s\\n' '\(expectedSession)' '\(expectedSequence)' > files/bridge-answer-request.tmp && mv files/bridge-answer-request.tmp files/bridge-answer-request"
        let escaped = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "run-as com.popowk.simai.companion sh -c " + escaped
        switch run(adb, args: ["-s", expectedSerial, "shell", command], timeout: 6) {
        case .completed(0, _): break
        case .completed: return "ANSWER_FALLBACK_FILE_WRITE_FAILED"
        case .timedOut: return "ANSWER_FALLBACK_ADB_TIMEOUT"
        case .launchFailed: return "ANSWER_FALLBACK_ADB_LAUNCH_FAILED"
        }
        for _ in 0..<6 {
            switch run(adb, args: ["-s", expectedSerial, "shell", "run-as",
                                   "com.popowk.simai.companion", "cat",
                                   "files/bridge-answer-result"], timeout: 3) {
            case .completed(0, let raw):
                let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "|", omittingEmptySubsequences: false)
                if fields.count == 3,
                   fields[0] == expectedSession,
                   fields[1] == String(expectedSequence) {
                    switch fields[2] {
                    case "ANSWER_REQUESTED": return "ANSWER_FALLBACK_REQUESTED"
                    case "PERMISSION_REQUIRED": return "ANSWER_FALLBACK_PERMISSION_REQUIRED"
                    case "RING_CHANGED", "NOT_RINGING": return "ANSWER_FALLBACK_RING_CHANGED"
                    default: return "ANSWER_FALLBACK_REJECTED"
                    }
                }
            default: break
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        // Some vivo builds fail to expose the one-shot result file via ADB
        // even though the foreground monitor processed the command. The
        // existing AtomicFile state snapshot is an independent confirmation.
        let diagnostic = readPrivateStateSnapshot(
            at: selected, authorizedSerial: expectedSerial)
        if let current = diagnostic.snapshot, current.session == expectedSession {
            if current.privateAnswerSequence == expectedSequence {
                switch current.privateAnswerResult {
                case "ANSWER_REQUESTED": return "ANSWER_FALLBACK_REQUESTED"
                case "PERMISSION_REQUIRED": return "ANSWER_FALLBACK_PERMISSION_REQUIRED"
                case "RING_CHANGED", "NOT_RINGING": return "ANSWER_FALLBACK_RING_CHANGED"
                case .some: return "ANSWER_FALLBACK_REJECTED"
                case .none: break
                }
            }
            if current.answerPermissionGranted == false {
                return "ANSWER_FALLBACK_PERMISSION_REQUIRED"
            }
            if current.privateAnswerPollerActive == false {
                return "ANSWER_FALLBACK_WORKER_INACTIVE"
            }
            if current.state != "RINGING" || current.seq != expectedSequence {
                return "ANSWER_FALLBACK_RING_CHANGED"
            }
        }
        return "ANSWER_FALLBACK_NO_ACK"
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

    /// Sets up a distinct ADB forward for raw cellular audio. No phone state,
    /// contact identifier or raw PCM is captured by this method.
    static func prepareAudioStream(at selected: String?, jar: URL) -> ADBAudioStreamResult {
        func fail(_ code: String) -> ADBAudioStreamResult { .init(setup: nil, errorCode: code) }
        guard let adb = executable(at: selected) else { return fail("ADB_MISSING") }
        guard jar.pathExtension.lowercased() == "jar",
              FileManager.default.fileExists(atPath: jar.path) else { return fail("AUDIO_HELPER_MISSING") }
        let devices: [(serial: String, state: String)]
        switch run(adb, args: ["devices"], timeout: 10) {
        case .completed(0, let output): devices = parseDevices(output)
        default: return fail("ADB_UNAVAILABLE")
        }
        var authorized = devices.filter { $0.state == "device" }
        if authorized.isEmpty,
           let saved = UserDefaults.standard.string(forKey: "SIMAI_LAST_AUTHORIZED_WIFI_ADB"),
           BridgeRetryPolicy.validWirelessEndpoint(saved) {
            _ = run(adb, args: ["connect", saved], timeout: 8)
            if case .completed(0, let refreshed) = run(adb, args: ["devices"], timeout: 10) {
                authorized = parseDevices(refreshed).filter { $0.state == "device" }
            }
        }
        guard authorized.count == 1 else { return fail("ADB_DEVICE_COUNT") }
        let serial = authorized[0].serial
        let remote = "/data/local/tmp/simai-audio-probe.jar"
        var pushed = false
        var pushFailure = "AUDIO_HELPER_PUSH_FAILED"
        // A locked handset can briefly stall the ADB transport even when
        // authorization is retained. Retry once with bounded timeouts.
        for attempt in 0..<2 {
            switch run(adb, args: ["-s", serial, "push", jar.path, remote],
                       timeout: attempt == 0 ? 12 : 20) {
            case .completed(0, _):
                pushed = true
            case .timedOut:
                pushFailure = "AUDIO_HELPER_PUSH_TIMEOUT"
            default:
                pushFailure = "AUDIO_HELPER_PUSH_FAILED"
            }
            if pushed { break }
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.7) }
        }
        guard pushed else { return fail(pushFailure) }
        switch run(adb, args: ["-s", serial, "forward", "tcp:0", "tcp:18765"], timeout: 10) {
        case .completed(0, let output):
            guard let port = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (1024...65535).contains(port) else { return fail("ADB_FORWARD_PORT") }
            let secret = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            return .init(setup: .init(executable: adb, serial: serial,
                                      localPort: port, secret: secret),
                         errorCode: "OK")
        default: return fail("ADB_FORWARD_FAILED")
        }
    }

    static func closeAudioStream(_ session: ADBAudioStreamSetup) {
        _ = run(session.executable, args: ["-s", session.serial,
                  "forward", "--remove", "tcp:\(session.localPort)"], timeout: 6)
    }

    /// Read a bounded, atomic JSON state snapshot from the already authorized
    /// Companion's private files. No HTTP, no ADB port forward, no raw output
    /// written to logs. Requires the debug APK's run-as access.
    static func readPrivateStateSnapshot(
        at selected: String?, authorizedSerial: String? = nil
    ) -> ADBSnapshotResult {
        func failure(_ reason: String) -> ADBSnapshotResult {
            .init(snapshot: nil, reason: reason)
        }
        guard let adb = executable(at: selected) else { return failure("ADB_MISSING") }
        let serial: String
        if let authorizedSerial, !authorizedSerial.isEmpty {
            // This serial was obtained from an already-authorized single
            // device bridge. adb -s fails closed if the device disconnects.
            serial = authorizedSerial
        } else {
            let devices: [(serial: String, state: String)]
            switch run(adb, args: ["devices"], timeout: 7) {
            case .completed(0, let raw): devices = parseDevices(raw)
            case .timedOut: return failure("ADB_ENUMERATION_TIMEOUT")
            default: return failure("ADB_ENUMERATION_FAILED")
            }
            let authorized = devices.filter { $0.state == "device" }
            guard authorized.count == 1 else { return failure("ADB_NOT_READY") }
            serial = authorized[0].serial
        }
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

    /// If an already-authorized phone's state service has gone stale, ask
    /// Android to restart the SAME permission-gated foreground monitor.
    /// Do not open its Activity or alter permissions. Respect an explicit
    /// "stop monitoring" choice persisted by the Companion.
    static func wakePhoneMonitorIfDesired(at selected: String?) -> String {
        guard let adb = executable(at: selected) else { return "ADB_MISSING" }
        let devices: [(serial: String, state: String)]
        switch run(adb, args: ["devices"], timeout: 6) {
        case .completed(0, let raw): devices = parseDevices(raw)
        default: return "ADB_ENUMERATION_FAILED"
        }
        let authorized = devices.filter { $0.state == "device" }
        guard authorized.count == 1 else { return "ADB_NOT_READY" }
        let serial = authorized[0].serial

        // The normal first-run default is monitoring enabled. An explicit
        // user stop is stored as false and must never be overridden.
        switch run(adb, args: ["-s", serial, "shell", "run-as",
                               "com.popowk.simai.companion", "cat",
                               "shared_prefs/simai_initial_setup.xml"], timeout: 6) {
        case .completed(0, let prefs):
            if prefs.contains("name=\"phone_state_monitor_desired\" value=\"false\"") ||
               prefs.contains("name=\"phone_state_monitor_desired\" value='false'") {
                return "PHONE_MONITOR_USER_DISABLED"
            }
        case .completed:
            // A first install may not have created preferences yet. Existing
            // Android READ_PHONE_STATE permission still gates the service.
            break
        default: return "ADB_PREFS_UNAVAILABLE"
        }
        switch run(adb, args: ["-s", serial, "shell", "am",
                               "start-foreground-service", "-n",
                               "com.popowk.simai.companion/.CallMonitorService"], timeout: 8) {
        case .completed(0, _): return "PHONE_MONITOR_WAKE_REQUESTED"
        case .timedOut: return "PHONE_MONITOR_WAKE_TIMEOUT"
        default:
            // Quiet background start-service; NEVER launch MainActivity into user's foreground!
            _ = run(adb, args: ["-s", serial, "shell", "am", "start-service",
                                "-n", "com.popowk.simai.companion/.CallMonitorService"],
                    timeout: 6)
            return "PHONE_MONITOR_WAKE_DENIED"
        }
    }

    /// Automatically retrieves the device's true Wi-Fi IP address over ADB.
    /// Excludes cellular modem IPs (rmnet/ccmni) and returns pure IPv4.
    static func fetchDeviceWiFiIP(at selected: String?, serial: String) -> String? {
        guard let adb = executable(at: selected) else { return nil }
        // 1. Try `ip -4 addr show wlan0`
        if case let .completed(0, output) = run(adb, args: ["-s", serial, "shell", "ip", "-4", "addr", "show", "wlan0"], timeout: 4) {
            let pattern = #"inet\s+([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
               let range = Range(match.range(at: 1), in: output) {
                let ip = String(output[range])
                if BridgeRetryPolicy.validWirelessEndpoint("\(ip):18764") { return ip }
            }
        }
        // 2. Try getprop dhcp.wlan0.ipaddress
        if case let .completed(0, output) = run(adb, args: ["-s", serial, "shell", "getprop", "dhcp.wlan0.ipaddress"], timeout: 3) {
            let ip = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if BridgeRetryPolicy.validWirelessEndpoint("\(ip):18764") { return ip }
        }
        // 3. Try `ip route`
        if case let .completed(0, output) = run(adb, args: ["-s", serial, "shell", "ip", "route"], timeout: 3) {
            for line in output.components(separatedBy: .newlines) {
                if line.contains("wlan") && line.contains("src ") {
                    let parts = line.components(separatedBy: "src ")
                    if parts.count > 1, let candidate = parts[1].split(separator: " ").first {
                        let ip = String(candidate).trimmingCharacters(in: .whitespacesAndNewlines)
                        if BridgeRetryPolicy.validWirelessEndpoint("\(ip):18764") { return ip }
                    }
                }
            }
        }
        return nil
    }

    /// Automatically starts Shizuku on the phone via ADB starter binary.
    static func launchShizuku(at selected: String?, serial: String) -> (success: Bool, message: String) {
        guard let adb = executable(at: selected) else {
            return (false, "未找到有效的 ADB 可执行文件")
        }
        // Check if shizuku_server is already running
        if case let .completed(0, psOut) = run(adb, args: ["-s", serial, "shell", "ps", "-A"], timeout: 5),
           psOut.contains("shizuku_server") {
            _ = run(adb, args: ["-s", serial, "shell", "pm", "grant", "com.popowk.simai.companion", "moe.shizuku.manager.permission.API_V23"], timeout: 4)
            return (true, "Shizuku 服务已在手机后台正常运行")
        }
        // 1. Try launching via Shizuku's native library starter
        let dump = run(adb, args: ["-s", serial, "shell", "pm", "dump", "moe.shizuku.privileged.api"], timeout: 5)
        if case let .completed(0, output) = dump, !output.isEmpty {
            for line in output.components(separatedBy: .newlines) {
                if line.contains("legacyNativeLibraryDir=") {
                    if let dir = line.components(separatedBy: "legacyNativeLibraryDir=").last?.trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty {
                        let starter = "\(dir)/libshizuku.so"
                        let res = run(adb, args: ["-s", serial, "shell", starter], timeout: 8)
                        if case let .completed(0, out) = res, out.contains("shizuku_server pid is") || out.contains("starter exit with 0") {
                            _ = run(adb, args: ["-s", serial, "shell", "pm", "grant", "com.popowk.simai.companion", "moe.shizuku.manager.permission.API_V23"], timeout: 4)
                            return (true, "已通过底层 Starter 成功启动手机 Shizuku 特权服务！")
                        }
                    }
                }
            }
        }
        // 2. Fallback to start.sh
        let shRes = run(adb, args: ["-s", serial, "shell", "sh", "/sdcard/Android/data/moe.shizuku.privileged.api/start.sh"], timeout: 8)
        if case let .completed(0, out) = shRes, out.contains("exit with 0") {
            _ = run(adb, args: ["-s", serial, "shell", "pm", "grant", "com.popowk.simai.companion", "moe.shizuku.manager.permission.API_V23"], timeout: 4)
            return (true, "已通过 start.sh 成功启动手机 Shizuku 特权服务！")
        }
        return (false, "未能自动启动 Shizuku；请确认手机已安装 Shizuku 并在应用内开启无线调试")
    }

    /// Robust ADB call hangup. Tries `cmd telecom end-call` (Android 10+ Telecom Manager),
    /// then legacy `telecom end-call`, and finally `input keyevent 6` (KEYCODE_ENDCALL).
    static func hangupCall(at selected: String?) -> String {
        guard let adb = executable(at: selected) else { return "HANGUP_NO_ADB" }
        let devices: [(serial: String, state: String)]
        switch run(adb, args: ["devices"], timeout: 6) {
        case .completed(0, let text): devices = parseDevices(text)
        default: return "HANGUP_DEVICE_UNAVAILABLE"
        }
        let authorized = devices.filter { $0.state == "device" }
        guard authorized.count == 1 else { return "HANGUP_DEVICE_AMBIGUOUS" }
        let serial = authorized[0].serial

        // 1. Android 10+ Telecom Manager CLI (most reliable on Android 10-15+)
        let cmdResult = run(adb, args: ["-s", serial, "shell", "cmd", "telecom", "end-call"], timeout: 4)
        if case .completed(0, _) = cmdResult {
            _ = run(adb, args: ["-s", serial, "shell", "input", "keyevent", "6"], timeout: 2)
            return "HANGUP_SUCCESS"
        }

        // 2. Legacy telecom CLI (Android 9-)
        let legacyResult = run(adb, args: ["-s", serial, "shell", "telecom", "end-call"], timeout: 4)
        if case .completed(0, _) = legacyResult {
            _ = run(adb, args: ["-s", serial, "shell", "input", "keyevent", "6"], timeout: 2)
            return "HANGUP_SUCCESS"
        }

        // 3. Fallback to hardware end-call key event (KEYCODE_ENDCALL = 6)
        switch run(adb, args: ["-s", serial, "shell", "input", "keyevent", "6"], timeout: 4) {
        case .completed(0, _): return "ENDCALL_KEY_SENT_UNCONFIRMED"
        case .timedOut: return "ENDCALL_KEY_TIMEOUT"
        default: return "ENDCALL_KEY_REJECTED"
        }
    }

    /// Compatibility with an already installed Companion that predates the
    /// optional /call/hangup endpoint. Only the exact authenticated Android
    /// monitor session and OFFHOOK sequence may receive KEYCODE_ENDCALL (6).
    /// Never send this input to an unknown, new or stale phone call.
    static func guardedLegacyHangup(at selected: String?,
                                    expectedSession: String,
                                    expectedSequence: Int) -> String {
        guard !expectedSession.isEmpty, expectedSequence > 0 else {
            return "ENDCALL_NO_SESSION_GUARD"
        }
        let result = readPrivateStateSnapshot(at: selected)
        guard let snapshot = result.snapshot else {
            return "ENDCALL_SNAPSHOT_UNAVAILABLE"
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard snapshot.session == expectedSession,
              snapshot.seq == expectedSequence,
              snapshot.state == "OFFHOOK",
              snapshot.isFresh(referenceMilliseconds: now,
                               maxAgeMilliseconds: 20_000) else {
            return "ENDCALL_CALL_CHANGED"
        }
        return hangupCall(at: selected)
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
