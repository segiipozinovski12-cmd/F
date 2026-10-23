import Foundation
import SwiftUI
import CryptoKit

// Content is shared only inside Signal events with explicitly selected contacts.
struct SharedProfile: Codable, Hashable {
    var name: String
    var bio: String
    var avatar: Data?
    var updatedAt: Date
    var status: String
    var decoration: ProfileDecoration? = nil
    var featuredGiftID: String? = nil
    func validate(now: Date = Date()) throws {
        try decoration?.validate()
        guard !name.isEmpty, name.count <= 40, bio.count <= 160, status.count <= 32,
              (avatar?.count ?? 0) <= 160_000, (featuredGiftID?.count ?? 0) <= 80, updatedAt <= now.addingTimeInterval(60) else {
            throw MessengerError.invalid("Некорректный профиль")
        }
    }
}
struct PrivateStory: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var author: String
    var text: String
    var image: Data?
    var createdAt: Date
    var expiresAt: Date
    func validate(sender: String, now: Date = Date()) throws {
        guard UUID(uuidString: id) != nil, author == sender, text.count <= 1200,
              !text.isEmpty || image != nil, (image?.count ?? 0) <= 400_000,
              createdAt <= now.addingTimeInterval(60), expiresAt > now,
              expiresAt > createdAt, expiresAt.timeIntervalSince(createdAt) <= 86400 else {
            throw MessengerError.invalid("История истекла или повреждена")
        }
    }
}
struct SocialState: Codable {
    var decoration: ProfileDecoration? = nil
    var featuredGiftID: String? = nil
    var profiles: [String: SharedProfile] = [:]
    var stories: [PrivateStory] = []
    var storyAudience: [String: [String]] = [:]
    var deletedStories: [String: Date] = [:]
    var status = ""
}
enum ReactionCatalog {
    static let all = ["❤️", "👍", "👎", "🔥", "😂", "🤣", "🥰", "😍", "😎", "🤝", "👏", "💯", "⚡️", "🖤", "🤍", "👀", "🤔", "😮", "😢", "😭", "🤯", "🫡", "💀", "🗿", "🎉", "🚀", "🏆", "🍕", "🤡", "💔", "🙏", "👌", "✨", "🎊", "🥳", "💕", "💘", "🤩", "🤗", "🥹", "😴", "😡", "😱", "🤨", "🫶", "✌️", "🤘", "👑", "💎", "🌚", "☕️", "🍿", "🦋", "🌪️", "🕊️", "🌟"]
    static func accepts(_ value: String) -> Bool { value.isEmpty || all.contains(value) }
}
extension ChatEvent {
    var contentExpiry: Date? { story?.expiresAt ?? message?.expiresAt }
}
extension ChatStore {
    var social: SocialState { state.social ?? SocialState() }
    var ownSharedProfile: SharedProfile {
        SharedProfile(name: state.nickname, bio: state.bio ?? "", avatar: state.profileAvatar.flatMap { $0.count <= 160_000 ? $0 : SocialImage.jpeg($0, maxSide: 384, limit: 160_000) }, updatedAt: Date(), status: social.status, decoration: social.decoration?.allowed(premium: hasPremium), featuredGiftID: social.featuredGiftID)
    }
    func socialRoom(_ contact: Contact) throws -> Room {
        guard let ownCard else { throw MessengerError.invalid("Нет личности") }
        return Room(id: "dm:" + [myID, contact.id].sorted().joined(separator: ":"), title: contact.name,
                    members: [ownCard, contact.card], creator: "", isGroup: false, createdAt: Date())
    }
    func shareProfile(with audience: Set<String>) throws {
        guard audience.count <= 50 else { throw MessengerError.invalid("Выбери не больше 50 контактов") }
        let contacts = state.contacts.filter { audience.contains($0.id) && !$0.blocked && $0.isBot != true && !isBuiltinBot($0.id) && extended.trustedIDs.contains($0.id) }
        guard contacts.count == audience.count else { throw MessengerError.invalid("Профиль можно отправить только доверенным контактам") }
        let profile = ownSharedProfile
        try profile.validate()
        let previous = state
        do {
            for contact in contacts {
                let room = try socialRoom(contact)
                var event = ChatEvent(kind: "profile", room: room, senderName: state.nickname)
                event.sharedProfile = profile
                try enqueue(event, room: room, to: [contact.card])
            }
            try save()
        } catch { state = previous; throw error }
    }
    func publishStory(text: String, image: Data?, audience: Set<String>) throws {
        guard !audience.isEmpty, audience.count <= 50 else { throw MessengerError.invalid("Выбери от 1 до 50 получателей истории") }
        let now = Date(), story = PrivateStory(author: myID, text: text.trimmingCharacters(in: .whitespacesAndNewlines), image: image, createdAt: now, expiresAt: now.addingTimeInterval(86400))
        try story.validate(sender: myID)
        let queuedBytes = state.outbox.reduce(0) { $0 + ($1.envelope.deferredEvent?.count ?? $1.envelope.ciphertext.utf8.count) }
        guard queuedBytes + ((image?.count ?? 0) + text.utf8.count + 180_000) * audience.count <= 40 * 1024 * 1024 else {
            throw MessengerError.invalid("Сначала дождись отправки очереди историй")
        }
        guard social.stories.filter({ $0.author == myID && $0.expiresAt > now }).count < 30 else {
            throw MessengerError.invalid("Достигнут лимит активных историй")
        }
        let contacts = state.contacts.filter { audience.contains($0.id) && !$0.blocked && $0.isBot != true && !isBuiltinBot($0.id) && extended.trustedIDs.contains($0.id) }
        guard contacts.count == audience.count else { throw MessengerError.invalid("Истории доступны только выбранным доверенным контактам") }
        let previous = state
        do {
            for contact in contacts {
                let room = try socialRoom(contact)
                var event = ChatEvent(kind: "story", room: room, senderName: state.nickname)
                event.story = story; event.sharedProfile = ownSharedProfile
                try enqueue(event, room: room, to: [contact.card])
            }
            var value = social; value.stories.append(story); value.storyAudience[story.id] = contacts.map(\.id)
            state.social = value; try save()
        } catch { state = previous; throw error }
    }
    func deleteStory(_ story: PrivateStory) throws {
        guard story.author == myID else { return }
        let previous = state
        do {
            state.outbox.removeAll { $0.storyID == story.id }
            for contact in state.contacts where (social.storyAudience[story.id] ?? []).contains(contact.id) && !contact.blocked {
                let room = try socialRoom(contact)
                var event = ChatEvent(kind: "storyDelete", room: room, target: story.id, senderName: state.nickname)
                event.value = String(Int(story.expiresAt.timeIntervalSince1970))
                try enqueue(event, room: room, to: [contact.card])
            }
            var value = social; value.stories.removeAll { $0.id == story.id }; value.storyAudience[story.id] = nil
            state.social = value; try save()
        } catch { state = previous; throw error }
    }
    func handleSocialEvent(_ event: ChatEvent, sender: ContactCard) throws -> Bool {
        guard ["profile", "profileRequest", "story", "storyDelete"].contains(event.kind) else { return false }
        guard !event.room.isGroup, event.room.members.count == 2,
              Set(event.room.members.map(\.id)) == Set([myID, sender.id]), event.room.members.contains(sender),
              event.room.id == "dm:" + [myID, sender.id].sorted().joined(separator: ":"),
              state.contacts.contains(where: { $0.card == sender && !$0.blocked }),
              extended.trustedIDs.contains(sender.id) else { return true }
        try validateScopedRoom(event.room)
        var value = social
        if let profile = event.sharedProfile {
            try profile.validate()
            if profile.updatedAt >= (value.profiles[sender.id]?.updatedAt ?? .distantPast) { value.profiles[sender.id] = profile }
        }
        switch event.kind {
        case "profileRequest":
            // Older clients can send this event, but it must not automatically
            // disclose our name, avatar or bio in response to a remote request.
            break
        case "story":
            guard let story = event.story else { throw MessengerError.invalid("Нет истории") }
            try story.validate(sender: sender.id)
            if value.deletedStories[sender.id + story.id] == nil && !value.stories.contains(where: { $0.id == story.id && $0.author == sender.id }) &&
                value.stories.count < 100 && value.stories.reduce(0, { $0 + ($1.image?.count ?? 0) }) + (story.image?.count ?? 0) <= 20 * 1024 * 1024 && value.stories.filter({ $0.author == sender.id }).count < 30 {
                value.stories.append(story)
            }
        case "storyDelete":
            guard let id = event.target, UUID(uuidString: id) != nil,
                  let expiry = Double(event.value ?? ""), expiry.isFinite, expiry <= Date().timeIntervalSince1970 + 86460 else { return true }
            value.stories.removeAll { $0.id == id && $0.author == sender.id }
            if value.deletedStories.count < 2000 { value.deletedStories[sender.id + id] = Date(timeIntervalSince1970: expiry) }
        default: break
        }
        state.social = value
        return true
    }
    func expireSocial() {
        guard var value = state.social else { return }
        guard value.stories.contains(where: { $0.expiresAt <= Date() }) || value.deletedStories.values.contains(where: { $0 <= Date() }) else { return }
        value.stories.removeAll { $0.expiresAt <= Date() }
        let live = Set(value.stories.map(\.id)); value.storyAudience = value.storyAudience.filter { live.contains($0.key) }
        value.deletedStories = value.deletedStories.filter { $0.value > Date() }
        state.social = value
    }
    func restoreDiscovery(using client: APIClient) async throws {
        let expected = generation
        struct Discovery: Decodable { var code: String?; var username: String? }
        let discovery: Discovery
        do { discovery = try await client.request("v1/discovery") }
        catch let failure as HTTPFailure where failure.status == 404 {
            // Let the previous v2 relay keep serving chats during a rolling
            // upgrade; only its existing username API is used in this case.
            discovery = Discovery(code: nil, username: nil)
        }
        guard expected == generation else { throw CancellationError() }
        if let username = discovery.username { state.username = username }
        else if let username = state.username {
            do {
                let claimed = try await client.claimUsername(username)
                guard expected == generation else { throw CancellationError() }
                state.username = claimed
            } catch let failure as HTTPFailure where failure.status == 409 {
                guard expected == generation else { throw CancellationError() }
                state.username = nil
                error = "После обновления сервера username занят. Выбери новый в настройках."
            }
        }
    }
}
