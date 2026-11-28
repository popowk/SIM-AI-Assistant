import Foundation

public struct WiFiDiscoveryCandidate: Hashable, Sendable {
    public let host: String
    public let pin: String
    public init?(host: String, pin: String) {
        guard BridgeRetryPolicy.validWirelessEndpoint(host + ":18766"),
              !host.hasPrefix("127."), !host.hasPrefix("169.254."),
              pin.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
        self.host = host; self.pin = pin
    }

    /// Never adopt a different certificate from a broadcast. Retain the last
    /// verified address as fallback; rotate matching hints after failures.
    public static func nextHost(trustedPin: String, current: String, failed: Bool,
                                candidates: [Self]) -> String? {
        let hosts = Array(Set(candidates.filter { $0.pin == trustedPin }.map(\.host))).sorted()
        guard !hosts.isEmpty else { return nil }
        if current.isEmpty { return hosts.first }
        guard failed else { return nil }
        if let index = hosts.firstIndex(of: current) {
            return hosts.count > 1 ? hosts[(index + 1) % hosts.count] : nil
        }
        return hosts.first
    }
}
