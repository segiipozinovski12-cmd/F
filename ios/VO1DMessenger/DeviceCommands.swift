import Foundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct SharedPrivateLink: Codable, Identifiable {
    var id: String
    var expiresAt: Int
    var revocationPending: Bool
    static func reference(token: String, owner: String) -> String {
        Crypto.hex(SHA256.hash(data: Data("VO1D-DEVICE-LINK-REF-1\n\(owner)\n\(token)".utf8)))
    }
}
struct DelegatedPrivateLinksView: View {
    var certificateID: String
    @EnvironmentObject private var store: ChatStore
    var body: some View {
        List {
            Text("Передаются только ID, срок и состояние ссылок. Секрет приглашения и разрешения ящика не копируются. Отзыв выполнит основное устройство после подключения.").font(.caption)
            ForEach(store.extended.archives.first(where: { $0.id == certificateID })?.sharedPrivateLinks ?? []) { link in
                VStack(alignment: .leading) {
                    Text(String(link.id.prefix(12))).font(.body.monospaced())
                    Text(Date(timeIntervalSince1970: Double(link.expiresAt)), style: .date).font(.caption)
                    Button("Отозвать через основное устройство", role: .destructive) {
                        do { try store.queueDeviceCommand(DeviceCommand(certificateID: certificateID, operation: "revokeLink", roomID: "", target: link.id)) } catch { store.error = error.localizedDescription }
                    }.disabled(link.revocationPending)
                }
            }
            ForEach(store.extended.pendingDeviceCommands.filter { $0.certificateID == certificateID && $0.operation == "revokeLink" }.suffix(20)) { command in
                Text(command.detail ?? "Отзыв ожидает основное устройство").font(.caption)
            }
        }.navigationTitle("Ссылки основной личности")
    }
}

