import XCTest
@testable import SIMAICore

final class PhoneTransportReadinessTests: XCTestCase {
    func testUSBDoesNotRequireShizuku() {
        XCTAssertTrue(PhoneTransportReadiness.ready(wifi: false, adbAuthorized: true,
            authenticatedWiFi: false, shizukuAuthorized: false, shizukuAudioReady: false))
        XCTAssertFalse(PhoneTransportReadiness.ready(wifi: false, adbAuthorized: false,
            authenticatedWiFi: true, shizukuAuthorized: true, shizukuAudioReady: true))
    }
    func testWiFiDoesNotRequireADB() {
        XCTAssertTrue(PhoneTransportReadiness.ready(wifi: true, adbAuthorized: false,
            authenticatedWiFi: true, shizukuAuthorized: true, shizukuAudioReady: true))
        XCTAssertFalse(PhoneTransportReadiness.ready(wifi: true, adbAuthorized: true,
            authenticatedWiFi: true, shizukuAuthorized: true, shizukuAudioReady: false))
        XCTAssertFalse(PhoneTransportReadiness.ready(wifi: true, adbAuthorized: true,
            authenticatedWiFi: false, shizukuAuthorized: true, shizukuAudioReady: true))
    }
}
