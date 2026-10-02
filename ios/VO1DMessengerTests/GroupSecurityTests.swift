import XCTest
@testable import VO1DMessenger

final class GroupSecurityTests: XCTestCase {
    @MainActor func testNewChannelsHideSubscriberRosterByDefault() throws {
        let store = ChatStore()
        let saved = store.state
        defer { store.state = saved; try? store.save() }

        let room = try store.createChannel(name: "Private channel", contacts: [])
        XCTAssertEqual(room.privateRoster, true)
        XCTAssertEqual(room.onlyAdminsCanPost, true)
        XCTAssertEqual(room.members.map(\.id), [store.myID])
    }

    @MainActor func testStrictDeliveryExplainsMissingGroupRouteWithoutMutation() throws {
        let store = ChatStore()
        let saved = store.state
        defer { store.state = saved; try? store.save() }
        let peer = try LocalIdentity.create().card
        let contact = Contact(card: peer, name: "No private route")
        var local = store.extended
        local.privacy.requirePrivateDelivery = true
        local.peerMailboxes = [:]
        store.state.extended = local
        let rooms = store.state.rooms.count, queued = store.state.outbox.count

        XCTAssertThrowsError(try store.createGroup(name: "Must stay private", contacts: [contact])) { error in
            XCTAssertTrue(error.localizedDescription.contains("QR-маршрут"))
        }
        XCTAssertEqual(store.state.rooms.count, rooms)
        XCTAssertEqual(store.state.outbox.count, queued)
    }

    @MainActor func testRejectedScopedGroupDoesNotLeaveRoomOrQueuedInvites() throws {
        let store = ChatStore()
        let savedState = store.state, savedRegistry = store.profileRegistry
        defer {
            store.state = savedState
            store.profileRegistry = savedRegistry
            try? savedRegistry.save()
            try? store.save()
        }
        let peer = try LocalIdentity.create().card
        let contact = Contact(card: peer, name: "Peer")
        guard let index = store.profileRegistry.profiles.firstIndex(where: { $0.id == store.profileID }) else {
            return XCTFail("Active profile missing")
        }
        var registry = store.profileRegistry
        registry.profiles[index].scope = .group
        registry.profiles[index].boundID = UUID().uuidString
        store.profileRegistry = registry
        let rooms = store.state.rooms.count, queued = store.state.outbox.count

        XCTAssertThrowsError(try store.createGroup(name: "Cannot bind", contacts: [contact]))
        XCTAssertEqual(store.state.rooms.count, rooms)
        XCTAssertEqual(store.state.outbox.count, queued)
    }

    func testMembershipCannotDowngradeOrAcceptStaleUpdates() throws {
        let a = try LocalIdentity.create().card, b = try LocalIdentity.create().card
        var room = Room(id:UUID().uuidString,title:"Group",members:[a,b],creator:a.id,isGroup:true,createdAt:Date())
        room.membershipEpoch = 3
        var old = room; old.membershipEpoch = 2
        XCTAssertThrowsError(try GroupEpoch.validate(current:room,incoming:old,update:false))
        XCTAssertThrowsError(try GroupEpoch.validate(current:room,incoming:old,update:true))
        XCTAssertThrowsError(try GroupEpoch.validate(current:room,incoming:room,update:true))
        var next = room; next.membershipEpoch = 5
        XCTAssertNoThrow(try GroupEpoch.validate(current:room,incoming:next,update:true))
        XCTAssertThrowsError(try GroupEpoch.validate(current:room,incoming:next,update:false))
        XCTAssertNoThrow(try GroupEpoch.validate(current:room,incoming:room,update:false))
    }
    func testInvitationBindsAudienceGroupExpiryAndMembershipEpoch() throws {
        let owner = try LocalIdentity.create(), card = try owner.card, recipient = try LocalIdentity.create().card
        let now = Int(Date().timeIntervalSince1970)
        var invitation = GroupInvitation(id:UUID().uuidString,roomID:UUID().uuidString,title:"Group",creator:card,audience:recipient.id,epoch:3,expiresAt:now+3600,signature:"")
        invitation.signature = try owner.signingPrivate.signature(for:invitation.signed).base64EncodedString()
        XCTAssertNoThrow(try invitation.validate(recipient:recipient.id,sender:card,now:now))
        XCTAssertThrowsError(try invitation.validate(recipient:card.id,sender:card,now:now))
        XCTAssertThrowsError(try invitation.validate(recipient:recipient.id,sender:card,now:now+3600))
        var changed = invitation; changed.epoch = 4
        XCTAssertThrowsError(try changed.validate(recipient:recipient.id,sender:card,now:now))
        changed = invitation; changed.roomID = UUID().uuidString
        XCTAssertThrowsError(try changed.validate(recipient:recipient.id,sender:card,now:now))
    }
}
