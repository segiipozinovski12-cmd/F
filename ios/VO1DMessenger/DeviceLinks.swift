import Foundation
import CryptoKit
import SwiftUI

struct DeviceCertificate: Codable, Identifiable {
    var id: String
    var issuer: ContactCard
    var device: String
    var expiresAt: Int
    var scope = "history"
    var signature: String
    var signed: Data { Data("VO1D-DEVICE-LINK-2\n\(id)\n\(issuer.id)\n\(device)\n\(expiresAt)\n\(scope)".utf8) }
    func validate(now: Int = Int(Date().timeIntervalSince1970)) throws {
        try Crypto.validate(issuer)
        guard UUID(uuidString:id) != nil, device.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              device != issuer.id, scope == "history", expiresAt > now, expiresAt <= now + 31*86400 else { throw MessengerError.invalid("Разрешение устройства недействительно") }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation:Crypto.decode(issuer.signingKey,count:32))
        guard try key.isValidSignature(Crypto.decode(signature,count:64),for:signed) else { throw MessengerError.invalid("Подпись устройства не совпала") }
    }
}
struct DeviceLink: Codable, Identifiable {
    var certificate: DeviceCertificate
    var peer: ContactCard
    var approved = false
    var id: String { certificate.id }
}

enum DeviceHistory {
    static func snapshot(state: VaultState, owner: ContactCard) throws -> HistoryArchive {
        let messages = Array(state.messages.filter { !$0.text.isEmpty || $0.poll != nil }.sorted { $0.createdAt < $1.createdAt }.suffix(200)).map { input -> ChatMessage in
            var result = input; result.attachment = nil; result.editHistory = nil
            result.readBy = []; result.deliveredTo = []; result.openedAt = nil
            return result
        }
        let roomIDs = Set(messages.map(\.roomID))
        let rooms = state.rooms.filter { roomIDs.contains($0.id) }.map(\.wireCopy)
        let contactIDs = Set(rooms.flatMap(\.members).map(\.id))
        let archive = HistoryArchive(title:"С другого устройства · \(Date().formatted(date:.numeric,time:.shortened))",rooms:rooms,messages:messages,
                                     contacts:state.contacts.filter { contactIDs.contains($0.id) },ownerCard:owner)
        guard try Wire.encoder.encode(archive).count <= 1024*1024 else { throw MessengerError.invalid("История больше 1 МБ. Используй зашифрованную резервную копию") }
        return archive
    }
    static func validate(_ archive: HistoryArchive, owner: ContactCard) throws {
        guard archive.ownerCard == owner, archive.messages.count <= 200, archive.rooms.count <= 200,
              archive.contacts.count <= 3200, archive.messages.allSatisfy({ $0.attachment == nil }),
              Set(archive.messages.map(\.id)).count == archive.messages.count,
              Set(archive.rooms.map(\.id)).count == archive.rooms.count,
              try Wire.encoder.encode(archive).count <= 1024*1024 else { throw MessengerError.invalid("Некорректная история устройства") }
        for contact in archive.contacts { try Crypto.validate(contact.card) }
        for member in archive.rooms.flatMap(\.members) { try Crypto.validate(member) }
        let roomIDs = Set(archive.rooms.map(\.id))
        guard archive.messages.allSatisfy({ roomIDs.contains($0.roomID) }) else { throw MessengerError.invalid("В истории нет соответствующего чата") }
    }
}

