import XCTest
@testable import SIMAICore

final class LocalCaptureConsentTests: XCTestCase {
    func testRevocationRemainsAvailableWithoutSpokenConsentPrompts() {
        XCTAssertTrue(LocalCaptureConsent.revokes("请停止录音"))
        XCTAssertTrue(LocalCaptureConsent.revokes("不要发送文字"))
        XCTAssertTrue(LocalCaptureConsent.revokes("我不同意"))
        XCTAssertFalse(LocalCaptureConsent.revokes("你好"))
    }
}
