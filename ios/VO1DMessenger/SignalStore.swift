import Foundation
import LibSignalClient

extension ChatStore {
    func maintainSignalPrekeys(api: APIClient, identity: LocalIdentity, generation expected: Int) async throws {
        if extended.signal == nil {
            var local = extended; local.signal = try SignalSnapshot.create(); state.extended = local
            try save()
        }
        guard var signal = extended.signal else { return }
        if signal.pendingPublication == nil {
            let available = try await api.prekeyCount()
            guard expected == generation, let fresh = extended.signal else { throw CancellationError() }
            signal = fresh
            if signal.pendingPublication == nil {
                if available >= 12, let last = signal.publishedAt, Date().timeIntervalSince(last) < 86400 { return }
                let generated = try SignalProtocol.publication(state:signal,identity:identity)
                signal = generated.0
                var local = extended; local.signal = signal; state.extended = local
                // Re-read after the await; never overwrite sessions advanced by
                // another foreground operation during the inventory request.
                try save()
            }
        }
        guard let pending = signal.pendingPublication else { return }
        try await api.publishPrekeys(pending)
        guard expected == generation else { throw CancellationError() }
        var local = extended
        guard local.signal?.pendingPublication?.bundles.map(\.prekeyId) == pending.bundles.map(\.prekeyId) else { return }
        local.signal?.pendingPublication = nil; local.signal?.publishedAt = Date()
        state.extended = local; try save()
    }

    func prepareSignalDelivery(_ pending: PendingDelivery, api: APIClient, identity: LocalIdentity, generation expected: Int) async throws -> Envelope {
        guard let clear = pending.envelope.deferredEvent else { return pending.envelope }
        var event = try Wire.decoder.decode(ChatEvent.self, from: clear)
        let target = state.contacts.first(where: { $0.id == pending.envelope.recipient })?.card
            ?? state.rooms.flatMap(\.members).first(where: { $0.id == pending.envelope.recipient })
        guard let target, let initial = extended.signal else { throw MessengerError.invalid("Ключи контакта недоступны") }
        let probe = SignalVaultStore(initial), address = try SignalProtocol.address(target)
        let bundle: SignalBundle?
        if try probe.loadSession(for: address, context: NullContext())?.hasCurrentState != true {
            if let invited = extended.invitationBundles[target.id] { bundle = invited }
            else { bundle = try await api.prekey(target) }
        }
        else { bundle = nil }
        let receiving = try await ensurePrivateMailbox(peerID: target.id, roomID:event.room.id, api: api, generation: expected)
        guard expected == generation, let current = extended.signal,
              let index = state.outbox.firstIndex(where: { $0.id == pending.id }) else { throw CancellationError() }
        // A send/retry can have completed while a prekey request was in flight.
        if state.outbox[index].envelope.deferredEvent == nil { return state.outbox[index].envelope }
        event.replyMailbox = receiving.address
        let result = try SignalProtocol.encrypt(Wire.encoder.encode(event), to: target, identity: identity, state: current, bundle: bundle)
        let envelope: Envelope
        if let route = privateRoute(peerID:target.id,roomID:event.room.id) {
            let opaque = try PrivateMailboxCrypto.seal(result.1, from: identity, to: target, route: route, id: pending.envelope.id, expiry: event.message?.expiresAt)
            envelope = Envelope(id: opaque.id, sender: try identity.card.id, recipient: target.id, ephemeralKey: "", salt: "", expiresAt: opaque.expiresAt, ciphertext: "", signature: "", opaque: opaque)
        } else {
            guard !preferences.requirePrivateDelivery else { throw MessengerError.invalid("Нужен приватный адрес контакта") }
            envelope = try Crypto.sealPayload(result.1, from: identity, to: target, expiry: event.message?.expiresAt, id: pending.envelope.id)
        }
        let previous = state
        var local = extended; local.signal = result.0; local.invitationBundles[target.id] = nil; state.extended = local
        state.outbox[index].envelope = envelope
        do { try save() } catch { state = previous; throw error }
        return envelope
    }

    func openSignalEvent(_ envelope: Envelope, identity: LocalIdentity, sender: ContactCard) throws -> ChatEvent {
        let payload = try Crypto.openPayload(envelope, identity: identity, sender: sender)
        if let packet = try? Wire.decoder.decode(SignalPacket.self, from: payload) {
            guard let current = extended.signal else { throw MessengerError.invalid("Сначала подготовь ключи v2") }
            let result = try SignalProtocol.decrypt(packet, from: sender, state: current)
            let event = try Wire.decoder.decode(ChatEvent.self, from: result.1)
            var local = extended; local.signal = result.0; state.extended = local
            try acceptReplyMailbox(event.replyMailbox, sender: sender,roomID:event.room.id)
            return event
        }
        if extended.signal?.trusted["\(sender.id):1"] != nil {
            throw MessengerError.invalid("Понижение защиты: контакт уже использует v2")
        }
        // Legacy history and incoming migration messages remain readable; no new v1 sends.
        return try Wire.decoder.decode(ChatEvent.self, from: payload)
    }
}
