import XCTest
@testable import SIMAICore

final class LocalReceptionPolicyTests: XCTestCase {
    func testDeliveryAndDetails() {
        var p = LocalReceptionPolicy()
        XCTAssertEqual(p.reply(to: "我是送快递的"), .delivery)
        XCTAssertTrue(p.awaitingDetails)
        XCTAssertEqual(p.reply(to: "有一份文件需要签收"), .noted)
        XCTAssertFalse(p.awaitingDetails)
        XCTAssertEqual(p.reply(to: "没事了再见"), .goodbye)
    }
    func testCallbackAndSensitiveData() {
        var p = LocalReceptionPolicy()
        XCTAssertEqual(p.reply(to: "请让他给我回个电话"), .callback)
        XCTAssertEqual(p.reply(to: "验证码是"), .noSensitive)
        XCTAssertFalse(p.awaitingDetails)
    }
    func testGreetingAndUncertain() {
        var p = LocalReceptionPolicy()
        XCTAssertEqual(p.reply(to: "王先生在吗"), .purpose)
        XCTAssertEqual(p.reply(to: "嗯"), .repeatPlease)
        XCTAssertEqual(p.reply(to: "我是来咨询产品报价的"), .business)
    }
}
