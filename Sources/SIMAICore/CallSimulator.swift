import Foundation

public enum SimulatedCallState: String, Codable {
    case idle = "空闲", ringing = "模拟来电中", connected = "模拟通话中", ended = "已结束"
}

public struct CallTransition: Equatable {
    public let old: SimulatedCallState
    public let new: SimulatedCallState
    public let sessionID: String
}

public struct CallSimulator {
    public private(set) var state: SimulatedCallState = .idle
    public private(set) var sessionID: String = UUID().uuidString
    public private(set) var beganAt: Date?

    public init() {}

    @discardableResult
    public mutating func ring() throws -> CallTransition {
        guard state == .idle || state == .ended else { throw SimulatorError.invalidTransition }
        let old = state; state = .ringing; beganAt = Date(); sessionID = UUID().uuidString
        return .init(old: old, new: state, sessionID: sessionID)
    }

    @discardableResult
    public mutating func answer() throws -> CallTransition {
        guard state == .ringing else { throw SimulatorError.invalidTransition }
        let old = state; state = .connected
        return .init(old: old, new: state, sessionID: sessionID)
    }

    @discardableResult
    public mutating func hangup() throws -> CallTransition {
        guard state == .ringing || state == .connected else { throw SimulatorError.invalidTransition }
        let old = state; state = .ended
        return .init(old: old, new: state, sessionID: sessionID)
    }

    public enum SimulatorError: Error, LocalizedError {
        case invalidTransition
        public var errorDescription: String? { "当前模拟通话状态不支持此操作" }
    }
}

public enum TestFault: String, CaseIterable, Identifiable {
    case bluetoothDisconnect = "模拟蓝牙断连"
    case permissionDenied = "模拟权限拒绝"
    case audioInitialization = "模拟音频初始化失败"
    public var id: String { rawValue }
    public var code: SIMErrorCode {
        switch self {
        case .bluetoothDisconnect: return .bluetoothUnavailable
        case .permissionDenied: return .permissionDenied
        case .audioInitialization: return .audioTestFailed
        }
    }
    public var module: DiagnosticModule {
        switch self {
        case .bluetoothDisconnect: return .bluetooth
        case .permissionDenied: return .system
        case .audioInitialization: return .audio
        }
    }
}
