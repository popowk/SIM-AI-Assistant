import Foundation

/// Only fixed status codes are allowed into privacy-safe diagnostic logs.
/// Never copy arbitrary socket messages, paths or shell output into the UI.
public enum PhoneAudioProtocol {
    /// Parses only the two anonymized Android helper fields emitted before
    /// its socket server becomes available. Rejects arbitrary adb/shell text,
    /// device identifiers, stack traces and session secrets.
    public static func helperExitStatus(_ output: String) -> String {
        func valid(_ text: String) -> Bool {
            (2...60).contains(text.count) &&
            text.utf8.allSatisfy { c in
                (c >= 65 && c <= 90) || (c >= 97 && c <= 122) ||
                (c >= 48 && c <= 57) || c == 95
            }
        }
        guard output.utf8.count <= 4096 else { return "ANDROID_HELPER_EXIT_UNKNOWN" }
        var code: String?
        var stage = "UNKNOWN"
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("SIMAI error=") {
                let value = String(line.dropFirst("SIMAI error=".count))
                if valid(value) { code = value.uppercased() }
            } else if line.hasPrefix("SIMAI stage=") {
                let value = String(line.dropFirst("SIMAI stage=".count))
                if valid(value) { stage = value.uppercased() }
            }
        }
        guard let code else { return "ANDROID_HELPER_EXIT_UNKNOWN" }
        return "ANDROID_HELPER_EXIT_\(stage)_\(code)"
    }

    public static func handshakeStatus(_ response: String?) -> String {
        guard let response else { return "AUDIO_HANDSHAKE_NO_RESPONSE" }
        if response == "OK" { return "OK" }
        guard response.hasPrefix("ERR ") else { return "AUDIO_HANDSHAKE_UNEXPECTED" }
        let code = String(response.dropFirst(4))
        guard (2...64).contains(code.count),
              code.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) || $0 == 95 })
        else { return "AUDIO_HANDSHAKE_UNEXPECTED" }
        return "ANDROID_\(code)"
    }
}
