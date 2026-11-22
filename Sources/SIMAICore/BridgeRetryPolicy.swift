import Foundation

/// Bounded automatic retry scheduling for phone status tunnel failures.
/// Delays are short for the first failure but avoid continuous ADB port churn
/// when the phone is asleep, Wi-Fi debugging is unavailable, or a tunnel stalls.
public enum BridgeRetryPolicy {
    /// Accept only literal IPv4:port learned from an already authorized ADB device.
    /// No hostnames, URLs, shell arguments, broadcast/multicast or whitespace.
    public static func validWirelessEndpoint(_ value: String) -> Bool {
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let port = Int(fields[1]), (1...65535).contains(port),
              String(port) == String(fields[1]) else { return false }
        let octets = fields[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        for octet in octets {
            guard let n = Int(octet), (0...255).contains(n),
                  String(n) == String(octet) else { return false }
        }
        let first = Int(octets[0]) ?? 0
        return first > 0 && first < 224
    }

    /// ADB read-only discovery runs frequently only while disconnected.
    /// A healthy phone status bridge already proves the ADB transport works,
    /// so use a slower scan to avoid contending with live audio traffic.
    public static func adbScanInterval(authorizedDevices: Int,
                                        recentlySynced: Bool) -> TimeInterval {
        authorizedDevices == 1 && recentlySynced ? 45 : 12
    }

    public static func delay(after consecutiveFailures: Int) -> TimeInterval {
        let capped = min(5, max(1, consecutiveFailures))
        return TimeInterval(min(30, 2 * (1 << (capped - 1))))
    }
}
