import XCTest
import CryptoKit
@testable import VO1DMessenger

final class SocialTests: XCTestCase {
    func testStoryBindsAuthorAndMaximumLifetime() throws {
        let now = Date()
        let alice = try LocalIdentity.create().card.id
        var story = PrivateStory(author: alice, text: "Hello", createdAt: now, expiresAt: now.addingTimeInterval(86400))
        XCTAssertNoThrow(try story.validate(sender: alice, now: now))
        XCTAssertThrowsError(try story.validate(sender: String(repeating: "a", count: 64), now: now))
        story.expiresAt = now.addingTimeInterval(86401)
        XCTAssertThrowsError(try story.validate(sender: alice, now: now))
        story.expiresAt = now
        XCTAssertThrowsError(try story.validate(sender: alice, now: now))
    }
    func testProfileBoundsAndReactionCatalog() throws {
        var profile = SharedProfile(name: "Alice", bio: "", updatedAt: Date(), status: "")
        XCTAssertNoThrow(try profile.validate())
        profile.avatar = Data(repeating: 1, count: 160001)
        XCTAssertThrowsError(try profile.validate())
        XCTAssertTrue(ReactionCatalog.accepts("🖤"))
        XCTAssertTrue(ReactionCatalog.accepts(""))
        XCTAssertFalse(ReactionCatalog.accepts(String(repeating: "🔥", count: 100)))
    }
    @MainActor func testSoloGroupsAndChannelsCanBeCreatedWithoutContacts() throws {
        let store = ChatStore(), saved = store.state
        defer { store.state = saved; try? store.save() }
        let group = try store.createGroup(name: "My group", contacts: [])
        let channel = try store.createChannel(name: "My channel", contacts: [])
        XCTAssertTrue(group.isGroup)
        XCTAssertEqual(group.members.count, 1)
        XCTAssertEqual(channel.isChannel, true)
        XCTAssertEqual(channel.onlyAdminsCanPost, true)
    }
    func testCallDirectionKeysCrossEpochAndRejectTamperingAndReplay() throws {
        let alice = try LocalIdentity.create(), bob = try LocalIdentity.create()
        let a = CallSecrets(), b = CallSecrets(), id = UUID().uuidString
        let offerA = try a.offer(identity: alice, callID: id, to: bob.card.id)
        let offerB = try b.offer(identity: bob, callID: id, to: alice.card.id)
        let keyA = try a.accept(key: offerB["key"]!, signature: offerB["keySignature"]!, identity: alice, peer: bob.card, callID: id)
        let keyB = try b.accept(key: offerA["key"]!, signature: offerA["keySignature"]!, identity: bob, peer: alice.card, callID: id)
        for index in 1...4097 {
            let bytes = Data("frame-\(index)".utf8), frame = try a.seal(bytes, key: keyA, callID: id)
            if index == 4097 {
                var changed = frame.0; changed[changed.count - 1] ^= 1
                XCTAssertThrowsError(try b.open(changed, sequence: frame.1, key: keyB, callID: id))
            }
            XCTAssertEqual(try b.open(frame.0, sequence: frame.1, key: keyB, callID: id), bytes)
            XCTAssertNil(try b.open(frame.0, sequence: frame.1, key: keyB, callID: id))
        }
    }
    @MainActor func testProfileAndStoryStayInEncryptedSignalPayload() throws {
        let alice = try LocalIdentity.create(), bob = try LocalIdentity.create()
        let publication = try SignalProtocol.publication(state: SignalSnapshot.create(), identity: bob, count: 1)
        let room = Room(id: "dm:" + [try alice.card.id, try bob.card.id].sorted().joined(separator: ":"), title: "DM", members: [try alice.card, try bob.card], creator: "", isGroup: false, createdAt: Date())
        var event = ChatEvent(kind: "story", room: room, senderName: "Alice")
        event.sharedProfile = SharedProfile(name: "PRIVATE_PROFILE", bio: "PRIVATE_BIO", updatedAt: Date(), status: "")
        event.story = PrivateStory(author: try alice.card.id, text: "PRIVATE_STORY", createdAt: Date(), expiresAt: Date().addingTimeInterval(3600))
        let encrypted = try SignalProtocol.encrypt(Wire.encoder.encode(event), to: bob.card, identity: alice, state: SignalSnapshot.create(), bundle: publication.1.bundles[0])
        let packet = try Wire.decoder.decode(SignalPacket.self, from: encrypted.1)
        let wire = String(data: try Wire.encoder.encode(packet), encoding: .utf8)!
        XCTAssertFalse(wire.contains("PRIVATE_STORY")); XCTAssertFalse(wire.contains("PRIVATE_BIO"))
        let clear = try SignalProtocol.decrypt(packet, from: alice.card, state: publication.0)
        XCTAssertEqual(try Wire.decoder.decode(ChatEvent.self, from: clear.1).story?.text, "PRIVATE_STORY")
    }
}

