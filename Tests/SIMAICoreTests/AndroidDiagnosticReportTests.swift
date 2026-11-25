import XCTest
@testable import SIMAICore
final class AndroidDiagnosticReportTests: XCTestCase {
    func testAllowedPhoneLogsOnly() {
        let ok = #"{"wallMs":1000000,"elapsedMs":1000,"uptimeMs":900,"event":"SCREEN_OFF","detail":"interactive=false idle=true"}"#
        let bad = #"{"wallMs":1000000,"elapsedMs":1000,"uptimeMs":900,"event":"SCREEN_OFF","detail":"phone=12345678901"}"#
        XCTAssertEqual(AndroidDiagnosticEntry.parse(ok + "\n" + bad).count, 1)
        XCTAssertEqual(AndroidDiagnosticReport.extractFields("mWakefulness=Asleep\nmBatteryLevel=80\naccount=secret", keys: ["mWakefulness","mBatteryLevel"]), ["mWakefulness":"Asleep","mBatteryLevel":"80"])
    }
    func testWakeErrors() {
        XCTAssertEqual(AndroidWakeResult.classify(exit: 0, output: "Starting service: Intent {}\nError: Permission Denial"), "PHONE_MONITOR_WAKE_PERMISSION_DENIED")
        XCTAssertEqual(AndroidWakeResult.classify(exit: 0, output: "Starting service: Intent {}"), "PHONE_MONITOR_WAKE_REQUESTED")
        XCTAssertEqual(AndroidWakeResult.classify(exit: 1, output: "ForegroundServiceStartNotAllowedException"), "PHONE_MONITOR_WAKE_BACKGROUND_RESTRICTED")
    }
}
