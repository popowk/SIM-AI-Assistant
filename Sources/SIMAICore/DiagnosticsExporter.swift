import Foundation

public struct ExportContext {
    public let system: SystemSnapshot
    public let audio: AudioSnapshot
    public let sessionID: String
    public let recentError: DiagnosticEvent?
    public let callState: String
    public let userReproductionNotes: String

    public init(system: SystemSnapshot, audio: AudioSnapshot,
                sessionID: String, recentError: DiagnosticEvent?, callState: String,
                userReproductionNotes: String = "") {
        self.system = system; self.audio = audio
        self.sessionID = sessionID; self.recentError = recentError
        self.callState = callState; self.userReproductionNotes = userReproductionNotes
    }
}

public enum DiagnosticsExportError: Error, LocalizedError {
    case archiveFailed(Int32)
    public var errorDescription: String? {
        switch self {
        case .archiveFailed(let code): return "创建 ZIP 失败（退出状态 \(code)）"
        }
    }
}

public final class DiagnosticsExporter {
    private let logs: LogStore
    private let fileManager: FileManager
    public init(logs: LogStore, fileManager: FileManager = .default) {
        self.logs = logs; self.fileManager = fileManager
    }

    public static func suggestedFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "SIM-AI-Diagnostics-\(formatter.string(from: date)).zip"
    }

    public func export(context: ExportContext, to destination: URL, android: AndroidDiagnosticReport? = nil) throws {
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("sim-ai-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("SIM-AI-Diagnostics", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }

        try writeJSON(["appVersion": context.system.appVersion, "build": context.system.build], name: "app-info.json", root: root)
        try writeJSON(context.system, name: "system-info.json", root: root)
        try writeJSON(context.audio.exportSafe(), name: "audio-devices.json", root: root)
        if let android { try writeJSON(android, name: "android-diagnostics.json", root: root) }
        try logs.readAllSafeLines().write(to: root.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        let errors = try logs.readRecent(limit: 5_000).filter { $0.level == .error }
        let errorsText = errors.map { "\($0.timestamp.ISO8601Format()) \($0.code ?? "UNKNOWN") \(PrivacyRedactor.clean($0.message)) [\($0.sessionID)]" }.joined(separator: "\n")
        try errorsText.write(to: root.appendingPathComponent("errors.log"), atomically: true, encoding: .utf8)
        let crash = root.appendingPathComponent("crash-reports", isDirectory: true)
        try fileManager.createDirectory(at: crash, withIntermediateDirectories: true)
        try "出于隐私保护，V0.2 不自动采集 macOS 全量崩溃报告。发生崩溃时请在 Console.app 中导出本应用的崩溃日志并自行检查后分享。\n"
            .write(to: crash.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        let error = context.recentError?.sanitized()
        let notes = PrivacyRedactor.clean(context.userReproductionNotes)
        let reproduce = """
        SIM AI Assistant 故障反馈
        应用版本：\(context.system.appVersion) (\(context.system.build))
        故障时间：\((error?.timestamp ?? Date()).ISO8601Format())
        故障模块：\(error?.module.rawValue ?? "待确认")
        错误代码：\(error?.code ?? "无")
        关联诊断 ID：\(PrivacyRedactor.clean(context.sessionID))
        实机电话状态：\(context.callState)

        操作流程（可补充）：
        \(notes.isEmpty ? "1. 打开应用\n2. 执行测试\n3. 观察异常" : notes)

        预期结果：
        实际结果：

        说明：未采集通话音频、完整号码、设备地址、ChatGPT 登录信息或内部会话数据。
        """
        try reproduce.write(to: root.appendingPathComponent("reproduce.txt"), atomically: true, encoding: .utf8)

        // Zip only a fresh, sanitized staging directory. Never zip the raw Application Support folder.
        let archive = temporary.appendingPathComponent("result.zip")
        let process = Process()
        #if os(macOS)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, archive.path]
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", archive.path, root.lastPathComponent]
        process.currentDirectoryURL = temporary
        #endif
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DiagnosticsExportError.archiveFailed(process.terminationStatus) }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: archive, to: destination)
    }

    private func writeJSON<T: Encodable>(_ value: T, name: String, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: root.appendingPathComponent(name), options: .atomic)
    }
}
