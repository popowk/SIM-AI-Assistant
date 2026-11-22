import Foundation

/// Only fixed status codes are allowed into privacy-safe diagnostic logs.
/// Never copy arbitrary socket messages, paths or shell output into the UI.
public enum PhoneAudioProtocol {
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