struct DeviceCommand: Codable, Identifiable {
    var id = UUID().uuidString
    var certificateID: String
    var operation: String
    var roomID: String
    var target: String? = nil
    var text = ""
    var attachment: Attachment? = nil
    var createdAt = Date()
    var status = "waiting"
    var detail: String? = nil
    var key: String { certificateID + ":" + id }
    func validate() throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: certificateID) != nil,
              ["send", "edit", "delete", "revokeLink"].contains(operation), roomID.count <= 160,
              text.count <= 16000, createdAt > Date().addingTimeInterval(-7*86400), createdAt < Date().addingTimeInterval(300),
              attachment == nil || (operation == "send" && attachment?.viewSeconds == nil),
              (attachment?.data.count ?? 0) <= 128*1024,
              (attachment?.previewData?.count ?? 0) <= 64*1024,
              (target?.count ?? 0) <= 160 else { throw MessengerError.invalid("Некорректный запрос второго устройства") }
        if operation == "send" { guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil else { throw MessengerError.invalid("Пустое сообщение") } }
        if operation == "edit" { guard !text.isEmpty else { throw MessengerError.invalid("Пустая правка") } }
    }
}
struct DeviceCommandResult: Codable {
    var commandID: String
    var certificateID: String
    var status: String
    var detail: String
    var at = Date()
}
enum DeviceAuthority {
    static func validate(link: DeviceLink, certificate: DeviceCertificate, sender: ContactCard, issuerID: String, revoked: [String:Int]) throws {
        try certificate.validate()
        guard certificate.scope == "collaboration", certificate.issuer.id == issuerID, certificate.device == sender.id,
              link.approved, link.certificate.signature == certificate.signature, link.peer.hasSameKeys(as: sender),
              revoked[certificate.id] == nil else { throw MessengerError.invalid("Отправка от основной личности не разрешена или связь отозвана") }
    }
}
extension ChatStore {
    func queueDeviceCommand(_ command: DeviceCommand) throws {
        try command.validate()
        guard !locked, let link = extended.deviceLinks.first(where: { $0.id == command.certificateID }), link.approved,
              link.certificate.scope == "collaboration", link.certificate.device == myID,
              state.contacts.contains(where: { $0.card.hasSameKeys(as: link.peer) && $0.verified && !$0.blocked }),
              extended.revokedDevices[link.id] == nil, state.outbox.count < 2000,
              extended.pendingDeviceCommands.filter({ $0.status == "waiting" }).count < 128 else { throw MessengerError.invalid("Нет разрешения или очередь запросов заполнена") }
        try link.certificate.validate()
        let previous = state
        do {
            try deviceEvent(kind: "deviceCommand", certificate: link.certificate, peer: link.peer, command: command)
            var local = extended; local.pendingDeviceCommands.removeAll { $0.id == command.id }
            var waiting = command; waiting.status = "waiting"; waiting.detail = nil
            local.pendingDeviceCommands.append(waiting); local.pendingDeviceCommands = Array(local.pendingDeviceCommands.suffix(500)); state.extended = local
            try save()
        } catch { state = previous; throw error }
        Task { await sync() }
    }
    func handleDeviceCommand(_ event: ChatEvent, sender: ContactCard, certificate: DeviceCertificate) throws {
        guard let link = extended.deviceLinks.first(where: { $0.id == certificate.id }),
              state.contacts.contains(where: { $0.card.hasSameKeys(as: sender) && $0.verified && !$0.blocked }) else { throw MessengerError.invalid("Устройство не проверено") }
        if event.kind == "deviceCommandResult" {
            guard certificate.scope == "collaboration", certificate.device == myID, link.approved,
                  certificate.signature == link.certificate.signature, link.peer.hasSameKeys(as: sender), extended.revokedDevices[certificate.id] == nil else { throw MessengerError.invalid("Связь устройства отсутствует или отозвана") }
            guard certificate.issuer.hasSameKeys(as: sender), let result = event.deviceCommandResult,
                  result.certificateID == certificate.id, ["queued", "applied", "rejected"].contains(result.status),
                  result.detail.count <= 240, let index = extended.pendingDeviceCommands.firstIndex(where: { $0.id == result.commandID && $0.certificateID == certificate.id }) else { throw MessengerError.invalid("Неизвестный ответ устройства") }
            var local = extended; local.pendingDeviceCommands[index].status = result.status; local.pendingDeviceCommands[index].detail = result.detail; state.extended = local; return
        }
        try DeviceAuthority.validate(link: link, certificate: certificate, sender: sender, issuerID: myID, revoked: extended.revokedDevices)
        guard let command = event.deviceCommand, command.certificateID == certificate.id else { throw MessengerError.invalid("Неизвестный запрос") }
        try command.validate()
        var pruned = extended; pruned.completedDeviceCommands = pruned.completedDeviceCommands.filter { $0.value.at > Date().addingTimeInterval(-8*86400) }; state.extended = pruned
        if let result = extended.completedDeviceCommands[command.key] {
            try deviceEvent(kind: "deviceCommandResult", certificate: certificate, peer: sender, result: result); return
        }
        guard extended.completedDeviceCommands.count < 10000, state.outbox.count < 1900 else { throw MessengerError.invalid("Очередь основного устройства заполнена") }
        let before = state
        var result = DeviceCommandResult(commandID: command.id, certificateID: certificate.id, status: "applied", detail: "Применено основным устройством")
        do {
            if command.operation == "revokeLink" {
                guard let target = command.target, let index = extended.privateLinks.firstIndex(where: { SharedPrivateLink.reference(token: $0.token, owner: myID) == target }) else { throw MessengerError.invalid("Ссылка отсутствует") }
                var local = extended; local.privateLinks[index].revocationPending = true; local.privateLinks[index].stopped = false; local.privateLinks[index].nextAttempt = nil; state.extended = local
            } else {
                guard let room = state.rooms.first(where: { $0.id == command.roomID }), !isLocalUtilityRoom(room.id),
                      room.members.contains(where: { $0.id == myID }), !extended.declinedRooms.contains(room.id) else { throw MessengerError.invalid("Чат отсутствует или недоступен") }
                switch command.operation {
                case "send":
                    guard !state.messages.contains(where: { $0.id == command.id }) else { throw MessengerError.invalid("Этот ID сообщения уже использован") }
                    try send(roomID: room.id, text: command.text, attachment: command.attachment, replyTo: command.target, deliveryID: command.id, persistImmediately: false)
                    result.status = "queued"; result.detail = "Основное устройство сохранило сообщение в очереди"
                case "edit", "delete":
                    guard let message = state.messages.first(where: { $0.id == command.target && $0.roomID == room.id }), message.sender == myID,
                          message.viewOnceSeconds == nil, message.attachment?.viewSeconds == nil,
                          (message.expiresAt ?? .distantFuture) > Date() else { throw MessengerError.invalid("Сообщение нельзя изменить") }
                    try action(command.operation, message: message, value: command.text, persistImmediately: false)
                default: throw MessengerError.invalid("Неизвестное действие")
                }
            }
        } catch { state = before; result.status = "rejected"; result.detail = String(error.localizedDescription.prefix(240)) }
        var local = extended; local.completedDeviceCommands[command.key] = result; state.extended = local
        try deviceEvent(kind: "deviceCommandResult", certificate: certificate, peer: sender, result: result)
        // The caller saves the accepted command, exact outgoing bytes and dedup
        // record together before ACK. No nested save is allowed in this path.
    }
}

