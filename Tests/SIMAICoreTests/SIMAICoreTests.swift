import Foundation
import XCTest
@testable import SIMAICore

final class SIMAICoreTests: XCTestCase {

    func testAudioHelperEarlyExitReportsOnlySafeCodes() {
        XCTAssertEqual(
            PhoneAudioProtocol.helperExitStatus("SIMAI status=error\nSIMAI error=ANDROID_IllegalStateException\nSIMAI stage=SERVE\n"),
            "ANDROID_HELPER_EXIT_SERVE_ANDROID_ILLEGALSTATEEXCEPTION")
        XCTAssertEqual(PhoneAudioProtocol.helperExitStatus("adb: permission denied"),
                       "ANDROID_HELPER_EXIT_UNKNOWN")
        XCTAssertEqual(PhoneAudioProtocol.helperExitStatus("SIMAI error=secret@127.0.0.1\n"),
                       "ANDROID_HELPER_EXIT_UNKNOWN")
        XCTAssertEqual(PhoneAudioProtocol.helperExitStatus("SIMAI error=API_MISSING\n"),
                       "ANDROID_HELPER_EXIT_UNKNOWN_API_MISSING")
    }

    func testLiveAudioHandshakeDistinguishesErrors() {
        XCTAssertEqual(PhoneAudioProtocol.handshakeStatus("OK"), "OK")
        XCTAssertEqual(PhoneAudioProtocol.handshakeStatus("ERR NOT_IN_CALL"),
                       "ANDROID_NOT_IN_CALL")
        XCTAssertEqual(PhoneAudioProtocol.handshakeStatus("ERR INIT_UPLINK_INVOKE_PERMISSION"),
                       "ANDROID_INIT_UPLINK_INVOKE_PERMISSION")
        XCTAssertEqual(PhoneAudioProtocol.handshakeStatus(nil),
                       "AUDIO_HANDSHAKE_NO_RESPONSE")
        XCTAssertEqual(PhoneAudioProtocol.handshakeStatus("ERR token=abc123"),
                       "AUDIO_HANDSHAKE_UNEXPECTED")
        XCTAssertEqual(PhoneAudioProtocol.handshakeStatus("stacktrace private-info"),
                       "AUDIO_HANDSHAKE_UNEXPECTED")
    }

    func testBridgeRetryBackoffIsBounded() {
        XCTAssertEqual(BridgeRetryPolicy.delay(after: 0), 2)
        XCTAssertEqual(BridgeRetryPolicy.delay(after: 1), 2)
        XCTAssertEqual(BridgeRetryPolicy.delay(after: 2), 4)
        XCTAssertEqual(BridgeRetryPolicy.delay(after: 3), 8)
        XCTAssertEqual(BridgeRetryPolicy.delay(after: 4), 16)
        XCTAssertEqual(BridgeRetryPolicy.delay(after: 5), 30)
        XCTAssertEqual(BridgeRetryPolicy.delay(after: 50), 30)
    }

