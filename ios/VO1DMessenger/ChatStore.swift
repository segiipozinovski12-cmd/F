import Foundation
import SwiftUI
import LocalAuthentication
import CryptoKit

@MainActor
final class ChatStore: ObservableObject {
    @Published var state = VaultState()
    @Published var error: String?
    @Published var connection = "Не подключён"
    @Published var busy = false
    @Published var locked = false
    @Published var sessionUnlocked = false
    @Published var fatalError: String?
    @Published var typing: [String: Date] = [:]
    private(set) var identity: LocalIdentity?
    private(set) var ownCard: ContactCard?
    private var vault: Vault?
    private var api: APIClient?
    private var syncing = false
    private var generation = 0
    private var lastTyping: [String: Date] = [:]
    var myID: String { ownCard?.id ?? "" }

    init() {
        do {
            let identity = try Keychain.load()
            let vault = try Vault()
            self.identity = identity; self.vault = vault; ownCard = try identity.card
            state = try vault.read(key: identity.storage)
            let credentialsChanged = try ensureCredentials()
            locked = state.appLock
            sessionUnlocked = !state.onboarded
            if !state.server.isEmpty { api = try APIClient(server: state.server, identity: identity) }
            expire()
            if credentialsChanged { try save() }
        } catch { fatalError = error.localizedDescription }
    }
    func save() throws {
        guard let identity, let vault else { throw MessengerError.invalid("Хранилище недоступно") }
        try vault.write(state, key: identity.storage)
    }
    func persist() {
        do { try save() } catch { self.error = error.localizedDescription }
    }
    func configure(name: String, server: String) async {
        guard let identity else { return }
        busy = true; defer { busy = false }
        do {
            let firstLaunch = !state.onboarded
            let client = try APIClient(server: server, identity: identity)
            try await client.authenticate()
            let publicCode = try await client.ensurePublicCode()
            api = client
            state.server = client.base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            state.nickname = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            if state.nickname.isEmpty { state.nickname = "Ghost" }
            _ = try ensureCredentials()
            state.publicCode = publicCode
            state.onboarded = true
            if firstLaunch { state.credentialsAcknowledged = false }
            sessionUnlocked = true
            try save()
            connection = "Подключён"
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    private func ensureCredentials() throws -> Bool {
        var changed = false
        if state.publicCode == nil {
            state.publicCode = try randomToken(length: 4)
            changed = true
        }
        if state.accessKey == nil {
            state.accessKey = try randomToken(length: 9)
            changed = true
        }
        if state.credentialsAcknowledged == nil {
            state.credentialsAcknowledged = state.onboarded ? false : nil
            changed = changed || state.onboarded
        }
        return changed
    }

    private func randomToken(length: Int) throws -> String {
        let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        let bytes = try Crypto.random(length)
        return bytes.map { String(alphabet[Int($0) & 31]) }.joined()
    }

    func finishLocalOnboarding(name: String) {
        do {
            state.nickname = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            if state.nickname.isEmpty { state.nickname = "Ghost" }
            _ = try ensureCredentials()
            state.onboarded = true
            state.credentialsAcknowledged = false
            sessionUnlocked = true
            try save()
        } catch { self.error = error.localizedDescription }
    }

    func acknowledgeCredentials() {
        state.credentialsAcknowledged = true
        sessionUnlocked = true
        persist()
    }

    func unlockWithAccessKey(_ value: String) -> Bool {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard candidate == state.accessKey else {
            error = "Неверный ключ доступа"
            return false
        }
        sessionUnlocked = true
        return true
    }

    func setEmergencyCode(_ value: String) -> Bool {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 4, code.allSatisfy({ $0.isNumber }) else {
            error = "Код экстренного сброса должен состоять из 4 цифр"
            return false
        }
        state.panicCodeHash = emergencyDigest(code)
        persist()
        return true
    }

    private func emergencyDigest(_ code: String) -> String {
        Crypto.hex(SHA256.hash(data: Data("VO1D-EMERGENCY-1\n\(code)".utf8)))
    }

    func emergencyReset(code: String) async -> Bool {
        guard let expected = state.panicCodeHash,
              emergencyDigest(code.trimmingCharacters(in: .whitespacesAndNewlines)) == expected else {
            error = "Неверный код экстренного сброса"
            return false
        }
        busy = true
        defer { busy = false }
        generation += 1
        if let api { try? await api.deleteAccount() }
        do {
            try resetLocalIdentity()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    func invite() throws -> String {
        guard let ownCard else { throw MessengerError.invalid("Нет ключей") }
        let data = try Wire.encoder.encode(Invite(server: state.server, name: state.nickname, card: ownCard))
        let code = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "vo1d://contact/\(code)"
    }
    func addContact(_ value: String) async throws -> Contact {
        var input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let card: ContactCard
        let name: String
        if input.hasPrefix("vo1d://contact/") {
            input = String(input.dropFirst("vo1d://contact/".count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            input += String(repeating: "=", count: (4 - input.count % 4) % 4)
            let invite = try Wire.decoder.decode(Invite.self, from: Crypto.decode(input))
            guard invite.version == 1 else { throw MessengerError.invalid("Неподдерживаемое приглашение") }
            let server = try APIClient.validateURL(invite.server)
            guard server.host == api?.base.host, server.port == api?.base.port, server.scheme == api?.base.scheme else {
                throw MessengerError.invalid("Контакт использует другой сервер. Оба устройства должны подключаться к одному серверу.")
            }
            card = invite.card; name = String(invite.name.prefix(40))
        } else {
            guard let api else { throw MessengerError.invalid("Подключись к relay-серверу") }
            let normalized = input.uppercased()
            if normalized.count == 4 {
                card = try await api.card(publicCode: normalized)
            } else {
                card = try await api.card(input.lowercased())
            }
            name = "Ghost \(card.shortID.prefix(6))"
        }
        try Crypto.validate(card)
        guard card.id != myID else { throw MessengerError.invalid("Это твой собственный ID") }
        if let existing = state.contacts.first(where: { $0.id == card.id }) {
            guard existing.card == card else { throw MessengerError.invalid("Ключ контакта изменился") }
            return existing
        }
        let contact = Contact(card: card, name: name)
        state.contacts.append(contact); try save()
        return contact
    }
    func direct(_ contact: Contact) throws -> Room {
        guard !contact.blocked, let ownCard else { throw MessengerError.invalid("Контакт заблокирован") }
        let ids = [myID, contact.id].sorted().joined(separator: ":")
        let id = "dm:" + ids
        if let existing = state.rooms.first(where: { $0.id == id }) { return existing }
        let room = Room(id: id, title: contact.name, members: [ownCard, contact.card], creator: "", isGroup: false, createdAt: Date())
        state.rooms.append(room); try save(); return room
    }
    func createGroup(name: String, contacts: [Contact]) throws -> Room {
        guard let ownCard, !contacts.isEmpty, contacts.count <= 15, contacts.allSatisfy({ !$0.blocked }) else {
            throw MessengerError.invalid("Выбери от 1 до 15 незаблокированных контактов")
        }
        let room = Room(id: UUID().uuidString, title: String(name.prefix(60)), members: [ownCard] + contacts.map(\.card), creator: myID, isGroup: true, createdAt: Date())
        state.rooms.append(room)
        try enqueue(ChatEvent(kind: "room", room: room, senderName: state.nickname), room: room)
        try save(); return room
    }
    func enqueue(_ event: ChatEvent, room: Room, to recipients: [ContactCard]? = nil, messageID: String? = nil) throws {
        guard let identity else { throw MessengerError.invalid("Нет ключей") }
        let targets = recipients ?? room.members.filter { $0.id != myID }
        let pending = try targets.map { PendingDelivery(envelope: try Crypto.seal(event, from: identity, to: $0), messageID: messageID) }
        state.outbox.append(contentsOf: pending)
    }
    func send(roomID: String, text: String, attachment: Attachment? = nil, replyTo: String? = nil) throws {
        guard let room = state.rooms.first(where: { $0.id == roomID }), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil else { return }
        guard text.count <= 16000 else { throw MessengerError.invalid("Сообщение слишком длинное") }
        guard (attachment?.data.count ?? 0) <= 3 * 1024 * 1024 else { throw MessengerError.invalid("Размер вложения — до 3 МБ") }
        guard !room.members.contains(where: { member in state.contacts.contains(where: { $0.id == member.id && $0.blocked }) }) else {
            throw MessengerError.invalid("В чате есть заблокированный контакт")
        }
        let expiry = room.disappearingSeconds > 0 ? Date().addingTimeInterval(Double(room.disappearingSeconds)) : nil
        let message = ChatMessage(id: UUID().uuidString, roomID: roomID, sender: myID, text: text, createdAt: Date(), expiresAt: expiry, replyTo: replyTo, attachment: attachment)
        try enqueue(ChatEvent(kind: "message", room: room, message: message, senderName: state.nickname), room: room, messageID: message.id)
        state.messages.append(message)
        if let index = state.rooms.firstIndex(where: { $0.id == roomID }) { state.rooms[index].draft = "" }
        try save()
    }
    func action(_ kind: String, message: ChatMessage, value: String? = nil) throws {
        guard let room = state.rooms.first(where: { $0.id == message.roomID }), let index = state.messages.firstIndex(where: { $0.id == message.id }) else { return }
        if kind == "edit" || kind == "delete" {
            guard message.sender == myID else { return }
        }
        try enqueue(ChatEvent(kind: kind, room: room, target: message.id, value: value, senderName: state.nickname), room: room)
        if kind == "edit" { state.messages[index].text = String((value ?? "").prefix(16000)); state.messages[index].edited = true }
        if kind == "delete" { state.messages.remove(at: index) }
        if kind == "reaction" { state.messages[index].reactions[myID] = value }
        try save()
    }
    func markRead(_ roomID: String) {
        guard let roomIndex = state.rooms.firstIndex(where: { $0.id == roomID }) else { return }
        state.rooms[roomIndex].unread = 0
        let room = state.rooms[roomIndex]
        for index in state.messages.indices where state.messages[index].roomID == roomID && state.messages[index].sender != myID && !state.messages[index].readBy.contains(myID) {
            state.messages[index].readBy.append(myID)
            if state.readReceipts, let sender = room.members.first(where: { $0.id == state.messages[index].sender }) {
                do { try enqueue(ChatEvent(kind: "read", room: room, target: state.messages[index].id, senderName: state.nickname), room: room, to: [sender]) }
                catch { self.error = error.localizedDescription }
            }
        }
        persist()
    }
    func sendTyping(_ roomID: String) async {
        guard let api, let identity, let room = state.rooms.first(where: { $0.id == roomID }), Date().timeIntervalSince(lastTyping[roomID] ?? .distantPast) > 5 else { return }
        lastTyping[roomID] = Date()
        let event = ChatEvent(kind: "typing", room: room, senderName: state.nickname)
        for target in room.members where target.id != myID {
            do { try await api.send(Crypto.seal(event, from: identity, to: target)) } catch { /* Ephemeral signal is intentionally not retried. */ }
        }
    }
    func sync() async {
        guard !syncing, !locked, state.onboarded, let api, let identity else { return }
        syncing = true; let currentGeneration = generation
        defer { syncing = false }
        do {
            expire()
            // Outbox is persisted before any network request. Retries reuse the exact signed envelope.
            for pending in Array(state.outbox.prefix(24)) {
                try await api.send(pending.envelope)
                guard currentGeneration == generation else { return }
                state.outbox.removeAll { $0.id == pending.id }
                if let id = pending.messageID, !state.outbox.contains(where: { $0.messageID == id }), let index = state.messages.firstIndex(where: { $0.id == id }) {
                    state.messages[index].state = "sent"
                }
                try save()
            }
            let envelopes = try await api.inbox()
            guard currentGeneration == generation else { return }
            var ack: [String] = []
            for envelope in envelopes {
                if state.processed.contains(envelope.id) || envelope.expiresAt <= Int(Date().timeIntervalSince1970) {
                    ack.append(envelope.id); continue
                }
                if state.contacts.contains(where: { $0.id == envelope.sender && $0.blocked }) {
                    ack.append(envelope.id); continue
                }
                // Network/key lookup failures leave the envelope unacknowledged for retry.
                let sender: ContactCard
                if let known = state.contacts.first(where: { $0.id == envelope.sender }) { sender = known.card }
                else { sender = try await api.card(envelope.sender) }
                guard currentGeneration == generation else { return }
                do {
                    let event = try Crypto.open(envelope, identity: identity, sender: sender)
                    try apply(event, sender: sender)
                } catch {
                    self.error = "Отклонено сообщение: \(error.localizedDescription)"
                }
                state.processed.append(envelope.id)
                ack.append(envelope.id)
            }
            // Commit received content and queued receipts before deleting server copies.
            try save()
            if !ack.isEmpty { try await api.ack(ack) }
            connection = "Подключён"
        } catch {
            connection = "Нет связи · очередь сохранена"
            // The visible status keeps transient network failures from producing alert loops.
        }
    }
    private func apply(_ event: ChatEvent, sender: ContactCard) throws {
        let incoming = event.room
        guard !incoming.id.isEmpty, incoming.id.count <= 160, incoming.members.count >= 2, incoming.members.count <= 16,
              Set(incoming.members.map(\.id)).count == incoming.members.count,
              incoming.members.contains(where: { $0.id == myID }), incoming.members.contains(sender) else {
            throw MessengerError.invalid("Неверный состав участников")
        }
        for member in incoming.members { try Crypto.validate(member) }
        if !incoming.isGroup {
            guard incoming.members.count == 2,
                  incoming.id == "dm:" + incoming.members.map(\.id).sorted().joined(separator: ":") else { throw MessengerError.invalid("Неверный личный чат") }
        }
        if let room = state.rooms.first(where: { $0.id == incoming.id }) {
            guard Set(room.members) == Set(incoming.members), room.creator == incoming.creator, room.isGroup == incoming.isGroup else {
                throw MessengerError.invalid("Изменение состава группы не разрешено")
            }
        } else {
            guard ["room", "message"].contains(event.kind), !incoming.isGroup || incoming.creator == sender.id else {
                throw MessengerError.invalid("Сначала нужно приглашение создателя группы")
            }
            var room = incoming
            room.pinned = false; room.archived = false; room.muted = false; room.unread = 0; room.draft = ""
            room.disappearingSeconds = 0
            if !room.isGroup { room.title = state.contacts.first(where: { $0.id == sender.id })?.name ?? String(event.senderName.prefix(40)) }
            state.rooms.append(room)
        }
        for member in incoming.members where member.id != myID && !state.contacts.contains(where: { $0.id == member.id }) {
            state.contacts.append(Contact(card: member, name: member.id == sender.id ? String(event.senderName.prefix(40)) : "Ghost \(member.shortID.prefix(6))"))
        }
        if event.kind == "message", var message = event.message {
            guard message.sender == sender.id, message.roomID == incoming.id, !message.id.isEmpty,
                  message.text.count <= 16000, (message.attachment?.data.count ?? 0) <= 3 * 1024 * 1024,
                  message.expiresAt == nil || message.expiresAt! > Date() else { throw MessengerError.invalid("Неверное содержимое сообщения") }
            if !state.messages.contains(where: { $0.id == message.id }) {
                message.state = "delivered"; message.reactions = [:]; message.readBy = []; message.deliveredTo = []; message.edited = false; message.openedAt = nil
                state.messages.append(message)
                if let index = state.rooms.firstIndex(where: { $0.id == incoming.id }) { state.rooms[index].unread += 1 }
                try enqueue(ChatEvent(kind: "delivered", room: incoming, target: message.id, senderName: state.nickname), room: incoming, to: [sender])
            }
        } else if event.kind == "typing" {
            if abs(event.at.timeIntervalSinceNow) < 8 { typing[incoming.id] = Date().addingTimeInterval(6) }
        } else if let target = event.target, let index = state.messages.firstIndex(where: { $0.id == target && $0.roomID == incoming.id }) {
            switch event.kind {
            case "edit" where state.messages[index].sender == sender.id:
                state.messages[index].text = String((event.value ?? "").prefix(16000)); state.messages[index].edited = true
            case "delete" where state.messages[index].sender == sender.id:
                state.messages.remove(at: index)
            case "reaction":
                if let value = event.value, ["❤️", "👍", "🔥", "😂", "👀", ""].contains(value) { state.messages[index].reactions[sender.id] = value.isEmpty ? nil : value }
            case "read" where state.messages[index].sender == myID:
                if !state.messages[index].readBy.contains(sender.id) { state.messages[index].readBy.append(sender.id) }
                state.messages[index].state = "read"
            case "delivered" where state.messages[index].sender == myID:
                if !state.messages[index].deliveredTo.contains(sender.id) { state.messages[index].deliveredTo.append(sender.id) }
                if state.messages[index].state != "read" { state.messages[index].state = "delivered" }
            default: break
            }
        }
    }
    func expire() {
        let now = Date()
        state.messages.removeAll { $0.expiresAt.map { $0 <= now } ?? false }
        state.outbox.removeAll { $0.envelope.expiresAt <= Int(now.timeIntervalSince1970) }
        // Keep a bounded replay cache. Relay also retains envelope tombstones until expiry.
        if state.processed.count > 50000 { state.processed.removeFirst(state.processed.count - 50000) }
        typing = typing.filter { $0.value > now }
    }
    func toggleBlock(_ contact: Contact) async {
        do {
            guard let api else { return }
            try await api.block(contact.id, blocked: !contact.blocked)
            if let index = state.contacts.firstIndex(where: { $0.id == contact.id }) { state.contacts[index].blocked.toggle() }
            if !contact.blocked { state.outbox.removeAll { $0.envelope.recipient == contact.id } }
            try save()
        } catch { self.error = error.localizedDescription }
    }
    func setLock(_ enabled: Bool) async {
        if enabled {
            let context = LAContext()
            do {
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Подтверди защиту VO1D") else { return }
            } catch { self.error = error.localizedDescription; return }
        }
        state.appLock = enabled; persist()
    }
    func unlock() async {
        do {
            if try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Открыть приватные чаты VO1D") { locked = false }
        } catch { self.error = error.localizedDescription }
    }
    private func resetLocalIdentity() throws {
        try vault?.delete()
        try Keychain.delete()
        let fresh = try Keychain.load()
        identity = fresh
        ownCard = try fresh.card
        api = nil
        state = VaultState()
        locked = false
        sessionUnlocked = false
        connection = "Не подключён"
        try save()
    }

    func deleteAccount() async {
        busy = true
        defer { busy = false }
        do {
            generation += 1
            if let api { try await api.deleteAccount() }
            try resetLocalIdentity()
        } catch { self.error = error.localizedDescription }
    }
    func name(_ id: String) -> String { id == myID ? "Ты" : state.contacts.first(where: { $0.id == id })?.name ?? "Ghost" }
    func messages(_ roomID: String, search: String = "") -> [ChatMessage] {
        state.messages.filter { $0.roomID == roomID && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)) }.sorted { $0.createdAt < $1.createdAt }
    }
    func openEphemeral(_ messageID: String) {
        guard let index = state.messages.firstIndex(where: { $0.id == messageID }),
              state.messages[index].openedAt == nil,
              let seconds = state.messages[index].attachment?.viewSeconds,
              seconds > 0 else { return }
        let duration = min(max(seconds, 1), 120)
        let now = Date()
        state.messages[index].openedAt = now
        state.messages[index].expiresAt = now.addingTimeInterval(TimeInterval(duration))
        persist()
    }

    func destroyEphemeralImmediately(_ messageID: String) {
        state.messages.removeAll { $0.id == messageID }
        persist()
    }

    func selectedVoiceEffect() -> VoiceEffect {
        VoiceEffect(rawValue: state.voiceEffect ?? "") ?? .natural
    }

    func setVoiceEffect(_ effect: VoiceEffect) {
        state.voiceEffect = effect.rawValue
        persist()
    }

    func updateRoom(_ id: String, _ update: (inout Room) -> Void) {
        if let index = state.rooms.firstIndex(where: { $0.id == id }) { update(&state.rooms[index]); persist() }
    }
}
