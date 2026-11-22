#if os(macOS)
import Foundation

/// Read-only ADB connectivity check. Never accesses the Mac Bluetooth controller.
/// Raw serial numbers and USB identifiers are deliberately discarded immediately.
struct ADBInspection {
    let installed: Bool
    let authorized: Int
    let unauthorized: Int
    let offline: Int
    let status: String
}

enum ADBInspector {
    private static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            home.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { String($0) + "/adb" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map {
            URL(fileURLWithPath: $0)
        }
    }

    static func inspect() -> ADBInspection {
        guard let url = executable() else {
            return ADBInspection(installed: false, authorized: 0, unauthorized: 0, offline: 0,
                                 status: "未安装 ADB；请安装 Android SDK Platform-Tools")
        }
        let process = Process()
        process.executableURL = url
        process.arguments = ["devices"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        do {
            try process.run()
        } catch {
            return ADBInspection(installed: true, authorized: 0, unauthorized: 0, offline: 0,
                                 status: "ADB 无法启动；请检查执行权限")
        }
        if group.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            return ADBInspection(installed: true, authorized: 0, unauthorized: 0, offline: 0,
                                 status: "ADB 连接检测超时")
        }
        let raw = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            return ADBInspection(installed: true, authorized: 0, unauthorized: 0, offline: 0,
                                 status: "ADB 返回失败状态（退出码 \(process.terminationStatus)）")
        }
        var authorized = 0
        var unauthorized = 0
        var offline = 0
        for line in raw.split(whereSeparator: \.isNewline) {
            // Parse the state only; never retain the first field (serial/identifier).
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) {
            case "device": authorized += 1
            case "unauthorized": unauthorized += 1
            case "offline": offline += 1
            default: break
            }
        }
        let summary: String
        if authorized > 0 {
            summary = "ADB 已授权 \(authorized) 台设备（尚未安装电话伴侣 APK）"
        } else if unauthorized > 0 {
            summary = "发现 \(unauthorized) 台未授权设备；请在手机上允许 USB 调试"
        } else if offline > 0 {
            summary = "发现 \(offline) 台离线设备；请重新连接数据线"
        } else {
            summary = "已安装 ADB，但暂未发现已授权的安卓设备"
        }
        return ADBInspection(installed: true, authorized: authorized,
                             unauthorized: unauthorized, offline: offline, status: summary)
    }
}
#endif
