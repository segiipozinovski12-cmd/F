import Foundation

struct ContactCard: Codable, Hashable, Identifiable {
    var id: String
    var signingKey: String
    var agreementKey: String
    var binding: String
    var shortID: String { String(id.prefix(12)).uppercased() }
}

struct Contact: Codable, Identifiable, Hashable {
    var card: ContactCard
    var name: String
    var verified = false
    var blocked = false
    var id: String { card.id }
}

struct Room: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var members: [ContactCard]
    var creator: String
    var isGroup: Bool
    var createdAt: Date
    var pinned = false
    var archived = false
    var muted = false
    var unread = 0
    var draft = ""
    var disappearingSeconds = 0
    var admins: [String]? = nil
    var onlyAdminsCanPost: Bool? = nil
    var pinnedMessageIDs: [String]? = nil
    var isChannel: Bool? = nil
    var topics: [String]? = nil
    var mutedUntil: Date? = nil
}

struct Attachment: Codable, Hashable {
    var name: String
    var mime: String
    var data: Data
    var viewSeconds: Int? = nil
    var voiceEffect: String? = nil
    var blobID: String? = nil
    var blobKey: String? = nil
    var blobSize: Int? = nil
    var blobDigest: String? = nil
    var blobExpiresAt: Date? = nil
    var previewData: Data? = nil
}

struct PollOption: Codable, Hashable, Identifiable {
    var id: String
    var text: String
    var voterIDs: [String]
}

struct PollData: Codable, Hashable {
    var question: String
    var options: [PollOption]
    var closed: Bool = false
}

struct CallMessageData: Codable, Hashable {
    var incoming: Bool
    var status: String
    var duration: Int
}

struct CallRecord: Codable, Hashable, Identifiable {
    var id: String
    var callID: String
    var peerID: String
    var peerName: String
    var incoming: Bool
    var startedAt: Date
    var endedAt: Date
    var status: String
    var duration: Int
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id: String
    var roomID: String
    var sender: String
    var text: String
    var createdAt: Date
    var expiresAt: Date?
    var replyTo: String?
    var attachment: Attachment?
    var state: String = "queued"
    var edited = false
    var reactions: [String: String] = [:]
    var readBy: [String] = []
    var deliveredTo: [String] = []
    var openedAt: Date? = nil
    var forwardedFrom: String? = nil
    var scheduledAt: Date? = nil
    var silent: Bool? = nil
    var editHistory: [String]? = nil
    var poll: PollData? = nil
    var topic: String? = nil
    var call: CallMessageData? = nil
}

/// All event content, including group membership and attachments, lives inside AEAD.
struct ChatEvent: Codable {
    var id: String = UUID().uuidString
    var kind: String
    var room: Room
    var message: ChatMessage?
    var target: String?
    var value: String?
    var senderName: String
    var at: Date = Date()
}

struct Envelope: Codable, Identifiable {
    var id: String
    var sender: String
    var recipient: String
    var ephemeralKey: String
    var salt: String
    var expiresAt: Int
    var ciphertext: String
    var signature: String
    var header: Data {
        Data("VO1D-ENVELOPE-1\n\(id)\n\(sender)\n\(recipient)\n\(ephemeralKey)\n\(salt)\n\(expiresAt)".utf8)
    }
}

struct PendingDelivery: Codable, Identifiable {
    var envelope: Envelope
    var messageID: String?
    var id: String { envelope.id + envelope.recipient }
}

struct VaultState: Codable {
    var nickname = "Ghost"
    var server = ""
    var onboarded = false
    var appLock = false
    var readReceipts = true
    var contacts: [Contact] = []
    var rooms: [Room] = []
    var messages: [ChatMessage] = []
    var outbox: [PendingDelivery] = []
    var processed: [String] = []
    var publicCode: String?
    var accessKey: String?
    var panicCodeHash: String?
    var credentialsAcknowledged: Bool?
    var voiceEffect: String? = nil
    var notificationsEnabled: Bool? = nil
    var username: String? = nil
    var bio: String? = nil
    var profileAvatar: Data? = nil
    var callHistory: [CallRecord]? = nil
}

struct Invite: Codable {
    var version = 1
    var server: String
    var name: String
    var card: ContactCard
}

enum MessengerError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let detail): return detail }
    }
}

enum Wire {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
