import XCTest
@testable import VO1DMessenger

final class EconomyTests: XCTestCase {
    func testPremiumRequiresBothServerEntitlementAndUnexpiredDate() throws {
        let future = Int(Date().timeIntervalSince1970) + 600
        let expired = CoinWallet(balance: 0, refundDebt: 0, premiumUntil: 1, premium: true, appAccountToken: UUID().uuidString)
        XCTAssertFalse(expired.isPremium)
        let denied = CoinWallet(balance: 0, refundDebt: 0, premiumUntil: future, premium: false, appAccountToken: UUID().uuidString)
        XCTAssertFalse(denied.isPremium)
        let entitled = CoinWallet(balance: 0, refundDebt: 0, premiumUntil: future, premium: true, appAccountToken: UUID().uuidString)
        XCTAssertTrue(entitled.isPremium)
    }
    func testOriginalGiftDecodesWithoutInventingTraitsOrVisibility() throws {
        let data = Data("""
        {"id":"gift","collection":"nova","serial":34628,"owner":"owner","ownerUsername":null,
         "pricePaid":500,"acquired":123,"visible":false,"traits":null,"listingID":null,"salePrice":null}
        """.utf8)
        let gift = try Wire.decoder.decode(CollectibleArtifact.self, from: data)
        XCTAssertEqual(gift.number, "#34,628")
        XCTAssertEqual(gift.title, "Nova")
        XCTAssertNil(gift.traits)
        XCTAssertFalse(gift.visible)
    }
    func testMutationCarriesIdempotencyKeyButCannotSetOwnershipOrResult() throws {
        let command = ArtifactCommand(artifactID: "gift", expectedPrice: 100)
        let data = try Wire.encoder.encode(command)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(body["requestID"] as? String)))
        XCTAssertNil(body["owner"])
        XCTAssertNil(body["traits"])
        XCTAssertNil(body["balance"])
        XCTAssertEqual(try Wire.encoder.encode(command), data)
    }
}
