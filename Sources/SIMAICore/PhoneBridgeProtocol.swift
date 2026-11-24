import Foundation

/// Anonymous phone-state updates from SIM AI Companion over a local USB ADB tunnel.
/// No subscriber identifiers, phone numbers or conversation audio are represented.
public struct PhoneBridgeEvent: Codable, Equatable {
    public let seq: Int
    public let state: String
    public let at: Int64

    public var isKnownState: Bool {
        ["IDLE", "RINGING", "OFFHOOK"].contains(state)
    }
}

public struct PhoneBridgeSnapshot: Codable, Equatable {
    public let schema: Int
    public let session: String
    public let running: Bool
    public let state: String
    public let seq: Int
    public let events: [PhoneBridgeEvent]
    public let updatedAt: Int64?
    /// Only anonymous Android-side diagnostics; old APKs may omit these keys.
    public var answerPermissionGranted: Bool? = nil
    public var privateAnswerPollerActive: Bool? = nil
    public var adbBroadcastAnswerAvailable: Bool? = nil
    /// Current Android TelephonyManager state, as opposed to callback cache.
    public var realPhoneState: String? = nil
    public var realPhoneStateAt: Int64? = nil
    public var lastAnswerTransport: String? = nil
    public var orderedAnswerReplyAvailable: Bool? = nil
    public var privateAnswerSequence: Int? = nil
    public var privateAnswerResult: String? = nil
    public var shizukuReady: Bool? = nil
    public var wifiListening: Bool? = nil

    /// Private-file transport uses a periodically refreshed timestamp; this
    /// prevents a killed Android service's last snapshot appearing online.
    public func isFresh(referenceMilliseconds now: Int64, maxAgeMilliseconds: Int64 = 90_000,
                        maxFutureSkewMilliseconds: Int64 = 0) -> Bool {
        guard let updatedAt, updatedAt > 0, now > 0 else { return false }
        if updatedAt > now { return updatedAt - now <= maxFutureSkewMilliseconds }
        return now - updatedAt <= maxAgeMilliseconds
    }

    public func newEvents(after lastSequence: Int) -> [PhoneBridgeEvent] {
        guard schema == 1 else { return [] }
        return events.filter { $0.isKnownState && $0.seq > lastSequence }
            .sorted { $0.seq < $1.seq }
    }
}


/// Maintains exactly-once delivery across reconnects to the same Android session.
/// The cursor resets ONLY when the Android monitor service starts a genuinely new session.
public struct PhoneBridgeCursor {
    public private(set) var session: String = ""
    public private(set) var lastSequence: Int = 0

    public init() {}

    public mutating func consume(_ snapshot: PhoneBridgeSnapshot) -> [PhoneBridgeEvent] {
        guard snapshot.schema == 1, !snapshot.session.isEmpty else { return [] }
        if session != snapshot.session {
            // A first connection (or a restarted Android listener) can
            // return up to 64 historic call transitions. Establish a
            // baseline without treating those events as new live calls.
            // The current snapshot.state is still handled separately by Mac.
            session = snapshot.session
            lastSequence = snapshot.seq
            return []
        }
        let fresh = snapshot.newEvents(after: lastSequence)
        lastSequence = max(lastSequence, snapshot.seq)
        return fresh
    }
}
