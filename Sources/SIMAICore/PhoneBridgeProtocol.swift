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
            session = snapshot.session
            lastSequence = 0
        }
        let fresh = snapshot.newEvents(after: lastSequence)
        lastSequence = max(lastSequence, snapshot.seq)
        return fresh
    }
}
