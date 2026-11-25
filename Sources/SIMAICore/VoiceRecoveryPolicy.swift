import Foundation

/// A single bounded recovery per call; do not restart just because both parties
/// are quiet. A missing verified route is different from audible caller PCM
/// with no recent GPT return. Wall time is checked by the periodic health tick.
public struct VoiceRecoveryPolicy {
    public private(set) var hasAttempted = false
    private var routeMissingSince: Date?
    private var callerUnansweredSince: Date?
    public init() {}
    public mutating func resetObservation() {
        routeMissingSince = nil
        callerUnansweredSince = nil
    }
    public mutating func observe(routeReady: Bool, callerRecentlyAudible: Bool,
                                 replyRecentlyAudible: Bool, now: Date) -> Bool {
        guard !hasAttempted else { return false }
        if routeReady { routeMissingSince = nil }
        else if routeMissingSince == nil { routeMissingSince = now }
        if callerRecentlyAudible && !replyRecentlyAudible {
            if callerUnansweredSince == nil { callerUnansweredSince = now }
        } else { callerUnansweredSince = nil }
        let missing = routeMissingSince.map { now.timeIntervalSince($0) >= 6 } ?? false
        let unanswered = callerUnansweredSince.map { now.timeIntervalSince($0) >= 12 } ?? false
        guard missing || unanswered else { return false }
        hasAttempted = true
        return true
    }
}
