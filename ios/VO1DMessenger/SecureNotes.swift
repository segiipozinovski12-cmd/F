import SwiftUI

struct SecureNote: Codable, Identifiable {
    var id = UUID().uuidString
    var title: String
    var text: String
    var updatedAt = Date()
}

struct SecureNotesView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var selected: SecureNote?
    var body: some View {
        List {
            Section {
                Text("Заметки хранятся только в зашифрованном хранилище текущей личности. Они не отправляются в чат или модерацию. Полная резервная копия включает заметки.").font(.caption)
            }
            ForEach((store.state.secureNotes ?? []).sorted { $0.updatedAt > $1.updatedAt }) { note in
                Button { selected = note } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(note.title.isEmpty ? "Без названия" : note.title).font(.headline)
                        Text(note.text).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    }
                }
            }.onDelete { indices in
                let sorted = (store.state.secureNotes ?? []).sorted { $0.updatedAt > $1.updatedAt }
                let ids = Set(indices.map { sorted[$0].id })
                store.state.secureNotes?.removeAll { ids.contains($0.id) }; store.persist()
            }
        }
        .navigationTitle("Secure Notes")
        .toolbar { Button("Создать заметку", systemImage: "square.and.pencil") { selected = SecureNote(title: "", text: "") } }
        .sheet(item: $selected) { note in SecureNoteEditor(note: note) }
    }
}

struct SecureNoteEditor: View {
    @State var note: SecureNote
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $note.title)
                TextEditor(text: $note.text).frame(minHeight: 240)
                Text("\(note.text.count)/20000").font(.caption)
                if let failure { Text(failure).font(.caption) }
            }
            .navigationTitle("Заметка")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        do {
                            guard !store.locked, note.title.count <= 120, note.text.count <= 20000 else { throw MessengerError.invalid("Уменьши название или текст заметки") }
                            var notes = store.state.secureNotes ?? []
                            note.updatedAt = Date()
                            if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note }
                            else { guard notes.count < 1000 else { throw MessengerError.invalid("Лимит заметок достигнут") }; notes.append(note) }
                            let previous = store.state.secureNotes
                            store.state.secureNotes = notes
                            do { try store.save() } catch { store.state.secureNotes = previous; throw error }
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }
                }
            }
            .onChange(of: store.generation) { _, _ in note.text = ""; dismiss() }
            .onChange(of: store.locked) { _, value in if value { note.text = ""; dismiss() } }
        }
    }
}
