import Foundation
import CryptoKit
import SwiftUI

struct GroupInvitation: Codable, Identifiable {
    var id: String
    var roomID: String
    var title: String
    var creator: ContactCard
    var audience: String
    var epoch: Int
    var expiresAt: Int
    var signature: String
    var signed: Data { Data("VO1D-GROUP-INVITE-2\n\(id)\n\(roomID)\n\(Data(title.utf8).base64EncodedString())\n\(creator.id)\n\(audience)\n\(epoch)\n\(expiresAt)\njoin".utf8) }
    func validate(recipient: String, sender: ContactCard, now: Int = Int(Date().timeIntervalSince1970)) throws {
        try Crypto.validate(creator); try Crypto.validate(sender)
        guard UUID(uuidString:id) != nil, UUID(uuidString:roomID) != nil, !title.isEmpty, title.count <= 60,
              creator == sender, audience == recipient, epoch >= 0, expiresAt > now, expiresAt <= now + 86400 else {
            throw MessengerError.invalid("Приглашение в группу недействительно или истекло")
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: Crypto.decode(creator.signingKey,count:32))
        guard try key.isValidSignature(Crypto.decode(signature,count:64),for:signed) else { throw MessengerError.invalid("Подпись приглашения в группу не совпала") }
    }
}

extension ChatStore {
    func issueGroupInvitation(roomID: String, to contact: Contact) throws {
        guard let room = state.rooms.first(where: { $0.id == roomID }), isGroupOwner(room),
              !room.members.contains(where: { $0.id == contact.id }), !contact.blocked, room.members.count < 16,
              let identity, let ownCard else { throw MessengerError.invalid("Нужна свободная группа и доступный контакт") }
        var invitation = GroupInvitation(id:UUID().uuidString,roomID:room.id,title:room.title,creator:ownCard,audience:contact.id,
                                         epoch:room.membershipEpoch ?? 0,expiresAt:Int(Date().timeIntervalSince1970)+3600,signature:"")
        invitation.signature = try identity.signingPrivate.signature(for:invitation.signed).base64EncodedString()
        var event = ChatEvent(kind:"groupInvite",room:room,senderName:state.nickname)
        event.groupInvitation = invitation
        let pending = PendingDelivery(authorizationID:invitation.id,envelope:try sealEvent(event,from:identity,to:contact.card),messageID:nil)
        var local = extended; local.issuedGroupInvites[invitation.id] = invitation; state.extended = local
        state.outbox.append(pending); try save()
    }
    func acceptGroupInvitation(_ invitation: GroupInvitation) throws {
        guard let identity, let owner = state.contacts.first(where:{ $0.id == invitation.creator.id }),
              extended.pendingGroupInvites.contains(where:{ $0.id == invitation.id }) else { throw MessengerError.invalid("Контакт создателя недоступен") }
        try invitation.validate(recipient:myID,sender:owner.card)
        guard let ownCard else { throw MessengerError.invalid("Нет личности") }
        let room = Room(id:invitation.roomID,title:invitation.title,members:[ownCard,owner.card],creator:owner.id,isGroup:true,createdAt:Date())
        var event = ChatEvent(kind:"groupJoin",room:room,senderName:state.nickname); event.groupInvitation = invitation
        let pending = PendingDelivery(envelope:try sealEvent(event,from:identity,to:owner.card),messageID:nil)
        var local = extended; local.acceptedGroupInvites[invitation.roomID] = invitation
        local.pendingGroupInvites.removeAll { $0.id == invitation.id }; state.extended = local
        state.outbox.append(pending); try save()
    }
    func revokeGroupInvitation(_ id: String) throws {
        var local = extended; local.issuedGroupInvites[id] = nil; state.extended = local
        state.outbox.removeAll { pending in
            pending.authorizationID == id
        }
        try save()
    }
    func handleGroupControl(_ event: ChatEvent, sender: ContactCard) throws -> Bool {
        guard event.kind == "groupInvite" || event.kind == "groupJoin" else { return false }
        guard let invitation = event.groupInvitation else { throw MessengerError.invalid("Нет подписанного приглашения") }
        if event.kind == "groupInvite" {
            try invitation.validate(recipient:myID,sender:sender)
            guard invitation.roomID == event.room.id, event.room.creator == sender.id else { throw MessengerError.invalid("Другая группа в приглашении") }
            try validateScopedRoom(event.room)
            var local = extended
            local.pendingGroupInvites.removeAll { $0.expiresAt <= Int(Date().timeIntervalSince1970) }
            if local.pendingGroupInvites.count < 100, !local.pendingGroupInvites.contains(where:{ $0.id == invitation.id }) { local.pendingGroupInvites.append(invitation) }
            state.extended = local
        } else {
            guard let issued = extended.issuedGroupInvites[invitation.id], issued.signature == invitation.signature,
                  issued.audience == sender.id, issued.creator.id == myID,
                  let room = state.rooms.first(where:{ $0.id == issued.roomID }), isGroupOwner(room),
                  issued.epoch == (room.membershipEpoch ?? 0) else { throw MessengerError.invalid("Приглашение отозвано, использовано или состав изменился") }
            try issued.validate(recipient:sender.id,sender:issued.creator)
            var contacts = state.contacts.filter { room.members.contains($0.card) && $0.id != myID }
            if !state.contacts.contains(where:{ $0.id == sender.id }) { state.contacts.append(Contact(card:sender,name:String(event.senderName.prefix(40)))) }
            if let joiner = state.contacts.first(where:{ $0.id == sender.id }), !contacts.contains(where:{ $0.id == joiner.id }) { contacts.append(joiner) }
            try updateGroupMembers(room.id,contacts:contacts)
            var local = extended; local.issuedGroupInvites[issued.id] = nil; state.extended = local
        }
        return true
    }
}

