import XCTest
@testable import VO1DMessenger

final class DeviceSecurityTests: XCTestCase {
    func testDeviceCertificateDoesNotAuthorizeAnotherIdentityOrScope() throws {
        let issuer = try LocalIdentity.create(), device = try LocalIdentity.create()
        let now = Int(Date().timeIntervalSince1970)
        var certificate = DeviceCertificate(id:UUID().uuidString,issuer:try issuer.card,device:try device.card.id,expiresAt:now+3600,signature:"")
        certificate.signature = try issuer.signingPrivate.signature(for:certificate.signed).base64EncodedString()
        XCTAssertNoThrow(try certificate.validate(now:now))
        XCTAssertThrowsError(try certificate.validate(now:now+3600))
        var changed = certificate; changed.device = try LocalIdentity.create().card.id
        XCTAssertThrowsError(try changed.validate(now:now))
        changed = certificate; changed.scope = "account"
        XCTAssertThrowsError(try changed.validate(now:now))
    }
    func testHistorySyncDoesNotIncludeAttachmentsDraftsOrRatchetKeys() throws {
        let owner = try LocalIdentity.create().card, peer = try LocalIdentity.create().card
        var state = VaultState(), room = Room(id:"dm:test",title:"History",members:[owner,peer],creator:"",isGroup:false,createdAt:Date())
        room.draft = "SECRET-DRAFT"; state.rooms = [room]; state.extended = ExtendedState()
        let attachment = Attachment(name:"SECRET-FILENAME",mime:"application/octet-stream",data:Data("SECRET-FILE".utf8))
        let message = ChatMessage(id:UUID().uuidString,roomID:room.id,sender:owner.id,text:"Text",createdAt:Date(),attachment:attachment,state:"sent")
        state.messages = [message]
        let archive = try DeviceHistory.snapshot(state:state,owner:owner)
        try DeviceHistory.validate(archive,owner:owner)
        let json = String(data:try Wire.encoder.encode(archive),encoding:.utf8)!
        XCTAssertFalse(json.contains("SECRET-DRAFT")); XCTAssertFalse(json.contains("SECRET-FILENAME"))
        XCTAssertNil(archive.messages.first?.attachment)
        XCTAssertThrowsError(try DeviceHistory.validate(archive,owner:peer))
    }
    func testWorkProofDifficultyAndTokenValidationAreBounded() throws {
        XCTAssertThrowsError(try WorkProof.solve(prefix:"test",bits:17))
        XCTAssertThrowsError(try WorkProof.solve(prefix:"test",bits:25))
        XCTAssertThrowsError(try WorkProof.validateToken("../outside"))
        XCTAssertNoThrow(try WorkProof.validateToken(WorkProof.token()))
    }
}
