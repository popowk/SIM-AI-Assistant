import Foundation
import XCTest
@testable import SIMAICore

final class SIMAICoreTests: XCTestCase {
    func testCallStateMachine() throws {
        var call = CallSimulator()
        XCTAssertThrowsError(try call.answer())
        let first = try call.ring()
        XCTAssertEqual(call.state, .ringing)
        XCTAssertEqual(first.new, .ringing)
        XCTAssertThrowsError(try call.ring())
        try call.answer()
        XCTAssertEqual(call.state, .connected)
        try call.hangup()
        XCTAssertEqual(call.state, .ended)
        try call.ring()
        XCTAssertEqual(call.state, .ringing)
    }

    func testPrivacyRedaction() {
        let raw = "phone +8613812345678 and 415-555-0199; MAC AA:BB:CC:DD:EE:FF; test@example.com; token sk-ABCDEFGHIJKLMN"
        let clean = PrivacyRedactor.clean(raw)
        XCTAssertFalse(clean.contains("13812345678"))
        XCTAssertFalse(clean.contains("415-555-0199"))
        XCTAssertFalse(clean.contains("AA:BB:CC"))
        XCTAssertFalse(clean.contains("test@example.com"))
        XCTAssertFalse(clean.contains("ABCDEFGHIJKLMN"))
        XCTAssertTrue(clean.contains("[REDACTED_PHONE]"))
        XCTAssertEqual(PrivacyRedactor.clean("2026-11-22 19:30:05"), "2026-11-22 19:30:05")
    }

    func testLogsSanitizedBeforeWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LogStore(directory: directory)
        let original = DiagnosticEvent(sessionID: "test-0001", level: .error, module: .call,
                                       message: "来电 13812345678 无法接听", details: ["reason": "test@example.com"])
        try store.append(original)
        let text = try store.readAllSafeLines()
        XCTAssertFalse(text.contains("13812345678"))
        XCTAssertFalse(text.contains("test@example.com"))
        XCTAssertEqual(try store.readRecent().count, 1)
    }

    func testRotationRemovesOldLogs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LogStore(directory: directory, maxAgeDays: 14)
        let old = directory.appendingPathComponent("events-20200101.jsonl")
        try "old\n".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: old.path)
        try store.prune()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testZIPContainsOnlyScrubbedDeviceNames() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = try LogStore(directory: temp.appendingPathComponent("logs"))
        try store.append(DiagnosticEvent(sessionID: "test-0001", level: .error, module: .audio,
                                         code: SIMErrorCode.audioTestFailed.rawValue,
                                         message: "测试失败 13812345678"))
        let context = ExportContext(system: SystemSnapshot(appVersion: "0.1.0", build: "1", osVersion: "macOS", architecture: "arm64"),
            bluetooth: BluetoothSnapshot(scanSucceeded: true, devices: [.init(id: "MAC-AA:BB:CC:DD:EE:FF", displayName: "私人手机", connected: true, targetCandidate: true)]),
            audio: AudioSnapshot(devices: [.init(id: "uid-raw", displayName: "John's AirPods")]),
            sessionID: "test-0001", recentError: nil, callState: .idle)
        let zip = temp.appendingPathComponent("result.zip")
        try DiagnosticsExporter(logs: store).export(context: context, to: zip)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
        // Validate with the platform unzip command if present, without requiring a shell pipeline.
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        command.arguments = ["-p", zip.path, "SIM-AI-Diagnostics/bluetooth-status.json"]
        let pipe = Pipe(); command.standardOutput = pipe
        try command.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(command.terminationStatus, 0)
        XCTAssertFalse(json.contains("私人手机"))
        XCTAssertFalse(json.contains("AA:BB"))
        XCTAssertTrue(json.contains("蓝牙设备 1"))
    }
}
