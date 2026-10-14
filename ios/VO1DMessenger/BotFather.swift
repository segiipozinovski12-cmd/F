import Foundation
import CryptoKit

struct ManagedBot: Codable, Identifiable {
    var card: ContactCard
    var keyProfileID: String
    var server: String
    var name: String
    var username: String
    var token: String
    var commands: [String: String]
    var registered = false
    var settingsPending = true
    var enabled = true
    var tokenRotationPending: Bool? = nil
    var id: String { card.id }
}
struct BotDirectoryEntry: Decodable, Identifiable {
    var id: String; var username: String; var name: String; var enabled: Bool; var commands: [String]
}

enum BotCommandRouter {
    static func reply(to event: ChatEvent, sender: ContactCard, bot: ContactCard, commands: [String: String]) -> String? {
        let room = event.room
        guard event.kind == "message", !room.isGroup, room.members.count == 2,
              Set(room.members.map(\.id)) == Set([sender.id, bot.id]),
              room.id == "dm:" + [sender.id, bot.id].sorted().joined(separator: ":"),
              let message = event.message, message.sender == sender.id, message.roomID == room.id,
              message.text.count <= 20000, message.viewOnceSeconds == nil, (message.expiresAt ?? .distantFuture) > Date() else { return nil }
        let command = String(message.text.split(whereSeparator: { $0.isWhitespace }).first ?? "").lowercased()
        guard command.hasPrefix("/") else { return "Доступные команды: " + commands.keys.sorted().map { "/" + $0 }.joined(separator: ", ") }
        let name = String(command.dropFirst()).split(separator: "@").first.map(String.init) ?? ""
        if name == "help" { return commands.keys.sorted().map { "/" + $0 }.joined(separator: "\n") }
        return commands[name].map { String($0.prefix(4000)) } ?? "Команда не найдена. /help — список команд."
    }
}

extension APIClient {
    func registerBot(_ bot: ManagedBot, keys: LocalIdentity, owner: String) async throws {
        struct Body: Encodable { var card: ContactCard; var name: String; var username: String; var token: String; var ownershipSignature: String }
        let digest = Crypto.hex(SHA256.hash(data: Data(bot.token.utf8)))
        let proof = Data("VO1D-BOT-CREATE-1\n\(owner)\n\(bot.id)\n\(bot.username)\n\(bot.name)\n\(digest)".utf8)
        let signature = try keys.signingPrivate.signature(for: proof).base64EncodedString()
        let _: OK = try await request("v2/bots", method: "POST", body: Wire.encoder.encode(Body(card: bot.card, name: bot.name, username: bot.username, token: bot.token, ownershipSignature: signature)))
    }
    func updateBot(_ bot: ManagedBot) async throws {
        struct Body: Encodable { var enabled: Bool; var commands: [String] }
        let _: OK = try await request("v2/bots/\(bot.id)/settings", method: "POST", body: Wire.encoder.encode(Body(enabled: bot.enabled, commands: bot.commands.keys.sorted())))
    }
    func rotateBotToken(id: String, token: String) async throws {
        let _: OK = try await request("v2/bots/\(id)/token", method: "POST", body: Wire.encoder.encode(["token": token]))
    }
    func deleteBot(_ id: String) async throws {
        let _: OK = try await request("v2/bots/\(id)", method: "DELETE")
    }
    func botDirectory(_ id: String) async throws -> BotDirectoryEntry? {
        struct Response: Decodable { var bot: BotDirectoryEntry? }
        let result: Response = try await request("v2/bots/directory/\(id)")
        return result.bot
    }
}

