import XCTest
import LibSignalClient
@testable import VO1DMessenger

final class SignalTests: XCTestCase {
    private func setupPair() throws -> (LocalIdentity, LocalIdentity, SignalSnapshot, SignalSnapshot, SignalBundle) {
        let alice = try LocalIdentity.create(), bob = try LocalIdentity.create()
        let publication = try SignalProtocol.publication(state: SignalSnapshot.create(), identity: bob, count: 2)
        return (alice, bob, try SignalSnapshot.create(), publication.0, publication.1.bundles[0])
    }
    func testPQXDHDeletesOneUseKeysAndReplyUsesRatchet() throws {
        let (alice, bob, a, b, bundle) = try setupPair()
        let encrypted = try SignalProtocol.encrypt(Data("first".utf8), to: bob.card, identity: alice, state: a, bundle: bundle)
        let packet = try Wire.decoder.decode(SignalPacket.self, from: encrypted.1)
        let opened = try SignalProtocol.decrypt(packet, from: alice.card, state: b)
        XCTAssertEqual(opened.1, Data("first".utf8))
        XCTAssertNil(opened.0.prekeys[String(bundle.prekeyId)])
        XCTAssertNil(opened.0.kyberKeys[String(bundle.kyberPrekeyId)])
        XCTAssertThrowsError(try SignalProtocol.decrypt(packet, from: alice.card, state: opened.0))
        let response = try SignalProtocol.encrypt(Data("reply".utf8), to: alice.card, identity: bob, state: opened.0)
        let reply = try Wire.decoder.decode(SignalPacket.self, from: response.1)
        XCTAssertEqual(reply.type, CiphertextMessage.MessageType.whisper.rawValue)
        XCTAssertEqual(try SignalProtocol.decrypt(reply, from: bob.card, state: encrypted.0).1, Data("reply".utf8))
    }
    func testOutOfOrderMessagesAndSerializedStateSurviveRestart() throws {
        let (alice, bob, a, b, bundle) = try setupPair()
        let first = try SignalProtocol.encrypt(Data("first".utf8), to: bob.card, identity: alice, state: a, bundle: bundle)
        let bobFirst = try SignalProtocol.decrypt(Wire.decoder.decode(SignalPacket.self, from: first.1), from: alice.card, state: b)
        let reply = try SignalProtocol.encrypt(Data("ack".utf8), to: alice.card, identity: bob, state: bobFirst.0)
        let aliceAck = try SignalProtocol.decrypt(Wire.decoder.decode(SignalPacket.self, from: reply.1), from: bob.card, state: first.0)
        let second = try SignalProtocol.encrypt(Data("second".utf8), to: bob.card, identity: alice, state: aliceAck.0)
        let third = try SignalProtocol.encrypt(Data("third".utf8), to: bob.card, identity: alice, state: second.0)
        let restart = try Wire.decoder.decode(SignalSnapshot.self, from: Wire.encoder.encode(reply.0))
        let openedThird = try SignalProtocol.decrypt(Wire.decoder.decode(SignalPacket.self, from: third.1), from: alice.card, state: restart)
        let openedSecond = try SignalProtocol.decrypt(Wire.decoder.decode(SignalPacket.self, from: second.1), from: alice.card, state: openedThird.0)
        XCTAssertEqual(openedThird.1, Data("third".utf8))
        XCTAssertEqual(openedSecond.1, Data("second".utf8))
        XCTAssertThrowsError(try SignalProtocol.decrypt(Wire.decoder.decode(SignalPacket.self, from: second.1), from: alice.card, state: openedSecond.0))
    }
    func testMutationAndIdentitySubstitutionDoNotConsumeState() throws {
        let (alice, bob, a, b, bundle) = try setupPair()
        var forged = bundle; forged.prekey = bundle.signedPrekey
        XCTAssertThrowsError(try SignalProtocol.encrypt(Data("secret".utf8), to: bob.card, identity: alice, state: a, bundle: forged))
        let encrypted = try SignalProtocol.encrypt(Data("secret".utf8), to: bob.card, identity: alice, state: a, bundle: bundle)
        var packet = try Wire.decoder.decode(SignalPacket.self, from: encrypted.1)
        packet.ciphertext[packet.ciphertext.count - 1] ^= 1
        XCTAssertThrowsError(try SignalProtocol.decrypt(packet, from: alice.card, state: b))
        let original = try Wire.decoder.decode(SignalPacket.self, from: encrypted.1)
        XCTAssertEqual(try SignalProtocol.decrypt(original, from: alice.card, state: b).1, Data("secret".utf8))
        var changed = original; changed.identityBinding = Data(repeating: 0, count: 64).base64EncodedString()
        XCTAssertThrowsError(try SignalProtocol.decrypt(changed, from: alice.card, state: b))
        XCTAssertNotNil(b.prekeys[String(bundle.prekeyId)])
    }
    func testTruncatedCiphertextsAndMalformedPacketsAreRejectedWithoutConsumingPrekeys() throws {
        let (alice,bob,a,b,bundle) = try setupPair()
        let encrypted = try SignalProtocol.encrypt(Data("fuzz".utf8),to:bob.card,identity:alice,state:a,bundle:bundle)
        let original = try Wire.decoder.decode(SignalPacket.self,from:encrypted.1)
        for length in [0,1,2,4,8,16,32,64,128] where length < original.ciphertext.count {
            var packet = original; packet.ciphertext = original.ciphertext.prefix(length)
            XCTAssertThrowsError(try SignalProtocol.decrypt(packet,from:alice.card,state:b))
        }
        for index in 0..<32 {
            var packet = original; packet.ciphertext[packet.ciphertext.count-1-index] ^= 128
            XCTAssertThrowsError(try SignalProtocol.decrypt(packet,from:alice.card,state:b))
        }
        XCTAssertEqual(try SignalProtocol.decrypt(original,from:alice.card,state:b).1,Data("fuzz".utf8))
        XCTAssertNotNil(b.prekeys[String(bundle.prekeyId)])
    }
    @MainActor func testDeferredPlaintextCannotReachAPI() async throws {
        let alice = try LocalIdentity.create(), bob = try LocalIdentity.create()
        let client = try APIClient(server: "https://example.invalid", identity: alice)
        let envelope = Envelope(id: UUID().uuidString, sender: try alice.card.id, recipient: try bob.card.id,
            ephemeralKey: "", salt: "", expiresAt: 1, ciphertext: "", signature: "", deferredEvent: Data("LOCAL ONLY".utf8))
        do { try await client.send(envelope); XCTFail("Deferred plaintext was accepted") }
        catch { XCTAssertTrue(error is MessengerError) }
    }
}
