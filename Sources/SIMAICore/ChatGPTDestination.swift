import Foundation

/// User-selected location for the official ChatGPT site. We never allow
/// non-ChatGPT hosts, insecure schemes, embedded credentials, or query tokens
/// to be persisted as an automatic Voice destination.
public enum ChatGPTDestination {
    public static let home = "https://chatgpt.com/"

    public static func validated(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 2048,
              let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "chatgpt.com",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.query == nil, components.fragment == nil,
              let url = components.url else { return nil }
        return url
    }
}
