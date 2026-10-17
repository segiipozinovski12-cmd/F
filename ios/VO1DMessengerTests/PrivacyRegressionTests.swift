import XCTest
import UIKit
import ImageIO
@testable import VO1DMessenger

private final class DelayedProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var receive: ((DelayedProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "regression.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Task { @MainActor in Self.receive?(self) } }
    override func stopLoading() {}
    func reply(_ object: [String: Any]) throws {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class PrivacyRegressionTests: XCTestCase {
    @MainActor func testLateUsernameResponseCannotWriteIntoAnotherSession() async throws {
        APIClient.testingProtocolClasses = [DelayedProtocol.self]
        let store = ChatStore(), original = store.state, oldAPI = store.api, oldGeneration = store.generation
        let client = try APIClient(server: "https://regression.invalid", identity: XCTUnwrap(store.identity))
        defer {
            DelayedProtocol.receive = nil; APIClient.testingProtocolClasses = nil; client.invalidate()
            store.state = original; store.generation = oldGeneration; store.api = oldAPI; try? store.save()
        }
        store.api = client
        let arrived = expectation(description: "Username request waits on network")
        var pending: DelayedProtocol?
        DelayedProtocol.receive = { value in pending = value; arrived.fulfill() }
        let operation = Task { await store.claimUsername("alice") }
        await fulfillment(of: [arrived], timeout: 3)
        store.generation += 1; store.state.username = "second_identity"
        try XCTUnwrap(pending).reply(["username": "alice"])
        let success = await operation.value
        XCTAssertFalse(success)
        XCTAssertEqual(store.state.username, "second_identity")
    }

    @MainActor func testPrivacyUpdateCannotSendNextIdentityTrustListToPreviousAccount() async throws {
        APIClient.testingProtocolClasses = [DelayedProtocol.self]
        let store = ChatStore(), original = store.state, oldAPI = store.api, oldGeneration = store.generation
        let client = try APIClient(server: "https://regression.invalid", identity: XCTUnwrap(store.identity))
        defer {
            DelayedProtocol.receive = nil; APIClient.testingProtocolClasses = nil; client.invalidate()
            store.state = original; store.generation = oldGeneration; store.api = oldAPI; try? store.save()
        }
        store.api = client
        let arrived = expectation(description: "First privacy request")
        var pending: DelayedProtocol?, paths: [String] = []
        DelayedProtocol.receive = { value in paths.append(value.request.url!.path); pending = value; arrived.fulfill() }
        let operation = Task { try await store.applyPrivacy() }
        await fulfillment(of: [arrived], timeout: 3)
        let peer = try LocalIdentity.create().card
        store.generation += 1; store.state.contacts = [Contact(card: peer, name: "Secret second contact")]
        store.changeExtended { $0.trustedIDs = [peer.id] }
        try XCTUnwrap(pending).reply(["ok": true])
        do { try await operation.value; XCTFail("Old privacy operation crossed sessions") }
        catch is CancellationError { }
        XCTAssertEqual(paths, ["/v1/privacy"])
    }

    @MainActor func testLegacyProfileRequestDoesNotDiscloseOurMetadata() throws {
        let store = ChatStore(), original = store.state
        defer { store.state = original; try? store.save() }
        let card = try LocalIdentity.create().card, contact = Contact(card: card, name: "Bob")
        store.state = VaultState(); store.state.nickname = "Private Alice"; store.state.contacts = [contact]
        store.changeExtended { $0.trustedIDs = [card.id] }
        let event = ChatEvent(kind: "profileRequest", room: try store.socialRoom(contact), senderName: "Bob")
        XCTAssertTrue(try store.handleSocialEvent(event, sender: card))
        XCTAssertTrue(store.state.outbox.isEmpty)
    }

    @MainActor func testReconnectWakesTemporaryRetriesWithoutBypassingScheduleOrPermanentFailure() throws {
        let store = ChatStore(), original = store.state, originalIssues = store.deliveryIssues
        defer { store.state = original; store.deliveryIssues = originalIssues; try? store.save() }
        let now = Date()
        func pending(_ id: String) -> PendingDelivery {
            PendingDelivery(notBefore: now.addingTimeInterval(60), envelope: Envelope(id: id, sender: "a", recipient: "b", ephemeralKey: "", salt: "", expiresAt: Int(now.timeIntervalSince1970) + 3600, ciphertext: "", signature: ""), messageID: nil)
        }
        store.state.outbox = [pending("temporary"), pending("permanent")]
        store.deliveryIssues = [
            "temporaryb": DeliveryIssue(id: "temporaryb", detail: "offline", attempts: 3, nextAttempt: now.addingTimeInterval(300)),
            "permanentb": DeliveryIssue(id: "permanentb", detail: "forbidden", attempts: 1, nextAttempt: .distantFuture)
        ]
        store.resumeNetworkQueue(now: now)
        XCTAssertTrue(SmartQueue.ready(store.state.outbox, issues: store.deliveryIssues, now: now).isEmpty)
        XCTAssertEqual(SmartQueue.ready(store.state.outbox, issues: store.deliveryIssues, now: now.addingTimeInterval(61)).map(\.envelope.id), ["temporary"])
    }

    func testRetiredEntitlementsAndFutureThemesDoNotBreakVaultMigration() throws {
        var value = VaultState(); value.nickname = "Keep my history"; value.social = SocialState()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Wire.encoder.encode(value)) as? [String: Any])
        var social = object["social"] as! [String: Any]
        social["premium"] = ["old": "receipt"]; social["collectibles"] = [["old": "certificate"]]; object["social"] = social
        object["appearance"] = ["appTheme": "future", "defaultChatTheme": "future", "roomThemes": ["chat": "future"]]
        let restored = try Wire.decoder.decode(VaultState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.nickname, value.nickname)
        XCTAssertEqual(restored.appearance?.appTheme, .void)
        XCTAssertEqual(restored.appearance?.defaultChatTheme, .follow)
        XCTAssertTrue(restored.appearance?.roomThemes.isEmpty == true)
    }

    @MainActor func testStoryPhotoIsDownsampledAndDoesNotKeepOriginalMetadata() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 1800, height: 1200), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1800, height: 1200))
        }
        let data = try XCTUnwrap(SocialImage.jpeg(XCTUnwrap(original.jpegData(compressionQuality: 0.8)), maxSide: 96))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual((properties[kCGImagePropertyPixelWidth] as! NSNumber).intValue, 96)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(SocialImage.jpeg(data, maxSide: .infinity))
    }
}