struct LinkedDeviceComposer: View {
    var archiveID: String
    var roomID: String
    @EnvironmentObject private var store: ChatStore
    @State private var text = ""
    @State private var importing = false
    @State private var busy = false
    @State private var failure: String?
    private var link: DeviceLink? { store.extended.deviceLinks.first { $0.id == archiveID && $0.approved && $0.certificate.scope == "collaboration" && $0.certificate.device == store.myID } }
    var body: some View {
        if let link {
            Section("От основной личности") {
                TextField("Сообщение", text: $text, axis: .vertical).lineLimit(1...6)
                HStack {
                    Button("Файл", systemImage: "paperclip") { importing = true }.disabled(busy)
                    Button("Отправить", systemImage: "paperplane") { submit(link: link, attachment: nil) }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
                Text("Запрос зашифрован и сохранён. Основное устройство отправит его после подключения.").font(.caption).foregroundStyle(.secondary)
                ForEach(store.extended.pendingDeviceCommands.filter { $0.certificateID == link.id && $0.roomID == roomID }.suffix(20)) { command in
                    VStack(alignment: .leading) {
                        Text(command.detail ?? "Ждёт основное устройство").font(.caption)
                        if command.status == "waiting" { Button("Повторить запрос") { do { try store.queueDeviceCommand(command) } catch { failure = error.localizedDescription } } }
                    }
                }
                if let failure { Text(failure).font(.caption) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                guard case .success(let url) = result else { return }; busy = true
                let expected = store.generation
                Task {
                    defer { busy = false }; let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size > 0, size <= 50*1024*1024 else { throw MessengerError.invalid("Файл должен быть до 50 МБ") }
                        let data = try Data(contentsOf: url), attachment = try await store.prepareRemoteAttachment(name: url.lastPathComponent, mime: "application/octet-stream", data: data)
                        guard expected == store.generation else { throw CancellationError() }
                        submit(link: link, attachment: attachment)
                    } catch { if expected == store.generation { failure = error.localizedDescription } }
                }
            }
            .onChange(of: store.generation) { _, _ in text = ""; failure = nil; importing = false }
        }
    }
    private func submit(link: DeviceLink, attachment: Attachment?) {
        do { try store.queueDeviceCommand(DeviceCommand(certificateID: link.id, operation: "send", roomID: roomID, text: text, attachment: attachment)); text = ""; failure = nil } catch { failure = error.localizedDescription }
    }
}
