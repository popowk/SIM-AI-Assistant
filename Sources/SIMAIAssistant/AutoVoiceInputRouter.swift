#if os(macOS)
import Foundation
import CoreAudio

/// Reversible macOS default-input selection for an already-authorized
/// ChatGPT Voice session. Does not change app-specific browser mic selection.
final class AutoVoiceInputRouter {
    private static let previousUIDKey = "SIMAI_AutoVoiceInputOriginalUID"
    private static let targetName = "BlackHole 2ch"
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultInput() -> AudioDeviceID? {
        var p = address(kAudioHardwarePropertyDefaultInputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &p, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    private static func devices() -> [AudioDeviceID] {
        var p = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &p, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var items = [AudioDeviceID](repeating: 0,
                                    count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status: OSStatus = items.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(systemObject, &p, 0, nil, &size, base)
        }
        return status == noErr ? items : []
    }

    private static func stringValue(_ device: AudioDeviceID,
                                    selector: AudioObjectPropertySelector) -> String? {
        var p = address(selector)
        var raw: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &p, 0, nil, &size, &raw) == noErr,
              let raw else { return nil }
        return raw as String
    }

    private static func uid(_ id: AudioDeviceID) -> String? {
        stringValue(id, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func target() -> AudioDeviceID? {
        let matches = devices().filter {
            stringValue($0, selector: kAudioObjectPropertyName)?
                .caseInsensitiveCompare(targetName) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func setInput(_ id: AudioDeviceID) -> Bool {
        var p = address(kAudioHardwarePropertyDefaultInputDevice)
        var desired = id
        return AudioObjectSetPropertyData(systemObject, &p, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &desired) == noErr
            && defaultInput() == id
    }

    @discardableResult
    func activate() -> String {
        guard let target = Self.target() else { return "INPUT_BLACKHOLE2_MISSING" }
        guard let current = Self.defaultInput() else { return "INPUT_DEFAULT_UNAVAILABLE" }
        let saved = UserDefaults.standard.string(forKey: Self.previousUIDKey)
        if current == target {
            return saved == nil ? "INPUT_ALREADY_SELECTED" : "INPUT_ALREADY_MANAGED"
        }
        if saved != nil {
            // The user chose a different input during our session.
            UserDefaults.standard.removeObject(forKey: Self.previousUIDKey)
            return "INPUT_USER_CHANGED"
        }
        guard let priorUID = Self.uid(current), !priorUID.isEmpty else {
            return "INPUT_PREVIOUS_UNKNOWN"
        }
        UserDefaults.standard.set(priorUID, forKey: Self.previousUIDKey)
        guard Self.setInput(target) else {
            UserDefaults.standard.removeObject(forKey: Self.previousUIDKey)
            return "INPUT_SWITCH_FAILED"
        }
        return "INPUT_ACTIVE"
    }

    @discardableResult
    func restore() -> String {
        guard let previousUID = UserDefaults.standard.string(forKey: Self.previousUIDKey) else {
            return "INPUT_NOT_OWNED"
        }
        guard let target = Self.target(), let current = Self.defaultInput() else {
            // Keep recovery intent if device was merely disconnected.
            return "INPUT_TARGET_UNAVAILABLE"
        }
        guard current == target else {
            UserDefaults.standard.removeObject(forKey: Self.previousUIDKey)
            return "INPUT_USER_CHANGED"
        }
        guard let original = Self.devices().first(where: { Self.uid($0) == previousUID }) else {
            // Preserve the saved UID for a later retry when USB mic returns.
            return "INPUT_PREVIOUS_DISCONNECTED"
        }
        guard Self.setInput(original) else { return "INPUT_RESTORE_FAILED" }
        UserDefaults.standard.removeObject(forKey: Self.previousUIDKey)
        return "INPUT_RESTORED"
    }

    func recoverPreviousSession() -> String { restore() }
}
#endif
