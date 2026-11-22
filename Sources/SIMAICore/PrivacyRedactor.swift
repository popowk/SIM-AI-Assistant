import Foundation

public enum PrivacyRedactor {
    private static let masks: [(String, String)] = [
        // Bearer tokens and OpenAI-like keys: redact long secrets without inspecting credentials.
        (#"(?i)\bBearer\s+[A-Za-z0-9_\.\-]{8,}\b"#, "[REDACTED_TOKEN]"),
        (#"\bsk-[A-Za-z0-9_-]{8,}\b"#, "[REDACTED_TOKEN]"),
        (#"(?i)\b(api[_-]?key|access[_-]?token|authorization)\s*[:=]\s*[\"']?[^\s\"']+"#, "[REDACTED_CREDENTIAL]"),
        (#"(?i)\b[A-F0-9]{2}(?:[:-][A-F0-9]{2}){5}\b"#, "[REDACTED_MAC]"),
        (#"(?i)\b[\w.%+\-]+@[\w.\-]+\.[A-Z]{2,}\b"#, "[REDACTED_EMAIL]"),
        // Mainland China cellular (11 digits), optional country prefix.
        (#"(?<!\d)(?:\+?86[ -]?)?1[3-9]\d{9}(?!\d)"#, "[REDACTED_PHONE]"),
        // North American numbers with optional +1 and common separators.
        (#"(?<!\d)(?:\+1[ .-]?)?\(?[2-9]\d{2}\)?[ .-]?[2-9]\d{2}[ .-]?\d{4}(?!\d)"#, "[REDACTED_PHONE]")
    ]

    public static func clean(_ value: String) -> String {
        var result = value
        for (pattern, replacement) in masks {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            result = expression.stringByReplacingMatches(in: result,
                range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        return result
    }
}
