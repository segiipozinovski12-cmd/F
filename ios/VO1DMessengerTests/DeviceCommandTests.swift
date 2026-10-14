import XCTest
@testable import VO1DMessenger

final class DeviceCommandTests: XCTestCase {
    func certificate(issuer: LocalIdentity, device: ContactCard, scope: String = "collaboration") throws -> DeviceCertificate {
        var value = DeviceCertificate(id: UUID().uuidString, issuer: try issuer.card, device: device.id, expiresAt: Int(Date().timeIntervalSince1970)+3600, signature: "")
        value.scope = scope; value.signature = try issuer.signingPrivate.signature(for: value.signed).base64EncodedString(); return value
    }
    @MainActor func configured(issuer: LocalIdentity, device: LocalIdentity, certificate: DeviceCertificate) throws -> ChatStore {
        let store = ChatStore(), profile = UUID().uuidString
        store.api?.invalidate(); store.api = nil; store.identity = issuer; store.ownCard = try issuer.card
        store.vault = try Vault(profileID: profile); store.fatalError = nil; store.locked = false
        store.profileRegistry = ProfileRegistry(activeID: profile, profiles: [LocalProfile(id: profile, label: "Test")])
        store.state = VaultState(); var local = ExtendedState(); local.deviceLinks = [DeviceLink(certificate: certificate, peer: try device.card, approved: true)]; store.state.extended = local
        store.state.contacts = [Contact(card: try device.card, name: "Device", verified: true)]
        return store
    }
    @MainActor func testDelegatedSendPersistsDedupAndExactOutgoingTogetherAcrossRestart() throws {
        let issuer = try LocalIdentity.create(), device = try LocalIdentity.create(), other = try LocalIdentity.create().card
        let certificate = try certificate(issuer: issuer, device: device.card), store = try configured(issuer: issuer, device: device, certificate: certificate)
        defer { try? store.vault?.delete() }
        let room = Room(id: "dm:"+[store.myID,other.id].sorted().joined(separator: ":"),title: "",members: [try issuer.card,other],creator: "",isGroup: false,createdAt: Date())
        store.state.rooms = [room]
        let command = DeviceCommand(certificateID: certificate.id, operation: "send", roomID: room.id, text: "From linked device")
        var event = ChatEvent(kind: "deviceCommand", room: room, senderName: "Device"); event.deviceCertificate = certificate; event.deviceCommand = command
        try store.applyAccepted(event, sender: device.card); try store.save()
        XCTAssertEqual(store.state.messages.map(\.id), [command.id])
        XCTAssertEqual(store.extended.completedDeviceCommands[command.key]?.status, "queued")
        let ciphertext = try Wire.encoder.encode(store.state.outbox.filter { $0.messageID == command.id })
        store.state = try XCTUnwrap(store.vault).read(key: issuer.storage)
        try store.applyAccepted(event, sender: device.card); try store.save()
        XCTAssertEqual(store.state.messages.count, 1)
        XCTAssertEqual(try Wire.encoder.encode(store.state.outbox.filter { $0.messageID == command.id }), ciphertext)
        store.state.contacts[0].verified = false
        XCTAssertThrowsError(try store.applyAccepted(event, sender: device.card))
        store.state.contacts[0].verified = true; store.state.extended?.revokedDevices[certificate.id] = certificate.expiresAt
        XCTAssertThrowsError(try store.applyAccepted(event, sender: device.card))
    }
    @MainActor func testSecondaryAcceptsOnlyPrimaryResultForItsPendingCommand() throws {
        let issuer = try LocalIdentity.create(), device = try LocalIdentity.create(), certificate = try certificate(issuer: issuer, device: device.card)
        let store = try configured(issuer: device, device: issuer, certificate: certificate); defer { try? store.vault?.delete() }
        let command = DeviceCommand(certificateID: certificate.id, operation: "send", roomID: "dm:test", text: "hello")
        store.state.extended?.pendingDeviceCommands = [command]
        let room = Room(id: "dm:test",title: "",members: [try issuer.card,try device.card],creator: "",isGroup: false,createdAt: Date())
        var event = ChatEvent(kind: "deviceCommandResult", room: room, senderName: "Primary"); event.deviceCertificate = certificate
        event.deviceCommandResult = DeviceCommandResult(commandID: command.id, certificateID: certificate.id, status: "queued", detail: "Saved")
        try store.applyAccepted(event, sender: issuer.card)
        XCTAssertEqual(store.extended.pendingDeviceCommands[0].status, "queued")
        event.deviceCommandResult?.commandID = UUID().uuidString
        XCTAssertThrowsError(try store.applyAccepted(event, sender: issuer.card))
    }
    @MainActor func testRejectedCommandCannotEditSomeoneElsesMessageOrSendOutsideExistingRooms() throws {
        let issuer = try LocalIdentity.create(), device = try LocalIdentity.create(), other = try LocalIdentity.create().card
        let cert = try certificate(issuer: issuer, device: device.card), store = try configured(issuer: issuer, device: device, certificate: cert); defer { try? store.vault?.delete() }
        let room = Room(id: "dm:"+[store.myID,other.id].sorted().joined(separator: ":"),title: "",members: [try issuer.card,other],creator: "",isGroup: false,createdAt: Date())
        store.state.rooms = [room]
        let message = ChatMessage(id: UUID().uuidString,roomID: room.id,sender: other.id,text: "Original",createdAt: Date(),attachment: nil)
        store.state.messages = [message]
        for command in [DeviceCommand(certificateID: cert.id,operation: "edit",roomID: room.id,target: message.id,text: "forged"),DeviceCommand(certificateID: cert.id,operation: "send",roomID: "missing",text: "forged")] {
            var event = ChatEvent(kind: "deviceCommand",room: room,senderName: "Device"); event.deviceCertificate = cert; event.deviceCommand = command
            try store.applyAccepted(event,sender: device.card)
            XCTAssertEqual(store.extended.completedDeviceCommands[command.key]?.status,"rejected")
            XCTAssertEqual(store.state.messages,[message])
        }
        let readonly = try certificate(issuer: issuer,device: device.card,scope: "history-live")
        XCTAssertThrowsError(try DeviceAuthority.validate(link: DeviceLink(certificate: readonly,peer: device.card,approved: true),certificate: readonly,sender: device.card,issuerID: issuer.card.id,revoked: [:]))
    }
    func testFileHistoryRequiresExplicitCollaborationAndNeverIncludesGhosts() throws {
        let owner = try LocalIdentity.create().card, peer = try LocalIdentity.create().card
        var state = VaultState(); let room = Room(id: "dm:test",title: "",members: [owner,peer],creator: "",isGroup: false,createdAt: Date()); state.rooms = [room]
        var file = Attachment(name: "file",mime: "application/octet-stream",data: Data()); file.blobID = try WorkProof.token(); file.blobReadToken = try WorkProof.token(); file.blobKey = try Crypto.random(32).base64EncodedString(); file.blobSize = 100; file.blobDigest = String(repeating: "a",count: 64)
        let message = ChatMessage(id: UUID().uuidString,roomID: room.id,sender: owner.id,text: "",createdAt: Date(),attachment: file)
        var ghost = message; ghost.id = UUID().uuidString; ghost.attachment?.viewSeconds = 30
        state.messages = [message,ghost]
        XCTAssertTrue(try DeviceHistory.snapshot(state: state,owner: owner).messages.isEmpty)
        let snapshot = try DeviceHistory.snapshot(state: state,owner: owner,shareFiles: true)
        XCTAssertEqual(snapshot.messages.count,1); XCTAssertEqual(snapshot.messages[0].attachment?.blobReadToken,file.blobReadToken)
        XCTAssertThrowsError(try DeviceHistory.validate(snapshot,owner: owner))
        XCTAssertNoThrow(try DeviceHistory.validate(snapshot,owner: owner,shareFiles: true))
    }
    func testExpiredFutureAndOversizedDelegatedCommandsFailBeforeAction() throws {
        var command = DeviceCommand(certificateID: UUID().uuidString,operation: "send",roomID: "dm:test",text: "hello")
        XCTAssertNoThrow(try command.validate()); command.createdAt = Date().addingTimeInterval(301); XCTAssertThrowsError(try command.validate())
        command.createdAt = Date().addingTimeInterval(-8*86400); XCTAssertThrowsError(try command.validate())
        command.createdAt = Date(); command.text = String(repeating: "x",count: 16001); XCTAssertThrowsError(try command.validate())
    }
}
