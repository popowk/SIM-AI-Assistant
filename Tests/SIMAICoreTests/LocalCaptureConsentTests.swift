import XCTest
@testable import SIMAICore
final class LocalCaptureConsentTests: XCTestCase {
    func testExplicitConsent() {
        XCTAssertTrue(LocalCaptureConsent.accepts("同意。"))
        XCTAssertFalse(LocalCaptureConsent.accepts("不同意"))
        XCTAssertFalse(LocalCaptureConsent.accepts("可以，但是不要转发"))
        XCTAssertFalse(LocalCaptureConsent.accepts("你好"))
        XCTAssertTrue(LocalCaptureConsent.revokes("请停止录音"))
    }
}
