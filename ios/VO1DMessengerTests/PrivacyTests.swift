import XCTest
@testable import VO1DMessenger

final class PrivacyTests: XCTestCase {
    func testCallOffersBindIdentitiesAndAudioRejectsReplayAndReflection() throws {
        let alice=try LocalIdentity.create(),bob=try LocalIdentity.create()
        let a=CallSecrets(),b=CallSecrets(),callID=UUID().uuidString
        let offer=try a.offer(identity:alice,callID:callID,to:bob.card.id)
        XCTAssertThrowsError(try b.accept(key:offer["key"]!,signature:offer["keySignature"]!,identity:bob,peer:alice.card,callID:UUID().uuidString))
        let bk=try b.accept(key:offer["key"]!,signature:offer["keySignature"]!,identity:bob,peer:alice.card,callID:callID)
        let answer=try b.offer(identity:bob,callID:callID,to:alice.card.id)
        let ak=try a.accept(key:answer["key"]!,signature:answer["keySignature"]!,identity:alice,peer:bob.card,callID:callID)
        let clear=Data("test audio".utf8)
        let frame=try a.seal(clear,key:ak,callID:callID)
        XCTAssertThrowsError(try a.open(frame.0,sequence:frame.1,key:ak,callID:callID))
        XCTAssertEqual(try b.open(frame.0,sequence:frame.1,key:bk,callID:callID),clear)
        XCTAssertNil(try b.open(frame.0,sequence:frame.1,key:bk,callID:callID))
        XCTAssertThrowsError(try b.open(frame.0,sequence:"999",key:bk,callID:callID))
        let next=try a.seal(clear,key:ak,callID:callID)
        XCTAssertEqual(try b.open(next.0,sequence:next.1,key:bk,callID:callID),clear)
    }

    func testWirePayloadDoesNotExposeLocalDraftOrSettings() throws {
        let alice=try LocalIdentity.create(),bob=try LocalIdentity.create()
        let ac=try alice.card,bc=try bob.card
        var room=Room(id:"dm:"+[ac.id,bc.id].sorted().joined(separator:":"),title:"LOCAL ALIAS",
            members:[ac,bc],creator:ac.id,isGroup:false,createdAt:Date())
        room.draft="PRIVATE UNSENT TEXT"; room.unread=17; room.archived=true
        let event=ChatEvent(kind:"room",room:room,senderName:"Alice")
        let envelope=try Crypto.seal(event,from:alice,to:bc)
        let opened=try Crypto.open(envelope,identity:bob,sender:ac)
        XCTAssertEqual(opened.room.draft,"")
        XCTAssertEqual(opened.room.title,"")
        XCTAssertEqual(opened.room.unread,0)
        XCTAssertFalse(opened.room.archived)
    }

    func testHiddenChannelDoesNotDiscloseAnotherSubscriberKey() throws {
        let alice=try LocalIdentity.create(),bob=try LocalIdentity.create(),carol=try LocalIdentity.create()
        let ac=try alice.card,bc=try bob.card,cc=try carol.card
        var room=Room(id:UUID().uuidString,title:"Channel",members:[ac,bc,cc],creator:ac.id,isGroup:true,createdAt:Date())
        room.isChannel=true; room.onlyAdminsCanPost=true; room.admins=[ac.id]; room.privateRoster=true
        let opened=try Crypto.open(Crypto.seal(ChatEvent(kind:"room",room:room,senderName:"A"),from:alice,to:bc),
            identity:bob,sender:ac)
        XCTAssertEqual(Set(opened.room.members.map(\.id)),Set([ac.id,bc.id]))
        XCTAssertFalse(String(data:try Wire.encoder.encode(opened),encoding:.utf8)!.contains(cc.id))
    }

    func testTrackerCleanupPreservesFunctionalParametersAndFragment() {
        let source=URL(string:"https://example.org/path?id=123&utm_source=x&fbclid=y#section")!
        XCTAssertEqual(SafeContent.cleanURL(source).absoluteString,"https://example.org/path?id=123#section")
    }

    func testMissingPrivacyFieldsMigrateToSafeDefaults() throws {
        let decoded=try JSONDecoder().decode(PrivacyPreferences.self,from:Data("{}".utf8))
        XCTAssertTrue(decoded.requireRequests)
        XCTAssertFalse(decoded.typingSignals)
        XCTAssertFalse(decoded.notificationPreview)
        XCTAssertFalse(decoded.backgroundCalls)
        let extended=try Wire.decoder.decode(ExtendedState.self,from:Data("{}".utf8))
        XCTAssertEqual(extended.pendingEvents.count,0)
    }

    func testEncryptedBackupRoundtripAndWrongPassword() throws {
        let identity=try LocalIdentity.create()
        var state=VaultState(); state.nickname="Private"; state.extended=ExtendedState()
        let encoded=try SecureBackup.export(BackupPayload(identity:identity,state:state),password:"correct horse battery")
        XCTAssertFalse(String(data:encoded,encoding:.utf8)!.contains("Private"))
        let restored=try SecureBackup.open(encoded,password:"correct horse battery")
        XCTAssertEqual(try restored.identity.card.id,try identity.card.id)
        XCTAssertEqual(restored.state.nickname,"Private")
        XCTAssertThrowsError(try SecureBackup.open(encoded,password:"another secret phrase"))
        var envelope=try Wire.decoder.decode(BackupEnvelope.self,from:encoded)
        envelope.ciphertext[envelope.ciphertext.startIndex] ^= 1
        XCTAssertThrowsError(try SecureBackup.open(Wire.encoder.encode(envelope),password:"correct horse battery"))
    }
}

extension PrivacyTests {
    func testDelegatedCallKeyCannotImpersonateAccountAndCertificateBindsCall() throws {
        let owner = try LocalIdentity.create(), peer = try LocalIdentity.create(), delegate = try LocalIdentity.create()
        var authority = CallAuthority(owner: try owner.card.id, key: try delegate.signingPrivate.publicKey.rawRepresentation.base64EncodedString(), expiresAt: Int(Date().timeIntervalSince1970) + 3600)
        authority.signature = try owner.signingPrivate.signature(for: authority.bytes).base64EncodedString()
        let packed = try Wire.encoder.encode(authority).base64EncodedString()
        let a = CallSecrets(), b = CallSecrets(), id = UUID().uuidString
        let offer = try a.offer(identity: delegate, callID: id, to: peer.card.id, ownerID: owner.card.id)
        XCTAssertThrowsError(try b.accept(key: offer["key"]!, signature: offer["keySignature"]!, identity: peer, peer: owner.card, callID: id))
        let bk = try b.accept(key: offer["key"]!, signature: offer["keySignature"]!, identity: peer, peer: owner.card, callID: id, certificate: packed)
        let reply = try b.offer(identity: peer, callID: id, to: owner.card.id)
        let ak = try a.accept(key: reply["key"]!, signature: reply["keySignature"]!, identity: delegate, peer: peer.card, callID: id, ownerID: owner.card.id)
        let encrypted = try a.seal(Data("delegated audio".utf8), key: ak, callID: id)
        XCTAssertEqual(try b.open(encrypted.0, sequence: encrypted.1, key: bk, callID: id), Data("delegated audio".utf8))
        authority.expiresAt = 0
        XCTAssertThrowsError(try authority.validate(for: owner.card))
    }
}
