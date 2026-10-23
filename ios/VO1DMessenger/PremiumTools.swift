import Foundation

struct SmartFolderRule: Codable, Hashable {
    var kinds: [String] = []
    var unreadOnly = false
    var excludeMuted = false
    var withAttachments = false
    var excludedRoomIDs: [String] = []
    func matches(_ room: Room, messages: [ChatMessage], now: Date = Date()) -> Bool {
        guard !excludedRoomIDs.contains(room.id) else { return false }
        let kind = room.isChannel == true ? "channels" : room.isGroup ? "groups" : "direct"
        return (kinds.isEmpty || kinds.contains(kind)) && (!unreadOnly || room.unread > 0) &&
            (!excludeMuted || (!room.muted && (room.mutedUntil ?? .distantPast) <= now)) &&
            (!withAttachments || messages.contains { $0.attachment != nil && $0.viewOnceSeconds == nil && ($0.expiresAt ?? .distantFuture) > now })
    }
}

struct SavedTag: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var color = "violet"
    static let colors = ["violet", "blue", "mint", "gold", "rose"]
}

struct ReplyTemplate: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var title: String
    var shortcut: String
    var body: String
    func rendered(name: String, me: String, now: Date = Date(), locale: Locale = .current) -> String {
        let date = DateFormatter(); date.locale = locale; date.dateStyle = .medium; date.timeStyle = .none
        let clock = DateFormatter(); clock.locale = locale; clock.dateStyle = .none; clock.timeStyle = .short
        // One replacement pass: contact names cannot inject another variable.
        let values = ["{name}": name, "{me}": me, "{date}": date.string(from: now), "{time}": clock.string(from: now)]
        let expression = try! NSRegularExpression(pattern: "\\{(?:name|me|date|time)\\}")
        var output = body
        for match in expression.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed() {
            guard let range = Range(match.range, in: output), let source = Range(match.range, in: body) else { continue }
            output.replaceSubrange(range, with: values[String(body[source])] ?? String(body[source]))
        }
        return String(output.prefix(4000))
    }
}

struct PremiumToolsState: Codable {
    var folderRules: [String: SmartFolderRule] = [:]
    var tags: [SavedTag] = []
    var messageTags: [String: [String]] = [:]
    var replyTemplates: [ReplyTemplate] = []
}

extension ChatStore {
    var premiumTools: PremiumToolsState { state.premiumTools ?? PremiumToolsState() }

    func changePremiumTools(_ update: (inout PremiumToolsState) throws -> Void) throws {
        guard hasPremium, !locked, sessionUnlocked else { throw MessengerError.invalid("Нужен активный VO1D Premium") }
        let previous = state
        var value = premiumTools
        try update(&value)
        let folders = Set(extended.folders.map(\.id))
        value.folderRules = value.folderRules.filter { folders.contains($0.key) }
        guard value.tags.count <= 50, value.replyTemplates.count <= 100, value.folderRules.count <= 50,
              value.tags.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 24 && SavedTag.colors.contains($0.color) }),
              Set(value.tags.map(\.id)).count == value.tags.count,
              value.folderRules.values.allSatisfy({ Set($0.kinds).isSubset(of: Set(["direct", "groups", "channels"])) && $0.excludedRoomIDs.count <= 1000 }),
              value.replyTemplates.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 40 && !$0.body.isEmpty && $0.body.count <= 4000 && $0.shortcut.range(of: "^[a-z0-9_]{1,24}$", options: .regularExpression) != nil }),
              Set(value.replyTemplates.map(\.shortcut)).count == value.replyTemplates.count else {
            throw MessengerError.invalid("Проверь названия, команды и лимиты: 50 тегов, 100 быстрых ответов")
        }
        value.messageTags = value.messageTags.filter { key, _ in state.messages.contains { $0.id == key && isSavedRoom($0.roomID) } }
        let ids = Set(value.tags.map(\.id))
        for key in Array(value.messageTags.keys) {
            let tags = Array(Set(value.messageTags[key, default: []]).intersection(ids)).sorted()
            value.messageTags[key] = tags.isEmpty ? nil : tags
        }
        state.premiumTools = value
        do { try save() } catch { state = previous; throw error }
    }

    func authorizePremiumTools() async throws {
        guard let api, !locked, sessionUnlocked else { throw MessengerError.invalid("Подключись к VO1D") }
        let fence = sessionFence
        let _: APIClient.OK = try await api.request("v3/economy/premium-authorize", method: "POST", body: Data("{}".utf8))
        try requireCurrentSession(fence)
        try await refreshEconomy()
        try requireCurrentSession(fence)
        guard hasPremium else { throw MessengerError.invalid("Нужен активный VO1D Premium") }
    }

    func folderContains(_ folder: ChatFolder, room: Room) -> Bool {
        guard !extended.hiddenRooms.contains(room.id) else { return false }
        guard hasPremium, let rule = premiumTools.folderRules[folder.id] else { return folder.roomIDs.contains(room.id) }
        if rule.excludedRoomIDs.contains(room.id) { return false }
        return folder.roomIDs.contains(room.id) || rule.matches(room, messages: messages(room.id))
    }

    func toggleSavedTag(_ tagID: String, message: ChatMessage) throws {
        guard isSavedRoom(message.roomID), message.viewOnceSeconds == nil, premiumTools.tags.contains(where: { $0.id == tagID }) else {
            throw MessengerError.invalid("Теги доступны для сообщений в Избранном")
        }
        try changePremiumTools { tools in
            var tags = tools.messageTags[message.id, default: []]
            if tags.contains(tagID) { tags.removeAll { $0 == tagID } } else { tags.append(tagID) }
            tools.messageTags[message.id] = tags
        }
    }

    func renderedReply(_ reply: ReplyTemplate, room: Room) -> String {
        let peer = room.members.first { $0.id != myID }
        return reply.rendered(name: room.isGroup ? room.title : peer.map { name($0.id) } ?? room.title, me: state.nickname)
    }
}