extension ChatStore {
    func deleteManagedBot(_ id: String) async throws {
        guard !botsSyncing else { throw MessengerError.invalid("Дождись завершения текущей операции бота") }
        guard let api, let bot = state.managedBots?.first(where: { $0.id == id }) else { return }
        let expected = generation
        try await api.deleteBot(id)
        guard expected == generation else { throw CancellationError() }
        let previous = state
        state.managedBots?.removeAll { $0.id == id }
        do { try save() } catch { state = previous; throw error }
        try Vault(profileID: bot.keyProfileID).delete()
        try Keychain.delete(profileID: bot.keyProfileID)
        botStatuses[id] = nil
    }
    func createBot(name: String, username: String) throws {
        let clean = username.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        guard let api, (state.managedBots ?? []).count < 20, !name.isEmpty, name.count <= 40,
              !name.unicodeScalars.contains(where: { $0.value < 32 }), clean.hasSuffix("_bot"),
              clean.range(of: "^[a-z0-9_]{5,20}$", options: .regularExpression) != nil else {
            throw MessengerError.invalid("Нужны имя до 40 символов и username 5–20 символов с окончанием _bot")
        }
        let keyProfile = UUID().uuidString, keys = try Keychain.load(profileID: keyProfile)
        let bot = ManagedBot(card: try keys.card, keyProfileID: keyProfile, server: api.base.absoluteString, name: name, username: clean,
                             token: try Crypto.random(32).base64URL, commands: ["start": "Привет! Это \(name). /help — список команд.", "help": "Список команд"])
        var workerState = VaultState(); workerState.nickname = name; workerState.server = bot.server
        var extended = ExtendedState(); extended.signal = try SignalSnapshot.create(); workerState.extended = extended
        try Vault(profileID: keyProfile).write(workerState, key: keys.storage)
        let previous = state
        state.managedBots = (state.managedBots ?? []) + [bot]
        do { try save() } catch { state = previous; throw error }
        Task { await sync() }
    }

    func syncManagedBots(generation expected: Int) async {
        guard !botsSyncing, let ownerAPI = api else { return }
        botsSyncing = true
        defer { botsSyncing = false }
        let bots = state.managedBots ?? []
        guard !bots.isEmpty else { return }
        let batch = (0..<min(4, bots.count)).map { bots[(botCursor + $0) % bots.count] }
        botCursor = (botCursor + batch.count) % bots.count
        for bot in batch {
            guard expected == generation, !locked, !Task.isCancelled, bot.server == ownerAPI.base.absoluteString else { return }
            do {
                let keys = try Keychain.load(profileID: bot.keyProfileID)
                guard try keys.card.hasSameKeys(as: bot.card) else { throw MessengerError.invalid("Ключи бота отсутствуют или изменились") }
                if !bot.registered { try await ownerAPI.registerBot(bot, keys: keys, owner: myID) }
                if bot.registered && bot.tokenRotationPending == true { try await ownerAPI.rotateBotToken(id: bot.id, token: bot.token) }
                guard expected == generation, !locked, !Task.isCancelled else { return }
                if bot.settingsPending { try await ownerAPI.updateBot(bot) }
                guard expected == generation, !locked, !Task.isCancelled,
                      let index = state.managedBots?.firstIndex(where: { $0.id == bot.id }) else { return }
                state.managedBots?[index].registered = true
                if state.managedBots?[index].token == bot.token { state.managedBots?[index].tokenRotationPending = false }
                if state.managedBots?[index].commands == bot.commands && state.managedBots?[index].enabled == bot.enabled {
                    state.managedBots?[index].settingsPending = false
                }
                if !state.contacts.contains(where: { $0.id == bot.id }) {
                    state.contacts.append(Contact(card: bot.card, name: "@" + bot.username, isBot: true))
                    var local = extended; local.trustedIDs.append(bot.id); state.extended = local
                }
                try save()
                let worker = try NativeBotWorker(bot: bot, preferences: preferences)
                if bot.enabled {
                    try await worker.run {
                        expected == self.generation && !self.locked && !Task.isCancelled &&
                        self.state.managedBots?.contains(where: { $0.id == bot.id && $0.enabled && $0.token == bot.token }) == true
                    }
                } else {
                    defer { worker.api.invalidate() }
                    try await worker.flushPrivateLinks { expected == self.generation && !self.locked && !Task.isCancelled }
                }
                botStatuses[bot.id] = bot.enabled ? "Готов · работает при открытом VO1D" : "Остановлен"
            } catch {
                guard expected == generation else { return }
                botStatuses[bot.id] = error.localizedDescription
            }
        }
    }
}

