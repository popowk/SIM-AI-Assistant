#if os(macOS)
import Foundation
import CoreAudio

/// Controlled, reversible *system default output* routing for ChatGPT Voice.
///
/// The call downlink and local monitor continue to use their own explicit
/// physical output device. This class NEVER changes the default input, system
/// alert output, per-app permission, or any hardware setting.
final class AutoVoiceOutputRouter {
    private static let restoreUIDKey = "SIMAI_AutoVoiceOutputOriginalUID"
    private static let targetName = "BlackHole 16ch"

    private static var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    private static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func currentDefaultOutput() -> AudioDeviceID? {
        var address = property(kAudioHardwarePropertyDefaultOutputDevice)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    private static func installedDevices() -> [AudioDeviceID] {
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status: OSStatus = ids.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, base)
        }
        return status == noErr ? ids : []
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector,
                                       device: AudioDeviceID) -> String? {
        var address = property(selector)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value as String
    }

    private static func name(_ device: AudioDeviceID) -> String? {
        stringProperty(kAudioObjectPropertyName, device: device)
    }

    private static func uid(_ device: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, device: device)
    }

    private static func isPhysicalOutput(_ device: AudioDeviceID) -> Bool {
        guard let name = name(device), !name.isEmpty else { return false }
        return !name.localizedCaseInsensitiveContains("BlackHole")
            && !name.localizedCaseInsensitiveContains("aggregate")
            && !name.localizedCaseInsensitiveContains("multi-output")
    }

    private static func target() -> AudioDeviceID? {
        let matches = installedDevices().filter {
            name($0)?.caseInsensitiveCompare(targetName) == .orderedSame
        }
        // Avoid accidentally routing private system audio to an ambiguous device.
        return matches.count == 1 ? matches[0] : nil
    }

    private static func setDefaultOutput(_ device: AudioDeviceID) -> Bool {
        var address = property(kAudioHardwarePropertyDefaultOutputDevice)
        var desired = device
        let status = AudioObjectSetPropertyData(systemObject, &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &desired)
        return status == noErr && currentDefaultOutput() == device
    }

    /// Returns only fixed diagnostic codes, never device identifiers or audio.
    @discardableResult
    func activate(physicalMonitorID: String) -> String {
        guard let blackHole16 = Self.target() else { return "ROUTE_BLACKHOLE16_MISSING" }
        guard let current = Self.currentDefaultOutput() else { return "ROUTE_NO_DEFAULT_OUTPUT" }
        let allDevices = Self.installedDevices()
        guard let selected = UInt32(physicalMonitorID),
              allDevices.contains(selected), Self.isPhysicalOutput(selected) else {
            return "ROUTE_MONITOR_PHYSICAL_REQUIRED"
        }

        // A manually chosen BlackHole is not our change to reverse.
        if current == blackHole16 {
            if UserDefaults.standard.string(forKey: Self.restoreUIDKey) != nil {
                return "ROUTE_ALREADY_MANAGED"
            }
            return "ROUTE_ALREADY_VIRTUAL_MANUAL"
        }

        // If the user manually changed the output after we routed it,
        // never override their choice or resurrect an earlier route.
        if UserDefaults.standard.string(forKey: Self.restoreUIDKey) != nil {
            UserDefaults.standard.removeObject(forKey: Self.restoreUIDKey)
            return "ROUTE_USER_CHANGED_OUTPUT"
        }

        let prior = Self.isPhysicalOutput(current) ? current : selected
        guard let restoreUID = Self.uid(prior), !restoreUID.isEmpty else {
            return "ROUTE_RESTORE_DEVICE_UNKNOWN"
        }
        // Persist FIRST: we can restore after a crash or forced quit.
        UserDefaults.standard.set(restoreUID, forKey: Self.restoreUIDKey)
        guard Self.setDefaultOutput(blackHole16) else {
            UserDefaults.standard.removeObject(forKey: Self.restoreUIDKey)
            return "ROUTE_CHANGE_FAILED"
        }
        return "ROUTE_ACTIVE"
    }

    /// Restores only the output that our own session changed. If the user
    /// changed output in System Settings, their newer preference wins.
    @discardableResult
    func restore() -> String {
        guard let previousUID = UserDefaults.standard.string(forKey: Self.restoreUIDKey) else {
            return "ROUTE_NOT_OWNED"
        }
        guard let blackHole16 = Self.target() else {
            UserDefaults.standard.removeObject(forKey: Self.restoreUIDKey)
            return "ROUTE_BLACKHOLE16_DISCONNECTED"
        }
        guard Self.currentDefaultOutput() == blackHole16 else {
            UserDefaults.standard.removeObject(forKey: Self.restoreUIDKey)
            return "ROUTE_USER_CHANGED_OUTPUT"
        }
        guard let previous = Self.installedDevices().first(where: { Self.uid($0) == previousUID }),
              Self.isPhysicalOutput(previous) else {
            // Do not send audio to an unknown replacement or silent device.
            UserDefaults.standard.removeObject(forKey: Self.restoreUIDKey)
            return "ROUTE_PREVIOUS_DEVICE_MISSING"
        }
        guard Self.setDefaultOutput(previous) else { return "ROUTE_RESTORE_FAILED" }
        UserDefaults.standard.removeObject(forKey: Self.restoreUIDKey)
        return "ROUTE_RESTORED"
    }

    /// Run once on launch: restores a previously app-managed output from a
    /// terminated/crashed session, without altering any other user setting.
    func recoverPreviousSession() -> String {
        guard UserDefaults.standard.string(forKey: Self.restoreUIDKey) != nil else {
            return "ROUTE_NOT_OWNED"
        }
        return restore()
    }
}
#endif
