import Foundation

/// Never substitute readiness of the other mode or fall back to it silently.
public enum PhoneTransportReadiness {
    public static func ready(wifi: Bool, adbAuthorized: Bool, authenticatedWiFi: Bool,
                             shizukuAuthorized: Bool, shizukuAudioReady: Bool) -> Bool {
        wifi ? authenticatedWiFi && shizukuAuthorized && shizukuAudioReady : adbAuthorized
    }
}
