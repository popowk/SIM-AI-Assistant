import XCTest
@testable import SIMAICore

final class WiFiDiscoveryCandidateTests: XCTestCase {
    func testOnlyMatchingPinCanBeDiscovered() {
        let pin = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64)
        let a = WiFiDiscoveryCandidate(host: "192.168.1.20", pin: pin)!
        let b = WiFiDiscoveryCandidate(host: "192.168.1.21", pin: other)!
        XCTAssertEqual(WiFiDiscoveryCandidate.nextHost(trustedPin: pin, current: "", failed: false, candidates: [b, a]), a.host)
        XCTAssertNil(WiFiDiscoveryCandidate.nextHost(trustedPin: pin, current: "", failed: true, candidates: [b]))
        XCTAssertNil(WiFiDiscoveryCandidate.nextHost(trustedPin: pin, current: "192.168.1.10", failed: false, candidates: [a]))
        XCTAssertEqual(WiFiDiscoveryCandidate.nextHost(trustedPin: pin, current: "192.168.1.10", failed: true, candidates: [a]), a.host)
    }
    func testRejectInvalidDiscovery() {
        XCTAssertNil(WiFiDiscoveryCandidate(host: "127.0.0.1", pin: String(repeating: "a", count: 64)))
        XCTAssertNil(WiFiDiscoveryCandidate(host: "192.168.1.10", pin: "invalid"))
    }
}
