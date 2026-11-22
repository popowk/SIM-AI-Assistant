#if os(macOS)
import Foundation
import CoreAudio
import AVFoundation
import AppKit
import SIMAICore

final class AudioInspector {
    private let savedInput: AudioDeviceID?
    private let savedOutput: AudioDeviceID?

    init() {
        self.savedInput = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        self.savedOutput = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func microphonePermission() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .restricted: return "系统限制"
        case .notDetermined: return "尚未请求"
        @unknown default: return "未知"
        }
    }

    func inspect() -> AudioSnapshot {
        let property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var address = property
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address,
                                             0, nil, &size) == noErr else {
            return AudioSnapshot(microphonePermission: Self.microphonePermission())
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let listStatus: OSStatus = ids.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                              0, nil, &size, baseAddress)
        }
        guard listStatus == noErr else {
            return AudioSnapshot(microphonePermission: Self.microphonePermission())
        }
        let currentInput = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let currentOutput = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let devices = ids.map { id in
            AudioDeviceSnapshot(id: String(id), displayName: Self.deviceName(id),
                sampleRate: Self.nominalRate(id), isDefaultInput: currentInput == id,
                isDefaultOutput: currentOutput == id)
        }
        return AudioSnapshot(devices: devices, microphonePermission: Self.microphonePermission(),
            blackHoleDetected: devices.contains { $0.displayName.localizedCaseInsensitiveContains("BlackHole") })
    }

    private static func deviceName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return "音频设备 \(id)" }
        return name as String
    }

    private static func nominalRate(_ id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr, device != 0 else { return nil }
        return device
    }

    /// Explicit recovery only. Never toggle Bluetooth or overwrite system audio settings automatically.
    func restoreStartupDefaults() -> [String] {
        var results: [String] = []
        if let savedInput {
            results.append("输入设备：\(Self.setDefaultDevice(savedInput, selector: kAudioHardwarePropertyDefaultInputDevice))")
        }
        if let savedOutput {
            results.append("输出设备：\(Self.setDefaultDevice(savedOutput, selector: kAudioHardwarePropertyDefaultOutputDevice))")
        }
        return results
    }

    private static func setDefaultDevice(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var mutableID = device
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, size, &mutableID)
        return status == noErr ? "恢复完成" : "失败（OSStatus \(status)）"
    }
}

final class MicrophoneLevelProbe {
    private var engine: AVAudioEngine?
    private var peak = 0.0
    private let mutex = NSLock()

    func run(completion: @escaping (Result<Double, Error>) -> Void) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            completion(.failure(NSError(domain: "SIMAI.Audio", code: 2003,
                userInfo: [NSLocalizedDescriptionKey: "输入音频设备采样率无效"])))
            return
        }
        mutex.lock(); peak = 0; mutex.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            var sum = 0.0
            let samples = channels[0]
            for i in 0..<frames {
                let value = Double(samples[i])
                sum += value * value
            }
            let rms = sqrt(sum / Double(frames))
            self.mutex.lock(); self.peak = max(self.peak, rms); self.mutex.unlock()
        }
        do {
            try engine.start()
            self.engine = engine
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                engine.stop()
                input.removeTap(onBus: 0)
                self.mutex.lock(); let observed = self.peak; self.mutex.unlock()
                self.engine = nil
                completion(.success(observed))
            }
        } catch {
            input.removeTap(onBus: 0)
            completion(.failure(error))
        }
    }
}
#endif
