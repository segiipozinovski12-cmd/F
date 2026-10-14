import XCTest
import Foundation
@testable import VO1DMessenger

@MainActor
final class NextSecurityTests: XCTestCase {
    private func event(alice: ContactCard, bot: ContactCard, text: String) -> ChatEvent {
        let room = Room(id: "dm:" + [alice.id, bot.id].sorted().joined(separator: ":"), title: "Bot", members: [alice, bot], creator: alice.id, isGroup: false, createdAt: Date())
        let message = ChatMessage(id: UUID().uuidString, roomID: room.id, sender: alice.id, text: text, createdAt: Date(), expiresAt: nil, replyTo: nil, attachment: nil)
        return ChatEvent(kind: "message", room: room, message: message, senderName: "Alice")
    }

    func testReportSharesOnlySelectedEvidenceAndRejectsDifferentRecipient() throws {
        let reporter = try LocalIdentity.create(), admin = try LocalIdentity.create(), outsider = try LocalIdentity.create()
        let id = UUID().uuidString
        let selected = ReportEvidence(id: UUID().uuidString, sender: try outsider.card.id, text: "VOLUNTARILY_SELECTED_EVIDENCE", createdAt: Date())
        let content = ReportContent(reportID: id, subject: try outsider.card.id, reason: .harassment, source: "message", comment: "Chosen comment", messages: [selected])
        let sealed = try Crypto.sealPayload(Wire.encoder.encode(content), from: reporter, to: admin.card, id: id)
        let request = ReportSubmission(subject: content.subject, reason: content.reason.rawValue, source: content.source, consent: true, envelope: sealed)
        let wire = try XCTUnwrap(String(data: Wire.encoder.encode(request), encoding: .utf8))
        XCTAssertFalse(wire.contains("VOLUNTARILY_SELECTED_EVIDENCE"))
        XCTAssertFalse(wire.contains("Chosen comment"))
        let opened = try Wire.decoder.decode(ReportContent.self, from: Crypto.openPayload(sealed, identity: admin, sender: reporter.card)).validated(for: sealed)
        XCTAssertEqual(opened.messages.count, 1)
        XCTAssertEqual(opened.messages.first?.text, selected.text)
        XCTAssertThrowsError(try Crypto.openPayload(sealed, identity: outsider, sender: reporter.card))
        var changed = sealed; changed.recipient = try outsider.card.id
        XCTAssertThrowsError(try Crypto.openPayload(changed, identity: outsider, sender: reporter.card))
    }

    func testReportDomainAndLimitsAreCheckedAfterDecryption() throws {
        let alice = try LocalIdentity.create(), admin = try LocalIdentity.create()
        let id = UUID().uuidString
        var content = ReportContent(reportID: id, subject: try alice.card.id, reason: .other, source: "profile", comment: "", messages: [])
        let envelope = try Crypto.sealPayload(Wire.encoder.encode(content), from: alice, to: admin.card, id: id)
        content.kind = "VO1D-BACKUP-1"
        XCTAssertThrowsError(try content.validated(for: envelope))
        content.kind = "VO1D-REPORT-1"; content.comment = String(repeating: "x", count: 4001)
        XCTAssertThrowsError(try content.validated(for: envelope))
    }

    func testDurableRetriesAndPendingReportsSurviveVaultRestart() throws {
        let profile = UUID().uuidString, keys = try LocalIdentity.create(), admin = try LocalIdentity.create()
        let vault = try Vault(profileID: profile)
        defer { try? vault.delete() }
        let envelope = try Crypto.sealPayload(Data("sealed evidence".utf8), from: keys, to: admin.card)
        var state = VaultState()
        state.pendingReports = [PendingReport(submission: ReportSubmission(subject: try admin.card.id, reason: "other", source: "profile", consent: true, envelope: envelope))]
        state.deliveryRetryState = ["pending": DeliveryIssue(id: "pending", detail: "retry", attempts: 4, nextAttempt: Date().addingTimeInterval(60))]
        state.secureNotes = [SecureNote(title: "local", text: "not a chat event")]
        try vault.write(state, key: keys.storage)
        let restored = try vault.read(key: keys.storage)
        XCTAssertEqual(restored.pendingReports?.first?.submission.envelope.ciphertext, envelope.ciphertext)
        XCTAssertEqual(restored.deliveryRetryState?["pending"]?.attempts, 4)
        XCTAssertEqual(restored.secureNotes?.first?.text, "not a chat event")
    }

