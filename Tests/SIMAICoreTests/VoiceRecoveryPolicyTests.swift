import XCTest
import SIMAICore

final class VoiceRecoveryPolicyTests: XCTestCase {
    func testQuietCallDoesNotRestart() {
        var policy = VoiceRecoveryPolicy()
        let start = Date(timeIntervalSince1970: 100)
        for i in 0...30 {
            XCTAssertFalse(policy.observe(routeReady: true, callerRecentlyAudible: false,
                                         replyRecentlyAudible: false, now: start.addingTimeInterval(Double(i))))
        }
    }
    func testPersistentMissingRouteRestartsOnce() {
        var policy = VoiceRecoveryPolicy()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(policy.observe(routeReady: false, callerRecentlyAudible: false, replyRecentlyAudible: false, now: start))
        XCTAssertTrue(policy.observe(routeReady: false, callerRecentlyAudible: false, replyRecentlyAudible: false, now: start.addingTimeInterval(6)))
        XCTAssertFalse(policy.observe(routeReady: false, callerRecentlyAudible: false, replyRecentlyAudible: false, now: start.addingTimeInterval(30)))
    }
    func testCallerAudioWithNoReplyAndReplyReset() {
        var policy = VoiceRecoveryPolicy()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(policy.observe(routeReady: true, callerRecentlyAudible: true, replyRecentlyAudible: false, now: start))
        XCTAssertFalse(policy.observe(routeReady: true, callerRecentlyAudible: true, replyRecentlyAudible: true, now: start.addingTimeInterval(10)))
        XCTAssertFalse(policy.observe(routeReady: true, callerRecentlyAudible: true, replyRecentlyAudible: false, now: start.addingTimeInterval(11)))
        XCTAssertTrue(policy.observe(routeReady: true, callerRecentlyAudible: true, replyRecentlyAudible: false, now: start.addingTimeInterval(23)))
    }
}
