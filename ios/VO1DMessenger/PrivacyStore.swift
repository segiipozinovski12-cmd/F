import Foundation
import UIKit
import SwiftUI
import LocalAuthentication
import CryptoKit

extension ChatStore {
    var extended: ExtendedState { state.extended ?? ExtendedState() }
    var preferences: PrivacyPreferences { extended.privacy }

    func changeExtended(_ update: (inout ExtendedState) -> Void) {
        var value = extended
        update(&value)
        state.extended = value
        persist()
    }

    func preferenceBinding<T>(_ key: WritableKeyPath<PrivacyPreferences,T>) -> SwiftUI.Binding<T> {
        SwiftUI.Binding(get: { self.preferences[keyPath:key] },
                        set: { value in self.changeExtended { $0.privacy[keyPath:key] = value } })
    }

    func applyPrivacy() async throws {
        guard let api else { throw MessengerError.invalid("Нет соединения") }
        struct Body: Encodable { var discoverable: Bool; var inactivityDays: Int; var trustedCalls: Bool }
        let _: APIClient.OK = try await api.request("v1/privacy",method:"POST",
            body: Wire.encoder.encode(Body(discoverable:preferences.discoverable,
                inactivityDays:preferences.inactivityDays,trustedCalls:preferences.requireRequests || preferences.verifiedOnlyCalls)))
        let allowed=state.contacts.filter { contact in
            !contact.blocked && extended.trustedIDs.contains(contact.id) && (!preferences.verifiedOnlyCalls || contact.verified)
        }.map(\.id)
        let _: APIClient.OK = try await api.request("v1/trust/sync",method:"POST",body:Wire.encoder.encode(["ids":allowed]))
        try await BackgroundCalls.prepare(self, api: api)
    }

    func trustOnServer(_ id: String, trusted: Bool) async throws {
        struct Body: Encodable { var id: String; var trusted: Bool }
        let contact=state.contacts.first { $0.id==id }
        let permitted=trusted && contact?.blocked != true && (!preferences.verifiedOnlyCalls || contact?.verified==true)
        let _: APIClient.OK = try await api?.request("v1/trust",method:"POST",
            body:Wire.encoder.encode(Body(id:id,trusted:permitted))) ?? APIClient.OK(ok:false)
    }

    func rotatePublicCode() async throws {
        struct Response: Decodable { var code: String }
        guard let api else { throw MessengerError.invalid("Нет соединения") }
        let result: Response = try await api.request("v1/code/rotate",method:"POST",body:Data("{}".utf8))
        state.publicCode = result.code
        try save()
    }

    func releaseUsername() async throws {
        guard let api else { throw MessengerError.invalid("Нет соединения") }
        let _: APIClient.OK = try await api.request("v1/username",method:"DELETE")
        state.username = nil
        try save()
    }

    func createInvite(seconds: Int, uses: Int) async throws -> InviteReceipt {
        struct Body: Encodable { var seconds: Int; var uses: Int }
        guard let api else { throw MessengerError.invalid("Нет соединения") }
        return try await api.request("v1/invites",method:"POST",body:Wire.encoder.encode(Body(seconds:seconds,uses:uses)))
    }

    func listInvites() async throws -> [InviteReceipt] {
        struct Response: Decodable { var invites: [InviteReceipt] }
        guard let api else { throw MessengerError.invalid("Нет соединения") }
        let result: Response = try await api.request("v1/invites")
        return result.invites
    }

    func revokeInvite(_ id: String) async throws {
        guard let api else { throw MessengerError.invalid("Нет соединения") }
        let _: APIClient.OK = try await api.request("v1/invites/\(id)",method:"DELETE")
    }

    func acceptRequest(_ roomID: String) async throws {
        let events = extended.pendingEvents.filter { $0.room.id == roomID }
        guard !events.isEmpty else { return }
        acceptedPendingIDs.insert(roomID)
        defer { acceptedPendingIDs.remove(roomID) }
        // Apply into a rollback-capable snapshot so a malformed request cannot half-create a chat.
        let original = state
        do {
            for pending in events {
                let sender = pending.sender
                if let expiry = pending.event.message?.expiresAt, expiry <= Date() { continue }
                try applyAccepted(pending.event, sender: sender)
                changeExtended { if !$0.trustedIDs.contains(sender.id) { $0.trustedIDs.append(sender.id) } }
            }
            changeExtended { $0.pendingEvents.removeAll { $0.room.id == roomID } }
            try save()
            for id in Set(events.map { $0.sender.id }) { try? await trustOnServer(id,trusted:true) }
        } catch {
            state = original
            try? save()
            throw error
        }
    }