    func testBotRepliesUseSignalAndExactCiphertextSurvivesWorkerRestart() throws {
        let profile = UUID().uuidString, botKeys = try Keychain.load(profileID: profile), alice = try LocalIdentity.create()
        let vault = try Vault(profileID: profile)
        defer { try? vault.delete(); try? Keychain.delete(profileID: profile) }
        let bot = ManagedBot(card: try botKeys.card, keyProfileID: profile, server: "https://relay.example", name: "Test", username: "test_bot", token: try Crypto.random(32).base64URL, commands: ["ping": "pong"])
        let published = try SignalProtocol.publication(state: SignalSnapshot.create(), identity: botKeys, count: 1)
        var state = VaultState(); var local = ExtendedState(); local.signal = published.0; state.extended = local
        try vault.write(state, key: botKeys.storage)
        let request = event(alice: try alice.card, bot: bot.card, text: "/ping")
        let sent = try SignalProtocol.encrypt(Wire.encoder.encode(request), to: bot.card, identity: alice, state: SignalSnapshot.create(), bundle: published.1.bundles[0])
        let packet = try Wire.decoder.decode(SignalPacket.self, from: sent.1)
        let worker = try NativeBotWorker(bot: bot, preferences: PrivacyPreferences())
        try worker.consume(packet, sender: alice.card, envelopeID: request.id)
        let restart = try NativeBotWorker(bot: bot, preferences: PrivacyPreferences())
        let ready = try XCTUnwrap(restart.state.outbox.first?.envelope)
        XCTAssertEqual(ready.ciphertext, worker.state.outbox.first?.envelope.ciphertext)
        let replyPacket = try Wire.decoder.decode(SignalPacket.self, from: Crypto.openPayload(ready, identity: alice, sender: bot.card))
        let reply = try SignalProtocol.decrypt(replyPacket, from: bot.card, state: sent.0)
        XCTAssertEqual(try Wire.decoder.decode(ChatEvent.self, from: reply.1).message?.text, "pong")
        XCTAssertThrowsError(try restart.consume(packet, sender: alice.card, envelopeID: request.id))
        XCTAssertEqual(restart.state.outbox.count, 1)
        worker.api.invalidate(); restart.api.invalidate()
    }

    func testBotCannotReplyToGroupOrForgedMessageAuthor() throws {
        let alice = try LocalIdentity.create(), bot = try LocalIdentity.create()
        var request = event(alice: try alice.card, bot: try bot.card, text: "/ping")
        XCTAssertEqual(BotCommandRouter.reply(to: request, sender: try alice.card, bot: try bot.card, commands: ["ping": "pong"]), "pong")
        request.room.isGroup = true
        XCTAssertNil(BotCommandRouter.reply(to: request, sender: try alice.card, bot: try bot.card, commands: ["ping": "pong"]))
        request.room.isGroup = false; request.message?.sender = try bot.card.id
        XCTAssertNil(BotCommandRouter.reply(to: request, sender: try alice.card, bot: try bot.card, commands: ["ping": "pong"]))
    }

    func testLocalLinkWarningsAndKeyValidation() throws {
        XCTAssertTrue(SafeContent.linkWarnings(URL(string: "https://example.org/normal")!).isEmpty)
        XCTAssertFalse(SafeContent.linkWarnings(URL(string: "http://127.0.0.1:8080/path")!).isEmpty)
        XCTAssertFalse(SafeContent.linkWarnings(URL(string: "https://bit.ly/hidden")!).isEmpty)
        XCTAssertFalse(SafeContent.linkWarnings(URL(string: "https://xn--example-9za.org")!).isEmpty)
        XCTAssertThrowsError(try LocalIdentity(signing: Data(repeating: 1, count: 31), agreement: Data(repeating: 2, count: 32), storage: Data(repeating: 3, count: 32)).validate())
        XCTAssertNoThrow(try LocalIdentity.create().validate())
        let valid = try LocalIdentity.create()
        var invalidCard = try valid.card
        invalidCard.agreementKey = Data(repeating: 0, count: 32).base64EncodedString()
        invalidCard.binding = try valid.signingPrivate.signature(for: Crypto.cardBytes(invalidCard)).base64EncodedString()
        XCTAssertThrowsError(try Crypto.validate(invalidCard))
    }

