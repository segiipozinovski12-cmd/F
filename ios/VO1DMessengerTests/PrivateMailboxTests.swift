import XCTest
@testable import VO1DMessenger

final class PrivateMailboxTests: XCTestCase {
    private func mailbox() throws -> LocalMailbox {
        LocalMailbox(address: MailboxAddress(id: try Crypto.random(32).base64URL, writeToken: try Crypto.random(32).base64URL,
            expiresAt: Int(Date().timeIntervalSince1970) + 86400), readToken: try Crypto.random(32).base64URL, peerID: nil, proof: "0")
    }
    func testOpaqueDeliveryAuthenticatesSenderAndDoesNotExposeIdentityFields() throws {
        let a = try LocalIdentity.create(), b = try LocalIdentity.create(), box = try mailbox()
        let packet = Data("INNER SIGNAL CIPHERTEXT".utf8)
        var envelope = try PrivateMailboxCrypto.seal(packet, from: a, to: b.card, route: box.address, id: UUID().uuidString, expiry: nil)
        let opened = try PrivateMailboxCrypto.open(envelope, identity: b, mailbox: box)
        XCTAssertEqual(opened.0.id, try a.card.id)
        XCTAssertEqual(opened.1, packet)
        envelope.writeToken = nil
        let wire = try Wire.encoder.encode(envelope)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set(["id","mailbox","ephemeralKey","salt","expiresAt","ciphertext"]))
        XCTAssertFalse(String(data: wire, encoding: .utf8)!.contains(try a.card.id))
        XCTAssertFalse(String(data: wire, encoding: .utf8)!.contains(try b.card.id))
        XCTAssertEqual(try Crypto.decode(envelope.ciphertext).count, 2048 + 28)
    }
    func testOpaqueEnvelopeRejectsMutationWrongRecipientAndWrongConversation() throws {
        let a = try LocalIdentity.create(), b = try LocalIdentity.create(), stranger = try LocalIdentity.create()
        var box = try mailbox()
        let valid = try PrivateMailboxCrypto.seal(Data("packet".utf8), from: a, to: b.card, route: box.address, id: UUID().uuidString, expiry: nil)
        var tampered = valid
        var cipher = try Crypto.decode(tampered.ciphertext); cipher[cipher.count - 1] ^= 1
        tampered.ciphertext = cipher.base64EncodedString()
        XCTAssertThrowsError(try PrivateMailboxCrypto.open(tampered, identity: b, mailbox: box))
        XCTAssertThrowsError(try PrivateMailboxCrypto.open(valid, identity: stranger, mailbox: box))
        box.peerID = try stranger.card.id
        XCTAssertThrowsError(try PrivateMailboxCrypto.open(valid, identity: b, mailbox: box))
    }
}
