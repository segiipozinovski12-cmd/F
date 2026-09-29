import SwiftUI

struct InboxView: View {
    @EnvironmentObject var store: ChatStore
    @State private var search = ""
    @State private var filter = "Все"
    @State private var composing = false
    var rooms: [Room] {
        store.state.rooms.filter { room in
            (filter == "Архив" ? room.archived : !room.archived) &&
            (filter != "Группы" || room.isGroup) && (filter != "Личные" || !room.isGroup) &&
            (search.isEmpty || room.title.localizedCaseInsensitiveContains(search) || store.messages(room.id).contains { $0.text.localizedCaseInsensitiveContains(search) })
        }.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return (store.messages(a.id).last?.createdAt ?? a.createdAt) > (store.messages(b.id).last?.createdAt ?? b.createdAt)
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("VO1D").font(.caption.monospaced()).tracking(4).foregroundStyle(Theme.secondary)
                            Text("Сообщения").font(.system(size: 33, weight: .semibold)).tracking(-1)
                        }
                        Spacer()
                        Button { composing = true } label: { Image(systemName: "square.and.pencil").font(.title3).frame(width: 46, height: 46).background(Theme.panel, in: Circle()) }.accessibilityLabel("Новый чат")
                    }
                    HStack(spacing: 10) {
                        Image(systemName: store.connection == "Подключён" ? "lock.shield" : "network.slash")
                        Text(store.connection).font(.caption)
                        Spacer()
                        if !store.state.outbox.isEmpty { Text("\(store.state.outbox.count) в очереди").font(.caption2) }
                    }.foregroundStyle(Theme.secondary).padding(.horizontal, 3)
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                        TextField("Найти чат или сообщение", text: $search).font(.subheadline)
                    }.voidField()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(["Все", "Личные", "Группы", "Архив"], id: \.self) { item in
                                Button { filter = item } label: {
                                    Text(item).font(.subheadline.weight(.medium)).padding(.horizontal, 17).padding(.vertical, 10)
                                        .background(filter == item ? Color.white : Theme.panel, in: Capsule()).foregroundStyle(filter == item ? Color.black : Theme.secondary)
                                }
                            }
                        }
                    }
                    if rooms.isEmpty {
                        VStack(spacing: 18) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 43, weight: .ultraLight)).foregroundStyle(Theme.accent)
                            Text(search.isEmpty ? "Здесь начинается разговор" : "Ничего не найдено").font(.headline)
                            Text("Добавь контакт по ID или QR-коду.\nТвоя адресная книга останется личной.").font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                            Button("Начать разговор") { composing = true }.buttonStyle(PrimaryButton())
                        }.padding(.vertical, 36).panel()
                    } else {
                        LazyVStack(spacing: 2) {
                            ForEach(rooms) { room in
                                NavigationLink { ChatView(roomID: room.id) } label: { roomRow(room) }.buttonStyle(.plain)
                                    .contextMenu {
                                        Button(room.pinned ? "Открепить" : "Закрепить", systemImage: "pin") { store.updateRoom(room.id) { $0.pinned.toggle() } }
                                        Button(room.archived ? "Вернуть из архива" : "В архив", systemImage: "archivebox") { store.updateRoom(room.id) { $0.archived.toggle() } }
                                    }
                            }
                        }
                    }
                    HStack { Spacer(); Label("Сообщения шифруются на устройстве", systemImage: "lock.fill").font(.caption2).foregroundStyle(Theme.secondary); Spacer() }.padding(.top, 12)
                }.padding(22)
            }.background(Theme.background).toolbar(.hidden, for: .navigationBar)
                .refreshable { await store.sync() }
                .sheet(isPresented: $composing) { ComposeView() }
        }
    }
    func roomRow(_ room: Room) -> some View {
        let last = store.messages(room.id).last
        return HStack(spacing: 14) {
            Avatar(name: room.title, group: room.isGroup, size: 54)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(room.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    if room.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.secondary) }
                    Spacer()
                    if let last { Text(last.createdAt, style: .time).font(.caption2).foregroundStyle(Theme.secondary) }
                }
                HStack {
                    Text(!room.draft.isEmpty ? "Черновик: \(room.draft)" : (last?.attachment?.name ?? last?.text ?? "Начни разговор"))
                        .font(.subheadline).foregroundStyle(Theme.secondary).lineLimit(1)
                    Spacer()
                    if room.unread > 0 { Text("\(room.unread)").font(.caption2.bold()).foregroundStyle(.black).padding(6).background(.white, in: Circle()) }
                }
            }
        }.padding(.vertical, 14)
    }
}

struct ComposeView: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) var dismiss
    @State var add = false
    @State var group = false
    @State var title = ""
    @State var selected: Set<String> = []
    @State var room: Room?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Создать группу", isOn: $group)
                    if group { TextField("Название группы", text: $title) }
                    Button("Добавить контакт", systemImage: "person.badge.plus") { add = true }
                }
                Section("Контакты") {
                    ForEach(store.state.contacts.filter { !$0.blocked }) { contact in
                        Button {
                            if group {
                                if selected.contains(contact.id) { selected.remove(contact.id) } else { selected.insert(contact.id) }
                            } else {
                                do { room = try store.direct(contact) } catch { store.error = error.localizedDescription }
                            }
                        } label: {
                            HStack { Avatar(name: contact.name, size: 38); Text(contact.name); Spacer(); if selected.contains(contact.id) { Image(systemName: "checkmark.circle.fill") } }
                        }.foregroundStyle(.white)
                    }
                }
                if group {
                    Button("Создать группу") {
                        do { room = try store.createGroup(name: title, contacts: store.state.contacts.filter { selected.contains($0.id) }) }
                        catch { store.error = error.localizedDescription }
                    }.disabled(selected.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.scrollContentBackground(.hidden).background(Theme.background)
                .navigationTitle("Новый разговор").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } } }
                .sheet(isPresented: $add) { AddContactView() }
                .navigationDestination(item: $room) { ChatView(roomID: $0.id) }
        }.presentationDragIndicator(.visible)
    }
}