    func testBackupExcludesBotCredentialsAndPendingReports() throws {
        let keys = try LocalIdentity.create(), botKeys = try LocalIdentity.create()
        var state = VaultState()
        state.managedBots = [ManagedBot(card: try botKeys.card, keyProfileID: UUID().uuidString, server: "https://relay.example", name: "Test", username: "test_bot", token: "NEVER_EXPORT_THIS_TOKEN", commands: [:])]
        state.secureNotes = [SecureNote(title: "local", text: "secret note")]
        let full = try SecureBackup.sanitized(BackupPayload(identity: keys, state: state, mode: .full))
        XCTAssertNil(full.state.managedBots)
        XCTAssertNil(full.state.pendingReports)
        XCTAssertEqual(full.state.secureNotes?.count, 1)
        let history = try SecureBackup.sanitized(BackupPayload(identity: keys, state: state, mode: .history))
        XCTAssertNil(history.state.secureNotes)
    }
    func testGhostConsumptionPersistsBeforeReopenAndCannotLeakToBackupOrDeviceHistory() throws {
        let keys = try LocalIdentity.create(), peer = try LocalIdentity.create().card
        let profile = UUID().uuidString, vault = try Vault(profileID: profile)
        defer { try? vault.delete() }
        let room = Room(id: "dm:ghost", title: "", members: [try keys.card, peer], creator: "", isGroup: false, createdAt: Date())
        var state = VaultState(); state.extended = ExtendedState(); state.rooms = [room]
        var message = ChatMessage(id: UUID().uuidString, roomID: room.id, sender: peer.id, text: "ONE_VIEW_SECRET", createdAt: Date(), expiresAt: Date().addingTimeInterval(3600), replyTo: nil, attachment: nil)
        message.viewOnceSeconds = 30; state.messages = [message]
        XCTAssertTrue(try DeviceHistory.snapshot(state: state, owner: keys.card).messages.isEmpty)
        XCTAssertTrue(try SecureBackup.sanitized(BackupPayload(identity: keys, state: state, mode: .full)).state.messages.isEmpty)
        let opened = try GhostText.consume(message.id, state: &state)
        XCTAssertEqual(opened.0, "ONE_VIEW_SECRET"); XCTAssertEqual(opened.1, 30)
        try vault.write(state, key: keys.storage)
        var restored = try vault.read(key: keys.storage)
        XCTAssertEqual(restored.messages[0].text, "")
        XCTAssertNotNil(restored.extended?.consumedGhosts[GhostText.key(message)])
        XCTAssertThrowsError(try GhostText.consume(message.id, state: &restored))
        restored.messages[0].openedAt = nil; restored.messages[0].text = "REPLAY_SECRET"
        XCTAssertThrowsError(try GhostText.consume(message.id, state: &restored))
    }