    func declineRequest(_ roomID: String, block: Bool) async {
        let events = extended.pendingEvents.filter { $0.room.id == roomID }
        changeExtended {
            $0.pendingEvents.removeAll { $0.room.id == roomID }
            if !$0.declinedRooms.contains(roomID) { $0.declinedRooms.append(roomID) }
            if $0.declinedRooms.count > 500 { $0.declinedRooms.removeFirst() }
        }
        if block, let peer = events.first?.sender.id, let api {
            try? await api.block(peer,blocked:true)
        }
    }

    var requestRooms: [Room] {
        var seen = Set<String>()
        return extended.pendingEvents.compactMap { seen.insert($0.room.id).inserted ? $0.room : nil }
    }

    func toggleBookmark(_ id: String) {
        changeExtended {
            if $0.bookmarks.contains(id) { $0.bookmarks.removeAll { $0 == id } }
            else { $0.bookmarks.append(id) }
        }
    }

    func toggleHidden(_ id: String) async {
        do {
            guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication,localizedReason:"Защитить скрытые чаты") else { return }
            changeExtended {
                if $0.hiddenRooms.contains(id) { $0.hiddenRooms.removeAll { $0 == id } }
                else { $0.hiddenRooms.append(id) }
            }
            revealedHiddenRooms = false
        } catch { self.error = error.localizedDescription }
    }

    func revealHidden() async {
        do {
            if try await LAContext().evaluatePolicy(.deviceOwnerAuthentication,localizedReason:"Открыть скрытые чаты") { revealedHiddenRooms = true }
        } catch { self.error = error.localizedDescription }
    }

    func createFolder(_ name: String) {
        let clean = String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(32))
        guard !clean.isEmpty, extended.folders.count < 20 else { return }
        changeExtended { $0.folders.append(ChatFolder(name:clean)) }
    }

    func folderToggle(_ folderID: String, roomID: String) {
        changeExtended {
            guard let i = $0.folders.firstIndex(where: { $0.id == folderID }) else { return }
            if $0.folders[i].roomIDs.contains(roomID) { $0.folders[i].roomIDs.removeAll { $0 == roomID } }
            else { $0.folders[i].roomIDs.append(roomID) }
        }
    }

    func removeRoom(_ roomID: String) {
        guard !isLocalUtilityRoom(roomID) else { return }
        let ids = Set(state.messages.filter { $0.roomID == roomID }.map(\.id))
        state.outbox.removeAll { ids.contains($0.messageID ?? "") }
        state.messages.removeAll { $0.roomID == roomID }
        state.rooms.removeAll { $0.id == roomID }
        changeExtended {
            $0.hiddenRooms.removeAll { $0 == roomID }
            $0.bookmarks.removeAll { ids.contains($0) }
            $0.pendingEvents.removeAll { $0.room.id == roomID }
            $0.roomNotes[roomID] = nil
            for i in $0.folders.indices { $0.folders[i].roomIDs.removeAll { $0 == roomID } }
        }
    }

    func cancelMessage(_ id: String) {
        state.outbox.removeAll { $0.messageID == id }
        if let i = state.messages.firstIndex(where: { $0.id == id }) {
            if state.messages[i].state == "scheduled" { state.messages.remove(at:i) }
            else { state.messages[i].state = "cancelled" }
        }
        deliveryIssues = deliveryIssues.filter { !($0.value.id == id) }
        persist()
    }

    func reschedule(_ id: String, at: Date) {
        guard let i = state.messages.firstIndex(where: { $0.id == id && $0.state == "scheduled" }),
              at > Date() else { return }
        state.messages[i].scheduledAt = at
        persist()
    }

    func localReminder(_ message: ChatMessage, seconds: Int) {
        let item = LocalReminder(messageID:message.id,roomID:message.roomID,at:Date().addingTimeInterval(Double(seconds)))
        changeExtended { $0.reminders.append(item) }
        NotificationCoordinator.shared.scheduleReminder(item)
    }

    var notificationsQuiet: Bool {
        guard preferences.quietHours else { return false }
        let hour = Calendar.current.component(.hour,from:Date())
        let start = preferences.quietStart, end = preferences.quietEnd
        return start < end ? hour >= start && hour < end : hour >= start || hour < end
    }

    func localStorageBytes(_ roomID: String? = nil) -> Int {
        state.messages.filter { roomID == nil || $0.roomID == roomID }.reduce(0) {
            $0 + $1.text.utf8.count + ($1.attachment?.data.count ?? 0) + ($1.attachment?.previewData?.count ?? 0)
        }
    }

    func clearMedia(_ roomID: String? = nil) {
        for i in state.messages.indices where roomID == nil || state.messages[i].roomID == roomID {
            // Remote ciphertext can be fetched again. Inline media has no other local copy.
            if state.messages[i].attachment?.blobID != nil { state.messages[i].attachment?.previewData = nil }
            else { state.messages[i].attachment = nil }
        }
        MediaFiles.clear()
        ResumableDownload.clear()
        persist()
    }

    func rotateAccessKey() throws {
        state.accessKey = try randomToken(length:9)
        try save()
    }

    func integrityReport() throws -> String {
        guard let identity else { throw MessengerError.invalid("Нет ключей") }
        try Crypto.validate(identity.card)
        for contact in state.contacts where !isBuiltinBot(contact.id) { try Crypto.validate(contact.card) }
        guard Set(state.rooms.map(\.id)).count == state.rooms.count,
              Set(state.messages.map(\.id)).count == state.messages.count else {
            throw MessengerError.invalid("Найдены повторяющиеся идентификаторы")
        }
        return "Подписи контактов, личность и уникальность записей проверены."
    }
}

