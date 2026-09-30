import SwiftUI

struct InboxView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var search = ""
    @State private var filter = "Все"
    @State private var composing = false

    private var rooms: [Room] {
        store.state.rooms.filter { room in
            (filter == "Архив" ? room.archived : !room.archived) &&
            (filter != "Группы" || room.isGroup) &&
            (filter != "Личные" || !room.isGroup) &&
            (search.isEmpty ||
             room.title.localizedCaseInsensitiveContains(search) ||
             store.messages(room.id).contains { $0.text.localizedCaseInsensitiveContains(search) })
        }
        .sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return (store.messages(a.id).last?.createdAt ?? a.createdAt) >
                   (store.messages(b.id).last?.createdAt ?? b.createdAt)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VoidBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        statusStrip
                        searchBar
                        filters

                        if rooms.isEmpty {
                            emptyState
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(rooms) { room in
                                    NavigationLink {
                                        ChatView(roomID: room.id)
                                    } label: {
                                        roomRow(room)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(room.pinned ? "Открепить" : "Закрепить", systemImage: "pin") {
                                            store.updateRoom(room.id) { $0.pinned.toggle() }
                                        }
                                        Button(room.archived ? "Вернуть из архива" : "В архив", systemImage: "archivebox") {
                                            store.updateRoom(room.id) { $0.archived.toggle() }
                                        }
                                    }
                                }
                            }
                        }

                        HStack {
                            Spacer()
                            Label("E2EE · зашифровано на устройстве", systemImage: "lock.fill")
                                .font(.caption2.monospaced())
                                .tracking(1)
                                .foregroundStyle(Theme.secondary)
                            Spacer()
                        }
                        .padding(.top, 8)
                    }
                    .padding(22)
                }
                .refreshable { await store.sync() }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $composing) { ComposeView() }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Wordmark(compact: true)
                Text("Сообщения")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .tracking(-1.4)
            }
            Spacer()
            Button { composing = true } label: {
                Image(systemName: "plus")
                    .font(.title3.bold())
                    .frame(width: 50, height: 50)
                    .background(.white, in: Circle())
                    .foregroundStyle(.black)
            }
            .accessibilityLabel("Новый разговор")
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: store.connection == "Подключён" ? "lock.shield.fill" : "circle.dashed")
            Text(store.connection.uppercased())
                .font(.caption2.monospaced())
                .tracking(1.5)
            Spacer()
            if !store.state.outbox.isEmpty {
                Text("QUEUE \(store.state.outbox.count)")
                    .font(.caption2.monospaced())
                    .tracking(1)
            }
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 2)
    }

    private var searchBar: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
            TextField("Найти чат или сообщение", text: $search)
        }
        .voidField()
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["Все", "Личные", "Группы", "Архив"], id: \.self) { item in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { filter = item }
                    } label: {
                        Text(item.uppercased())
                            .font(.caption2.monospaced())
                            .tracking(1.5)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(filter == item ? Color.white : Color.white.opacity(0.055), in: Capsule())
                            .foregroundStyle(filter == item ? .black : Theme.secondary)
                            .overlay(Capsule().stroke(.white.opacity(filter == item ? 0 : 0.08)))
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            BrandMark(size: 88)
            Text(search.isEmpty ? "Здесь пока тихо." : "Ничего не найдено.")
                .font(.title3.bold())
            Text(search.isEmpty
                 ? "Добавь человека по 4-символьному VO1D ID и начни разговор."
                 : "Измени запрос или верни фильтр «Все».")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            if search.isEmpty {
                Button("НОВЫЙ РАЗГОВОР") { composing = true }
                    .buttonStyle(PrimaryButton())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .panel()
    }

    private func roomRow(_ room: Room) -> some View {
        let last = store.messages(room.id).last
        return HStack(spacing: 14) {
            Avatar(name: room.title, group: room.isGroup, size: 56)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text(room.title)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)

                    if room.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                    }

                    Spacer()

                    if let last {
                        Text(last.createdAt, style: .time)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Text(!room.draft.isEmpty
                         ? "Черновик: \(room.draft)"
                         : (last?.attachment?.name ?? last?.text ?? "Начни разговор"))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)

                    Spacer()

                    if room.unread > 0 {
                        Text("\(room.unread)")
                            .font(.caption2.bold())
                            .foregroundStyle(.black)
                            .frame(minWidth: 24, minHeight: 24)
                            .background(.white, in: Circle())
                    }
                }
            }
        }
        .panel()
    }
}

struct ComposeView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var add = false
    @State private var group = false
    @State private var title = ""
    @State private var selected: Set<String> = []
    @State private var room: Room?

    var body: some View {
        NavigationStack {
            ZStack {
                VoidBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Wordmark(compact: true)
                            Spacer()
                            Button("Готово") { dismiss() }.foregroundStyle(Theme.secondary)
                        }

                        Text("Новый разговор")
                            .font(.system(size: 32, weight: .black, design: .rounded))

                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Создать группу", isOn: $group)
                                .tint(.white)

                            if group {
                                TextField("Название группы", text: $title)
                                    .voidField()
                            }

                            Button("ДОБАВИТЬ ЧЕЛОВЕКА", systemImage: "person.badge.plus") { add = true }
                                .buttonStyle(GhostButton())
                        }
                        .panel()

                        if store.state.contacts.filter({ !$0.blocked }).isEmpty {
                            VStack(spacing: 14) {
                                Text("Нет доступных контактов").font(.headline)
                                Text("Сначала добавь человека по VO1D ID.")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.secondary)
                                Button("ДОБАВИТЬ") { add = true }.buttonStyle(PrimaryButton())
                            }
                            .frame(maxWidth: .infinity)
                            .panel()
                        } else {
                            VStack(spacing: 10) {
                                ForEach(store.state.contacts.filter { !$0.blocked }) { contact in
                                    Button {
                                        if group {
                                            if selected.contains(contact.id) { selected.remove(contact.id) }
                                            else { selected.insert(contact.id) }
                                        } else {
                                            do { room = try store.direct(contact) }
                                            catch { store.error = error.localizedDescription }
                                        }
                                    } label: {
                                        HStack(spacing: 13) {
                                            Avatar(name: contact.name, size: 42)
                                            Text(contact.name).font(.headline)
                                            Spacer()
                                            if group {
                                                Image(systemName: selected.contains(contact.id) ? "checkmark.circle.fill" : "circle")
                                            } else {
                                                Image(systemName: "arrow.up.right")
                                            }
                                        }
                                        .panel()
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if group {
                            Button("СОЗДАТЬ ГРУППУ") {
                                do {
                                    room = try store.createGroup(
                                        name: title,
                                        contacts: store.state.contacts.filter { selected.contains($0.id) }
                                    )
                                } catch {
                                    store.error = error.localizedDescription
                                }
                            }
                            .buttonStyle(PrimaryButton())
                            .disabled(selected.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(24)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $add) { AddContactView() }
            .navigationDestination(item: $room) { ChatView(roomID: $0.id) }
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }
}
