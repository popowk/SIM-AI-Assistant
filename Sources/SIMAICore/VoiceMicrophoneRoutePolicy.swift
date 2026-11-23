import Foundation

/// A live audio track verified in a ChatGPT subframe is valid evidence even
/// when the main frame never calls getUserMedia. Evidence expires promptly
/// if that frame stops reporting its live track.
public enum VoiceMicrophoneRoutePolicy {
    public static func verified(mainFrameCode: String,
                                childFrameLastSignalAge: TimeInterval?) -> Bool {
        if mainFrameCode == "BLACKHOLE2_CAPTURE_VERIFIED" { return true }
        guard let age = childFrameLastSignalAge else { return false }
        return age >= 0 && age < 8
    }
}
