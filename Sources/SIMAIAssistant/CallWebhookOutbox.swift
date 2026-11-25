#if os(macOS)
import Foundation
import CryptoKit

/// Persist authorized messages before network I/O. No webhook URL or signing
/// secret is stored here; credentials remain in the existing Keychain store.
actor CallWebhookOutbox {
    static let shared = CallWebhookOutbox()
    private struct Item: Codable {
        let id: String
        let text: String
        let destination: String
        let created: Date
        var nextAttempt: Date
        var attempts: Int
    }
    private var busy = false
    private let fm = FileManager.default
    private var directory: URL {
        LocalCallCapture.directory.deletingLastPathComponent()
            .appendingPathComponent("CallWebhookOutbox", isDirectory: true)
    }
    private func destination(_ settings: FeishuWebhookSettings) -> String {
        SHA256.hash(data: Data(settings.webhook.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    private func save(_ item: Item) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent(item.id + ".json")
        try JSONEncoder().encode(item).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func enqueue(id: String, text: String, settings: FeishuWebhookSettings) async -> String {
        guard UUID(uuidString: id) != nil, FeishuWebhookSettings.validWebhook(settings.webhook) else {
            return "飞书配置无效，未发送"
        }
        let item = Item(id: id, text: String(text.prefix(12000)), destination: destination(settings),
                        created: Date(), nextAttempt: Date(), attempts: 0)
        do { try save(item) }
        catch { return "飞书待发送消息无法保存，请检查本机存储" }
        await drain(settings: settings)
        return fm.fileExists(atPath: directory.appendingPathComponent(id + ".json").path)
            ? "飞书消息已进入本地重试队列" : "飞书文字发送成功"
    }
    func drain(settings: FeishuWebhookSettings) async {
        guard !busy, FeishuWebhookSettings.validWebhook(settings.webhook) else { return }
        busy = true
        defer { busy = false }
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var item = try? JSONDecoder().decode(Item.self, from: data),
                  UUID(uuidString: item.id) != nil, file.lastPathComponent == item.id + ".json" else { continue }
            let now = Date()
            if now.timeIntervalSince(item.created) >= 86400 {
                try? fm.removeItem(at: file)
                continue
            }
            guard item.destination == destination(settings), item.nextAttempt <= now else { continue }
            // Re-read saved destination before each send. Never redirect an
            // old queued transcript to a newly configured robot.
            guard let current = FeishuWebhookStore.load(),
                  destination(current) == item.destination else { continue }
            item.attempts += 1
            item.nextAttempt = now.addingTimeInterval(min(1800, 60 * pow(2, Double(min(item.attempts - 1, 5)))))
            do { try save(item) } catch { continue }
            if await LocalCallCapture.sendWithRetry(item.text, settings: current) {
                try? fm.removeItem(at: file)
            }
        }
    }
}
#endif