    func testWirelessReconnectAddressIsStrictlyValidated() {
        XCTAssertTrue(BridgeRetryPolicy.validWirelessEndpoint("192.168.2.20:5555"))
        XCTAssertTrue(BridgeRetryPolicy.validWirelessEndpoint("10.0.0.6:43321"))
        XCTAssertFalse(BridgeRetryPolicy.validWirelessEndpoint("192.168.2.300:5555"))
        XCTAssertFalse(BridgeRetryPolicy.validWirelessEndpoint("192.168.2.20:0"))
        XCTAssertFalse(BridgeRetryPolicy.validWirelessEndpoint("224.2.1.5:5555"))
        XCTAssertFalse(BridgeRetryPolicy.validWirelessEndpoint("1.2.3.4:5555;rm -rf /"))
        XCTAssertFalse(BridgeRetryPolicy.validWirelessEndpoint("adb-phone.local:5555"))
        XCTAssertFalse(BridgeRetryPolicy.validWirelessEndpoint(""))
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


    func testCleanupDeletesOnlyOldEventFilesAndPreservesOtherFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LogStore(directory: directory)
        let old = directory.appendingPathComponent("events-20260101.jsonl")
        let recent = directory.appendingPathComponent("events-20261120.jsonl")
        let today = directory.appendingPathComponent("events-20261122.jsonl")
        let unrelated = directory.appendingPathComponent("unrelated.txt")
        for url in [old, recent, today, unrelated] {
            try "test-data".write(to: url, atomically: true, encoding: .utf8)
        }
        let now = ISO8601DateFormatter().date(from: "2026-11-22T12:00:00Z")!
        let preview = try store.previewCleanup(olderThanDays: 7, referenceDate: now)
        XCTAssertEqual(preview.fileCount, 1)
        XCTAssertEqual(preview.totalBytes, 9)
        let removed = try store.cleanup(olderThanDays: 7, referenceDate: now)
        XCTAssertEqual(removed, preview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: today.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCleanupRejectsInvalidRetentionDays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LogStore(directory: directory)
        XCTAssertThrowsError(try store.previewCleanup(olderThanDays: 0))
        XCTAssertThrowsError(try store.cleanup(olderThanDays: -1))
    }

    func testClearAllAppLogsIncludesTodayButPreservesUnrelatedFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LogStore(directory: folder)
        let older = folder.appendingPathComponent("events-20261101.jsonl")
        let today = folder.appendingPathComponent("events-20261122.jsonl")
        let unrelated = folder.appendingPathComponent("readme.txt")
        for file in [older, today, unrelated] {
            try "hello".write(to: file, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try store.previewAllLogs().fileCount, 2)
        let removed = try store.clearAllLogs()
        XCTAssertEqual(removed.fileCount, 2)
        XCTAssertEqual(removed.totalBytes, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: older.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: today.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(try store.readRecent().count, 0)
    }

    func testADBFileSnapshotFreshnessAndStaleRejection() throws {
        let body = """
        {"schema":1,"session":"service-1","running":true,"state":"OFFHOOK","seq":1,
         "updatedAt":1000000,
         "events":[{"seq":1,"state":"OFFHOOK","at":999990}]}
        """
        let snapshot = try JSONDecoder().decode(PhoneBridgeSnapshot.self, from: Data(body.utf8))
        XCTAssertTrue(snapshot.isFresh(referenceMilliseconds: 1_000_010))
        XCTAssertTrue(snapshot.isFresh(referenceMilliseconds: 1_090_000))
        XCTAssertFalse(snapshot.isFresh(referenceMilliseconds: 1_090_001))
        XCTAssertFalse(snapshot.isFresh(referenceMilliseconds: 999_999))
        let legacy = """
        {"schema":1,"session":"old","running":true,"state":"IDLE","seq":0,"events":[]}
        """
        let older = try JSONDecoder().decode(PhoneBridgeSnapshot.self, from: Data(legacy.utf8))
        XCTAssertNil(older.updatedAt)
        XCTAssertFalse(older.isFresh(referenceMilliseconds: 1_000_010))
    }

    func testHTTPAndPrivateFileSnapshotsShareOneCursor() throws {
        let json = """
        {"schema":1,"session":"same-service","running":true,"state":"OFFHOOK","seq":2,
         "updatedAt":1000000,
         "events":[{"seq":1,"state":"RINGING","at":1000},
                   {"seq":2,"state":"OFFHOOK","at":2000}]}
        """
        let file = """
        {"schema":1,"session":"same-service","running":true,"state":"IDLE","seq":3,
         "updatedAt":1000100,
         "events":[{"seq":1,"state":"RINGING","at":1000},
                   {"seq":2,"state":"OFFHOOK","at":2000},
                   {"seq":3,"state":"IDLE","at":3000}]}
        """
        let decoder = JSONDecoder()
        let a = try decoder.decode(PhoneBridgeSnapshot.self, from: Data(json.utf8))
        let b = try decoder.decode(PhoneBridgeSnapshot.self, from: Data(file.utf8))
        var cursor = PhoneBridgeCursor()
        XCTAssertEqual(cursor.consume(a).map(\.state), ["RINGING", "OFFHOOK"])
        XCTAssertEqual(cursor.consume(b).map(\.state), ["IDLE"])
        XCTAssertEqual(cursor.consume(a).count, 0)
        XCTAssertEqual(cursor.consume(b).count, 0)
    }

    func testPhoneBridgeProtocolFiltersDuplicateAndUnknownEvents() throws {
        let body = """
        {"schema":1,"session":"abc","running":true,"state":"RINGING","seq":4,
         "events":[{"seq":1,"state":"IDLE","at":1763812000000},
                   {"seq":3,"state":"RINGING","at":1763812001000},
                   {"seq":4,"state":"IGNORED","at":1763812002000}]}
        """
        let decoded = try JSONDecoder().decode(PhoneBridgeSnapshot.self, from: Data(body.utf8))
        XCTAssertEqual(decoded.session, "abc")
        XCTAssertEqual(decoded.newEvents(after: 1).map(\.state), ["RINGING"])
        XCTAssertEqual(decoded.newEvents(after: 3).count, 0)
    }


    func testBridgeCursorDoesNotReplayEventsAfterUSBReconnect() throws {
        let first = """
        {"schema":1,"session":"same-android-session","running":true,"state":"OFFHOOK","seq":3,
         "events":[{"seq":1,"state":"IDLE","at":1000},
                   {"seq":2,"state":"RINGING","at":2000},
                   {"seq":3,"state":"OFFHOOK","at":3000}]}
        """
        let second = """
        {"schema":1,"session":"same-android-session","running":true,"state":"IDLE","seq":4,
         "events":[{"seq":1,"state":"IDLE","at":1000},
                   {"seq":2,"state":"RINGING","at":2000},
                   {"seq":3,"state":"OFFHOOK","at":3000},
                   {"seq":4,"state":"IDLE","at":4000}]}
        """
        let decoder = JSONDecoder()
        var cursor = PhoneBridgeCursor()
        let a = try decoder.decode(PhoneBridgeSnapshot.self, from: Data(first.utf8))
        let b = try decoder.decode(PhoneBridgeSnapshot.self, from: Data(second.utf8))
        XCTAssertEqual(cursor.consume(a).map(\.state), ["IDLE", "RINGING", "OFFHOOK"])
        XCTAssertEqual(cursor.lastSequence, 3)
        // Mimic ADB reconnect while Android monitor service/session stays alive.
        XCTAssertEqual(cursor.consume(b).map(\.state), ["IDLE"])
        XCTAssertEqual(cursor.consume(b).count, 0)
        XCTAssertEqual(cursor.lastSequence, 4)
    }

    func testBridgeCursorResetsOnlyWhenPhoneStartsNewServiceSession() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(PhoneBridgeSnapshot.self,
            from: Data(#"{"schema":1,"session":"old","running":true,"state":"OFFHOOK","seq":2,"events":[{"seq":1,"state":"RINGING","at":1000},{"seq":2,"state":"OFFHOOK","at":2000}]}"#.utf8))
        let fresh = try decoder.decode(PhoneBridgeSnapshot.self,
            from: Data(#"{"schema":1,"session":"new","running":true,"state":"IDLE","seq":1,"events":[{"seq":1,"state":"IDLE","at":3000}]}"#.utf8))
        var cursor = PhoneBridgeCursor()
        XCTAssertEqual(cursor.consume(old).count, 2)
        XCTAssertEqual(cursor.consume(fresh).map(\.state), ["IDLE"])
        XCTAssertEqual(cursor.session, "new")
        XCTAssertEqual(cursor.lastSequence, 1)
    }

    func testZIPContainsOnlyScrubbedAudioDeviceNames() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = try LogStore(directory: temp.appendingPathComponent("logs"))
        try store.append(DiagnosticEvent(sessionID: "test-0001", level: .error, module: .audio,
                                         code: SIMErrorCode.audioTestFailed.rawValue,
                                         message: "测试失败 13812345678"))
        let context = ExportContext(system: SystemSnapshot(appVersion: "0.1.0", build: "1", osVersion: "macOS", architecture: "arm64"),
            audio: AudioSnapshot(devices: [.init(id: "uid-raw", displayName: "John's AirPods")]),
            sessionID: "test-0001", recentError: nil, callState: "IDLE")
        let zip = temp.appendingPathComponent("result.zip")
        try DiagnosticsExporter(logs: store).export(context: context, to: zip)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
        // Validate with the platform unzip command if present, without requiring a shell pipeline.
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        command.arguments = ["-p", zip.path, "SIM-AI-Diagnostics/audio-devices.json"]
        let pipe = Pipe(); command.standardOutput = pipe
        try command.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(command.terminationStatus, 0)
        XCTAssertFalse(json.contains("John\'s AirPods"))
        XCTAssertFalse(json.contains("AA:BB"))
        XCTAssertTrue(json.contains("音频设备 1"))
    }
}
