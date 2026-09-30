import Foundation

struct PrivacyPreferences: Codable {
    var backgroundCalls = false
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
    var requirePrivateDelivery = false
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
    init() {}
    enum CodingKeys: String, CodingKey {
        case requirePrivateDelivery
        case backgroundCalls, requireRequests, allowGroupInvites, discoverable, typingSignals, deliveryReceipts, notificationPreview, cleanLinks, confirmLinks, clipboardSeconds, inactivityDays, localRetentionDays, defaultDisappearing, proxyHost, proxyPort, proxyEnabled, padding, quietHours, quietStart, quietEnd, compactRows, sortOrder, fontSize, lowData, maxUploadMB, hideMedia, forwardWithoutName, verifiedOnlyCalls, autoLockSeconds, keepEditHistory, protectRecording, linkPreviews, wifiOnlyUploads, anonymizeFilenames
    }
    init(from decoder: Decoder) throws {
        self.init()
        let container=try decoder.container(keyedBy:CodingKeys.self)
        backgroundCalls=try container.decodeIfPresent(Bool.self,forKey:.backgroundCalls) ?? backgroundCalls
        requireRequests=try container.decodeIfPresent(Bool.self,forKey:.requireRequests) ?? requireRequests
        allowGroupInvites=try container.decodeIfPresent(Bool.self,forKey:.allowGroupInvites) ?? allowGroupInvites
        discoverable=try container.decodeIfPresent(Bool.self,forKey:.discoverable) ?? discoverable
        typingSignals=try container.decodeIfPresent(Bool.self,forKey:.typingSignals) ?? typingSignals
        deliveryReceipts=try container.decodeIfPresent(Bool.self,forKey:.deliveryReceipts) ?? deliveryReceipts
        notificationPreview=try container.decodeIfPresent(Bool.self,forKey:.notificationPreview) ?? notificationPreview
        cleanLinks=try container.decodeIfPresent(Bool.self,forKey:.cleanLinks) ?? cleanLinks
        confirmLinks=try container.decodeIfPresent(Bool.self,forKey:.confirmLinks) ?? confirmLinks
        clipboardSeconds=try container.decodeIfPresent(Int.self,forKey:.clipboardSeconds) ?? clipboardSeconds
        inactivityDays=try container.decodeIfPresent(Int.self,forKey:.inactivityDays) ?? inactivityDays
        localRetentionDays=try container.decodeIfPresent(Int.self,forKey:.localRetentionDays) ?? localRetentionDays
        defaultDisappearing=try container.decodeIfPresent(Int.self,forKey:.defaultDisappearing) ?? defaultDisappearing
        proxyHost=try container.decodeIfPresent(String.self,forKey:.proxyHost) ?? proxyHost
        proxyPort=try container.decodeIfPresent(Int.self,forKey:.proxyPort) ?? proxyPort
        proxyEnabled=try container.decodeIfPresent(Bool.self,forKey:.proxyEnabled) ?? proxyEnabled
        requirePrivateDelivery=try container.decodeIfPresent(Bool.self,forKey:.requirePrivateDelivery) ?? requirePrivateDelivery
        padding=try container.decodeIfPresent(Bool.self,forKey:.padding) ?? padding
        quietHours=try container.decodeIfPresent(Bool.self,forKey:.quietHours) ?? quietHours
        quietStart=try container.decodeIfPresent(Int.self,forKey:.quietStart) ?? quietStart
        quietEnd=try container.decodeIfPresent(Int.self,forKey:.quietEnd) ?? quietEnd
        compactRows=try container.decodeIfPresent(Bool.self,forKey:.compactRows) ?? compactRows
        sortOrder=try container.decodeIfPresent(String.self,forKey:.sortOrder) ?? sortOrder
        fontSize=try container.decodeIfPresent(Double.self,forKey:.fontSize) ?? fontSize
        lowData=try container.decodeIfPresent(Bool.self,forKey:.lowData) ?? lowData
        maxUploadMB=try container.decodeIfPresent(Int.self,forKey:.maxUploadMB) ?? maxUploadMB
        hideMedia=try container.decodeIfPresent(Bool.self,forKey:.hideMedia) ?? hideMedia
        forwardWithoutName=try container.decodeIfPresent(Bool.self,forKey:.forwardWithoutName) ?? forwardWithoutName
        verifiedOnlyCalls=try container.decodeIfPresent(Bool.self,forKey:.verifiedOnlyCalls) ?? verifiedOnlyCalls
        autoLockSeconds=try container.decodeIfPresent(Int.self,forKey:.autoLockSeconds) ?? autoLockSeconds
        keepEditHistory=try container.decodeIfPresent(Bool.self,forKey:.keepEditHistory) ?? keepEditHistory
        protectRecording=try container.decodeIfPresent(Bool.self,forKey:.protectRecording) ?? protectRecording
        linkPreviews=try container.decodeIfPresent(Bool.self,forKey:.linkPreviews) ?? linkPreviews
        wifiOnlyUploads=try container.decodeIfPresent(Bool.self,forKey:.wifiOnlyUploads) ?? wifiOnlyUploads
        anonymizeFilenames=try container.decodeIfPresent(Bool.self,forKey:.anonymizeFilenames) ?? anonymizeFilenames
    }

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
    var signal: SignalSnapshot? = nil
    var ownMailboxes: [LocalMailbox] = []
    var peerMailboxes: [String: MailboxAddress] = [:]
    var invitationBundles: [String: SignalBundle] = [:]
    var privateInvite: Invite? = nil
    var privateInviteLink: String? = nil
    var lastOpenedAt: Date? = nil
    var privatePollVotes: [String: [String: String]] = [:]
    var privatePollSelections: [String: String] = [:]
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
    init() {}
    enum CodingKeys: String, CodingKey {
        case signal
        case ownMailboxes, peerMailboxes, invitationBundles, privateInvite
        case privateInviteLink
        case lastOpenedAt, privatePollVotes, privatePollSelections, privacy, folders, bookmarks, notes, aliases, favorites, hiddenRooms, trustedIDs, pendingEvents, declinedRooms, reminders, snippets, roomRetention, roomFontSize, receiptExceptions, protectedMessages, ocrText, roomNotes
    }
    init(from decoder: Decoder) throws {
        self.init()
        let container=try decoder.container(keyedBy:CodingKeys.self)
        lastOpenedAt=try container.decodeIfPresent(Date.self,forKey:.lastOpenedAt)
        signal=try container.decodeIfPresent(SignalSnapshot.self,forKey:.signal)
        ownMailboxes=try container.decodeIfPresent([LocalMailbox].self,forKey:.ownMailboxes) ?? []
        peerMailboxes=try container.decodeIfPresent([String: MailboxAddress].self,forKey:.peerMailboxes) ?? [:]
        invitationBundles=try container.decodeIfPresent([String: SignalBundle].self,forKey:.invitationBundles) ?? [:]
        privateInvite=try container.decodeIfPresent(Invite.self,forKey:.privateInvite)
        privateInviteLink=try container.decodeIfPresent(String.self,forKey:.privateInviteLink)
        privatePollVotes=try container.decodeIfPresent([String: [String: String]].self,forKey:.privatePollVotes) ?? privatePollVotes
        privatePollSelections=try container.decodeIfPresent([String: String].self,forKey:.privatePollSelections) ?? privatePollSelections
        privacy=try container.decodeIfPresent(PrivacyPreferences.self,forKey:.privacy) ?? privacy
        folders=try container.decodeIfPresent([ChatFolder].self,forKey:.folders) ?? folders
        bookmarks=try container.decodeIfPresent([String].self,forKey:.bookmarks) ?? bookmarks
        notes=try container.decodeIfPresent([String: String].self,forKey:.notes) ?? notes
        aliases=try container.decodeIfPresent([String: String].self,forKey:.aliases) ?? aliases
        favorites=try container.decodeIfPresent([String].self,forKey:.favorites) ?? favorites
        hiddenRooms=try container.decodeIfPresent([String].self,forKey:.hiddenRooms) ?? hiddenRooms
        trustedIDs=try container.decodeIfPresent([String].self,forKey:.trustedIDs) ?? trustedIDs
        pendingEvents=try container.decodeIfPresent([PendingRequest].self,forKey:.pendingEvents) ?? pendingEvents
        declinedRooms=try container.decodeIfPresent([String].self,forKey:.declinedRooms) ?? declinedRooms
        reminders=try container.decodeIfPresent([LocalReminder].self,forKey:.reminders) ?? reminders
        snippets=try container.decodeIfPresent([String].self,forKey:.snippets) ?? snippets
        roomRetention=try container.decodeIfPresent([String: Int].self,forKey:.roomRetention) ?? roomRetention
        roomFontSize=try container.decodeIfPresent([String: Double].self,forKey:.roomFontSize) ?? roomFontSize
        receiptExceptions=try container.decodeIfPresent([String].self,forKey:.receiptExceptions) ?? receiptExceptions
        protectedMessages=try container.decodeIfPresent([String].self,forKey:.protectedMessages) ?? protectedMessages
        ocrText=try container.decodeIfPresent([String: String].self,forKey:.ocrText) ?? ocrText
        roomNotes=try container.decodeIfPresent([String: String].self,forKey:.roomNotes) ?? roomNotes
    }

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
