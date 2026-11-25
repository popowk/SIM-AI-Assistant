import Foundation

/// Explicitly allowlisted phone diagnostics. Unknown or free-form fields are
/// dropped, including any unrecognized vendor-specific dump output.
public struct AndroidDiagnosticEntry: Codable, Equatable {
    public let wallMs: Int64
    public let elapsedMs: Int64
    public let uptimeMs: Int64
    public let event: String
    public let detail: String

    public static func parse(_ text: String) -> [Self] {
        let allowed: Set<String> = [
            "PROCESS_START", "PREVIOUS_EXIT", "EXIT_HISTORY_UNAVAILABLE",
            "SERVICE_CREATE", "SERVICE_START", "SERVICE_USER_DISABLED", "SERVICE_PERMISSION_MISSING",
            "FOREGROUND_STARTED", "FOREGROUND_FAILED", "MONITOR_READY", "MONITOR_INIT_FAILED",
            "SCREEN_ON", "SCREEN_OFF", "USER_PRESENT", "DEVICE_IDLE_CHANGED", "POWER_SAVE_CHANGED",
            "POWER_RECEIVER_FAILED", "SERVICE_HEARTBEAT", "CPU_LOCK_RENEWED", "CPU_LOCK_FAILED",
            "WIFI_LOCK_FAILED", "CALL_STATE", "TASK_REMOVED", "TRIM_MEMORY", "SERVICE_DESTROY",
            "ACTIVITY_CREATE", "ACTIVITY_RESUME", "ACTIVITY_PAUSE", "USER_STOP_MONITOR",
            "PHONE_BROADCAST", "BROADCAST_WAKE_REQUESTED", "BROADCAST_WAKE_DENIED",
            "BRIDGE_STARTED", "ANSWER_RESULT", "SNAPSHOT_HEARTBEAT", "SNAPSHOT_WRITE_FAILED"
        ]
        let keys: Set<String> = ["sdk","version","reason","status","importance","exitWallMs","error",
            "interactive","locked","idle","powerSave","ignoreBatteryOpt","backgroundRestricted",
            "cpuLock","wifiLock","running","flags","startId","state","level","transport","result","active","actual"]
        return text.split(whereSeparator: \.isNewline).prefix(2000).compactMap { line in
            guard line.utf8.count < 900,
                  let entry = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)),
                  entry.wallMs > 0, entry.elapsedMs >= 0, entry.uptimeMs >= 0,
                  entry.elapsedMs >= entry.uptimeMs, allowed.contains(entry.event),
                  entry.detail.utf8.count <= 400 else { return nil }
            for field in entry.detail.split(separator: " ") {
                let parts = field.split(separator: "=", omittingEmptySubsequences: false)
                guard parts.count == 2, keys.contains(String(parts[0])),
                      parts[1].range(of: "^[A-Za-z0-9_.-]{1,80}$", options: .regularExpression) != nil else { return nil }
                let k = String(parts[0]), v = String(parts[1])
                if ["interactive","locked","idle","powerSave","ignoreBatteryOpt","backgroundRestricted","cpuLock","wifiLock","running","active"].contains(k),
                   !["true","false"].contains(v) { return nil }
                if ["sdk","reason","status","importance","exitWallMs","flags","startId","level"].contains(k),
                   Int64(v) == nil { return nil }
                if ["state","actual"].contains(k), !["IDLE","RINGING","OFFHOOK","UNKNOWN"].contains(v) { return nil }
                if k == "version", v != "unknown", v.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) == nil { return nil }
                if k == "error", v.range(of: "^[A-Za-z_]{1,80}$", options: .regularExpression) == nil { return nil }
                if ["result","transport"].contains(k), v.range(of: "^[A-Z_]{1,60}$", options: .regularExpression) == nil { return nil }
            }
            return entry
        }
    }
}
public struct AndroidDiagnosticReport: Codable {
    public var collectedAt = Date()
    public var collection: [String: String]
    public var events: [AndroidDiagnosticEntry] = []
    public var power: [String: String] = [:]
    public var idle: [String: String] = [:]
    public var display: [String: String] = [:]
    public init(status: String) { collection = ["status": status] }

    public static func extractFields(_ text: String, keys: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard parts.count == 2, keys.contains(String(parts[0])),
                  let first = parts[1].split(whereSeparator: \.isWhitespace).first,
                  first.range(of: "^(true|false|Awake|Asleep|Dozing|Dreaming|ON|OFF|DOZE|DOZE_SUSPEND|UNKNOWN|ACTIVE|INACTIVE|IDLE|IDLE_PENDING|IDLE_MAINTENANCE|SENSING|LOCATING|QUICK_DOZE_DELAY|WAITING_FOR_NETWORK|PRE_IDLE|OVERRIDE|[0-9]{1,18}|0x[0-9a-fA-F]{1,12})$", options: .regularExpression) != nil else { continue }
            result[String(parts[0])] = String(first)
        }
        return result
    }
}
public enum AndroidWakeResult {
    /// Classify only known errors; never export raw shell stdout or stderr.
    public static func classify(exit: Int32, output: String) -> String {
        let text = output.lowercased()
        if text.contains("foregroundservicestartnotallowed") || text.contains("startforegroundservice() not allowed") ||
           text.contains("background start not allowed") || text.contains("background execution not allowed") {
            return "PHONE_MONITOR_WAKE_BACKGROUND_RESTRICTED"
        }
        if text.contains("permission denial") || text.contains("securityexception") || text.contains("not exported") ||
           text.contains("requires permission") { return "PHONE_MONITOR_WAKE_PERMISSION_DENIED" }
        if text.contains("not found") || text.contains("does not exist") { return "PHONE_MONITOR_WAKE_COMPONENT_MISSING" }
        if text.contains("device offline") { return "PHONE_MONITOR_WAKE_ADB_OFFLINE" }
        if exit == 0 && text.contains("starting service:") && !text.contains("error") && !text.contains("exception") {
            return "PHONE_MONITOR_WAKE_REQUESTED"
        }
        return "PHONE_MONITOR_WAKE_DENIED"
    }
}
