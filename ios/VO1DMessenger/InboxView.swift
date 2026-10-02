import SwiftUI

struct InboxView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = ""
    @State private var filter = "Все"
    @State private var composing = false

    private var rooms: [Room] {
        store.state.rooms.filter { room in
            guard !store.extended.hiddenRooms.contains(room.id) else { return false }
            if let folder=store.extended.folders.first(where: { $0.id==filter }), !folder.roomIDs.contains(room.id) { return false }
            let archiveMatch = filter == "Архив" ? room.archived : !room.archived
            let typeMatch: Bool

            switch filter {
            case "Непрочитанные":
                typeMatch = room.unread > 0
            case "Личные":
                typeMatch = !room.isGroup && !store.isLocalUtilityRoom(room.id)
            case "Группы":
                typeMatch = room.isGroup && room.isChannel != true
            case "Каналы":
                typeMatch = room.isChannel == true
            case "Сохранённые":
                typeMatch = store.isSavedRoom(room.id)
            default:
                typeMatch = true
            }

            return archiveMatch &&
                typeMatch &&
                (search.isEmpty ||
                 room.title.localizedCaseInsensitiveContains(search) ||
                 store.messages(room.id).contains { $0.text.localizedCaseInsensitiveContains(search) })
        }
        .sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if store.preferences.sortOrder=="name" { return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending }
            if store.preferences.sortOrder=="unread", a.unread != b.unread { return a.unread>b.unread }
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
                        if !store.requestRooms.isEmpty {
                            NavigationLink { MessageRequestsView() } label: {
                                Label("Запросы на переписку · \(store.requestRooms.count)",systemImage:"person.badge.clock").panel()
                            }.buttonStyle(.plain)
                        }

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
                                    .transition(reduceMotion ? .opacity : .asymmetric(
                                        insertion: .opacity.combined(with: .scale(scale: 0.96)).combined(with: .move(edge: .top)),
                                        removal: .opacity.combined(with: .scale(scale: 0.96))
                                    ))
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button {
                                            store.updateRoom(room.id) { $0.archived.toggle() }
                                        } label: {
                                            Label(room.archived ? "Вернуть" : "Архив", systemImage: "archivebox")
                                        }
                                        .tint(.gray)

                                        Button {
                                            if store.isRoomMuted(room) {
                                                store.muteRoom(room.id, for: 0)
                                            } else {
                                                store.muteRoom(room.id, for: nil)
                                            }
                                        } label: {
                                            Label(store.isRoomMuted(room) ? "Со звуком" : "Без звука", systemImage: store.isRoomMuted(room) ? "speaker.wave.2" : "speaker.slash")
                                        }
                                        .tint(.black)
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                        Button {
                                            store.updateRoom(room.id) { $0.pinned.toggle() }
                                        } label: {
                                            Label(room.pinned ? "Открепить" : "Закрепить", systemImage: "pin")
                                        }
                                        .tint(.white)
                                    }
                                    .contextMenu {
                                        Button("Скрыть с Face ID",systemImage:"eye.slash") { Task { await store.toggleHidden(room.id) } }
                                        Menu("В папку") {
                                            ForEach(store.extended.folders) { folder in
                                                Button(folder.name) { store.folderToggle(folder.id,roomID:room.id) }
                                            }
                                        }

                                        Button(room.pinned ? "Открепить" : "Закрепить", systemImage: "pin") {
                                            store.updateRoom(room.id) { $0.pinned.toggle() }
                                        }
                                        Button(room.archived ? "Вернуть из архива" : "В архив", systemImage: "archivebox") {
                                            store.updateRoom(room.id) { $0.archived.toggle() }
                                        }
                                        Menu("Уведомления") {
                                            if store.isRoomMuted(room) {
                                                Button("Включить звук", systemImage: "speaker.wave.2") {
                                                    store.muteRoom(room.id, for: 0)
                                                }
                                            }
                                            Button("Без звука на 1 час", systemImage: "clock") {
                                                store.muteRoom(room.id, for: 3600)
                                            }
                                            Button("Без звука на 8 часов", systemImage: "clock") {
                                                store.muteRoom(room.id, for: 8 * 3600)
                                            }
                                            Button("Без звука навсегда", systemImage: "speaker.slash") {
                                                store.muteRoom(room.id, for: nil)
                                            }
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
            .onChange(of: store.extended.folders.map(\.id)) { _, folderIDs in
                let builtIn = ["Все", "Непрочитанные", "Личные", "Группы", "Каналы", "Архив"]
                guard !builtIn.contains(filter), !folderIDs.contains(filter) else { return }
                filter = "Все"
            }
            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88), value: rooms.map(\.id))
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
            if store.state.rooms.contains(where: { store.isSavedRoom($0.id) }) {
                NavigationLink {
                    ChatView(roomID: ChatStore.savedRoomID)
                } label: {
                    Image(systemName: "bookmark.fill")
                        .font(.subheadline.bold())
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.075), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Сохранённые сообщения")
            }

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
            ConnectionGlyph(connected: store.connection == "Подключён")
            Text(store.connection.uppercased())
                .font(.caption2.monospaced())
                .tracking(1.5)
                .contentTransition(.opacity)
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
                .submitLabel(.search)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Очистить поиск")
            }
        }
        .voidField()
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["Все", "Непрочитанные", "Личные", "Группы", "Каналы", "Архив"] + store.extended.folders.map(\.id), id: \.self) { item in
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) { filter = item }
                    } label: {
                        Text((store.extended.folders.first { $0.id==item }?.name ?? item).uppercased())
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
            Text(search.isEmpty && filter == "Все" ? "Здесь пока тихо." : "Ничего не найдено.")
                .font(.title3.bold())
            Text(search.isEmpty && filter == "Все"
                 ? "Добавь человека по 4-символьному VO1D ID или приватному QR и начни разговор."
                 : "Очисти поиск или верни фильтр «Все».")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            if search.isEmpty && filter == "Все" {
                Button("НОВЫЙ РАЗГОВОР") { composing = true }
                    .buttonStyle(PrimaryButton())
            } else {
                Button("СБРОСИТЬ ФИЛЬТРЫ") {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                        search = ""
                        filter = "Все"
                    }
                }
                .buttonStyle(GhostButton())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .panel()
    }

    private func roomRow(_ room: Room) -> some View {
        let last = store.messages(room.id).last
        return HStack(spacing: 14) {
            Avatar(name: room.title, group: room.isGroup, size: store.preferences.compactRows ? 42 : 56)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text(room.title)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)

                    if store.isBuiltinBotRoom(room.id) {
                        Text("BOT")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .tracking(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    if room.isChannel == true {
                        Text("CHANNEL")
                            .font(.system(size: 7, weight: .black, design: .monospaced))
                            .tracking(0.8)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.10), in: Capsule())
                            .foregroundStyle(.white.opacity(0.82))
                    }

                    if room.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                    }

                    if store.isRoomMuted(room) {
                        Image(systemName: "speaker.slash.fill")
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
                         : (last?.state == "scheduled"
                            ? "Запланировано: \(last?.text ?? "")"
                            : (last?.attachment?.name ?? last?.text ?? "Начни разговор")))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var add = false
    @State private var mode = 0
    @State private var title = ""
    @State private var selected: Set<String> = []
    @State private var room: Room?
    @State private var creating = false

    private var isMulti: Bool { mode != 0 }
    private var isChannel: Bool { mode == 2 }

    private var visibleContacts: [Contact] {
        store.state.contacts.filter {
            !$0.blocked && (!isMulti || !store.isBuiltinBot($0.id))
        }
    }

    private func hasDeliveryRoute(_ contact: Contact) -> Bool {
        !store.preferences.requirePrivateDelivery || store.privateRoute(peerID: contact.id, roomID: "") != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VoidBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Wordmark(compact: true)
                            Spacer()
                            Button("Готово") { dismiss() }
                                .foregroundStyle(Theme.secondary)
                        }

                        Text(mode == 2 ? "Новый канал" : (mode == 1 ? "Новая группа" : "Новый разговор"))
                            .font(.system(size: 32, weight: .black, design: .rounded))

                        VStack(alignment: .leading, spacing: 14) {
                            Picker("Тип", selection: $mode) {
                                Text("Личный").tag(0)
                                Text("Группа").tag(1)
                                Text("Канал").tag(2)
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: mode) { _, _ in
                                selected.removeAll()
                                title = ""
                            }

                            if isMulti {
                                TextField(isChannel ? "Название канала" : "Название группы", text: $title)
                                    .textInputAutocapitalization(.sentences)
                                    .submitLabel(.done)
                                    .voidField()

                                HStack {
                                    Label("\(selected.count) выбрано", systemImage: isChannel ? "megaphone.fill" : "person.2.fill")
                                        .contentTransition(.numericText(value: Double(selected.count)))
                                    Spacer()
                                    Text("до 15")
                                }
                                .font(.caption)
                                .foregroundStyle(Theme.secondary)
                            }

                            Button("ДОБАВИТЬ ЧЕЛОВЕКА", systemImage: "person.badge.plus") {
                                add = true
                            }
                            .buttonStyle(GhostButton())
                        }
                        .panel()

                        if visibleContacts.isEmpty {
                            VStack(spacing: 14) {
                                Text(isMulti ? "Нет доступных контактов" : "Нет контактов")
                                    .font(.headline)
                                Text(
                                    isChannel
                                        ? "Канал можно создать пустым и добавить участников позже."
                                        : (isMulti ? "Для группы добавь хотя бы один обычный контакт." : "Сначала добавь человека по VO1D ID или @username.")
                                )
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                                .multilineTextAlignment(.center)

                                Button("ДОБАВИТЬ") { add = true }
                                    .buttonStyle(PrimaryButton())
                            }
                            .frame(maxWidth: .infinity)
                            .panel()
                        } else {
                            VStack(spacing: 10) {
                                ForEach(visibleContacts) { contact in
                                    Button {
                                        if isMulti {
                                            guard hasDeliveryRoute(contact) else {
                                                store.error = "Строгая приватная доставка требует QR-маршрут этого контакта"
                                                return
                                            }
                                            if selected.contains(contact.id) {
                                                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) {
                                                    selected.remove(contact.id)
                                                }
                                            } else {
                                                guard selected.count < 15 else {
                                                    store.error = "В группе или канале может быть до 15 приглашённых участников"
                                                    return
                                                }
                                                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) {
                                                    selected.insert(contact.id)
                                                }
                                            }
                                        } else {
                                            do {
                                                room = try store.direct(contact)
                                            } catch {
                                                store.error = error.localizedDescription
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 13) {
                                            Avatar(name: contact.name, size: 42)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(contact.name)
                                                    .font(.headline)
                                                if store.isBuiltinBot(contact.id) {
                                                    Text("XROSB")
                                                        .font(.caption2.monospaced())
                                                        .foregroundStyle(Theme.secondary)
                                                }
                                            }
                                            Spacer()

                                            if isMulti {
                                                if !hasDeliveryRoute(contact) {
                                                    Label("Нужен QR", systemImage: "lock.trianglebadge.exclamationmark")
                                                        .font(.caption2)
                                                        .foregroundStyle(Theme.secondary)
                                                } else {
                                                    SelectionMark(selected: selected.contains(contact.id))
                                                }
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

                        if isMulti {
                            Button {
                                guard !creating else { return }
                                creating = true

                                do {
                                    let members = visibleContacts.filter { selected.contains($0.id) }
                                    let created: Room
                                    if isChannel {
                                        created = try store.createChannel(name: title, contacts: members)
                                    } else {
                                        created = try store.createGroup(name: title, contacts: members)
                                    }
                                    selected.removeAll()
                                    title = ""
                                    Haptics.success()
                                    room = created
                                } catch {
                                    Haptics.warning()
                                    store.error = error.localizedDescription
                                }

                                creating = false
                            } label: {
                                HStack {
                                    Text(creating ? "СОЗДАЁМ…" : (isChannel ? "СОЗДАТЬ КАНАЛ" : "СОЗДАТЬ ГРУППУ"))
                                    Spacer()
                                    if creating {
                                        ProgressView()
                                            .tint(.black)
                                            .scaleEffect(0.82)
                                    } else {
                                        Image(systemName: isChannel ? "megaphone.fill" : "arrow.up.right")
                                    }
                                }
                            }
                            .buttonStyle(PrimaryButton())
                            .disabled(
                                creating ||
                                title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                (!isChannel && selected.isEmpty)
                            )

                            Text(
                                isChannel
                                    ? "В канале писать могут только админы. Участников можно добавить позже."
                                    : "VO1D Bot · XROSB не добавляется в группы."
                            )
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                            .lineSpacing(3)
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
