#if os(macOS)
import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// Brief, anonymous level-only check of the ACTUAL BlackHole 2ch input.
/// The normal PCM HAL output callback being pulled does not prove another
/// client (including WebKit) can read the corresponding virtual microphone.
/// No samples, speech, or device identifiers are saved or exported.
enum BlackHoleInputProbe {
    struct Result {
        let code: String
        let peakRMS: Double
        let sampledFrames: Int
    }

    static func run(duration: TimeInterval = 2.0) -> Result {
        let devices = AudioInspector().inspect().devices.filter {
            $0.displayName.caseInsensitiveCompare("BlackHole 2ch") == .orderedSame
        }
        guard devices.count == 1, let raw = UInt32(devices[0].id) else {
            return .init(code: "BLACKHOLE2_LOOPBACK_DEVICE_MISSING",
                         peakRMS: 0, sampledFrames: 0)
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit else {
            return .init(code: "BLACKHOLE2_LOOPBACK_INPUT_UNIT_MISSING",
                         peakRMS: 0, sampledFrames: 0)
        }
        var selected = AudioDeviceID(raw)
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &selected, size) == noErr else {
            return .init(code: "BLACKHOLE2_LOOPBACK_SELECT_FAILED",
                         peakRMS: 0, sampledFrames: 0)
        }
        var current: AudioDeviceID = 0
        var currentSize = size
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &current, &currentSize) == noErr,
              current == selected else {
            return .init(code: "BLACKHOLE2_LOOPBACK_DEVICE_MISMATCH",
                         peakRMS: 0, sampledFrames: 0)
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32 else {
            return .init(code: "BLACKHOLE2_LOOPBACK_FORMAT_UNSUPPORTED",
                         peakRMS: 0, sampledFrames: 0)
        }
        let lock = NSLock()
        var peak = 0.0
        var framesObserved = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) {
            buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channelCount = min(2, Int(buffer.format.channelCount))
            guard frames > 0, channelCount > 0 else { return }
            var power = 0.0
            for frame in 0..<frames {
                for channel in 0..<channelCount {
                    let value = buffer.format.isInterleaved
                        ? channels[0][frame * Int(buffer.format.channelCount) + channel]
                        : channels[channel][frame]
                    let sample = Double(value)
                    power += sample * sample
                }
            }
            let rms = sqrt(power / Double(frames * channelCount))
            lock.lock()
            peak = max(peak, rms)
            framesObserved += frames
            lock.unlock()
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            return .init(code: "BLACKHOLE2_LOOPBACK_START_FAILED",
                         peakRMS: 0, sampledFrames: 0)
        }
        Thread.sleep(forTimeInterval: min(3, max(0.5, duration)))
        input.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let rms = peak
        let frames = framesObserved
        lock.unlock()
        let code = frames < 500 ? "BLACKHOLE2_LOOPBACK_NO_FRAMES"
            : rms >= 0.003 ? "BLACKHOLE2_LOOPBACK_PRESENT"
            : "BLACKHOLE2_LOOPBACK_SILENT"
        return .init(code: code, peakRMS: rms, sampledFrames: frames)
    }
}
#endif
