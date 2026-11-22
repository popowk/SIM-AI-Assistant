#if os(macOS)
import Foundation
import Security

/// Sensitive bot credentials never belong in UserDefaults, diagnostics or
/// ADB command arguments. Only the user's local login Keychain stores them.
struct FeishuWebhookSettings: Codable {
    let webhook: String
    let signingSecret: String
    let enabled: Bool

    static func validWebhook(_ input: String) -> Bool {
        guard input.utf8.count <= 512,
              let parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(),
              host == "open.feishu.cn" || host == "open.larksuite.com",
              parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return false }
        return parts.path.range(of: "^/open-apis/bot/v2/hook/[A-Za-z0-9-]{8,100}$",
                                options: .regularExpression) != nil
    }
}

enum FeishuWebhookStore {
    private static let service = "com.simai.assistant.feishu-sms"
    private static let account = "desktop-webhook-settings"

    private static var attributes: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> FeishuWebhookSettings? {
        var query = attributes
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(FeishuWebhookSettings.self, from: data)
    }

    static func save(_ value: FeishuWebhookSettings) throws {
        guard FeishuWebhookSettings.validWebhook(value.webhook),
              value.signingSecret.utf8.count <= 256 else {
            throw NSError(domain: "SIMAI.Feishu", code: 1)
        }
        let data = try JSONEncoder().encode(value)
        var add = attributes
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updated = SecItemUpdate(attributes as CFDictionary,
                                        [kSecValueData as String: data] as CFDictionary)
            guard updated == errSecSuccess else {
                throw NSError(domain: "SIMAI.Keychain", code: Int(updated))
            }
        } else if status != errSecSuccess {
            throw NSError(domain: "SIMAI.Keychain", code: Int(status))
        }
    }
}
#endif
