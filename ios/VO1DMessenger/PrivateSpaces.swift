import SwiftUI

struct PrivateSpacesView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var name = ""
    @State private var failure: String?
    @State private var working = false
    var body: some View {
        List {
            Section("Раздельные пространства") {
                Text("У каждого пространства свои ключи, переписка, очередь, заметки и настройки. Переход защищён Face ID или кодом устройства.")
                Text("Новые пространства отключают публичный поиск, previews, receipts и фоновые звонки; требуют private invitation. Они не скрывают корреляцию сети или действия оператора. Одновременно активно одно пространство.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Создать Private Space") {
                TextField("Локальное название", text: $name)
                Button("Создать и открыть", systemImage: "lock.rectangle.stack") {
                    working = true
                    Task {
                        do { try await store.createProfile(label: name, privateSpace: true); name = ""; failure = nil }
                        catch { failure = error.localizedDescription }
                        working = false
                    }
                }.disabled(name.isEmpty || store.profileRegistry.profiles.count >= 12)
            }
            Section("Пространства на устройстве") {
                ForEach(store.profileRegistry.profiles.filter { $0.isPrivateSpace == true }) { profile in
                    Button {
                        working = true
                        Task {
                            do { try await store.switchProfile(profile.id); failure = nil } catch { failure = error.localizedDescription }
                            working = false
                        }
                    } label: {
                        Label(profile.label + (profile.id == store.profileID ? " · активно" : ""), systemImage: profile.id == store.profileID ? "checkmark.circle" : "lock")
                    }
                }
                NavigationLink("Все личности и отдельные роли") { ProfilesView() }
            }
            if let failure { Text(failure).font(.caption) }
        }.disabled(working).navigationTitle("Private Spaces")
    }
}
