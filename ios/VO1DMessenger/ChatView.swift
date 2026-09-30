import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import QuickLook

struct ChatView: View {
    let roomID: String
    @EnvironmentObject var store: ChatStore
    @State private var text = ""
    @State private var search = ""
    @State private var reply: ChatMessage?
    @State private var editing: ChatMessage?
    @State private var photo: PhotosPickerItem?
    @State private var ephemeralPhoto: PhotosPickerItem?
    @State private var photoOptions = false
    @State private var photoSeconds = 10
    @State private var importing = false
    @State private var info = false
    @State private var preview: URL?
    @State private var selectionMode = false
    @State private var selectedIDs: Set<String> = []
    @State private var showDeleteSelection = false
    @State private var forwarding: ChatMessage?
    @StateObject private var audio = VoiceRecorder()
    var room: Room? { store.state.rooms.first { $0.id == roomID } }
    var messages: [ChatMessage] { store.messages(roomID, search: search) }
    var body: some View {
        VStack(spacing: 0) {
            if let room {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        if let pinned = store.pinnedMessages(roomID).last {
                            Button {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                    proxy.scrollTo(pinned.id, anchor: .center)
                                }
                            } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: "pin.fill")
                                        .font(.caption.bold())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("ЗАКРЕПЛЕНО")
                                            .font(.system(size: 8, weight: .black, design: .monospaced))
                                            .tracking(1.4)
                                        Text(pinned.text.isEmpty ? (pinned.attachment?.name ?? "Вложение") : pinned.text)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .foregroundStyle(Theme.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5)
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        ScrollView {
                            LazyVStack(spacing: 14) {
                                Label(
                                    store.isSavedRoom(roomID) ? "Личный архив" : (store.isBuiltinBotRoom(roomID) ? "Системный помощник" : "Приватная переписка"),
                                    systemImage: store.isSavedRoom(roomID) ? "bookmark.fill" : (store.isBuiltinBotRoom(roomID) ? "sparkles" : "lock")
                                )
                                .font(.caption2)
                                .foregroundStyle(Theme.secondary)
                                .padding(.vertical, 18)

                                ForEach(messages) { message in
                                    bubble(message, group: room.isGroup).id(message.id)
                                }
                                Color.clear.frame(height: 1).id("bottom")
                            }
                            .padding(.horizontal, 18)
                            .padding(.bottom, 10)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: messages.count) { _, _ in
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                            store.markRead(roomID)
                        }
                        .onAppear {
                            proxy.scrollTo("bottom", anchor: .bottom)
                            store.markRead(roomID)
                        }
                    }
                }
                if let until = store.typing[roomID], until > Date() {
                    Text("Собеседник печатает…")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if selectionMode {
                    selectionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if room.isGroup && room.onlyAdminsCanPost == true && !store.isGroupAdmin(room) {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Только админы могут писать")
                                .font(.subheadline.bold())
                            Text("Ты можешь читать сообщения и реакции.")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial)
                    .overlay(alignment: .top) {
                        Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5)
                    }
                } else {
                    composer
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else { ContentUnavailableView("Чат недоступен", systemImage: "bubble.left") }
        }.background(Theme.background)
            .navigationTitle(room?.title ?? "Чат").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selectionMode {
                        Button("Готово") {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                selectionMode = false
                                selectedIDs.removeAll()
                            }
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if room?.isGroup == false && !selectionMode && !store.isLocalUtilityRoom(roomID) {
                        Button {
                            store.startCall(roomID)
                        } label: {
                            Image(systemName: "phone.fill")
                        }
                        .disabled(store.connection != "Подключён")
                        .accessibilityLabel("Позвонить")
                    }

                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                            selectionMode.toggle()
                            if !selectionMode { selectedIDs.removeAll() }
                        }
                    } label: {
                        Image(systemName: selectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .accessibilityLabel(selectionMode ? "Закончить выбор" : "Выбрать сообщения")

                    Button { info = true } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Настройки чата")
                }
            }
            .searchable(text: $search, prompt: "Поиск в переписке")
            .sheet(isPresented: $info) { RoomInfoView(roomID: roomID) }
            .sheet(item: $forwarding) { message in
                ForwardPickerView(message: message, sourceRoomID: roomID)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                do {
                    let url = try result.get(); let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                    guard (values.fileSize ?? 0) <= 3 * 1024 * 1024 else { throw MessengerError.invalid("Файл должен быть не больше 3 МБ") }
                    let attachment = Attachment(name: url.lastPathComponent, mime: values.contentType?.preferredMIMEType ?? "application/octet-stream", data: try Data(contentsOf: url))
                    send(attachment)
                } catch { store.error = error.localizedDescription }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task { await processPhoto(item, viewSeconds: nil); photo = nil }
            }
            .onChange(of: ephemeralPhoto) { _, item in
                guard let item else { return }
                Task {
                    await processPhoto(item, viewSeconds: photoSeconds)
                    ephemeralPhoto = nil
                    photoOptions = false
                }
            }
            .sheet(isPresented: $photoOptions) {
                EphemeralPhotoPickerSheet(
                    selection: $ephemeralPhoto,
                    seconds: $photoSeconds
                )
            }
            .quickLookPreview($preview)
            .onChange(of: preview) { _, value in if value == nil { MediaFiles.clear() } }
            .onAppear {
                text = room?.draft ?? ""
                store.activeRoomID = roomID
            }
            .onDisappear {
                audio.cancel()
                store.activeRoomID = nil
                store.updateRoom(roomID) { $0.draft = text }
                MediaFiles.clear()
            }
            .onChange(of: text) { _, _ in Task { await store.sendTyping(roomID) } }
            .confirmationDialog("Удалить выбранные сообщения?", isPresented: $showDeleteSelection, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    perform {
                        try store.deleteMessages(selectedIDs, roomID: roomID)
                        selectedIDs.removeAll()
                        selectionMode = false
                    }
                }
            } message: {
                Text("Твои сообщения будут удалены у участников при следующей доставке события удаления. Чужие выбранные сообщения удаляются только локально.")
            }
    }

    var selectionBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ВЫБРАНО")
                    .font(.caption2.monospaced())
                    .tracking(1.6)
                    .foregroundStyle(Theme.secondary)
                Text("\(selectedIDs.count)")
                    .font(.title3.bold().monospacedDigit())
            }

            Spacer()

            Button {
                guard !selectedIDs.isEmpty else { return }
                showDeleteSelection = true
            } label: {
                Label("Удалить", systemImage: "trash")
                    .lineLimit(1)
            }
            .buttonStyle(GhostButton())
            .frame(maxWidth: 160)
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)
        }
    }

    var composer: some View {
        VStack(spacing: 8) {
            if reply != nil || editing != nil {
                HStack {
                    Rectangle().fill(Theme.accent).frame(width: 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(editing != nil ? "Редактирование" : "Ответ · \(store.name(reply?.sender ?? ""))").font(.caption.bold())
                        Text(editing?.text ?? reply?.text ?? "Вложение").font(.caption).lineLimit(1).foregroundStyle(Theme.secondary)
                    }
                    Spacer(); Button { reply = nil; editing = nil; text = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Отменить ответ")
                }.frame(height: 36).padding(.horizontal, 18)
            }
            if audio.recording {
                HStack {
                    Image(systemName: "waveform").symbolEffect(.variableColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(audio.paused ? "Пауза · \(audio.seconds) с" : "Запись · \(audio.seconds) с")
                            .font(.subheadline.monospacedDigit())
                        Text(store.selectedVoiceEffect().title)
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Button {
                        audio.togglePause()
                    } label: {
                        Image(systemName: audio.paused ? "mic.fill" : "pause.fill")
                            .font(.headline)
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .accessibilityLabel(audio.paused ? "Продолжить запись" : "Поставить запись на паузу")

                    Button("Отмена") { audio.cancel() }
                    Button {
                        do {
                            if let attachment = try audio.finish(effect: store.selectedVoiceEffect()) { send(attachment) }
                        } catch { store.error = error.localizedDescription }
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                }.padding(18)
            } else {
                HStack(alignment: .bottom, spacing: 12) {
                    Menu {
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label("Фото", systemImage: "photo")
                        }
                        Button("Фото с таймером", systemImage: "timer") { photoOptions = true }
                        Button("Файл", systemImage: "doc") { importing = true }
                        Menu("Голос: \(store.selectedVoiceEffect().title)") {
                            ForEach(VoiceEffect.allCases) { effect in
                                Button {
                                    store.setVoiceEffect(effect)
                                } label: {
                                    Label(effect.title, systemImage: store.selectedVoiceEffect() == effect ? "checkmark" : "waveform")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3)
                            .frame(width: 30, height: 42)
                    }
                    .accessibilityLabel("Добавить вложение")
                    TextField("Сообщение", text: $text, axis: .vertical).lineLimit(1...5).padding(.vertical, 12).padding(.horizontal, 14)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 21))
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button { Task { do { try await audio.start() } catch { store.error = error.localizedDescription } } } label: {
                            Image(systemName: "mic").font(.title3).frame(width: 42, height: 42).background(Theme.panel, in: Circle())
                        }.accessibilityLabel("Записать голосовое сообщение")
                    } else {
                        Button { send() } label: { Image(systemName: "arrow.up").font(.headline).foregroundStyle(.black).frame(width: 42, height: 42).background(.white, in: Circle()) }.accessibilityLabel("Отправить")
                    }
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }
        }.background(Theme.background).overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5) }
    }
    func bubble(_ message: ChatMessage, group: Bool) -> some View {
        let mine = message.sender == store.myID
        return HStack(alignment: .bottom) {
            if mine { Spacer(minLength: 42) }
            VStack(alignment: .leading, spacing: 8) {
                if group && !mine {
                    Text(store.name(message.sender))
                        .font(.caption.bold())
                        .foregroundStyle(Theme.accent)
                }

                if let forwardedFrom = message.forwardedFrom {
                    HStack(spacing: 6) {
                        Image(systemName: "arrowshape.turn.up.right.fill")
                        Text("Переслано · \(forwardedFrom)")
                    }
                    .font(.caption2.bold())
                    .opacity(0.58)
                }

                if let replyID = message.replyTo,
                   let source = store.state.messages.first(where: { $0.id == replyID }) {
                    HStack(alignment: .top, spacing: 8) {
                        Capsule()
                            .fill(mine ? .black.opacity(0.45) : .white.opacity(0.55))
                            .frame(width: 2.5)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.name(source.sender))
                                .font(.caption2.bold())
                            HStack(spacing: 5) {
                                if source.attachment != nil {
                                    Image(systemName: source.attachment?.mime.hasPrefix("image/") == true ? "photo" : source.attachment?.mime.hasPrefix("audio/") == true ? "waveform" : "doc")
                                }
                                Text(source.text.isEmpty ? "Вложение" : source.text)
                                    .lineLimit(2)
                            }
                            .font(.caption)
                            .opacity(0.66)
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        (mine ? Color.black.opacity(0.065) : Color.white.opacity(0.055)),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                if let attachment = message.attachment {
                    if attachment.mime.hasPrefix("image/"), let image = UIImage(data: attachment.data) {
                        if let seconds = attachment.viewSeconds, seconds > 0 {
                            EphemeralPhotoView(
                                messageID: message.id,
                                mine: mine,
                                image: image,
                                seconds: seconds
                            )
                        } else {
                            Button {
                                do { preview = try MediaFiles.export(attachment) }
                                catch { store.error = error.localizedDescription }
                            } label: {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 260)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    } else if attachment.mime.hasPrefix("audio/") {
                        VoiceMessagePlayer(
                            attachment: attachment,
                            tint: mine ? .black : .white
                        )
                    } else {
                        Button {
                            do { preview = try MediaFiles.export(attachment) }
                            catch { store.error = error.localizedDescription }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.fill")
                                    .font(.title)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(attachment.name)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(2)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                        .font(.caption2)
                                }
                            }
                            .padding(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !message.text.isEmpty { Text(message.text).font(.system(size: 16)).textSelection(.enabled) }
                HStack(spacing: 5) {
                    if message.edited { Text("изменено") }
                    if message.expiresAt != nil { Image(systemName: "timer") }
                    Text(message.createdAt, style: .time)
                    if mine {
                        Image(systemName: message.state == "queued" ? "clock" : (message.state == "read" ? "checkmark.circle.fill" : message.state == "delivered" ? "checkmark.circle" : "checkmark"))
                            .accessibilityLabel(message.state)
                    }
                }.font(.system(size: 10)).opacity(0.55).frame(maxWidth: .infinity, alignment: .trailing)
                if !message.reactions.isEmpty {
                    Text(message.reactions.values.sorted().joined(separator: " ")).font(.subheadline).padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.08), in: Capsule())
                }
            }.padding(13).foregroundStyle(mine ? Color.black : Color.white)
                .background(mine ? Color(red: 0.88, green: 0.88, blue: 0.92) : Theme.panel, in: RoundedRectangle(cornerRadius: 21))
                .overlay(alignment: mine ? .topLeading : .topTrailing) {
                    if selectionMode {
                        Button {
                            if selectedIDs.contains(message.id) {
                                selectedIDs.remove(message.id)
                            } else {
                                selectedIDs.insert(message.id)
                            }
                        } label: {
                            Image(systemName: selectedIDs.contains(message.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(mine ? .black : .white)
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                .onTapGesture {
                    guard selectionMode else { return }
                    if selectedIDs.contains(message.id) {
                        selectedIDs.remove(message.id)
                    } else {
                        selectedIDs.insert(message.id)
                    }
                }
                .contextMenu {
                    Button("Выбрать", systemImage: "checkmark.circle") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                            selectionMode = true
                            selectedIDs.insert(message.id)
                        }
                    }
                    Button("Ответить", systemImage: "arrowshape.turn.up.left") { reply = message; editing = nil }
                    Button("Переслать", systemImage: "arrowshape.turn.up.right") {
                        forwarding = message
                    }
                    Button(
                        (room?.pinnedMessageIDs ?? []).contains(message.id) ? "Открепить" : "Закрепить",
                        systemImage: "pin"
                    ) {
                        perform { try store.togglePinnedMessage(message) }
                    }
                    Button("Копировать", systemImage: "doc.on.doc") { UIPasteboard.general.setItems([["public.utf8-plain-text": message.text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]) }
                    Menu("Реакция") { ForEach(["❤️", "👍", "🔥", "😂", "👀"], id: \.self) { emoji in Button(emoji) { perform { try store.action("reaction", message: message, value: emoji) } } } }
                    if mine {
                        Button("Редактировать", systemImage: "pencil") { editing = message; reply = nil; text = message.text }
                        Button("Удалить у всех", systemImage: "trash", role: .destructive) { perform { try store.action("delete", message: message) } }
                    }
                }
            if !mine { Spacer(minLength: 42) }
        }
    }
    @MainActor
    func processPhoto(_ item: PhotosPickerItem, viewSeconds: Int?) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }

            let maxSide: CGFloat = 1600
            let scale = min(1, maxSide / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let jpeg = resized.jpegData(compressionQuality: 0.78) else { return }
            guard jpeg.count <= 3 * 1024 * 1024 else {
                throw MessengerError.invalid("Фото получилось слишком большим")
            }

            send(Attachment(
                name: "Photo.jpg",
                mime: "image/jpeg",
                data: jpeg,
                viewSeconds: viewSeconds,
                voiceEffect: nil
            ))
        } catch {
            store.error = error.localizedDescription
        }
    }

    func send(_ attachment: Attachment? = nil) {
        perform {
            if let editing { try store.action("edit", message: editing, value: text) }
            else { try store.send(roomID: roomID, text: text, attachment: attachment, replyTo: reply?.id) }
            text = ""; reply = nil; editing = nil
        }
    }
    func perform(_ action: () throws -> Void) { do { try action() } catch { store.error = error.localizedDescription } }
}

private struct ForwardPickerView: View {
    let message: ChatMessage
    let sourceRoomID: String

    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var rooms: [Room] {
        store.state.rooms
            .filter {
                !$0.archived &&
                ($0.title.localizedCaseInsensitiveContains(search) || search.isEmpty)
            }
            .sorted { a, b in
                if store.isSavedRoom(a.id) != store.isSavedRoom(b.id) {
                    return store.isSavedRoom(a.id)
                }
                if a.pinned != b.pinned { return a.pinned }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VoidBackground()

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(rooms) { room in
                            Button {
                                do {
                                    try store.forward(message, to: room.id)
                                    dismiss()
                                } catch {
                                    store.error = error.localizedDescription
                                }
                            } label: {
                                HStack(spacing: 13) {
                                    Image(systemName: store.isSavedRoom(room.id) ? "bookmark.fill" : (room.isGroup ? "person.2.fill" : "bubble.left.fill"))
                                        .frame(width: 42, height: 42)
                                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(room.title)
                                            .font(.headline)
                                        Text(store.isSavedRoom(room.id) ? "Личный архив" : (room.id == sourceRoomID ? "Текущий чат" : "Переслать сюда"))
                                            .font(.caption2)
                                            .foregroundStyle(Theme.secondary)
                                    }

                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .foregroundStyle(Theme.secondary)
                                }
                                .panel()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Переслать")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Найти чат")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct RoomInfoView: View {
    let roomID: String
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) var dismiss
    @State private var clearing = false
    var room: Room? { store.state.rooms.first { $0.id == roomID } }
    var body: some View {
        NavigationStack {
            Form {
                if let room {
                    Section {
                        HStack { Spacer(); VStack(spacing: 14) { Avatar(name: room.title, group: room.isGroup, size: 80); Text(room.title).font(.title2.bold()); Text(room.isGroup ? "\(room.members.count) участника · закрытая группа" : "Личный чат").font(.caption).foregroundStyle(Theme.secondary) }; Spacer() }.padding(.vertical, 16)
                    }
                    if !room.isGroup && !store.isLocalUtilityRoom(roomID) {
                        Section("Связь") {
                            Button("Позвонить", systemImage: "phone.fill") {
                                store.startCall(roomID)
                                dismiss()
                            }
                            .disabled(store.connection != "Подключён")
                        }
                    }
                    if room.isGroup {
                        Section("Группа") {
                            NavigationLink {
                                GroupManagementView(roomID: roomID)
                            } label: {
                                Label("Управление группой", systemImage: "person.2.badge.gearshape")
                            }

                            HStack {
                                Text("Режим")
                                Spacer()
                                Text(room.onlyAdminsCanPost == true ? "Только админы" : "Все участники")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondary)
                            }

                            HStack {
                                Text("Админов")
                                Spacer()
                                Text("\(store.groupAdminIDs(room).count)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                    }

                    Section("Переписка") {
                        Toggle("Закрепить", isOn: Binding(get: { room.pinned }, set: { value in store.updateRoom(roomID) { $0.pinned = value } }))
                        Toggle("Архивировать", isOn: Binding(get: { room.archived }, set: { value in store.updateRoom(roomID) { $0.archived = value } }))
                        Toggle("Без звука", isOn: Binding(get: { room.muted }, set: { value in store.updateRoom(roomID) { $0.muted = value } }))
                        NavigationLink {
                            SharedMediaView(roomID: roomID)
                        } label: {
                            Label("Медиа и файлы", systemImage: "square.grid.2x2")
                        }
                        Button("Отметить непрочитанным", systemImage: "circlebadge") {
                            store.markRoomUnread(roomID)
                        }
                        Picker("Мои сообщения исчезают", selection: Binding(get: { room.disappearingSeconds }, set: { value in store.updateRoom(roomID) { $0.disappearingSeconds = value } })) {
                            Text("Никогда").tag(0)
                            Text("Через 10 секунд").tag(10)
                            Text("Через 1 минуту").tag(60)
                            Text("Через 5 минут").tag(300)
                            Text("Через 1 час").tag(3600)
                            Text("Через 24 часа").tag(86400)
                            Text("Через 7 дней").tag(604800)
                        }
                        Text("Таймер идёт с момента отправки. Получатель всё равно может сохранить содержимое вне VO1D.").font(.caption).foregroundStyle(Theme.secondary)
                        Button("Очистить локальную историю", systemImage: "trash", role: .destructive) {
                            clearing = true
                        }
                    }
                    Section("Участники") {
                        ForEach(room.members) { member in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(store.name(member.id))
                                Text(store.isBuiltinBot(member.id) ? "XROSB" : member.shortID)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("О чате")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Готово") { dismiss() } }
            .confirmationDialog("Очистить историю на этом устройстве?", isPresented: $clearing, titleVisibility: .visible) {
                Button("Очистить локально", role: .destructive) {
                    store.clearLocalHistory(roomID)
                }
            } message: {
                Text("Это удалит локальные сообщения этого чата на текущем устройстве. Копии у других участников не изменятся.")
            }
        }
    }
}


private struct GroupManagementView: View {
    let roomID: String

    @EnvironmentObject private var store: ChatStore
    @State private var title = ""
    @State private var showAdd = false

    private var room: Room? {
        store.state.rooms.first { $0.id == roomID }
    }

    private var memberContacts: [Contact] {
        guard let room else { return [] }
        let ids = Set(room.members.map(\.id))
        return store.state.contacts.filter {
            ids.contains($0.id) &&
            $0.id != store.myID &&
            !store.isBuiltinBot($0.id)
        }
    }

    private var addableContacts: [Contact] {
        guard let room else { return [] }
        let ids = Set(room.members.map(\.id))
        return store.state.contacts.filter {
            !ids.contains($0.id) &&
            !$0.blocked &&
            !store.isBuiltinBot($0.id)
        }
    }

    var body: some View {
        Form {
            if let room {
                Section {
                    HStack {
                        Avatar(name: room.title, group: true, size: 64)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(room.title)
                                .font(.title3.bold())
                            Text("\(room.members.count) участников")
                                .font(.caption)
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }

                if store.isGroupOwner(room) {
                    Section("Настройки") {
                        TextField("Название группы", text: $title)

                        Button("Сохранить название") {
                            do {
                                try store.renameGroup(roomID, title: title)
                            } catch {
                                store.error = error.localizedDescription
                            }
                        }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Toggle(
                            "Писать могут только админы",
                            isOn: Binding(
                                get: { room.onlyAdminsCanPost == true },
                                set: { value in
                                    do {
                                        try store.setGroupAdminsOnly(roomID, enabled: value)
                                    } catch {
                                        store.error = error.localizedDescription
                                    }
                                }
                            )
                        )
                    }
                }

                Section("Участники") {
                    ForEach(room.members) { member in
                        HStack(spacing: 12) {
                            Avatar(name: store.name(member.id), size: 38)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.name(member.id))
                                HStack(spacing: 6) {
                                    if member.id == room.creator {
                                        Text("ВЛАДЕЛЕЦ")
                                            .font(.system(size: 8, weight: .black, design: .monospaced))
                                            .tracking(1)
                                    } else if store.groupAdminIDs(room).contains(member.id) {
                                        Text("АДМИН")
                                            .font(.system(size: 8, weight: .black, design: .monospaced))
                                            .tracking(1)
                                    } else {
                                        Text(member.shortID)
                                            .font(.caption2.monospaced())
                                    }
                                }
                                .foregroundStyle(Theme.secondary)
                            }

                            Spacer()

                            if store.isGroupOwner(room) && member.id != store.myID {
                                Menu {
                                    Button(
                                        store.groupAdminIDs(room).contains(member.id) ? "Снять админа" : "Сделать админом",
                                        systemImage: "person.badge.key"
                                    ) {
                                        do {
                                            try store.toggleGroupAdmin(roomID, memberID: member.id)
                                        } catch {
                                            store.error = error.localizedDescription
                                        }
                                    }

                                    Button("Удалить из группы", systemImage: "person.badge.minus", role: .destructive) {
                                        let remaining = memberContacts.filter { $0.id != member.id }
                                        do {
                                            try store.updateGroupMembers(roomID, contacts: remaining)
                                        } catch {
                                            store.error = error.localizedDescription
                                        }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                            }
                        }
                    }

                    if store.isGroupOwner(room) {
                        Button("Добавить участников", systemImage: "person.badge.plus") {
                            showAdd = true
                        }
                        .disabled(addableContacts.isEmpty || room.members.count >= 16)
                    }
                }

                if !store.isGroupOwner(room) {
                    Section {
                        Text("Состав группы, админов и режим публикации меняет создатель группы.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .navigationTitle("Управление")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            title = room?.title ?? ""
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                List(addableContacts) { contact in
                    Button {
                        var next = memberContacts
                        next.append(contact)
                        do {
                            try store.updateGroupMembers(roomID, contacts: next)
                            showAdd = false
                        } catch {
                            store.error = error.localizedDescription
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(name: contact.name, size: 42)
                            Text(contact.name)
                            Spacer()
                            Image(systemName: "plus.circle.fill")
                        }
                    }
                    .buttonStyle(.plain)
                }
                .navigationTitle("Добавить")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Закрыть") { showAdd = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct EphemeralPhotoPickerSheet: View {
    @Binding var selection: PhotosPickerItem?
    @Binding var seconds: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                VoidBackground()
                VStack(alignment: .leading, spacing: 22) {
                    Text("Фото с таймером")
                        .font(.system(size: 31, weight: .black, design: .rounded))
                    Text("Получатель увидит размытую карточку. Таймер начнётся только после открытия.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .lineSpacing(4)

                    Picker("Время", selection: $seconds) {
                        Text("5 сек").tag(5)
                        Text("10 сек").tag(10)
                        Text("30 сек").tag(30)
                        Text("60 сек").tag(60)
                    }
                    .pickerStyle(.segmented)

                    PhotosPicker(selection: $selection, matching: .images) {
                        Label("ВЫБРАТЬ ФОТО", systemImage: "photo.fill")
                    }
                    .buttonStyle(PrimaryButton())

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Пересылка для такого фото в VO1D не предлагается", systemImage: "arrowshape.turn.up.right")
                        Label("При записи экрана просмотр закрывается", systemImage: "record.circle")
                        Label("После таймера локальная копия исчезает", systemImage: "timer")
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .panel()

                    Spacer()
                }
                .padding(24)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct EphemeralPhotoView: View {
    let messageID: String
    let mine: Bool
    let image: UIImage
    let seconds: Int

    @EnvironmentObject private var store: ChatStore
    @State private var revealed = false
    @State private var remaining = 0
    @State private var captureActive = UIScreen.main.isCaptured
    @State private var timerTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .blur(radius: revealed && !captureActive ? 0 : 18)

            if captureActive {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "record.circle")
                            Text("ЗАПИСЬ ЭКРАНА")
                                .font(.caption2.monospaced())
                                .tracking(1.6)
                            Text("Просмотр закрыт")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.58))
                        }
                    }
            } else if !revealed {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(0.30))
                    .overlay {
                        VStack(spacing: 9) {
                            Image(systemName: mine ? "timer" : "eye.fill")
                                .font(.title2)
                            Text(mine ? "ФОТО С ТАЙМЕРОМ" : "НАЖМИ ДЛЯ ПРОСМОТРА")
                                .font(.caption2.monospaced())
                                .tracking(1.3)
                            Text("\(seconds) сек")
                                .font(.caption.bold())
                        }
                        .foregroundStyle(.white)
                    }
            } else {
                VStack {
                    HStack {
                        Spacer()
                        Text("\(remaining)")
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.72), in: Capsule())
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            guard !mine, !revealed, !captureActive else { return }
            revealed = true
            remaining = max(1, seconds)
            store.openEphemeral(messageID)
            startCountdown()
        }
        .onDisappear { timerTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            captureActive = UIScreen.main.isCaptured
            if captureActive && revealed {
                store.destroyEphemeralImmediately(messageID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            if revealed {
                store.destroyEphemeralImmediately(messageID)
            }
        }
    }

    private func startCountdown() {
        timerTask?.cancel()
        timerTask = Task {
            while remaining > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                await MainActor.run { remaining -= 1 }
            }
            if !Task.isCancelled {
                await MainActor.run {
                    store.destroyEphemeralImmediately(messageID)
                }
            }
        }
    }
}
