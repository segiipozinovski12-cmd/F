import Foundation
import SwiftUI

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
    var body: some View {
        List(archive.rooms) { room in NavigationLink(room.title.isEmpty ? "Личный чат" : room.title) { ArchiveMessagesView(archive:archive,room:room) } }
            .navigationTitle(archive.title)
    }
}
private struct ArchiveMessagesView: View {
    var archive: HistoryArchive
    var room: Room
    var body: some View {
        List(archive.messages.filter { $0.roomID == room.id }.sorted { $0.createdAt < $1.createdAt }) { message in
            VStack(alignment:.leading,spacing:8) {
                HStack {
                    Text(message.sender == archive.ownerCard?.id ? "Ты в архиве" : (archive.contacts.first { $0.id == message.sender }?.name ?? "Участник"))
                        .font(.caption.bold())
                    Spacer()
                    Text(message.createdAt,style:.date).font(.caption2).foregroundStyle(.secondary)
                }
                if !message.text.isEmpty { Text(message.text).textSelection(.enabled) }
                if let attachment = message.attachment { Label(attachment.name,systemImage:"paperclip").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical,6)
        }.navigationTitle(room.title.isEmpty ? "Архив чата" : room.title)
    }
}
