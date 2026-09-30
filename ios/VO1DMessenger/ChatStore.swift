import Foundation
import SwiftUI
import LocalAuthentication
import CryptoKit

@MainActor
final class ChatStore: ObservableObject {
    @Published var state = VaultState()
    @Published var error: String?
    @Published var connection = "Подключение…"
    @Published var busy = false
    @Published var locked = false
    @Published var sessionUnlocked = false
    @Published var fatalError: String?
    @Published var typing: [String: Date] = [:]
    @Published var activeRoomID: String?
    private(set) var identity: LocalIdentity?
    private(set) var ownCard: ContactCard?
    private var vault: Vault?
    private var api: APIClient?
    private var syncing = false
    private var generation = 0
    private var lastTyping: [String: Date] = [:]
    var myID: String { ownCard?.id ?? "" }

    static let builtinBotKey = "XROSB"
    static let builtinBotID = String(repeating: "b", count: 64)
    static let builtinBotRoomID = "bot:xrosb"
    static let savedRoomID = "saved:me"

    static var builtinBotCard: ContactCard {
        ContactCard(
            id: builtinBotID,
            signingKey: Data(repeating: 0x42, count: 32).base64EncodedString(),
            agreementKey: Data(repeating: 0x24, count: 32).base64EncodedString(),
            binding: Data(repeating: 0, count: 64).base64EncodedString()
        )
    }

    func isBuiltinBot(_ id: String) -> Bool { id == Self.builtinBotID }
    func isBuiltinBotRoom(_ id: String) -> Bool { id == Self.builtinBotRoomID }
    func isSavedRoom(_ id: String) -> Bool { id == Self.savedRoomID }
    func isLocalUtilityRoom(_ id: String) -> Bool { isBuiltinBotRoom(id) || isSavedRoom(id) }

    init() {
        do {
            let identity = try Keychain.load()
            let vault = try Vault()
            self.identity = identity; self.vault = vault; ownCard = try identity.card
            state = try vault.read(key: identity.storage)
            let credentialsChanged = try ensureCredentials()
            locked = state.appLock
            sessionUnlocked = !state.onboarded

            var relayChanged = false
            if state.onboarded {
                if state.server != AppConfig.productionRelay {
                    state.server = AppConfig.productionRelay
                    relayChanged = true
                }
                api = try APIClient(server: AppConfig.productionRelay, identity: identity)
                connection = "Подключение…"
            } else {
                connection = "Готов к регистрации"
            }

            expire()
            let botChanged = state.onboarded ? ensureBuiltinBot() : false
            let savedChanged = state.onboarded ? ensureSavedMessages() : false
            if credentialsChanged || relayChanged || botChanged || savedChanged { try save() }
        } catch { fatalError = error.localizedDescription }
    }
    func save() throws {
        guard let identity, let vault else { throw MessengerError.invalid("Хранилище недоступно") }
        try vault.write(state, key: identity.storage)
    }
    func persist() {
        do { try save() } catch { self.error = error.localizedDescription }
    }
    func onboardProduction(name: String) async {
        await configure(name: name, server: AppConfig.productionRelay)
    }

