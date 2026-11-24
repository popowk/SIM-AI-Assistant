#if os(macOS)
import Foundation
import CryptoKit
import SIMAICore

/// Explicitly enabled, per-call consent-gated storage/forwarding. Only PCM
/// actually read/written by the telephone bridge is captured, not desktop audio.
final class LocalCallCapture {
    let recordAudio: Bool
    private let webhook: FeishuWebhookSettings?
    var requestsForwarding: Bool { webhook != nil }
    private let gate = NSLock()
    private let began = Date()
    private let identifier = UUID().uuidString
    private var allowed = false
    private var finalized = false
    private var incoming = Data()
    private var outgoing = Data()
    private var turns: [String] = []
    // Existing phone audio helper enforces 180 seconds. A little headroom.
    private let limit = 16_000 * 2 * 185

    init(recordAudio: Bool, webhook: FeishuWebhookSettings?) {
        self.recordAudio = recordAudio
        self.webhook = webhook
    }
    var greeting: LocalReceptionPolicy.Reply {
        if recordAudio && webhook != nil { return .consentBoth }
        return recordAudio ? .consentRecording : .consentWebhook
    }
    func authorize() { gate.lock(); if !finalized { allowed = true }; gate.unlock() }
    func revoke() {
        gate.lock(); allowed = false; incoming.removeAll(); outgoing.removeAll(); turns.removeAll(); gate.unlock()
    }
    func append(_ bytes: [UInt8], uplink: Bool) {
        guard recordAudio, bytes.count == 640 else { return }
        gate.lock(); defer { gate.unlock() }
        guard allowed, !finalized else { return }
        if uplink {
            if outgoing.count + bytes.count <= limit { outgoing.append(contentsOf: bytes) }
        } else if incoming.count + bytes.count <= limit { incoming.append(contentsOf: bytes) }
    }
    func addTurn(_ heard: String, reply: LocalReceptionPolicy.Reply) {
        gate.lock(); defer { gate.unlock() }
        guard allowed, !finalized, turns.count < 180 else { return }
        let clean = reply == .noSensitive ? "（涉及敏感信息，已省略）" : String(heard.prefix(600))
        turns.append("来电者：" + clean + "\n助理：" + reply.text)
    }
    static var directory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("SIM-AI-Assistant/CallRecordings", isDirectory: true)
    }
    /// Returns a fixed, non-content status. No audio/text/URL is logged.
    func finish() async -> String {
        let payload = take()
        guard let payload else { return "未取得同意：未保存、未转发" }
        let text = "【SIM AI 本地电话接待】\n时间：" + began.formatted() + "\n通话识别文字（可能有误）：\n" + payload.2.joined(separator: "\n\n")
        var statuses: [String] = []
        if recordAudio {
            do {
                let fm = FileManager.default
                let dir = Self.directory.appendingPathComponent(identifier, isDirectory: true)
                try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try Self.write(Self.wav(payload.0), to: dir.appendingPathComponent("caller.wav"))
                try Self.write(Self.wav(payload.1), to: dir.appendingPathComponent("assistant.wav"))
                try Self.write(Data(text.utf8), to: dir.appendingPathComponent("transcript.txt"))
                statuses.append("双向录音和识别文字已保存")
            } catch { statuses.append("本地保存失败，请检查存储权限或空间") }
        }
        if let webhook {
            if payload.2.isEmpty { statuses.append("无可发送文字") }
            else { statuses.append(await Self.send(text, settings: webhook) ? "飞书文字发送成功" : "飞书发送失败（未自动重试）") }
        }
        return statuses.joined(separator: "；")
    }
    private func take() -> (Data, Data, [String])? {
        gate.lock(); defer { gate.unlock() }
        guard !finalized else { return nil }
        finalized = true
        guard allowed else { return nil }
        let result = (incoming, outgoing, turns)
        incoming.removeAll(); outgoing.removeAll(); turns.removeAll()
        return result
    }
    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func wav(_ pcm: Data) -> Data {
        var d = Data()
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + pcm.count))
        d.append(contentsOf: "WAVEfmt ".utf8); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: "data".utf8); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static func send(_ text: String, settings: FeishuWebhookSettings) async -> Bool {
        guard FeishuWebhookSettings.validWebhook(settings.webhook), let url = URL(string: settings.webhook.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        // Conservative UTF-8-size bound for the Feishu text message.
        var bounded = ""
        for ch in text {
            if bounded.utf8.count + String(ch).utf8.count > 12_000 { bounded += "\n（文字过长，已截断）"; break }
            bounded.append(ch)
        }
        var payload: [String: Any] = ["msg_type": "text", "content": ["text": bounded]]
        if !settings.signingSecret.isEmpty {
            let timestamp = String(Int(Date().timeIntervalSince1970))
            let key = SymmetricKey(data: Data((timestamp + "\n" + settings.signingSecret).utf8))
            payload["timestamp"] = timestamp
            payload["sign"] = Data(HMAC<SHA256>.authenticationCode(for: Data(), using: key)).base64EncodedString()
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 10
        request.httpBody = body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return (result["code"] as? Int ?? result["StatusCode"] as? Int) == 0
        } catch { return false }
    }
}
#endif