extension ChatStore {
    func reconfigureTransport() async throws {
        guard let identity else { throw MessengerError.invalid("Нет ключей") }
        generation += 1
        let expected = generation
        CallManager.shared.disconnect(); api?.session.invalidateAndCancel(); api = nil
        try await prepareNetworkRoute()
        guard expected == generation else { throw CancellationError() }
        let client = try APIClient(server:state.server.isEmpty ? AppConfig.productionRelay : state.server,identity:identity,privacy:preferences)
        try await client.authenticate()
        guard expected == generation else { throw CancellationError() }
        try await BackgroundCalls.prepare(self,api:client)
        guard expected == generation else { throw CancellationError() }
        api=client
        CallManager.shared.configure(api:client,identity:identity,nameResolver:{ [weak self] in self?.name($0) ?? "VO1D" },recordSink:{ [weak self] in self?.recordCall($0) })
        CallManager.shared.allowedPeer = { [weak self] id in
            guard let self else { return false }
            let known=self.extended.trustedIDs.contains(id)
            let verified=self.state.contacts.first(where: { $0.id==id })?.verified==true
            let blocked=self.state.contacts.first(where: { $0.id==id })?.blocked==true
            return !blocked && (!self.preferences.requireRequests || known) && (!self.preferences.verifiedOnlyCalls || verified)
        }
        connection="Подключён"
        try await PushCoordinator.shared.register(api:client,enabled:state.notificationsEnabled==true)
    }

    func sealEvent(_ input: ChatEvent, from identity: LocalIdentity, to target: ContactCard) throws -> Envelope {
        if preferences.requirePrivateDelivery, extended.peerMailboxes[target.id] == nil {
            throw MessengerError.invalid("Нужен приватный QR контакта: строгий режим скрывает отправителя при доставке")
        }
        var event=input
        if !event.room.isGroup, let alias=extended.aliases[target.id], !alias.isEmpty { event.senderName=alias }
        if preferences.padding { event.padding=try Crypto.random(128).base64EncodedString() }
        event = try Crypto.sanitized(event, from: identity, to: target)
        return Envelope(id: UUID().uuidString, sender: try identity.card.id, recipient: target.id,
            ephemeralKey: "", salt: "", expiresAt: Int(Date().timeIntervalSince1970) + 7 * 86400,
            ciphertext: "", signature: "", deferredEvent: try Wire.encoder.encode(event))
    }

