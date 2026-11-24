import Foundation

/// Coordinates verified phone-state events without reading numbers or audio.
public struct AutoCallStateMachine {
    public enum Action: Equatable {
        case none, answerIncoming, openCallAudio, stopCallAudio
    }
    private var attemptedAnswer = false
    private var requestedAudio = false

    public init() {}

    /// Armed means the owner has prepared a voice service and local routing.
    /// The state machine cannot start or verify the official ChatGPT Voice UI.
    public mutating func update(state: String, armed: Bool) -> Action {
        if state == "IDLE" {
            let hadAudio = requestedAudio
            attemptedAnswer = false
            requestedAudio = false
            return hadAudio ? .stopCallAudio : .none
        }
        guard armed else { return .none }
        if state == "RINGING", !attemptedAnswer {
            attemptedAnswer = true
            return .answerIncoming
        }
        if state == "OFFHOOK", attemptedAnswer, !requestedAudio {
            requestedAudio = true
            return .openCallAudio
        }
        return .none
    }

    public mutating func reset() {
        attemptedAnswer = false
        requestedAudio = false
    }

    /// Explicitly tracks that an answer was commanded outside the state machine
    /// (e.g. by safety timer, Wi-Fi Shizuku, or local guarded shell),
    /// so the subsequent OFFHOOK state properly triggers openCallAudio.
    public mutating func markAnswerAttempted() {
        attemptedAnswer = true
    }
}
