import Foundation

/// Allows GPT audio for a manually answered call that SIM AI actually saw
/// ringing. This NEVER gives the app permission to hang up that call.
public enum ManualPickupPolicy {
    public static func isSameTrackedCall(
        state: String,
        session: String,
        sequence: Int,
        ringSession: String,
        ringSequence: Int,
        automationEnabled: Bool,
        voiceStartedForRing: Bool,
        automaticAnswerAcknowledged: Bool
    ) -> Bool {
        automationEnabled && voiceStartedForRing &&
        !automaticAnswerAcknowledged &&
        state == "OFFHOOK" &&
        !ringSession.isEmpty && session == ringSession &&
        ringSequence > 0 && sequence == ringSequence + 1
    }
}
