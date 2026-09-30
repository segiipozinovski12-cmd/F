import Foundation

struct PrivacyPreferences: Codable {
    var requireRequests = true
    var allowGroupInvites = false
    var discoverable = true
    var typingSignals = false
    var deliveryReceipts = true
    var notificationPreview = false
    var cleanLinks = true
    var confirmLinks = true
    var clipboardSeconds = 60
    var inactivityDays = 0
    var localRetentionDays = 0
    var defaultDisappearing = 0
    var proxyHost = ""
    var proxyPort = 9050
    var proxyEnabled = false
    var padding = true
    var quietHours = false
    var quietStart = 22
    var quietEnd = 8
    var compactRows = false
    var sortOrder = "recent"
    var fontSize = 16.0
    var lowData = false
    var maxUploadMB = 50
    var hideMedia = false
    var forwardWithoutName = true
    var verifiedOnlyCalls = false
    var autoLockSeconds = 0
    var keepEditHistory = false
    var protectRecording = true
    var linkPreviews = false
    var wifiOnlyUploads = false
    var anonymizeFilenames = true
}

struct ChatFolder: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var roomIDs: [String] = []
}

struct LocalReminder: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var messageID: String
    var roomID: String
    var at: Date
}

struct ExtendedState: Codable {
    var privacy = PrivacyPreferences()
    var folders: [ChatFolder] = []
    var bookmarks: [String] = []
    var notes: [String: String] = [:]
    var aliases: [String: String] = [:]
    var favorites: [String] = []
    var hiddenRooms: [String] = []
    var trustedIDs: [String] = []
    var pendingEvents: [PendingRequest] = []
    var declinedRooms: [String] = []
    var reminders: [LocalReminder] = []
    var snippets: [String] = []
    var roomRetention: [String: Int] = [:]
    var roomFontSize: [String: Double] = [:]
    var receiptExceptions: [String] = []
    var protectedMessages: [String] = []
    var ocrText: [String: String] = [:]
    var roomNotes: [String: String] = [:]
}

struct InviteReceipt: Codable, Identifiable {
    var id: String
    var token: String?
    var expiresAt: Int
    var remaining: Int
}

struct RelaySession: Codable, Identifiable {
    var id: String
    var expiresAt: Int
    var current: Bool
}

struct RelayStorage: Codable {
    var queuedMessages: Int
    var mailboxBytes: Int
    var files: Int
    var fileBytes: Int
}

struct DeliveryIssue: Identifiable {
    var id: String
    var detail: String
    var attempts: Int
    var nextAttempt: Date
}

extension Room {
    /// Never publish draft text, unread counts, local folders or notification preferences.
    var wireCopy: Room {
        var result = self
        result.pinned = false
        result.archived = false
        result.muted = false
        result.mutedUntil = nil
        result.unread = 0
        result.draft = ""
        if !result.isGroup { result.title="" }
        result.disappearingSeconds = 0
        result.pinnedMessageIDs = nil
        return result
    }
}

struct PendingRequest: Codable, Identifiable {
    var event: ChatEvent
    var sender: ContactCard
    var id: String { event.id }
    var room: Room { event.room }
}