/// A bounded foreground executor. Only bot-addressed E2EE content reaches this worker.
@MainActor
final class NativeBotWorker {
    let bot: ManagedBot
    let keys: LocalIdentity
    let vault: Vault
    let api: APIClient
    var state: VaultState
    init(bot: ManagedBot, preferences: PrivacyPreferences) throws {
        let loadedKeys = try Keychain.load(profileID: bot.keyProfileID)
        guard try loadedKeys.card.hasSameKeys(as: bot.card) else { throw MessengerError.invalid("Ключи бота не совпадают") }
        let loadedVault = try Vault(profileID: bot.keyProfileID)
        let loadedState = try loadedVault.read(key: loadedKeys.storage)
        let client = try APIClient(server: bot.server, identity: loadedKeys, privacy: preferences, botToken: bot.token)
        self.bot = bot
        keys = loadedKeys; vault = loadedVault; state = loadedState; api = client
    }
    func save() throws { try vault.write(state, key: keys.storage) }
    func maintainPrekeys(canContinue: () -> Bool) async throws {
        guard canContinue() else { return }
        if state.extended?.signal == nil {
            var local = state.extended ?? ExtendedState(); local.signal = try SignalSnapshot.create(); state.extended = local; try save()
        }
        guard var signal = state.extended?.signal else { return }
        if signal.pendingPublication == nil {
            let available = try await api.prekeyCount()
            guard canContinue() else { return }
            if available < 12 || Date().timeIntervalSince(signal.publishedAt ?? .distantPast) > 86400 {
                signal = try SignalProtocol.publication(state: signal, identity: keys, count: 24).0
                state.extended?.signal = signal; try save()
            }
        }
        if let pending = signal.pendingPublication {
            try await api.publishPrekeys(pending)
            guard canContinue() else { return }
            state.extended?.signal?.pendingPublication = nil
            state.extended?.signal?.publishedAt = Date(); try save()
        }
    }
    func preparePrivateInvite(canContinue: () -> Bool) async throws {
        state.extended?.privateLinks.removeAll { $0.expiresAt <= Int(Date().timeIntervalSince1970) }
        state.extended?.ownMailboxes.removeAll { $0.address.expiresAt <= Int(Date().timeIntervalSince1970) }
        guard canContinue(), (state.extended?.privateLinks.count ?? 0) < 32, (state.extended?.ownMailboxes.count ?? 0) < 512 else { throw MessengerError.invalid("Доступно до 32 ссылок и 512 приватных адресов бота") }
        try await maintainPrekeys(canContinue: canContinue)
        let bits = try await api.publicWorkBits()
        let mailbox = try await Task.detached(priority: .utility) { try LocalMailbox.create(peerID: nil, bits: bits) }.value
        guard canContinue() else { throw CancellationError() }
        state.extended?.ownMailboxes.append(mailbox); try save()
        try await api.registerMailbox(mailbox)
        guard canContinue() else { throw CancellationError() }
        if let index = state.extended?.ownMailboxes.firstIndex(where: { $0.id == mailbox.id }) { state.extended?.ownMailboxes[index].registered = true }
        try save()
        let bundle = try await api.prekey(bot.card)
        guard canContinue() else { throw CancellationError() }
        _ = try bundle.validated(for: bot.card)
        let invite = Invite(version: 2, server: bot.server, name: bot.name, card: bot.card, mailbox: mailbox.address, prekey: bundle)
        state.extended?.privateLinks.append(try PrivateLinkRecord.create(invitation: invite, mailbox: mailbox)); try save()
        try await flushPrivateLinks(canContinue: canContinue)
    }
    func flushPrivateLinks(canContinue: () -> Bool) async throws {
        state.extended?.privateLinks.removeAll { $0.expiresAt <= Int(Date().timeIntervalSince1970) }
        for record in (state.extended?.privateLinks ?? []).filter({ (!$0.published || $0.revocationPending) && $0.stopped != true && ($0.nextAttempt ?? .distantPast) <= Date() }).prefix(8) {
            guard canContinue(), let mailbox = state.extended?.ownMailboxes.first(where: { $0.id == record.mailboxID }) else { return }
            do {
                if record.revocationPending { try await api.revokePrivateInvite(record.token, mailbox: mailbox) }
                else { try await api.publishPrivateInvite(token: record.token, ciphertext: record.ciphertext, mailbox: mailbox, expiresAt: record.expiresAt) }
            } catch {
                guard canContinue() else { throw CancellationError() }
                if let index = state.extended?.privateLinks.firstIndex(where: { $0.id == record.id }) {
                    state.extended?.privateLinks[index].failure = error.localizedDescription
                    state.extended?.privateLinks[index].nextAttempt = Date().addingTimeInterval(60)
                    state.extended?.privateLinks[index].stopped = (error as? HTTPFailure).map { [400,403,404,409,413].contains($0.status) } ?? false
                }
                try save(); continue
            }
            guard canContinue() else { throw CancellationError() }
            if record.revocationPending { state.extended?.privateLinks.removeAll { $0.id == record.id } }
            else if let index = state.extended?.privateLinks.firstIndex(where: { $0.id == record.id }) { state.extended?.privateLinks[index].published = true; state.extended?.privateLinks[index].failure = nil; state.extended?.privateLinks[index].nextAttempt = nil }
            try save()
        }
    }
    func run(canContinue: () -> Bool) async throws {
        defer { api.invalidate() }
        guard canContinue() else { return }
        try await maintainPrekeys(canContinue: canContinue)
        try await flushPrivateLinks(canContinue: canContinue)
        guard canContinue() else { return }
        try await drain(canContinue: canContinue)
        guard canContinue(), state.outbox.count < 100 else { return }
        let inbox = try await api.inbox()
        guard canContinue() else { return }
        var ack: [String] = []
        for envelope in inbox {
            guard canContinue(), state.outbox.count < 100 else { break }
            if state.processed.contains(envelope.id) || envelope.expiresAt <= Int(Date().timeIntervalSince1970) { ack.append(envelope.id); continue }
            let sender = try await api.card(envelope.sender)
            guard canContinue() else { return }
            let packet = try Wire.decoder.decode(SignalPacket.self, from: Crypto.openPayload(envelope, identity: keys, sender: sender))
            try consume(packet, sender: sender, envelopeID: envelope.id)
            ack.append(envelope.id)
        }
        try save()
        if !ack.isEmpty { try await api.ack(ack) }
        guard canContinue() else { return }
        let activeMailboxes = (state.extended?.ownMailboxes ?? []).filter { $0.registered && $0.address.expiresAt > Int(Date().timeIntervalSince1970) }
        let start = activeMailboxes.isEmpty ? 0 : max(0, state.extended?.privateInboxOffset ?? 0) % activeMailboxes.count
        for offset in 0..<min(32, activeMailboxes.count) {
            let position = (start + offset) % activeMailboxes.count, mailbox = activeMailboxes[position]
            let privateInbox = try await api.privateInbox(mailbox)
            guard canContinue() else { return }
            var privateAck: [String] = []
            for envelope in privateInbox {
                if state.processed.contains(envelope.id) { privateAck.append(envelope.id); continue }
                guard state.outbox.count < 100 else { break }
                let opened = try PrivateMailboxCrypto.open(envelope, identity: keys, mailbox: mailbox)
                let packet = try Wire.decoder.decode(SignalPacket.self, from: opened.1)
                try consume(packet, sender: opened.0, envelopeID: envelope.id)
                privateAck.append(envelope.id)
            }
            state.extended?.privateInboxOffset = (position + 1) % activeMailboxes.count; try save()
            if !privateAck.isEmpty { try await api.privateAck(privateAck, mailbox: mailbox) }
            guard canContinue() else { return }
        }
        try await drain(canContinue: canContinue)
    }
    func consume(_ packet: SignalPacket, sender: ContactCard, envelopeID: String) throws {
        guard let current = state.extended?.signal else { return }
        let decrypted = try SignalProtocol.decrypt(packet, from: sender, state: current)
        let event = try Wire.decoder.decode(ChatEvent.self, from: decrypted.1)
        var next = state
        next.extended?.signal = decrypted.0
        if let known = next.contacts.first(where: { $0.id == sender.id }), !known.card.hasSameKeys(as: sender) { throw MessengerError.invalid("Ключ клиента бота изменился") }
        if !next.contacts.contains(where: { $0.id == sender.id }) {
            guard next.contacts.count < 1000 else { throw MessengerError.invalid("Лимит контактов бота достигнут") }
            next.contacts.append(Contact(card: sender, name: sender.shortID))
        }
        if let text = BotCommandRouter.reply(to: event, sender: sender, bot: bot.card, commands: bot.commands) {
            if let route = event.replyMailbox { try route.validate() }
            let room = event.room.wireCopy
            let reply = ChatMessage(id: UUID().uuidString, roomID: room.id, sender: bot.id, text: text, createdAt: Date(), expiresAt: event.message?.expiresAt, replyTo: event.message?.id, attachment: nil)
            let response = ChatEvent(kind: "message", room: room, message: reply, senderName: bot.name)
            let encrypted = try SignalProtocol.encrypt(Wire.encoder.encode(response), to: sender, identity: keys, state: decrypted.0)
            let outgoing: Envelope
            if let route = event.replyMailbox {
                let opaque = try PrivateMailboxCrypto.seal(encrypted.1, from: keys, to: sender, route: route, id: response.id, expiry: reply.expiresAt)
                outgoing = Envelope(id: opaque.id, sender: bot.id, recipient: sender.id, ephemeralKey: "", salt: "", expiresAt: opaque.expiresAt, ciphertext: "", signature: "", opaque: opaque)
            } else {
                outgoing = try Crypto.sealPayload(encrypted.1, from: keys, to: sender, expiry: reply.expiresAt, id: response.id)
            }
            next.extended?.signal = encrypted.0
            next.outbox.append(PendingDelivery(envelope: outgoing))
        }
        next.processed = Array((next.processed + [envelopeID]).suffix(5000))
        try vault.write(next, key: keys.storage)
        state = next
    }
    private func drain(canContinue: () -> Bool) async throws {
        state.outbox.removeAll { $0.envelope.expiresAt <= Int(Date().timeIntervalSince1970) }
        let ids = Set(state.outbox.map(\.id))
        state.deliveryRetryState = (state.deliveryRetryState ?? [:]).filter { ids.contains($0.key) }
        try save()
        for pending in SmartQueue.ready(state.outbox, issues: state.deliveryRetryState ?? [:], limit: 8) {
            guard canContinue() else { return }
            do { try await api.send(pending.envelope) }
            catch {
                guard canContinue() else { return }
                let attempts = (state.deliveryRetryState?[pending.id]?.attempts ?? 0) + 1
                let permanent = (error as? HTTPFailure).map { [400,404,409,413].contains($0.status) } ?? false
                state.deliveryRetryState?[pending.id] = DeliveryIssue(id: pending.id, detail: error.localizedDescription, attempts: attempts, nextAttempt: permanent ? .distantFuture : Date().addingTimeInterval(min(300, pow(2, Double(min(8, attempts))))))
                try save(); continue
            }
            guard canContinue() else { return }
            state.deliveryRetryState?[pending.id] = nil
            state.outbox.removeAll { $0.id == pending.id }; try save()
        }
    }
}
