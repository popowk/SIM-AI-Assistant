import XCTest
@testable import SIMAICore
final class IsolatedReturnTests: XCTestCase {
    func testOnlyFullyVerifiedIsolatedReturnIsAllowed() {
        for mask in 0..<16 {
            XCTAssertEqual(VoiceAudioIsolationPolicy.canForwardIsolated(
                physicalDefaultOutput: mask & 1 != 0,
                microphoneCapturing: mask & 2 != 0,
                microphoneVerified: mask & 4 != 0,
                mediaRouted: mask & 8 != 0), mask == 15)
        }
    }
}
