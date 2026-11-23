import Foundation

/// A disconnected phone PCM stream must release the Voice page only if
/// that stream belongs to a call initiated by the auto-answer state machine.
/// Manual browser sessions are not owned by the phone.
public enum AutoCallVoiceShutdownPolicy {
    public static func closeOnAudioEnd(reason: String,
                                       automaticAudioSession: Bool) -> Bool {
        automaticAudioSession && reason == "AUDIO_REMOTE_CLOSED"
    }

    public static func closeOnPhoneIdle(autoAnswerAcknowledged: Bool) -> Bool {
        autoAnswerAcknowledged
    }
}