extension ChatStore {
    private func deviceEvent(kind: String, certificate: DeviceCertificate, peer: ContactCard, archive: HistoryArchive? = nil) throws {
        guard let identity, let ownCard else { throw MessengerError.invalid("Нет личности") }
        let room = Room(id:"dm:"+[myID,peer.id].sorted().joined(separator:":"),title:"",members:[ownCard,peer],creator:"",isGroup:false,createdAt:Date())
        var event = ChatEvent(kind:kind,room:room,senderName:state.nickname)
        event.deviceCertificate = certificate; event.historyArchive = archive
        state.outbox.append(PendingDelivery(authorizationID:kind == "deviceRevoke" ? nil : certificate.id,envelope:try sealEvent(event,from:identity,to:peer),messageID:nil))
    }
    func pairDevice(_ contact: Contact) throws {
        guard activeProfile?.scope == nil || activeProfile?.scope == .general else { throw MessengerError.invalid("Для изолированной личности используй отдельную копию истории") }
        guard contact.verified, !contact.blocked, let identity, let ownCard, extended.deviceLinks.count < 8 else { throw MessengerError.invalid("Сверь отпечаток устройства; доступно до 8 связей") }
        var certificate = DeviceCertificate(id:UUID().uuidString,issuer:ownCard,device:contact.id,expiresAt:Int(Date().timeIntervalSince1970)+30*86400,signature:"")
        certificate.signature = try identity.signingPrivate.signature(for:certificate.signed).base64EncodedString()
        try deviceEvent(kind:"devicePair",certificate:certificate,peer:contact.card)
        var local = extended; local.deviceLinks.append(DeviceLink(certificate:certificate,peer:contact.card)); state.extended = local; try save()
    }
    func approveDevice(_ id: String) throws {
        guard let link = extended.deviceLinks.first(where:{ $0.id == id }), link.certificate.device == myID,
              state.contacts.contains(where:{ $0.card == link.peer && $0.verified && !$0.blocked }) else { throw MessengerError.invalid("Сверь отпечаток второго устройства") }
        try link.certificate.validate()
        try deviceEvent(kind:"deviceApprove",certificate:link.certificate,peer:link.peer)
        var local = extended
        if let index = local.deviceLinks.firstIndex(where:{ $0.id == id }) { local.deviceLinks[index].approved = true }
        state.extended = local; try save()
    }
    func syncDeviceHistory(_ id: String) throws {
        guard let link = extended.deviceLinks.first(where:{ $0.id == id && $0.approved }), link.certificate.issuer.id == myID, let ownCard else { throw MessengerError.invalid("Другое устройство не подтвердило связь") }
        try link.certificate.validate()
        let snapshot = try DeviceHistory.snapshot(state:state,owner:ownCard)
        try deviceEvent(kind:"deviceHistory",certificate:link.certificate,peer:link.peer,archive:snapshot); try save()
    }
    func revokeDevice(_ id: String) throws {
        guard let link = extended.deviceLinks.first(where:{ $0.id == id }) else { return }
        // Local authorization ends immediately. The peer gets the revocation
        // through the persisted encrypted outbox when connectivity is available.
        try deviceEvent(kind:"deviceRevoke",certificate:link.certificate,peer:link.peer)
        var local = extended; local.deviceLinks.removeAll { $0.id == id }; local.revokedDevices[id] = link.certificate.expiresAt; state.extended = local
        state.outbox.removeAll { pending in
            pending.authorizationID == id
        }
        try save()
    }
    func handleDeviceControl(_ event: ChatEvent, sender: ContactCard) throws -> Bool {
        guard ["devicePair","deviceApprove","deviceHistory","deviceRevoke"].contains(event.kind) else { return false }
        guard let certificate = event.deviceCertificate else { throw MessengerError.invalid("Нет разрешения устройства") }
        try certificate.validate()
        var local = extended
        local.revokedDevices = local.revokedDevices.filter { $0.value > Int(Date().timeIntervalSince1970) }
        if event.kind == "deviceRevoke" {
            guard (certificate.issuer == sender && certificate.device == myID) || (certificate.issuer.id == myID && certificate.device == sender.id) else { throw MessengerError.invalid("Другая связь устройства") }
            local.deviceLinks.removeAll { $0.id == certificate.id }
            local.revokedDevices[certificate.id] = certificate.expiresAt
            state.extended = local; return true
        }
        guard local.revokedDevices[certificate.id] == nil else { throw MessengerError.invalid("Эта связь отозвана") }
        if event.kind == "devicePair" {
            guard certificate.issuer == sender, certificate.device == myID, local.deviceLinks.count < 8,
                  state.contacts.contains(where:{ $0.card == sender && !$0.blocked }) else { throw MessengerError.invalid("Незнакомое устройство") }
            if !local.deviceLinks.contains(where:{ $0.id == certificate.id }) { local.deviceLinks.append(DeviceLink(certificate:certificate,peer:sender)) }
        } else {
            guard let index = local.deviceLinks.firstIndex(where:{ $0.id == certificate.id }), local.deviceLinks[index].peer == sender,
                  local.deviceLinks[index].certificate.signature == certificate.signature else { throw MessengerError.invalid("Связь устройства отозвана или отсутствует") }
            switch event.kind {
            case "deviceApprove":
                guard certificate.issuer.id == myID, certificate.device == sender.id else { throw MessengerError.invalid("Другое устройство в подтверждении") }
                local.deviceLinks[index].approved = true
            case "deviceHistory":
                guard local.deviceLinks[index].approved, certificate.issuer == sender, certificate.device == myID, let archive = event.historyArchive else { throw MessengerError.invalid("История не разрешена") }
                try DeviceHistory.validate(archive,owner:sender)
                local.archives.removeAll { $0.id == archive.id }
                guard local.archives.count < 20 else { throw MessengerError.invalid("Удалить старые архивы можно в разделе истории") }
                local.archives.append(archive)
            case "deviceRevoke": local.deviceLinks.remove(at:index)
            default: break
            }
        }
        state.extended = local
        return true
    }
}

struct DeviceLinksView: View {
    @EnvironmentObject var store: ChatStore
    var body: some View {
        List {
            Section("Связать устройства") {
                Text("На втором устройстве создай отдельную личность. Обменяйся приватными QR и сравни отпечатки через другой канал. Затем отметь контакт проверенным на обоих устройствах и подтверди связь здесь.").font(.caption).foregroundStyle(.secondary)
                ForEach(store.state.contacts.filter { $0.verified && !$0.blocked && !store.isBuiltinBot($0.id) }) { contact in
                    Button("Связать с \(contact.name)") { do { try store.pairDevice(contact) } catch { store.error = error.localizedDescription } }
                }
            }
            Section("Связанные устройства") {
                ForEach(store.extended.deviceLinks) { link in
                    VStack(alignment:.leading,spacing:10) {
                        Text(store.name(link.peer.id)).font(.headline)
                        Text(link.peer.shortID).font(.caption.monospaced())
                        Text(link.approved ? "Связь подтверждена · история" : "Ожидает подтверждения").font(.caption).foregroundStyle(.secondary)
                        if link.certificate.device == store.myID && !link.approved {
                            Button("Подтвердить своё второе устройство") { do { try store.approveDevice(link.id) } catch { store.error = error.localizedDescription } }
                        }
                        if link.approved && link.certificate.issuer.id == store.myID {
                            Button("Передать последние 200 текстовых сообщений") { do { try store.syncDeviceHistory(link.id) } catch { store.error = error.localizedDescription } }
                        }
                        Button("Отозвать связь",role:.destructive) { do { try store.revokeDevice(link.id) } catch { store.error = error.localizedDescription } }
                    }
                }
                Text("Передача использует отдельную сессию libsignal. Долгосрочные ключи личности не копируются. На втором устройстве история появляется архивом; вложения и полноценная синхронизация новых чатов пока не поддерживаются. Отзыв не удаляет уже полученную историю.").font(.caption).foregroundStyle(.secondary)
            }
        }.scrollContentBackground(.hidden).background(.black).navigationTitle("Мои устройства")
    }
}
