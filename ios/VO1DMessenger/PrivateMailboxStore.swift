import Foundation
import CryptoKit

extension ChatStore {
    func ensurePrivateMailbox(peerID: String?, api: APIClient, generation expected: Int, fresh: Bool = false) async throws -> LocalMailbox {
        if !fresh, let mailbox = extended.ownMailboxes.last(where: { $0.peerID == peerID && $0.address.expiresAt > Int(Date().timeIntervalSince1970) + 7 * 86400 }) {
            if !mailbox.registered {
                try await api.registerMailbox(mailbox)
                guard expected == generation else { throw CancellationError() }
                var local = extended
                if let i = local.ownMailboxes.firstIndex(where: { $0.id == mailbox.id }) { local.ownMailboxes[i].registered = true }
                state.extended = local; try save()
            }
            var ready = mailbox; ready.registered = true; return ready
        }
        let mailbox = try await Task.detached(priority: .utility) { try LocalMailbox.create(peerID: peerID) }.value
        guard expected == generation else { throw CancellationError() }
        var local = extended; local.ownMailboxes.append(mailbox); state.extended = local
        try save()
        try await api.registerMailbox(mailbox)
        guard expected == generation else { throw CancellationError() }
        local = extended
        if let i = local.ownMailboxes.firstIndex(where: { $0.id == mailbox.id }) { local.ownMailboxes[i].registered = true }
        state.extended = local; try save()
        var ready = mailbox; ready.registered = true; return ready
    }
    func preparePrivateInvite() async throws {
        guard let api, let identity, let card = ownCard else { throw MessengerError.invalid("Сначала подключись к relay") }
        let expected = generation
        try await maintainSignalPrekeys(api: api, identity: identity, generation: expected)
        let mailbox = try await ensurePrivateMailbox(peerID: nil, api: api, generation: expected, fresh: true)
        let bundle = try await api.prekey(card)
        guard expected == generation else { throw CancellationError() }
        _ = try bundle.validated(for: card)
        let invitation = Invite(version: 2, server: state.server, name: state.nickname, card: card, mailbox: mailbox.address, prekey: bundle)
        let token = try Crypto.random(32).base64URL, key = try Crypto.random(32)
        let box = try AES.GCM.seal(Wire.encoder.encode(invitation), using: SymmetricKey(data: key), authenticating: Data("VO1D-PRIVATE-INVITE-2\n\(token)".utf8))
        guard let encrypted = box.combined else { throw MessengerError.invalid("Ошибка приглашения") }
        try await api.publishPrivateInvite(token: token, ciphertext: encrypted, mailbox: mailbox)
        guard expected == generation else { throw CancellationError() }
        var local = extended
        local.privateInvite = invitation
        local.privateInviteLink = "vo1d://private/\(token)/\(key.base64URL)"
        state.extended = local; try save()
    }
    func acceptReplyMailbox(_ route: MailboxAddress?, sender: ContactCard) throws {
        guard let route else { return }
        try route.validate()
        var local = extended; local.peerMailboxes[sender.id] = route; state.extended = local
    }
    func importPrivateInvite(_ invite: Invite) throws {
        guard invite.version == 2, let route = invite.mailbox, let bundle = invite.prekey else { throw MessengerError.invalid("В приглашении отсутствуют приватный адрес или ключи") }
        try route.validate(); _ = try bundle.validated(for: invite.card)
        var local = extended
        local.peerMailboxes[invite.card.id] = route
        local.invitationBundles[invite.card.id] = bundle
        state.extended = local
    }
    func decodePrivateLink(_ link: String) async throws -> Invite {
        let parts = String(link.dropFirst("vo1d://private/".count)).split(separator: "/")
        guard parts.count == 2, let api else { throw MessengerError.invalid("Недействительное приватное приглашение") }
        let token = String(parts[0]), key = try Data.decodeURL(String(parts[1]))
        guard token.count == 43, key.count == 32 else { throw MessengerError.invalid("Недействительный ключ приглашения") }
        let encrypted = try await api.redeemPrivateInvite(token: token)
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: SymmetricKey(data: key), authenticating: Data("VO1D-PRIVATE-INVITE-2\n\(token)".utf8))
        let invite = try Wire.decoder.decode(Invite.self, from: clear)
        let server = try APIClient.validateURL(invite.server,privacy:preferences)
        guard server == api.base else { throw MessengerError.invalid("Приглашение использует другой relay") }
        return invite
    }
    func collectPrivateInbox(api: APIClient, identity: LocalIdentity, generation expected: Int) async throws {
        let active = extended.ownMailboxes.filter { $0.registered && $0.address.expiresAt > Int(Date().timeIntervalSince1970) }
        for mailbox in active {
            let envelopes = try await api.privateInbox(mailbox)
            guard expected == generation else { throw CancellationError() }
            var ack: [String] = []
            for envelope in envelopes {
                if state.processed.contains(envelope.id) { ack.append(envelope.id); continue }
                do {
                    let content = try PrivateMailboxCrypto.open(envelope, identity: identity, mailbox: mailbox)
                    if !state.contacts.contains(where: { $0.id == content.0.id && $0.blocked }) {
                        guard let signal = extended.signal else { throw MessengerError.invalid("Ключи v2 недоступны") }
                        let packet = try Wire.decoder.decode(SignalPacket.self, from: content.1)
                        let result = try SignalProtocol.decrypt(packet, from: content.0, state: signal)
                        let event = try Wire.decoder.decode(ChatEvent.self, from: result.1)
                        var local = extended; local.signal = result.0; state.extended = local
                        try acceptReplyMailbox(event.replyMailbox, sender: content.0)
                        try applyAccepted(event, sender: content.0)
                        if mailbox.peerID == nil {
                            local = extended
                            if let i = local.ownMailboxes.firstIndex(where: { $0.id == mailbox.id }) { local.ownMailboxes[i].peerID = content.0.id }
                            state.extended = local
                        }
                    }
                } catch { self.error = "Отклонён приватный конверт: \(error.localizedDescription)" }
                state.processed.append(envelope.id); ack.append(envelope.id)
            }
            // Commit ratchet advancement and content together, then delete relay copies.
            try save()
            if !ack.isEmpty { try await api.privateAck(ack, mailbox: mailbox) }
        }
    }
    func revokePrivateAddresses(_ peerID: String) async throws {
        guard let api else { return }
        for mailbox in extended.ownMailboxes.filter({ $0.peerID == peerID }) { try await api.deleteMailbox(mailbox) }
        var local = extended
        local.ownMailboxes.removeAll { $0.peerID == peerID }
        local.peerMailboxes[peerID] = nil; local.invitationBundles[peerID] = nil
        state.extended = local; try save()
    }
}
