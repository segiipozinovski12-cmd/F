import XCTest
@testable import VO1DMessenger

private final class EconomyDelayedProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var receive: ((EconomyDelayedProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "economy.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Task { @MainActor in Self.receive?(self) } }
    override func stopLoading() {}
    func reply(_ data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}

final class EconomyTests: XCTestCase {
    @MainActor func testLateCatalogCannotOverwriteAnotherProfilesWallet() async throws {
        APIClient.testingProtocolClasses = [EconomyDelayedProtocol.self]
        let store = ChatStore(), oldAPI = store.api, oldGeneration = store.generation
        let oldLocked = store.locked, oldUnlocked = store.sessionUnlocked
        let api = try APIClient(server: "https://economy.invalid", identity: XCTUnwrap(store.identity))
        defer {
            api.invalidate(); APIClient.testingProtocolClasses = nil; EconomyDelayedProtocol.receive = nil
            store.api = oldAPI; store.generation = oldGeneration; store.locked = oldLocked; store.sessionUnlocked = oldUnlocked
        }
        store.api = api; store.locked = false; store.sessionUnlocked = true
        let arrived = expectation(description: "Catalog request waits on network")
        var request: EconomyDelayedProtocol?
        EconomyDelayedProtocol.receive = { request = $0; arrived.fulfill() }
        let operation = Task { try await store.refreshEconomy() }
        await fulfillment(of: [arrived], timeout: 3)
        store.generation += 1; store.economy = EconomyState(owner: "new-profile")
        try XCTUnwrap(request).reply(Data("""
        {"collections":[],"wallet":{"balance":9999,"refundDebt":0,"premiumUntil":9999999999,"premium":true,"appAccountToken":"old"},"admin":true,"products":[],"premiumProduct":"premium"}
        """.utf8))
        do { try await operation.value; XCTFail("Late catalog crossed profiles") }
        catch is CancellationError { }
        XCTAssertEqual(store.economy.owner, "new-profile")
        XCTAssertNil(store.coinWallet)
    }
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
