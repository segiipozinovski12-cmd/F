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
    func reply(_ object: [String: Any], status: Int = 200) throws {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class PrivacyRegressionTests: XCTestCase {
    @MainActor func testLateAccountDeletionCannotEraseAnotherSessionVaultOrKeys() async throws {
        APIClient.testingProtocolClasses = [DelayedProtocol.self]
        let store = ChatStore(), original = store.state, oldAPI = store.api, oldGeneration = store.generation
        let client = try APIClient(server: "https://regression.invalid", identity: XCTUnwrap(store.identity))
        defer {
            DelayedProtocol.receive = nil; APIClient.testingProtocolClasses = nil; client.invalidate()
            store.state = original; store.generation = oldGeneration; store.api = oldAPI; try? store.save()
        }
        store.state = VaultState(); store.api = client
        let arrived = expectation(description: "Account deletion waits on network")
        var pending: DelayedProtocol?
        DelayedProtocol.receive = { value in pending = value; arrived.fulfill() }
        let operation = Task { await store.deleteAccount() }
        await fulfillment(of: [arrived], timeout: 3)
        XCTAssertEqual(pending?.request.url?.path, "/v1/account")
        store.generation += 1; store.state.nickname = "Second identity survives"
        try store.save()
        let identityID = store.myID, vault = try XCTUnwrap(store.vault)
        let encrypted = try Data(contentsOf: vault.url)
        try XCTUnwrap(pending).reply(["ok": true])
        await operation.value
        XCTAssertEqual(store.myID, identityID)
        XCTAssertEqual(store.state.nickname, "Second identity survives")
        XCTAssertEqual(try Data(contentsOf: vault.url), encrypted)
    }
    @MainActor func testCancellingBeforeMicrophonePermissionCannotStartRecordingLater() async throws {
        let asked = expectation(description: "System microphone prompt")
        var decision: CheckedContinuation<Bool, Never>?
        let recorder = VoiceRecorder(permission: {
            await withCheckedContinuation { continuation in decision = continuation; asked.fulfill() }
        })
        let operation = Task { try await recorder.start() }
        await fulfillment(of: [asked], timeout: 3)
        recorder.cancel()
        try XCTUnwrap(decision).resume(returning: true)
        do { try await operation.value; XCTFail("Cancelled microphone prompt started recording") }
        catch is CancellationError { }
        XCTAssertFalse(recorder.recording)
        XCTAssertEqual(recorder.seconds, 0)
    }
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

extension PrivacyRegressionTests {
    @MainActor func testEnrollmentPermissionIsConsumedBeforeBackgroundCallRefresh() async throws {
        APIClient.testingProtocolClasses = [DelayedProtocol.self]
        let client = try APIClient(server: "https://regression.invalid", identity: LocalIdentity.create(), allowEnrollment: true)
        defer { DelayedProtocol.receive = nil; APIClient.testingProtocolClasses = nil; client.invalidate() }
        var registrations: [[String: Any]] = []
        DelayedProtocol.receive = { request in
            do {
                switch request.request.url?.path {
                case "/v2/capabilities": try request.reply(["accountEpoch":"epoch"])
                case "/v1/register":
                    let data: Data
                    if let body = request.request.httpBody { data = body }
                    else if let stream = request.request.httpBodyStream {
                        stream.open(); defer { stream.close() }
                        var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                        while stream.hasBytesAvailable {
                            let count = stream.read(&buffer, maxLength: buffer.count)
                            if count <= 0 { break }
                            body.append(contentsOf: buffer.prefix(count))
                        }
                        data = body
                    } else { throw NSError(domain: "Missing registration body", code: 1) }
                    registrations.append(try JSONSerialization.jsonObject(with: data) as! [String: Any])
                    try request.reply(["ok":true])
                case "/v1/challenge": try request.reply(["nonce":"single-use-test-challenge"])
                case "/v1/session": try request.reply(["token":"test-session-\(registrations.count)"])
                default: XCTFail("Unexpected authentication route")
                }
            } catch { XCTFail(error.localizedDescription) }
        }
        try await client.authenticate()
        let firstSocketAuthority = try client.callSocketRequest().value(forHTTPHeaderField: "Authorization")
        try await client.refreshCallAuthorization()
        XCTAssertEqual(registrations.count, 1)
        try await client.refreshCallAuthorization(force: true)
        XCTAssertNotEqual(try client.callSocketRequest().value(forHTTPHeaderField: "Authorization"), firstSocketAuthority)
        XCTAssertEqual(registrations.count, 2)
        XCTAssertEqual(registrations[0]["enroll"] as? Bool, true)
        XCTAssertEqual(registrations[1]["enroll"] as? Bool, false)
        XCTAssertEqual(registrations[0]["enrollmentVersion"] as? Int, 2)
    }
}

extension PrivacyRegressionTests {
    @MainActor func testMissingMailboxRecoveryRequiresExplicitEnrollment() async throws {
        APIClient.testingProtocolClasses = [DelayedProtocol.self]
        let store = ChatStore(), original = store.state
        let identity = try XCTUnwrap(store.identity)
        let client = try APIClient(server: "https://regression.invalid", identity: identity)
        defer {
            DelayedProtocol.receive = nil; APIClient.testingProtocolClasses = nil; client.invalidate()
            store.state = original; try? store.save()
        }
        let mailbox = LocalMailbox(
            address: MailboxAddress(id: try Crypto.random(32).base64URL,
                                    writeToken: try Crypto.random(32).base64URL,
                                    expiresAt: Int(Date().timeIntervalSince1970) + 86400),
            readToken: try Crypto.random(32).base64URL, peerID: nil, registered: true, proof: "0")
        store.state.extended = ExtendedState()
        var local = store.extended; local.ownMailboxes = [mailbox]; store.state.extended = local
        var creations = 0
        DelayedProtocol.receive = { request in
            do {
                switch request.request.url?.path {
                case "/v2/mailboxes/\(mailbox.id)/inbox": try request.reply(["error":"missing"], status: 404)
                case "/v1/discovery": try request.reply(["error":"session expired"], status: 401)
                case "/v2/capabilities": try request.reply(["accountEpoch":"new-epoch"])
                case "/v1/register": try request.reply(["error":"explicit enrollment required"], status: 410)
                case "/v2/mailboxes":
                    creations += 1; try request.reply(["ok":true])
                default:
                    XCTFail("Unexpected reset recovery route")
                    try request.reply(["error":"unexpected"], status: 400)
                }
            } catch { request.client?.urlProtocol(request, didFailWithError: error) }
        }
        do {
            try await store.collectPrivateInbox(api: client, identity: identity, generation: store.generation)
            XCTFail("A reset account silently recovered a mailbox")
        } catch let failure as HTTPFailure { XCTAssertEqual(failure.status, 410) }
        XCTAssertEqual(creations, 0)
    }

    @MainActor func testEnrolledMailboxRecoveryRestoresAddressWithoutAccountHeaders() async throws {
        APIClient.testingProtocolClasses = [DelayedProtocol.self]
        let store = ChatStore(), original = store.state
        let identity = try XCTUnwrap(store.identity)
        let client = try APIClient(server: "https://regression.invalid", identity: identity)
        defer {
            DelayedProtocol.receive = nil; APIClient.testingProtocolClasses = nil; client.invalidate()
            store.state = original; try? store.save()
        }
        let mailbox = LocalMailbox(
            address: MailboxAddress(id: try Crypto.random(32).base64URL,
                                    writeToken: try Crypto.random(32).base64URL,
                                    expiresAt: Int(Date().timeIntervalSince1970) + 86400),
            readToken: try Crypto.random(32).base64URL, peerID: nil, registered: true, proof: "0")
        store.state.extended = ExtendedState()
        var local = store.extended; local.ownMailboxes = [mailbox]; store.state.extended = local
        var creations = 0, inboxReads = 0, accountChecks = 0
        DelayedProtocol.receive = { request in
            do {
                switch request.request.url?.path {
                case "/v2/capabilities": try request.reply(["accountEpoch":"current-epoch"])
                case "/v1/register": try request.reply(["ok":true])
                case "/v1/challenge": try request.reply(["nonce":"mailbox-recovery-challenge"])
                case "/v1/session": try request.reply(["token":"enrolled-session"])
                case "/v1/discovery":
                    accountChecks += 1
                    XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer enrolled-session")
                    try request.reply(["code":"ABCD", "username":NSNull()])
                case "/v2/mailboxes/\(mailbox.id)/inbox":
                    inboxReads += 1
                    XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Capability \(mailbox.readToken)")
                    if inboxReads == 1 { try request.reply(["error":"missing"], status: 404) }
                    else { try request.reply(["envelopes":[]]) }
                case "/v2/mailboxes":
                    XCTAssertNil(request.request.value(forHTTPHeaderField: "Authorization"))
                    creations += 1; try request.reply(["ok":true])
                default:
                    XCTFail("Unexpected enrolled recovery route")
                    try request.reply(["error":"unexpected"], status: 400)
                }
            } catch { request.client?.urlProtocol(request, didFailWithError: error) }
        }
        try await client.authenticate()
        try await store.collectPrivateInbox(api: client, identity: identity, generation: store.generation)
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(inboxReads, 2)
        XCTAssertEqual(accountChecks, 1)
        XCTAssertEqual(store.extended.ownMailboxes.first?.address, mailbox.address)
    }
}
