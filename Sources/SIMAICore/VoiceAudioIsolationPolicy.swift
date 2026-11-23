import Foundation

/// Only a web view with both live capture and a confirmed per-page output
/// selection may auto-answer in video-safe mode. This ensures that desktop
/// video/audio cannot be silently used as the phone's GPT return path.
public enum VoiceAudioIsolationPolicy {
    public static func browserReady(
        embedded: Bool,
        microphoneCapturing: Bool,
        isolatedMicrophoneVerified: Bool,
        isolationEnabled: Bool,
        isolatedMediaRouted: Bool
    ) -> Bool {
        if !embedded { return true }
        guard microphoneCapturing && isolatedMicrophoneVerified else { return false }
        return !isolationEnabled || isolatedMediaRouted
    }
}
