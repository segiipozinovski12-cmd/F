import SwiftUI

struct ContactsView: View {
    @EnvironmentObject var store: ChatStore
    @State var adding = false
    @State var search = ""
    @State var room: Room?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { MyIdentityView() } label: { Label("Мой QR-код и ID", systemImage: "qrcode") }
                    Button("Добавить контакт", systemImage: "person.badge.plus") { adding = true }
                }
                Section("Люди · \(store.state.contacts.count)") {
                    ForEach(store.state.contacts.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { contact in
                        NavigationLink { ContactDetailView(contactID: contact.id) } label: {
                            HStack(spacing: 13) {
                                Avatar(name: contact.name)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack { Text(contact.name); if contact.verified { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(Theme.accent) } }
                                    Text(contact.blocked ? "Заблокирован" : contact.card.shortID).font(.caption.monospaced()).foregroundStyle(Theme.secondary)
                                }
                            }.padding(.vertical, 5)
                        }
                    }
                }
                if store.state.contacts.isEmpty { Text("Контакты добавляются только по приглашению или ID. Доступ к телефонной книге не нужен.").font(.subheadline).foregroundStyle(Theme.secondary).listRowBackground(Color.clear) }
            }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Контакты")
                .searchable(text: $search, prompt: "Имя контакта").sheet(isPresented: $adding) { AddContactView() }
        }
    }
}

struct AddContactView: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) var dismiss
    @State var value = ""
    @State var scanning = false
    @State var busy = false
    @State var failure: String?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("Без номеров.\nПросто приглашение.").font(.system(size: 30, weight: .semibold)).padding(.top, 14)
                Text("Вставь ссылку vo1d:// или полный ID собеседника. Сверь отпечаток по другому каналу, прежде чем доверять контакту.").font(.subheadline).foregroundStyle(Theme.secondary)
                TextField("Приглашение или ID", text: $value, axis: .vertical).lineLimit(3...6).textInputAutocapitalization(.never).voidField()
                Button("Сканировать QR", systemImage: "qrcode.viewfinder") { scanning = true }.frame(maxWidth: .infinity).padding().background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
                Button(busy ? "Добавляем…" : "Добавить контакт") {
                    busy = true
                    Task {
                        do { _ = try await store.addContact(value); dismiss() }
                        catch { failure = error.localizedDescription }
                        busy = false
                    }
                }.buttonStyle(PrimaryButton()).disabled(value.isEmpty || busy)
                Spacer()
            }.padding(24).background(Theme.background).navigationTitle("Новый контакт").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Закрыть") { dismiss() } }
                .sheet(isPresented: $scanning) { QRScanner { value = $0; scanning = false }.ignoresSafeArea().overlay(alignment: .topTrailing) { Button("Закрыть") { scanning = false }.padding().background(.black.opacity(0.5), in: Capsule()).padding() } }
        }
    }
}

struct MyIdentityView: View {
    @EnvironmentObject var store: ChatStore
    var body: some View {
        ScrollView {
            VStack(spacing: 25) {
                Avatar(name: store.state.nickname, size: 78)
                Text(store.state.nickname).font(.title.bold())
                if let invite = try? store.invite() {
                    QRCodeView(text: invite).frame(maxWidth: 290)
                    ShareLink(item: invite) { Label("Поделиться приглашением", systemImage: "square.and.arrow.up") }.buttonStyle(PrimaryButton())
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("ТВОЙ ID").font(.caption2.monospaced()).tracking(3).foregroundStyle(Theme.secondary)
                    Text(store.myID).font(.caption.monospaced()).textSelection(.enabled)
                    Text("Приглашение содержит публичные ключи и адрес сервера. Приватные ключи никогда не включаются.").font(.caption).foregroundStyle(Theme.secondary)
                }.panel()
            }.padding(26)
        }.background(Theme.background).navigationTitle("Моя личность").navigationBarTitleDisplayMode(.inline)
    }
}

struct ContactDetailView: View {
    var contactID: String
    @EnvironmentObject var store: ChatStore
    @State var room: Room?
    @State var alias = ""
    var contact: Contact? { store.state.contacts.first { $0.id == contactID } }
    var body: some View {
        Form {
            if let contact {
                Section {
                    HStack { Spacer(); VStack(spacing: 12) { Avatar(name: contact.name, size: 80); Text(contact.name).font(.title2.bold()) }; Spacer() }.padding(.vertical, 20)
                    Button("Написать сообщение", systemImage: "bubble.left") {
                        do { room = try store.direct(contact) } catch { store.error = error.localizedDescription }
                    }.disabled(contact.blocked)
                }
                Section("Локальное имя") {
                    TextField("Имя", text: $alias)
                    Button("Сохранить имя") {
                        if let index = store.state.contacts.firstIndex(where: { $0.id == contactID }), !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            store.state.contacts[index].name = String(alias.prefix(40))
                            for index in store.state.rooms.indices where !store.state.rooms[index].isGroup && store.state.rooms[index].members.contains(where: { $0.id == contactID }) { store.state.rooms[index].title = String(alias.prefix(40)) }
                            store.persist()
                        }
                    }
                }
                Section("Проверка контакта") {
                    Text(contact.id).font(.caption.monospaced()).textSelection(.enabled)
                    Toggle("Отпечаток сверен лично", isOn: Binding(get: { contact.verified }, set: { value in
                        if let index = store.state.contacts.firstIndex(where: { $0.id == contactID }) { store.state.contacts[index].verified = value; store.persist() }
                    }))
                    Text("Сравните полный ID при встрече или через уже доверенный канал. Имя само по себе не подтверждает личность.").font(.caption).foregroundStyle(Theme.secondary)
                }
                Section {
                    Button(contact.blocked ? "Разблокировать" : "Заблокировать", role: .destructive) { Task { await store.toggleBlock(contact) } }
                }
            }
        }.navigationTitle("Контакт").navigationBarTitleDisplayMode(.inline)
            .onAppear { alias = contact?.name ?? "" }.navigationDestination(item: $room) { ChatView(roomID: $0.id) }
    }
}