    func testLiveDeviceSnapshotAuthorityAndReorderedDeliveryAcrossRestart() throws {
        let keys = try LocalIdentity.create(), owner = try keys.card, device = try LocalIdentity.create().card, outsider = try LocalIdentity.create().card
        var certificate = DeviceCertificate(id: UUID().uuidString, issuer: owner, device: device.id, expiresAt: Int(Date().timeIntervalSince1970) + 3600, signature: "")
        certificate.scope = "history-live"; certificate.signature = try keys.signingPrivate.signature(for: certificate.signed).base64EncodedString()
        var link = DeviceLink(certificate: certificate, peer: owner, approved: true)
        var archive = try DeviceHistory.snapshot(state: VaultState(), owner: owner); archive.id = certificate.id
        XCTAssertTrue(try DeviceHistory.acceptSnapshot(archive, revision: 2, link: link, sender: owner, deviceID: device.id))
        link.receivedRevision = 2
        let restored = try Wire.decoder.decode(DeviceLink.self, from: Wire.encoder.encode(link))
        XCTAssertFalse(try DeviceHistory.acceptSnapshot(archive, revision: 1, link: restored, sender: owner, deviceID: device.id))
        XCTAssertFalse(try DeviceHistory.acceptSnapshot(archive, revision: 2, link: restored, sender: owner, deviceID: device.id))
        XCTAssertThrowsError(try DeviceHistory.acceptSnapshot(archive, revision: 3, link: link, sender: outsider, deviceID: device.id))
        XCTAssertThrowsError(try DeviceHistory.acceptSnapshot(archive, revision: 3, link: link, sender: owner, deviceID: outsider.id))
        link.approved = false
        XCTAssertThrowsError(try DeviceHistory.acceptSnapshot(archive, revision: 3, link: link, sender: owner, deviceID: device.id))
    }

    func testPrivateLinkExactPublicationSurvivesVaultRestartAndBackupExcludesSecrets() throws {
        let keys = try LocalIdentity.create(), profile = UUID().uuidString, vault = try Vault(profileID: profile)
        defer { try? vault.delete() }
        let mailbox = LocalMailbox(address: MailboxAddress(id: try Crypto.random(32).base64URL, writeToken: try Crypto.random(32).base64URL, expiresAt: Int(Date().timeIntervalSince1970) + 86400), readToken: try Crypto.random(32).base64URL, peerID: nil, registered: true, proof: "123")
        let publication = try SignalProtocol.publication(state: SignalSnapshot.create(), identity: keys, count: 1)
        let invitation = Invite(version: 2, server: "https://relay.example", name: "test", card: try keys.card, mailbox: mailbox.address, prekey: publication.1.bundles[0])
        let record = try PrivateLinkRecord.create(invitation: invitation, mailbox: mailbox)
        var state = VaultState(); state.extended = ExtendedState(); state.extended?.privateLinks = [record]
        try vault.write(state, key: keys.storage)
        let restored = try vault.read(key: keys.storage)
        XCTAssertEqual(restored.extended?.privateLinks[0].ciphertext, record.ciphertext)
        XCTAssertEqual(restored.extended?.privateLinks[0].expiresAt, record.expiresAt)
        let backup = try SecureBackup.sanitized(BackupPayload(identity: keys, state: state, mode: .full))
        XCTAssertTrue(backup.state.extended?.privateLinks.isEmpty == true)
    }
    func testSeededContactAndEnvelopeMutationsNeverAuthenticate() throws {
        let sender = try LocalIdentity.create(), recipient = try LocalIdentity.create()
        let cardData = try Wire.encoder.encode(sender.card)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: cardData) as? [String: Any])
        let fields = ["id", "signingKey", "agreementKey", "binding"]
        var seed: UInt64 = 0x564F31444E455854
        let values: [Any] = ["", true, NSNull(), ["unexpected"], 42, String(repeating: "A", count: 200)]
        for _ in 0..<256 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            var input = original
            input[fields[Int((seed >> 32) % 4)]] = values[Int(seed % UInt64(values.count))]
            let data = try JSONSerialization.data(withJSONObject: input)
            if let decoded = try? Wire.decoder.decode(ContactCard.self, from: data) { XCTAssertThrowsError(try Crypto.validate(decoded)) }
        }
        let sealed = try Crypto.sealPayload(Data("VALID_CONTROL".utf8), from: sender, to: recipient.card)
        XCTAssertEqual(try Crypto.openPayload(sealed, identity: recipient, sender: sender.card), Data("VALID_CONTROL".utf8))
        for index in 0..<128 {
            var changed = sealed
            var ciphertext = try Crypto.decode(changed.ciphertext)
            ciphertext[index % ciphertext.count] ^= UInt8(index % 255 + 1)
            changed.ciphertext = ciphertext.base64EncodedString()
            XCTAssertThrowsError(try Crypto.openPayload(changed, identity: recipient, sender: sender.card))
        }
    }
}