    func retryDelivery(_ messageID: String) {
        guard state.outbox.contains(where: { $0.messageID == messageID }) else {
            error = "Сохранённой очереди для этого сообщения нет. Отправь его заново: старые ключи из резервной копии не восстанавливаются."
            return
        }
        for pending in state.outbox where pending.messageID==messageID { deliveryIssues[pending.id]=nil }
        if let i=state.messages.firstIndex(where: { $0.id==messageID }) { state.messages[i].state="queued" }
        persist()
        Task { await sync() }
    }
}

extension ChatStore {
    func reloadProtectedData() async {
        guard fatalError != nil, UIApplication.shared.isProtectedDataAvailable else { return }
        do {
            profileRegistry = try ProfileRegistry.load()
            let loaded=try Keychain.load(profileID: profileID)
            let storage=try Vault(profileID: profileID)
            let restored=try storage.read(key:loaded.storage)
            identity=loaded; ownCard=try loaded.card; vault=storage; state=restored
            fatalError=nil; locked=state.appLock; sessionUnlocked = !state.onboarded
        } catch { fatalError=error.localizedDescription }
    }
}

extension ChatStore {
    func setupCallPolicy() {
        CallManager.shared.allowedPeer = { [weak self] id in
            guard let self else { return false }
            let known=self.extended.trustedIDs.contains(id)
            let verified=self.state.contacts.first(where: { $0.id==id })?.verified==true
            let blocked=self.state.contacts.first(where: { $0.id==id })?.blocked==true
            return !blocked && (!self.preferences.requireRequests || known) && (!self.preferences.verifiedOnlyCalls || verified)
        }
    }
}

extension ChatStore {
    func recordPrivateVote(messageID: String,voterID: String,optionID: String) throws {
        guard let index=state.messages.firstIndex(where: { $0.id==messageID }),state.messages[index].sender==myID,
              var poll=state.messages[index].poll,poll.privateVotes==true,!poll.closed,
              poll.options.contains(where: { $0.id==optionID }),
              let room=state.rooms.first(where: { $0.id==state.messages[index].roomID }),room.members.contains(where: { $0.id==voterID }) else { return }
        var extra=extended
        var votes=extra.privatePollVotes[messageID] ?? [:]
        votes[voterID]=optionID
        extra.privatePollVotes[messageID]=votes
        state.extended=extra
        var counts: [String:Int]=[:]
        for value in votes.values { counts[value,default:0] += 1 }
        poll.privateCounts=counts
        for i in poll.options.indices { poll.options[i].voterIDs=[] }
        state.messages[index].poll=poll
        if !isLocalUtilityRoom(room.id) {
            let encoded=String(data:try JSONEncoder().encode(counts),encoding:.utf8) ?? "{}"
            try enqueue(ChatEvent(kind:"privatePollResult",room:room,target:messageID,value:encoded,senderName:state.nickname),room:room)
        }
        try save()
    }

    func setPrivateRoster(_ roomID: String,enabled: Bool) throws {
        guard let index=state.rooms.firstIndex(where: { $0.id==roomID }),isGroupOwner(state.rooms[index]),state.rooms[index].isChannel==true else {
            throw MessengerError.invalid("Скрытый состав доступен для собственного канала")
        }
        let old=state.rooms[index]
        guard Set(old.admins ?? [myID])==Set([myID]) else { throw MessengerError.invalid("Сначала оставь одного администратора канала") }
        var updated=old
        updated.privateRoster=enabled
        updated.onlyAdminsCanPost=true
        try publishRoomUpdate(oldRoom:old,newRoom:updated)
        state.rooms[index]=updated
        try save()
    }

    func beginActiveSession() {
        let days=preferences.inactivityDays
        if days>0,let previous=extended.lastOpenedAt,Date().timeIntervalSince(previous)>=Double(days)*86400 {
            do { try resetLocalIdentity() } catch { self.error=error.localizedDescription }
        }
        changeExtended { $0.lastOpenedAt=Date() }
    }
}