    func connectProductionRelay() async {
        guard state.onboarded, let identity else { return }
        connection = "Подключение…"
        do {
            let client = try APIClient(server: AppConfig.productionRelay, identity: identity)
            try await client.authenticate()
            let publicCode = try await client.ensurePublicCode()
            api = client
            state.server = AppConfig.productionRelay
            state.publicCode = publicCode
            try save()
            CallManager.shared.configure(api: client, identity: identity) { [weak self] id in
                self?.name(id) ?? "VO1D"
            }
            connection = "Подключён"
        } catch {
            connection = "Нет связи"
        }
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
            _ = ensureBuiltinBot()
            _ = ensureSavedMessages()
            try save()
            CallManager.shared.configure(api: client, identity: identity) { [weak self] id in
                self?.name(id) ?? "VO1D"
            }
            connection = "Подключён"
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    private func ensureBuiltinBot() -> Bool {
        guard let ownCard else { return false }
        var changed = false

        if !state.contacts.contains(where: { $0.id == Self.builtinBotID }) {
            state.contacts.append(
                Contact(
                    card: Self.builtinBotCard,
                    name: "VO1D Bot",
                    verified: true,
                    blocked: false
                )
            )
            changed = true
        }

        if !state.rooms.contains(where: { $0.id == Self.builtinBotRoomID }) {
            state.rooms.append(
                Room(
                    id: Self.builtinBotRoomID,
                    title: "VO1D Bot",
                    members: [ownCard, Self.builtinBotCard],
                    creator: Self.builtinBotID,
                    isGroup: false,
                    createdAt: Date(),
                    pinned: true
                )
            )

            state.messages.append(
                ChatMessage(
                    id: UUID().uuidString,
                    roomID: Self.builtinBotRoomID,
                    sender: Self.builtinBotID,
                    text: "VO1D Bot готов. Мой ключ — XROSB. Напиши /help, чтобы увидеть команды.",
                    createdAt: Date(),
                    expiresAt: nil,
                    replyTo: nil,
                    attachment: nil,
                    state: "delivered"
                )
            )
            changed = true
        }

        return changed
    }

    func builtinBotRoom() throws -> Room {
        _ = ensureBuiltinBot()
        guard let room = state.rooms.first(where: { $0.id == Self.builtinBotRoomID }) else {
            throw MessengerError.invalid("VO1D Bot недоступен")
        }
        try save()
        return room
    }

    @discardableResult
    private func ensureSavedMessages() -> Bool {
        guard let ownCard else { return false }
        guard !state.rooms.contains(where: { $0.id == Self.savedRoomID }) else { return false }

        state.rooms.append(
            Room(
                id: Self.savedRoomID,
                title: "Сохранённые",
                members: [ownCard],
                creator: myID,
                isGroup: false,
                createdAt: Date(),
                pinned: true
            )
        )
        return true
    }

    func savedRoom() throws -> Room {
        _ = ensureSavedMessages()
        guard let room = state.rooms.first(where: { $0.id == Self.savedRoomID }) else {
            throw MessengerError.invalid("Сохранённые сообщения недоступны")
        }
        try save()
        return room
    }

    private func botReply(to text: String, attachment: Attachment?) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clean.lowercased()

        if attachment != nil && clean.isEmpty {
            return "Вложение получил. Я системный бот VO1D; могу подсказать по функциям приложения. Напиши /help."
        }
        if lower == "/help" || lower.contains("помощ") {
            return "Команды: /id, /username, /status, /privacy, /groups, /calls, /saved. Можно также просто задать вопрос о VO1D."
        }
        if lower == "/id" || lower.contains("мой id") || lower.contains("мой айди") {
            return "Твой VO1D ID: \(state.publicCode ?? "----"). Ключ доступа смотри только в настройках — я его не показываю."
        }
        if lower == "/username" || lower.contains("юзернейм") || lower.contains("username") {
            return state.username.map { "Твой username: @\($0)." } ?? "Username пока не занят. Задай его в Настройки → Профиль."
        }
        if lower == "/saved" || lower.contains("сохран") {
            return "«Сохранённые» — локальный чат с собой. Перешли туда сообщение или открой его из списка чатов."
        }
        if lower == "/status" || lower.contains("статус") {
            return "Соединение: \(connection). Очередь отправки: \(state.outbox.count)."
        }
        if lower == "/privacy" || lower.contains("приват") {
            return "Содержимое переписки шифруется на устройстве. Сервис всё равно может видеть технические метаданные соединения, поэтому VO1D не заявляет абсолютную сетевую анонимность."
        }
        if lower == "/groups" || lower.contains("групп") {
            return "Группа: Чаты → + → включи «Создать группу» → выбери людей → введи название → «Создать группу». VO1D Bot в группы не добавляется."
        }
        if lower == "/calls" || lower.contains("звон") {
            return "В личном чате нажми значок телефона. Для звонка оба пользователя должны быть онлайн и подключены к VO1D."
        }
        if ["привет", "hello", "hi", "ку", "здарова"].contains(lower) {
            return "Привет. Я VO1D Bot · XROSB. Могу подсказать по функциям приложения — напиши /help."
        }

        return clean.isEmpty
            ? "Я здесь. Напиши /help."
            : "Получил сообщение. Я системный VO1D Bot, а не человек. Для списка полезных команд напиши /help."
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
    func checkUsername(_ value: String) async -> APIClient.UsernameCheck? {
        guard let api else {
            error = "Нет соединения с VO1D"
            return nil
        }
        do {
            return try await api.checkUsername(value)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func claimUsername(_ value: String) async -> Bool {
        guard let api else {
            error = "Нет соединения с VO1D"
            return false
        }
        do {
            let username = try await api.claimUsername(value)
            state.username = username
            try save()
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

        if input.uppercased() == Self.builtinBotKey {
            _ = ensureBuiltinBot()
            try save()
            guard let bot = state.contacts.first(where: { $0.id == Self.builtinBotID }) else {
                throw MessengerError.invalid("VO1D Bot недоступен")
            }
            return bot
        }

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
            guard let api else { throw MessengerError.invalid("Нет соединения с VO1D") }
            let normalized = input.uppercased()
            let usernameCandidate = input
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "@"))

            if normalized.count == 4 {
                card = try await api.card(publicCode: normalized)
                name = "Ghost \(card.shortID.prefix(6))"
            } else if input.hasPrefix("@") || (usernameCandidate.count >= 4 && usernameCandidate.count <= 20 && input.count != 64) {
                card = try await api.card(username: usernameCandidate)
                name = "@\(usernameCandidate)"
            } else {
                card = try await api.card(input.lowercased())
                name = "Ghost \(card.shortID.prefix(6))"
            }
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
    func startCall(_ roomID: String) {
        guard connection == "Подключён",
              !isLocalUtilityRoom(roomID),
              let room = state.rooms.first(where: { $0.id == roomID }),
              !room.isGroup,
              let peer = room.members.first(where: { $0.id != myID }) else {
            error = "Звонок доступен только в подключённом личном чате"
            return
        }
        CallManager.shared.startCall(peer: peer, name: room.title)
    }

    func direct(_ contact: Contact) throws -> Room {
        if isBuiltinBot(contact.id) { return try builtinBotRoom() }
        guard !contact.blocked, let ownCard else { throw MessengerError.invalid("Контакт заблокирован") }
        let ids = [myID, contact.id].sorted().joined(separator: ":")
        let id = "dm:" + ids
        if let existing = state.rooms.first(where: { $0.id == id }) { return existing }
        let room = Room(id: id, title: contact.name, members: [ownCard, contact.card], creator: "", isGroup: false, createdAt: Date())
        state.rooms.append(room); try save(); return room
    }
    func createGroup(name: String, contacts: [Contact]) throws -> Room {
        guard let ownCard else { throw MessengerError.invalid("Личность VO1D недоступна") }

        let cleanTitle = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !cleanTitle.isEmpty else { throw MessengerError.invalid("Введи название группы") }

        var seen = Set<String>()
        let cleanContacts = contacts.filter {
            !$0.blocked &&
            !isBuiltinBot($0.id) &&
            seen.insert($0.id).inserted
        }

        guard !cleanContacts.isEmpty, cleanContacts.count <= 15 else {
            throw MessengerError.invalid("Выбери от 1 до 15 доступных контактов")
        }

        for contact in cleanContacts { try Crypto.validate(contact.card) }

        let room = Room(
            id: UUID().uuidString,
            title: cleanTitle,
            members: [ownCard] + cleanContacts.map(\.card),
            creator: myID,
            isGroup: true,
            createdAt: Date(),
            admins: [myID]
        )

        let event = ChatEvent(kind: "room", room: room, senderName: state.nickname)
        let targets = cleanContacts.map(\.card)
        guard let identity else { throw MessengerError.invalid("Нет ключей") }
        let pending = try targets.map {
            PendingDelivery(envelope: try Crypto.seal(event, from: identity, to: $0), messageID: nil)
        }

        state.rooms.append(room)
        state.outbox.append(contentsOf: pending)
        try save()
        return room
    }
    func createChannel(name: String, contacts: [Contact]) throws -> Room {
        guard let ownCard else { throw MessengerError.invalid("Личность VO1D недоступна") }

        let cleanTitle = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !cleanTitle.isEmpty else { throw MessengerError.invalid("Введи название канала") }

        var seen = Set<String>()
        let cleanContacts = contacts.filter {
            !$0.blocked &&
            !isBuiltinBot($0.id) &&
            seen.insert($0.id).inserted
        }
        guard cleanContacts.count <= 15 else {
            throw MessengerError.invalid("Сейчас канал поддерживает до 16 участников")
        }
        for contact in cleanContacts { try Crypto.validate(contact.card) }

        let room = Room(
            id: UUID().uuidString,
            title: cleanTitle,
            members: [ownCard] + cleanContacts.map(\.card),
            creator: myID,
            isGroup: true,
            createdAt: Date(),
            admins: [myID],
            onlyAdminsCanPost: true,
            isChannel: true,
            topics: []
        )

        let event = ChatEvent(kind: "room", room: room, senderName: state.nickname)
        let targets = cleanContacts.map(\.card)
        guard let identity else { throw MessengerError.invalid("Нет ключей") }
        let pending = try targets.map {
            PendingDelivery(envelope: try Crypto.seal(event, from: identity, to: $0), messageID: nil)
        }

        state.rooms.append(room)
        state.outbox.append(contentsOf: pending)
        try save()
        return room
    }

    func isRoomMuted(_ room: Room) -> Bool {
        if room.muted { return true }
        if let until = room.mutedUntil, until > Date() { return true }
        return false
    }

    func muteRoom(_ roomID: String, for interval: TimeInterval?) {
        guard let index = state.rooms.firstIndex(where: { $0.id == roomID }) else { return }
        if let interval {
            if interval <= 0 {
                state.rooms[index].muted = false
                state.rooms[index].mutedUntil = nil
            } else {
                state.rooms[index].muted = false
                state.rooms[index].mutedUntil = Date().addingTimeInterval(interval)
            }
        } else {
            state.rooms[index].muted = true
            state.rooms[index].mutedUntil = nil
        }
        persist()
    }

    func addTopic(_ roomID: String, name: String) throws {
        guard let index = state.rooms.firstIndex(where: { $0.id == roomID }) else { return }
        let oldRoom = state.rooms[index]
        guard isGroupOwner(oldRoom) else {
            throw MessengerError.invalid("Темы меняет создатель группы")
        }
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !clean.isEmpty else { return }

        var topics = oldRoom.topics ?? []
        guard !topics.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        guard topics.count < 20 else { throw MessengerError.invalid("Максимум 20 тем") }
        topics.append(clean)

        var newRoom = oldRoom
        newRoom.topics = topics
        try publishRoomUpdate(oldRoom: oldRoom, newRoom: newRoom)
        state.rooms[index] = newRoom
        try save()
    }

    func removeTopic(_ roomID: String, name: String) throws {
        guard let index = state.rooms.firstIndex(where: { $0.id == roomID }) else { return }
        let oldRoom = state.rooms[index]
        guard isGroupOwner(oldRoom) else {
            throw MessengerError.invalid("Темы меняет создатель группы")
        }

        var newRoom = oldRoom
        newRoom.topics = (oldRoom.topics ?? []).filter { $0 != name }
        try publishRoomUpdate(oldRoom: oldRoom, newRoom: newRoom)
        state.rooms[index] = newRoom
        try save()
    }

    func groupAdminIDs(_ room: Room) -> Set<String> {
        var result = Set(room.admins ?? [])
        if !room.creator.isEmpty { result.insert(room.creator) }
        return result
    }

    func isGroupOwner(_ room: Room) -> Bool {
        room.isGroup && room.creator == myID
    }

    func isGroupAdmin(_ room: Room) -> Bool {
        room.isGroup && groupAdminIDs(room).contains(myID)
    }

    private func publishRoomUpdate(oldRoom: Room, newRoom: Room) throws {
        guard oldRoom.isGroup,
              newRoom.isGroup,
              oldRoom.creator == myID,
              newRoom.creator == myID,
              let identity else {
            throw MessengerError.invalid("Только создатель группы может менять её структуру")
        }

        let event = ChatEvent(kind: "roomUpdate", room: newRoom, senderName: state.nickname)
        var recipients: [ContactCard] = []
        var seen = Set<String>()
        for card in oldRoom.members + newRoom.members where card.id != myID {
            if seen.insert(card.id).inserted { recipients.append(card) }
        }

        let pending = try recipients.map {
            PendingDelivery(
                envelope: try Crypto.seal(event, from: identity, to: $0),
                messageID: nil
            )
        }

        state.outbox.append(contentsOf: pending)
    }

    func updateGroupMembers(_ roomID: String, contacts: [Contact]) throws {
        guard let roomIndex = state.rooms.firstIndex(where: { $0.id == roomID }),
              let ownCard else { return }

        let oldRoom = state.rooms[roomIndex]
        guard isGroupOwner(oldRoom) else {
            throw MessengerError.invalid("Менять состав может только создатель группы")
        }

        var seen = Set<String>()
        let cleanContacts = contacts.filter {
            !$0.blocked &&
            !isBuiltinBot($0.id) &&
            $0.id != myID &&
            seen.insert($0.id).inserted
        }
        guard cleanContacts.count <= 15 else {
            throw MessengerError.invalid("В группе может быть до 16 участников вместе с тобой")
        }
        for contact in cleanContacts { try Crypto.validate(contact.card) }

        var newRoom = oldRoom
        newRoom.members = [ownCard] + cleanContacts.map(\.card)

        let allowed = Set(newRoom.members.map(\.id))
        var admins = groupAdminIDs(oldRoom).intersection(allowed)
        admins.insert(myID)
        newRoom.admins = Array(admins).sorted()

        try publishRoomUpdate(oldRoom: oldRoom, newRoom: newRoom)
        state.rooms[roomIndex] = newRoom
        try save()
    }

    func toggleGroupAdmin(_ roomID: String, memberID: String) throws {
        guard let roomIndex = state.rooms.firstIndex(where: { $0.id == roomID }) else { return }
        let oldRoom = state.rooms[roomIndex]
        guard isGroupOwner(oldRoom) else {
            throw MessengerError.invalid("Админов назначает создатель группы")
        }
        guard memberID != myID,
              oldRoom.members.contains(where: { $0.id == memberID }) else { return }

        var newRoom = oldRoom
        var admins = groupAdminIDs(oldRoom)
        if admins.contains(memberID) {
            admins.remove(memberID)
        } else {
            admins.insert(memberID)
        }
        admins.insert(myID)
        newRoom.admins = Array(admins).sorted()

        try publishRoomUpdate(oldRoom: oldRoom, newRoom: newRoom)
        state.rooms[roomIndex] = newRoom
        try save()
    }

    func setGroupAdminsOnly(_ roomID: String, enabled: Bool) throws {
        guard let roomIndex = state.rooms.firstIndex(where: { $0.id == roomID }) else { return }
        let oldRoom = state.rooms[roomIndex]
        guard isGroupOwner(oldRoom) else {
            throw MessengerError.invalid("Это разрешение меняет создатель группы")
        }

        var newRoom = oldRoom
        newRoom.onlyAdminsCanPost = enabled

        try publishRoomUpdate(oldRoom: oldRoom, newRoom: newRoom)
        state.rooms[roomIndex] = newRoom
        try save()
    }

    func renameGroup(_ roomID: String, title: String) throws {
        guard let roomIndex = state.rooms.firstIndex(where: { $0.id == roomID }) else { return }
        let oldRoom = state.rooms[roomIndex]
        guard isGroupOwner(oldRoom) else {
            throw MessengerError.invalid("Название меняет создатель группы")
        }
        let clean = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !clean.isEmpty else { throw MessengerError.invalid("Название не может быть пустым") }

        var newRoom = oldRoom
        newRoom.title = clean

        try publishRoomUpdate(oldRoom: oldRoom, newRoom: newRoom)
        state.rooms[roomIndex] = newRoom
        try save()
    }

    func enqueue(_ event: ChatEvent, room: Room, to recipients: [ContactCard]? = nil, messageID: String? = nil) throws {
        guard let identity else { throw MessengerError.invalid("Нет ключей") }
        let targets = recipients ?? room.members.filter { $0.id != myID }
        let pending = try targets.map { PendingDelivery(envelope: try Crypto.seal(event, from: identity, to: $0), messageID: messageID) }
        state.outbox.append(contentsOf: pending)
    }
    func send(
        roomID: String,
        text: String,
        attachment: Attachment? = nil,
        replyTo: String? = nil,
        forwardedFrom: String? = nil,
        scheduledAt: Date? = nil,
        silent: Bool = false,
        poll: PollData? = nil,
        topic: String? = nil
    ) throws {
        guard let room = state.rooms.first(where: { $0.id == roomID }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil || poll != nil else { return }

        if let scheduledAt, scheduledAt > Date().addingTimeInterval(1) {
            let scheduled = ChatMessage(
                id: UUID().uuidString,
                roomID: roomID,
                sender: myID,
                text: text,
                createdAt: Date(),
                expiresAt: nil,
                replyTo: replyTo,
                attachment: attachment,
                state: "scheduled",
                forwardedFrom: forwardedFrom,
                scheduledAt: scheduledAt,
                silent: silent,
                poll: poll,
                topic: topic
            )
            state.messages.append(scheduled)
            if let index = state.rooms.firstIndex(where: { $0.id == roomID }) {
                state.rooms[index].draft = ""
            }
            try save()
            return
        }

        if isSavedRoom(roomID) {
            let message = ChatMessage(
                id: UUID().uuidString,
                roomID: roomID,
                sender: myID,
                text: text,
                createdAt: Date(),
                expiresAt: nil,
                replyTo: replyTo,
                attachment: attachment,
                state: "read",
                forwardedFrom: forwardedFrom,
                scheduledAt: nil,
                silent: silent,
                poll: poll,
                topic: topic
            )
            state.messages.append(message)
            if let index = state.rooms.firstIndex(where: { $0.id == roomID }) {
                state.rooms[index].draft = ""
            }
            try save()
            return
        }

        if isLocalUtilityRoom(roomID) {
            let now = Date()
            let mine = ChatMessage(
                id: UUID().uuidString,
                roomID: roomID,
                sender: myID,
                text: text,
                createdAt: now,
                expiresAt: nil,
                replyTo: replyTo,
                attachment: attachment,
                state: "read",
                forwardedFrom: forwardedFrom,
                scheduledAt: nil,
                silent: silent,
                poll: poll,
                topic: topic
            )
            let response = ChatMessage(
                id: UUID().uuidString,
                roomID: roomID,
                sender: Self.builtinBotID,
                text: botReply(to: text, attachment: attachment),
                createdAt: now.addingTimeInterval(0.001),
                expiresAt: nil,
                replyTo: mine.id,
                attachment: nil,
                state: "delivered"
            )
            state.messages.append(contentsOf: [mine, response])
            if let index = state.rooms.firstIndex(where: { $0.id == roomID }) {
                state.rooms[index].draft = ""
                state.rooms[index].unread = 0
            }
            try save()
            return
        }
        if room.isGroup && room.onlyAdminsCanPost == true && !isGroupAdmin(room) {
            throw MessengerError.invalid("В этой группе писать могут только админы")
        }
        guard text.count <= 16000 else { throw MessengerError.invalid("Сообщение слишком длинное") }
        guard (attachment?.data.count ?? 0) <= 3 * 1024 * 1024 else { throw MessengerError.invalid("Размер вложения — до 3 МБ") }
        guard !room.members.contains(where: { member in state.contacts.contains(where: { $0.id == member.id && $0.blocked }) }) else {
            throw MessengerError.invalid("В чате есть заблокированный контакт")
        }
        let expiry = room.disappearingSeconds > 0 ? Date().addingTimeInterval(Double(room.disappearingSeconds)) : nil
        let message = ChatMessage(
            id: UUID().uuidString,
            roomID: roomID,
            sender: myID,
            text: text,
            createdAt: Date(),
            expiresAt: expiry,
            replyTo: replyTo,
            attachment: attachment,
            forwardedFrom: forwardedFrom,
            scheduledAt: nil,
            silent: silent,
            poll: poll,
            topic: topic
        )
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

        if isLocalUtilityRoom(message.roomID) {
            if kind == "edit" {
            var history = state.messages[index].editHistory ?? []
            if !state.messages[index].text.isEmpty {
                history.append(state.messages[index].text)
                if history.count > 20 { history.removeFirst(history.count - 20) }
            }
            state.messages[index].editHistory = history
            state.messages[index].text = String((value ?? "").prefix(16000))
            state.messages[index].edited = true
        }
            if kind == "delete" { state.messages.remove(at: index) }
            if kind == "reaction" { state.messages[index].reactions[myID] = value }
            try save()
            return
        }

        try enqueue(ChatEvent(kind: kind, room: room, target: message.id, value: value, senderName: state.nickname), room: room)
        if kind == "edit" { state.messages[index].text = String((value ?? "").prefix(16000)); state.messages[index].edited = true }
        if kind == "delete" { state.messages.remove(at: index) }
        if kind == "reaction" { state.messages[index].reactions[myID] = value }
        try save()
    }
    func forward(_ message: ChatMessage, to roomID: String) throws {
        let source = message.forwardedFrom ?? name(message.sender)
        try send(
            roomID: roomID,
            text: message.text,
            attachment: message.attachment,
            replyTo: nil,
            forwardedFrom: source
        )
    }

    func pinnedMessages(_ roomID: String) -> [ChatMessage] {
        guard let room = state.rooms.first(where: { $0.id == roomID }) else { return [] }
        let ids = Set(room.pinnedMessageIDs ?? [])
        return state.messages
            .filter { $0.roomID == roomID && ids.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func togglePinnedMessage(_ message: ChatMessage) throws {
        guard let roomIndex = state.rooms.firstIndex(where: { $0.id == message.roomID }) else { return }
        var ids = state.rooms[roomIndex].pinnedMessageIDs ?? []
        let willPin = !ids.contains(message.id)

        if willPin {
            ids.append(message.id)
            if ids.count > 20 { ids.removeFirst(ids.count - 20) }
        } else {
            ids.removeAll { $0 == message.id }
        }
        state.rooms[roomIndex].pinnedMessageIDs = ids

        if !isLocalUtilityRoom(message.roomID) {
            let room = state.rooms[roomIndex]
            try enqueue(
                ChatEvent(kind: "pin", room: room, target: message.id, value: willPin ? "1" : "0", senderName: state.nickname),
                room: room
            )
        }
        try save()
    }

    func createPoll(
        roomID: String,
        question: String,
        options: [String],
        scheduledAt: Date? = nil,
        topic: String? = nil
    ) throws {
        let cleanQuestion = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        let cleanOptions = options
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }
            .filter { !$0.isEmpty }

        guard !cleanQuestion.isEmpty else {
            throw MessengerError.invalid("Введи вопрос опроса")
        }
        guard cleanOptions.count >= 2 && cleanOptions.count <= 10 else {
            throw MessengerError.invalid("Нужно от 2 до 10 вариантов")
        }

        let poll = PollData(
            question: cleanQuestion,
            options: cleanOptions.map {
                PollOption(id: UUID().uuidString, text: $0, voterIDs: [])
            }
        )

        try send(
            roomID: roomID,
            text: cleanQuestion,
            attachment: nil,
            replyTo: nil,
            forwardedFrom: nil,
            scheduledAt: scheduledAt,
            silent: false,
            poll: poll,
            topic: topic
        )
    }

    func votePoll(messageID: String, optionID: String) throws {
        guard let index = state.messages.firstIndex(where: { $0.id == messageID }),
              var poll = state.messages[index].poll,
              !poll.closed,
              poll.options.contains(where: { $0.id == optionID }) else { return }

        for optionIndex in poll.options.indices {
            poll.options[optionIndex].voterIDs.removeAll { $0 == myID }
            if poll.options[optionIndex].id == optionID {
                poll.options[optionIndex].voterIDs.append(myID)
            }
        }
        state.messages[index].poll = poll

        if !isLocalUtilityRoom(state.messages[index].roomID),
           let room = state.rooms.first(where: { $0.id == state.messages[index].roomID }) {
            try enqueue(
                ChatEvent(kind: "pollVote", room: room, target: messageID, value: optionID, senderName: state.nickname),
                room: room
            )
        }
        try save()
    }

    func closePoll(messageID: String) throws {
        guard let index = state.messages.firstIndex(where: { $0.id == messageID }),
              state.messages[index].sender == myID,
              var poll = state.messages[index].poll else { return }

        poll.closed = true
        state.messages[index].poll = poll

        if !isLocalUtilityRoom(state.messages[index].roomID),
           let room = state.rooms.first(where: { $0.id == state.messages[index].roomID }) {
            try enqueue(
                ChatEvent(kind: "pollClose", room: room, target: messageID, value: "1", senderName: state.nickname),
                room: room
            )
        }
        try save()
    }

    func markRead(_ roomID: String) {
        guard let roomIndex = state.rooms.firstIndex(where: { $0.id == roomID }) else { return }
        state.rooms[roomIndex].unread = 0
        if isLocalUtilityRoom(roomID) {
            persist()
            return
        }
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
        guard !isLocalUtilityRoom(roomID),
              let api, let identity, let room = state.rooms.first(where: { $0.id == roomID }), Date().timeIntervalSince(lastTyping[roomID] ?? .distantPast) > 5 else { return }
        lastTyping[roomID] = Date()
        let event = ChatEvent(kind: "typing", room: room, senderName: state.nickname)
        for target in room.members where target.id != myID {
            do { try await api.send(Crypto.seal(event, from: identity, to: target)) } catch { /* Ephemeral signal is intentionally not retried. */ }
        }
    }
    private func processScheduledMessages() {
        let now = Date()
        let due = state.messages.filter {
            $0.state == "scheduled" &&
            ($0.scheduledAt ?? .distantFuture) <= now
        }

        for scheduled in due {
            state.messages.removeAll { $0.id == scheduled.id }
            do {
                try send(
                    roomID: scheduled.roomID,
                    text: scheduled.text,
                    attachment: scheduled.attachment,
                    replyTo: scheduled.replyTo,
                    forwardedFrom: scheduled.forwardedFrom,
                    scheduledAt: nil,
                    silent: scheduled.silent == true,
                    poll: scheduled.poll,
                    topic: scheduled.topic
                )
            } catch {
                var retry = scheduled
                retry.scheduledAt = now.addingTimeInterval(30)
                state.messages.append(retry)
                self.error = error.localizedDescription
            }
        }

        if !due.isEmpty { persist() }
    }

    func sync() async {
        guard !syncing, !locked, state.onboarded, let api, let identity else { return }
        syncing = true; let currentGeneration = generation
        defer { syncing = false }
        do {
            processScheduledMessages()
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
        let minimumMembers = incoming.isGroup ? 1 : 2

        guard !incoming.id.isEmpty,
              incoming.id.count <= 160,
              incoming.members.count >= minimumMembers,
              incoming.members.count <= 16,
              Set(incoming.members.map(\.id)).count == incoming.members.count,
              incoming.members.contains(sender) else {
            throw MessengerError.invalid("Неверный состав участников")
        }

        for member in incoming.members { try Crypto.validate(member) }

        if !incoming.isGroup {
            guard incoming.members.count == 2,
                  incoming.members.contains(where: { $0.id == myID }),
                  incoming.id == "dm:" + incoming.members.map(\.id).sorted().joined(separator: ":") else {
                throw MessengerError.invalid("Неверный личный чат")
            }
        } else {
            guard incoming.members.contains(where: { $0.id == incoming.creator }) else {
                throw MessengerError.invalid("Создатель должен оставаться участником группы")
            }
            let adminIDs = Set(incoming.admins ?? [incoming.creator])
            guard adminIDs.isSubset(of: Set(incoming.members.map(\.id))),
                  adminIDs.contains(incoming.creator) else {
                throw MessengerError.invalid("Некорректный список админов")
            }
        }

        if let roomIndex = state.rooms.firstIndex(where: { $0.id == incoming.id }) {
            let current = state.rooms[roomIndex]

            if event.kind == "roomUpdate" {
                guard current.isGroup,
                      incoming.isGroup,
                      current.creator == incoming.creator,
                      sender.id == current.creator else {
                    throw MessengerError.invalid("Недопустимое изменение группы")
                }

                if !incoming.members.contains(where: { $0.id == myID }) {
                    let removedRoomID = current.id
                    let messageIDs = Set(state.messages.filter { $0.roomID == removedRoomID }.map(\.id))
                    state.messages.removeAll { $0.roomID == removedRoomID }
                    state.outbox.removeAll { pending in
                        guard let messageID = pending.messageID else { return false }
                        return messageIDs.contains(messageID)
                    }
                    state.rooms.remove(at: roomIndex)
                    typing[removedRoomID] = nil
                    return
                }

                var updated = incoming
                updated.pinned = current.pinned
                updated.archived = current.archived
                updated.muted = current.muted
                updated.unread = current.unread
                updated.draft = current.draft
                updated.disappearingSeconds = current.disappearingSeconds
                updated.pinnedMessageIDs = current.pinnedMessageIDs
                state.rooms[roomIndex] = updated
            } else {
                guard Set(current.members) == Set(incoming.members),
                      current.creator == incoming.creator,
                      current.isGroup == incoming.isGroup else {
                    throw MessengerError.invalid("Изменение состава группы требует roomUpdate")
                }

                if current.isGroup {
                    let currentAdmins = Set(current.admins ?? [current.creator])
                    let incomingAdmins = Set(incoming.admins ?? [incoming.creator])
                    guard currentAdmins == incomingAdmins,
                          current.onlyAdminsCanPost == incoming.onlyAdminsCanPost,
                          current.isChannel == incoming.isChannel,
                          current.topics == incoming.topics,
                          current.title == incoming.title else {
                        throw MessengerError.invalid("Метаданные группы изменены без roomUpdate")
                    }
                }
            }
        } else {
            guard incoming.members.contains(where: { $0.id == myID }) else {
                throw MessengerError.invalid("Событие не адресовано этому участнику")
            }

            let allowedFirstEvents = ["room", "message", "roomUpdate"]
            guard allowedFirstEvents.contains(event.kind),
                  !incoming.isGroup || incoming.creator == sender.id else {
                throw MessengerError.invalid("Сначала нужно приглашение создателя группы")
            }

            var room = incoming
            room.pinned = false
            room.archived = false
            room.muted = false
            room.unread = 0
            room.draft = ""
            room.disappearingSeconds = 0
            room.pinnedMessageIDs = []

            if !room.isGroup {
                room.title = state.contacts.first(where: { $0.id == sender.id })?.name ?? String(event.senderName.prefix(40))
            }
            state.rooms.append(room)
        }

        if event.kind == "roomUpdate" {
            for member in incoming.members where member.id != myID && !state.contacts.contains(where: { $0.id == member.id }) {
                state.contacts.append(
                    Contact(
                        card: member,
                        name: member.id == sender.id ? String(event.senderName.prefix(40)) : "Ghost \(member.shortID.prefix(6))"
                    )
                )
            }
            return
        }

        for member in incoming.members where member.id != myID && !state.contacts.contains(where: { $0.id == member.id }) {
            state.contacts.append(Contact(card: member, name: member.id == sender.id ? String(event.senderName.prefix(40)) : "Ghost \(member.shortID.prefix(6))"))
        }
        if event.kind == "message", var message = event.message {
            if let effectiveRoom = state.rooms.first(where: { $0.id == incoming.id }),
               effectiveRoom.isGroup,
               effectiveRoom.onlyAdminsCanPost == true,
               !groupAdminIDs(effectiveRoom).contains(sender.id) {
                throw MessengerError.invalid("Участник без прав попытался отправить сообщение")
            }

            guard message.sender == sender.id, message.roomID == incoming.id, !message.id.isEmpty,
                  message.text.count <= 16000, (message.attachment?.data.count ?? 0) <= 3 * 1024 * 1024,
                  message.expiresAt == nil || message.expiresAt! > Date() else { throw MessengerError.invalid("Неверное содержимое сообщения") }
            if !state.messages.contains(where: { $0.id == message.id }) {
                message.state = "delivered"; message.reactions = [:]; message.readBy = []; message.deliveredTo = []; message.edited = false; message.openedAt = nil
                state.messages.append(message)
                if let index = state.rooms.firstIndex(where: { $0.id == incoming.id }) { state.rooms[index].unread += 1 }

                if state.notificationsEnabled == true &&
                   message.silent != true &&
                   activeRoomID != incoming.id &&
                   !(state.rooms.first(where: { $0.id == incoming.id }).map(isRoomMuted) ?? false) {
                    let title = state.rooms.first(where: { $0.id == incoming.id })?.title ?? String(event.senderName.prefix(40))
                    let body: String
                    if !message.text.isEmpty {
                        body = String(message.text.prefix(120))
                    } else if message.attachment?.mime.hasPrefix("audio/") == true {
                        body = "Голосовое сообщение"
                    } else if message.attachment?.mime.hasPrefix("image/") == true {
                        body = message.attachment?.viewSeconds == nil ? "Фото" : "Фото с таймером"
                    } else {
                        body = "Вложение"
                    }
                    NotificationCoordinator.shared.postMessage(title: title, body: body, roomID: incoming.id)
                }

                try enqueue(ChatEvent(kind: "delivered", room: incoming, target: message.id, senderName: state.nickname), room: incoming, to: [sender])
            }
        } else if event.kind == "typing" {
            if abs(event.at.timeIntervalSinceNow) < 8 { typing[incoming.id] = Date().addingTimeInterval(6) }
        } else if let target = event.target, let index = state.messages.firstIndex(where: { $0.id == target && $0.roomID == incoming.id }) {
            switch event.kind {
            case "edit" where state.messages[index].sender == sender.id:
                var history = state.messages[index].editHistory ?? []
                if !state.messages[index].text.isEmpty {
                    history.append(state.messages[index].text)
                    if history.count > 20 { history.removeFirst(history.count - 20) }
                }
                state.messages[index].editHistory = history
                state.messages[index].text = String((event.value ?? "").prefix(16000))
                state.messages[index].edited = true
            case "delete" where state.messages[index].sender == sender.id:
                state.messages.remove(at: index)
            case "reaction":
                if let value = event.value, ["❤️", "👍", "🔥", "😂", "👀", ""].contains(value) { state.messages[index].reactions[sender.id] = value.isEmpty ? nil : value }
            case "pollVote":
                if var poll = state.messages[index].poll,
                   let optionID = event.value,
                   poll.options.contains(where: { $0.id == optionID }),
                   !poll.closed {
                    for optionIndex in poll.options.indices {
                        poll.options[optionIndex].voterIDs.removeAll { $0 == sender.id }
                        if poll.options[optionIndex].id == optionID {
                            poll.options[optionIndex].voterIDs.append(sender.id)
                        }
                    }
                    state.messages[index].poll = poll
                }
            case "pollClose" where state.messages[index].sender == sender.id:
                if var poll = state.messages[index].poll {
                    poll.closed = true
                    state.messages[index].poll = poll
                }
            case "pin":
                if let roomIndex = state.rooms.firstIndex(where: { $0.id == incoming.id }) {
                    var ids = state.rooms[roomIndex].pinnedMessageIDs ?? []
                    if event.value == "1" {
                        if !ids.contains(target) { ids.append(target) }
                        if ids.count > 20 { ids.removeFirst(ids.count - 20) }
                    } else {
                        ids.removeAll { $0 == target }
                    }
                    state.rooms[roomIndex].pinnedMessageIDs = ids
                }
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
        if isBuiltinBot(contact.id) {
            error = "VO1D Bot — системный контакт"
            return
        }
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
        CallManager.shared.disconnect()
        try vault?.delete()
        try Keychain.delete()
        let fresh = try Keychain.load()
        identity = fresh
        ownCard = try fresh.card
        api = nil
        state = VaultState()
        locked = false
        sessionUnlocked = false
        connection = "Готов к регистрации"
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
    func name(_ id: String) -> String {
        if id == myID { return "Ты" }
        if isBuiltinBot(id) { return "VO1D Bot" }
        return state.contacts.first(where: { $0.id == id })?.name ?? "Ghost"
    }
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

    func setNotifications(_ enabled: Bool) async {
        if enabled {
            let granted = await NotificationCoordinator.shared.requestPermission()
            state.notificationsEnabled = granted
            if !granted { error = "Разрешение на уведомления не выдано в iOS" }
        } else {
            state.notificationsEnabled = false
            NotificationCoordinator.shared.clearDelivered()
        }
        persist()
    }

    func deleteMessages(_ ids: Set<String>, roomID: String) throws {
        guard !ids.isEmpty,
              let room = state.rooms.first(where: { $0.id == roomID }) else { return }

        let selected = state.messages.filter { ids.contains($0.id) && $0.roomID == roomID }

        if isLocalUtilityRoom(roomID) {
            state.messages.removeAll { ids.contains($0.id) && $0.roomID == roomID }
            try save()
            return
        }

        for message in selected where message.sender == myID {
            try enqueue(
                ChatEvent(kind: "delete", room: room, target: message.id, senderName: state.nickname),
                room: room
            )
        }

        state.messages.removeAll { ids.contains($0.id) && $0.roomID == roomID }
        state.outbox.removeAll { pending in
            guard let messageID = pending.messageID else { return false }
            return ids.contains(messageID)
        }
        try save()
    }

    func selectedVoiceEffect() -> VoiceEffect {
        VoiceEffect(rawValue: state.voiceEffect ?? "") ?? .natural
    }

    func setVoiceEffect(_ effect: VoiceEffect) {
        state.voiceEffect = effect.rawValue
        persist()
    }

    func markRoomUnread(_ roomID: String) {
        if let index = state.rooms.firstIndex(where: { $0.id == roomID }) {
            state.rooms[index].unread = max(1, state.rooms[index].unread)
            persist()
        }
    }

    func clearLocalHistory(_ roomID: String) {
        let messageIDs = Set(state.messages.filter { $0.roomID == roomID }.map(\.id))
        state.messages.removeAll { $0.roomID == roomID }
        state.outbox.removeAll { pending in
            guard let messageID = pending.messageID else { return false }
            return messageIDs.contains(messageID)
        }
        if let index = state.rooms.firstIndex(where: { $0.id == roomID }) {
            state.rooms[index].unread = 0
            state.rooms[index].draft = ""
            state.rooms[index].pinnedMessageIDs = []
        }
        typing[roomID] = nil
        persist()
    }

    func updateRoom(_ id: String, _ update: (inout Room) -> Void) {
        if let index = state.rooms.firstIndex(where: { $0.id == id }) { update(&state.rooms[index]); persist() }
    }
}
