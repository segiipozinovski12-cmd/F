import XCTest
import CryptoKit
@testable import VO1DMessenger

final class CryptoTests: XCTestCase {
    func fixture() throws -> (LocalIdentity, LocalIdentity, ChatEvent) {
        let alice = try LocalIdentity.create(), bob = try LocalIdentity.create()
        let room = Room(id: "test-room", title: "Private", members: [try alice.card, try bob.card], creator: try alice.card.id, isGroup: true, createdAt: Date())
        let message = ChatMessage(id: UUID().uuidString, roomID: room.id, sender: try alice.card.id, text: "Secret hello 👋", createdAt: Date(), attachment: Attachment(name: "secret.txt", mime: "text/plain", data: Data("attachment secret".utf8)))
        return (alice, bob, ChatEvent(kind: "message", room: room, message: message, senderName: "Alice"))
    }
    func testMessageAndAttachmentRoundTrip() throws {
        let (alice, bob, event) = try fixture()
        let envelope = try Crypto.seal(event, from: alice, to: bob.card)
        let decoded = try Crypto.open(envelope, identity: bob, sender: alice.card)
        XCTAssertEqual(decoded.message?.text, event.message?.text)
        XCTAssertEqual(decoded.message?.attachment?.data, event.message?.attachment?.data)
        XCTAssertFalse(String(data: try Wire.encoder.encode(envelope), encoding: .utf8)!.contains("Secret hello"))
    }
    func testCiphertextTamperingIsRejected() throws {
        let (alice, bob, event) = try fixture()
        var envelope = try Crypto.seal(event, from: alice, to: bob.card)
        var data = try Crypto.decode(envelope.ciphertext); data[data.count - 1] ^= 1
        envelope.ciphertext = data.base64EncodedString()
        XCTAssertThrowsError(try Crypto.open(envelope, identity: bob, sender: alice.card))
    }
    func testSignedMetadataCannotBeChanged() throws {
        let (alice, bob, event) = try fixture()
        var envelope = try Crypto.seal(event, from: alice, to: bob.card)
        envelope.expiresAt += 1
        XCTAssertThrowsError(try Crypto.open(envelope, identity: bob, sender: alice.card))
    }
    func testDifferentRecipientCannotDecrypt() throws {
        let (alice, bob, event) = try fixture()
        let mallory = try LocalIdentity.create()
        let envelope = try Crypto.seal(event, from: alice, to: bob.card)
        XCTAssertThrowsError(try Crypto.open(envelope, identity: mallory, sender: alice.card))
    }
    func testContactKeySubstitutionIsRejected() throws {
        let alice = try LocalIdentity.create(), mallory = try LocalIdentity.create()
        var card = try alice.card; card.agreementKey = try mallory.card.agreementKey
        XCTAssertThrowsError(try Crypto.validate(card))
    }
    func testFreshEphemeralKeysPerMessage() throws {
        let (alice, bob, event) = try fixture()
        let first = try Crypto.seal(event, from: alice, to: bob.card)
        let second = try Crypto.seal(event, from: alice, to: bob.card)
        XCTAssertNotEqual(first.ephemeralKey, second.ephemeralKey)
        XCTAssertNotEqual(first.salt, second.salt)
        XCTAssertNotEqual(first.ciphertext, second.ciphertext)
    }
    func testExpiredEnvelopeIsRejected() throws {
        let (alice, bob, event) = try fixture()
        var envelope = try Crypto.seal(event, from: alice, to: bob.card)
        envelope.expiresAt = 0
        XCTAssertThrowsError(try Crypto.open(envelope, identity: bob, sender: alice.card))
    }
    @MainActor func testInsecureRemoteServerRejected() throws {
        XCTAssertThrowsError(try APIClient.validateURL("http://example.com"))
        XCTAssertThrowsError(try APIClient.validateURL("https://user:pass@example.com"))
        XCTAssertThrowsError(try APIClient.validateURL("https://example.com/path"))
        XCTAssertNoThrow(try APIClient.validateURL("https://example.com"))
        #if DEBUG
        XCTAssertNoThrow(try APIClient.validateURL("http://127.0.0.1:8080"))
        #endif
    }
}
