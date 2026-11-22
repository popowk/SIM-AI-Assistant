import Foundation

public enum DiagnosticLevel: String, Codable, CaseIterable {
    case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR"
}

public enum DiagnosticModule: String, Codable {
    case system = "System", bluetooth = "Bluetooth", call = "Call"
    case audio = "Audio", voice = "Voice", diagnostic = "Diagnostic"
}

public enum SIMErrorCode: String, Codable {
    case bluetoothUnavailable = "BT-1001"
    case bluetoothNotPaired = "BT-1002"
    case bluetoothHFPUnverified = "BT-1003"
    case callUnsupported = "CALL-1001"
    case invalidCallTransition = "CALL-1002"
    case audioEnumerationFailed = "AUDIO-2001"
    case microphoneDenied = "AUDIO-2002"
    case audioTestFailed = "AUDIO-2003"
    case virtualAudioUnavailable = "AUDIO-2004"
    case voiceManualOnly = "VOICE-3001"
    case permissionDenied = "SYS-4001"
    case exportFailed = "SYS-4002"
}

public struct DiagnosticEvent: Codable, Identifiable, Equatable {
    public var id: UUID
    public var timestamp: Date
    public var sessionID: String
    public var level: DiagnosticLevel
    public var module: DiagnosticModule
    public var code: String?
    public var message: String
    public var details: [String: String]

    public init(id: UUID = UUID(), timestamp: Date = Date(), sessionID: String,
                level: DiagnosticLevel, module: DiagnosticModule, code: String? = nil,
                message: String, details: [String: String] = [:]) {
        self.id = id; self.timestamp = timestamp; self.sessionID = sessionID
        self.level = level; self.module = module; self.code = code
        self.message = message; self.details = details
    }

    public func sanitized() -> DiagnosticEvent {
        var result = self
        result.sessionID = PrivacyRedactor.clean(sessionID)
        result.message = PrivacyRedactor.clean(message)
        result.code = code.map(PrivacyRedactor.clean)
        result.details = details.mapValues(PrivacyRedactor.clean)
        // Keys must be developer-supplied, never user-provided input.
        return result
    }
}

public struct SystemSnapshot: Codable {
    public var appVersion: String
    public var build: String
    public var osVersion: String
    public var architecture: String
    public var capturedAt: Date
    public init(appVersion: String, build: String, osVersion: String,
                architecture: String, capturedAt: Date = Date()) {
        self.appVersion = appVersion; self.build = build
        self.osVersion = osVersion; self.architecture = architecture
        self.capturedAt = capturedAt
    }
}

public struct BluetoothDeviceSnapshot: Codable, Identifiable {
    public var id: String
    public var displayName: String
    public var connected: Bool
    public var targetCandidate: Bool
    public init(id: String, displayName: String, connected: Bool, targetCandidate: Bool) {
        self.id = id; self.displayName = displayName
        self.connected = connected; self.targetCandidate = targetCandidate
    }
}

public struct BluetoothSnapshot: Codable {
    public var scanSucceeded: Bool
    public var devices: [BluetoothDeviceSnapshot]
    public var hfpVerified: Bool
    public var note: String
    public init(scanSucceeded: Bool = false, devices: [BluetoothDeviceSnapshot] = [],
                hfpVerified: Bool = false, note: String = "仅检查已配对设备，不能证明 HFP 可用") {
        self.scanSucceeded = scanSucceeded; self.devices = devices
        self.hfpVerified = hfpVerified; self.note = note
    }
    public func exportSafe() -> BluetoothSnapshot {
        BluetoothSnapshot(scanSucceeded: scanSucceeded, devices: devices.enumerated().map { index, item in
            BluetoothDeviceSnapshot(id: "BT-DEVICE-\(index + 1)", displayName: "蓝牙设备 \(index + 1)",
                                    connected: item.connected, targetCandidate: item.targetCandidate)
        }, hfpVerified: hfpVerified, note: note)
    }
}

public struct AudioDeviceSnapshot: Codable, Identifiable {
    public var id: String
    public var displayName: String
    public var sampleRate: Double?
    public var isDefaultInput: Bool
    public var isDefaultOutput: Bool
    public init(id: String, displayName: String, sampleRate: Double? = nil,
                isDefaultInput: Bool = false, isDefaultOutput: Bool = false) {
        self.id = id; self.displayName = displayName
        self.sampleRate = sampleRate; self.isDefaultInput = isDefaultInput
        self.isDefaultOutput = isDefaultOutput
    }
}

public struct AudioSnapshot: Codable {
    public var devices: [AudioDeviceSnapshot]
    public var microphonePermission: String
    public var lastProbePeak: Double?
    public var blackHoleDetected: Bool
    public init(devices: [AudioDeviceSnapshot] = [], microphonePermission: String = "unknown",
                lastProbePeak: Double? = nil, blackHoleDetected: Bool = false) {
        self.devices = devices; self.microphonePermission = microphonePermission
        self.lastProbePeak = lastProbePeak; self.blackHoleDetected = blackHoleDetected
    }
    public func exportSafe() -> AudioSnapshot {
        AudioSnapshot(devices: devices.enumerated().map { index, item in
            AudioDeviceSnapshot(id: "AUDIO-DEVICE-\(index + 1)", displayName: "音频设备 \(index + 1)",
                                sampleRate: item.sampleRate, isDefaultInput: item.isDefaultInput,
                                isDefaultOutput: item.isDefaultOutput)
        }, microphonePermission: microphonePermission, lastProbePeak: lastProbePeak,
        blackHoleDetected: blackHoleDetected)
    }
}