struct GroupInvitationsView: View {
    var roomID: String? = nil
    @EnvironmentObject var store: ChatStore
    var body: some View {
        List {
            Section("Полученные") {
                ForEach(store.extended.pendingGroupInvites.filter { $0.expiresAt > Int(Date().timeIntervalSince1970) }) { invitation in
                    VStack(alignment:.leading,spacing:8) {
                        Text(invitation.title).font(.headline)
                        Text("Подписано создателем · только для этой личности · 1 час").font(.caption).foregroundStyle(.secondary)
                        Button("Принять приглашение") { do { try store.acceptGroupInvitation(invitation) } catch { store.error = error.localizedDescription } }
                    }
                }
            }
            if let roomID {
                Section("Пригласить контакт") {
                    ForEach(store.state.contacts.filter { !$0.blocked && !store.isBuiltinBot($0.id) && store.state.rooms.first(where:{ $0.id == roomID })?.members.contains($0.card) == false }) { contact in
                        Button(contact.name) { do { try store.issueGroupInvitation(roomID:roomID,to:contact) } catch { store.error = error.localizedDescription } }
                    }
                }
            }
            Section("Выданные") {
                ForEach(Array(store.extended.issuedGroupInvites.values).filter { $0.expiresAt > Int(Date().timeIntervalSince1970) }) { invitation in
                    HStack {
                        VStack(alignment:.leading) { Text(invitation.title); Text(store.name(invitation.audience)).font(.caption) }
                        Spacer()
                        Button("Отозвать") { do { try store.revokeGroupInvitation(invitation.id) } catch { store.error = error.localizedDescription } }
                    }
                }
                Text("Приглашение подписано для одного контакта и версии состава группы. Создатель проверяет его повторно при вступлении. Отзыв применяется на его устройстве; для проверки вступления оно должно быть онлайн.").font(.caption).foregroundStyle(.secondary)
            }
        }.scrollContentBackground(.hidden).background(.black).navigationTitle("Приглашения в группы")
    }
}
