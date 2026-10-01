import XCTest
@testable import VO1DMessenger

final class GroupSecurityTests: XCTestCase {
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