extension SocialTests {
    func testNearbyProofRejectsReplayDifferentKeyAndAckSubstitution() throws {
        let alice = try LocalIdentity.create(), mallory = try LocalIdentity.create()
        let nonce = try Crypto.random(32).base64EncodedString(), other = try Crypto.random(32).base64EncodedString()
        let proof = try alice.signingPrivate.signature(for: NearbyProof.challenge(nonce)).base64EncodedString()
        XCTAssertTrue(try NearbyProof.verify(card: alice.card, nonce: nonce, signature: proof))
        XCTAssertFalse(try NearbyProof.verify(card: alice.card, nonce: other, signature: proof))
        XCTAssertFalse(try NearbyProof.verify(card: mallory.card, nonce: nonce, signature: proof))
        let id = UUID().uuidString, bytes = NearbyProof.ack(id, sender: "sender", recipient: "recipient")
        let ack = try alice.signingPrivate.signature(for: bytes)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: Crypto.decode(alice.card.signingKey))
        XCTAssertTrue(key.isValidSignature(ack, for: bytes))
        XCTAssertFalse(key.isValidSignature(ack, for: NearbyProof.ack(id, sender: "recipient", recipient: "sender")))
        XCTAssertFalse(key.isValidSignature(ack, for: NearbyProof.ack(UUID().uuidString, sender: "sender", recipient: "recipient")))
    }
}


extension SocialTests {
    @MainActor func testDeletingUnsentStoryRemovesQueuedCopiesAndQueuesRetraction() throws {
        let store = ChatStore(), saved = store.state
        defer { store.state = saved; try? store.save() }
        let peer = try LocalIdentity.create().card
        store.state = VaultState(); store.state.contacts = [Contact(card: peer, name: "Bob")]
        var local = ExtendedState(); local.trustedIDs = [peer.id]; store.state.extended = local
        try store.publishStory(text: "Ephemeral", image: nil, audience: [peer.id])
        let story = try XCTUnwrap(store.social.stories.first)
        XCTAssertTrue(store.state.outbox.contains { $0.storyID == story.id })
        try store.deleteStory(story)
        XCTAssertFalse(store.state.outbox.contains { $0.storyID == story.id })
        XCTAssertTrue(store.social.stories.isEmpty)
        let bytes = try XCTUnwrap(store.state.outbox.last?.envelope.deferredEvent)
        XCTAssertEqual(try Wire.decoder.decode(ChatEvent.self, from: bytes).kind, "storyDelete")
    }
}

extension SocialTests {
    @MainActor func testNearbyEnvelopeCannotLeaveThroughAccountRelayOrStarveNetworkQueue() async throws {
        let alice = try LocalIdentity.create()
        let api = try APIClient(server: "https://relay.example", identity: alice)
        defer { api.invalidate() }
        var envelope = Envelope(id: UUID().uuidString, sender: "sender", recipient: "recipient", ephemeralKey: "", salt: "", expiresAt: Int(Date().timeIntervalSince1970) + 60, ciphertext: "", signature: "")
        envelope.nearbyOnly = true
        do { try await api.send(envelope); XCTFail("Nearby data escaped to account API") }
        catch { XCTAssertTrue(error.localizedDescription.contains("только для устройства рядом")) }
        let local = PendingDelivery(envelope: envelope, messageID: nil)
        var remote = envelope; remote.nearbyOnly = nil; remote.id = UUID().uuidString
        let network = PendingDelivery(envelope: remote, messageID: nil)
        XCTAssertEqual(SmartQueue.ready(Array(repeating: local, count: 40) + [network], issues: [:], limit: 1).first?.id, network.id)
    }
}

extension SocialTests {
    @MainActor func testSearchableModeRestoresDiscoveryWithoutDisablingTorRoute() throws {
        let store = ChatStore(), saved = store.state
        defer { store.state = saved; try? store.save() }
        var local = ExtendedState(); local.privacy.embeddedTor = true; store.state.extended = local
        try store.selectPrivacyProfile(.privateDelivery)
        XCTAssertFalse(store.preferences.discoverable)
        XCTAssertTrue(store.preferences.requirePrivateDelivery)
        try store.selectPrivacyProfile(.everyday)
        XCTAssertTrue(store.preferences.discoverable)
        XCTAssertFalse(store.preferences.requirePrivateDelivery)
        XCTAssertTrue(store.preferences.embeddedTor)
    }
}
