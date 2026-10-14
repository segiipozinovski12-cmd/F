import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct HistoryArchive: Codable, Identifiable {
    var id = UUID().uuidString
    var title: String
    var rooms: [Room]
    var messages: [ChatMessage]
    var contacts: [Contact]
    var ownerCard: ContactCard?
}
struct HistoryArchivesView: View {
    @EnvironmentObject var store: ChatStore
    var body: some View {
        List {
            Section {
                Text("Архивы открываются для чтения. Импорт истории не меняет текущие ключи и не возобновляет старые сессии.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.extended.archives) { archive in
                NavigationLink(archive.title) { ArchiveRoomsView(archive:archive) }
            }.onDelete { indices in
                store.changeExtended { local in for index in indices.sorted(by:>) { local.archives.remove(at:index) } }
            }
        }.navigationTitle("Архивы истории")
    }
}
private struct ArchiveRoomsView: View {
    var archive: HistoryArchive
    @EnvironmentObject private var store: ChatStore
    private var current: HistoryArchive { store.extended.archives.first { $0.id == archive.id } ?? archive }
    var body: some View {
        List(current.rooms) { room in NavigationLink(room.title.isEmpty ? "Личный чат" : room.title) { ArchiveMessagesView(archive:current,room:room) } }
            .navigationTitle(archive.title)
    }
}
private struct ArchiveMessagesView: View {
    var archive: HistoryArchive
    var room: Room
    @EnvironmentObject private var store: ChatStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var editing: ChatMessage?
    @State private var editedText = ""
    @State private var showEdit = false
    @State private var exporting = false
    @State private var document = BackupDocument(data: Data())
    @State private var filename = "file"
    @State private var failure: String?
    private var current: HistoryArchive { store.extended.archives.first { $0.id == archive.id } ?? archive }
    private var link: DeviceLink? { store.extended.deviceLinks.first { $0.id == archive.id && $0.approved && $0.certificate.scope == "collaboration" && $0.certificate.device == store.myID } }
    var body: some View {
        List {
          ForEach(current.messages.filter { $0.roomID == room.id && $0.viewOnceSeconds == nil && ($0.expiresAt ?? .distantFuture) > Date() }.sorted { $0.createdAt < $1.createdAt }) { message in
            VStack(alignment:.leading,spacing:8) {
                HStack {
                    Text(message.sender == archive.ownerCard?.id ? "Ты в архиве" : (archive.contacts.first { $0.id == message.sender }?.name ?? "Участник"))
                        .font(.caption.bold())
                    Spacer()
                    Text(message.createdAt,style:.date).font(.caption2).foregroundStyle(.secondary)
                }
                if !message.text.isEmpty { Text(message.text).textSelection(.enabled) }
                if let attachment = message.attachment { Label(attachment.name,systemImage:"paperclip").font(.caption).foregroundStyle(.secondary) }
                if let attachment = message.attachment, attachment.blobReadToken != nil {
                    Button("Сохранить выбранный файл") { download(attachment) }
                }
            }.padding(.vertical,6).contextMenu {
                if let link, message.sender == current.ownerCard?.id {
                    if !message.text.isEmpty { Button("Изменить через основное устройство") { editing = message; editedText = message.text; showEdit = true } }
                    Button("Удалить через основное устройство", role: .destructive) { command("delete", message: message, link: link) }
                }
            }
          }
          LinkedDeviceComposer(archiveID: archive.id, roomID: room.id)
          if let failure { Text(failure).font(.caption) }
        }.navigationTitle(room.title.isEmpty ? "Архив чата" : room.title)
        .alert("Изменить через основное устройство", isPresented: $showEdit) {
            TextField("Сообщение", text: $editedText)
            Button("Сохранить") { if let editing, let link { command("edit", message: editing, link: link) } }
            Button("Отмена", role: .cancel) { editing = nil; editedText = "" }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: filename) { result in
            if case .failure(let error) = result { failure = error.localizedDescription }; document = BackupDocument(data: Data())
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { document = BackupDocument(data: Data()); exporting = false; editing = nil; editedText = ""; showEdit = false } }
    }
    private func command(_ operation: String, message: ChatMessage, link: DeviceLink) {
        do { try store.queueDeviceCommand(DeviceCommand(certificateID: link.id, operation: operation, roomID: room.id, target: message.id, text: operation == "edit" ? editedText : "")); editing = nil; editedText = "" } catch { failure = error.localizedDescription }
    }
    private func download(_ attachment: Attachment) {
        let expected = store.generation
        Task {
            do { let data = try await store.downloadRemoteAttachment(attachment); guard expected == store.generation, !store.locked, scenePhase == .active else { return }; document = BackupDocument(data: data); filename = attachment.name; exporting = true }
            catch { if expected == store.generation { failure = error.localizedDescription } }
        }
    }
}
