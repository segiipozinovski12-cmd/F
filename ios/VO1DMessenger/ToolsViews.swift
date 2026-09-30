import SwiftUI
import LocalAuthentication
import UserNotifications

struct ToolsCenterView: View {
    @EnvironmentObject var store: ChatStore
    @State private var report = ""
    var body: some View {
        List {
            Section("Личности и восстановление") {
                NavigationLink("Независимые личности") { ProfilesView() }
                NavigationLink("Архивы истории") { HistoryArchivesView() }
            }
            Section("Приватность") {
                NavigationLink("Настройки приватности") { PrivacyCenterView() }
                NavigationLink("Проверка приватности") { PrivacyDashboardView() }
                NavigationLink("Одноразовые приглашения") { InvitationCenterView() }
                NavigationLink("Запросы · \(store.requestRooms.count)") { MessageRequestsView() }
                NavigationLink("Скрытые чаты") { HiddenRoomsView() }
            }
            Section("Порядок в переписках") {
                NavigationLink("Папки") { FolderCenterView() }
                NavigationLink("Закладки сообщений") { MessageLibraryView(mode:"bookmarks") }
                NavigationLink("Черновики") { DraftsView() }
                NavigationLink("Отложенные сообщения") { MessageLibraryView(mode:"scheduled") }
                NavigationLink("Очередь и ошибки доставки") { MessageLibraryView(mode:"outbox") }
                NavigationLink("Шаблоны текста") { SnippetsView() }
                NavigationLink("Напоминания") { RemindersView() }
            }
            Section("Данные") {
                NavigationLink("Память и вложения") { StorageCenterView() }
                NavigationLink("Зашифрованная резервная копия") { BackupCenterView() }
                NavigationLink("Сессии на сервере") { SessionCenterView() }
                Button("Проверить локальные данные") {
                    do { report=try store.integrityReport() } catch { report=error.localizedDescription }
                }
                if !report.isEmpty { Text(report).font(.caption) }
            }
            Section("Доступ") {
                Button("Заблокировать сейчас") { store.locked=true; store.sessionUnlocked=false }
                Button("Заменить 9-символьный ключ") {
                    Task {
                        let context=LocalAuthentication.LAContext()
                        do {
                            guard try await context.evaluatePolicy(.deviceOwnerAuthentication,localizedReason:"Заменить ключ VO1D") else { return }
                            try store.rotateAccessKey()
                            report="Новый ключ находится в настройках профиля"
                        } catch { report=error.localizedDescription }
                    }
                }
                Button("Освободить username") { Task { do { try await store.releaseUsername(); report="Username освобождён" } catch { report=error.localizedDescription } } }
            }
            Section("Сеть") { NetworkStatusRow() }
        }.navigationTitle("Инструменты VO1D")
    }
}

struct NetworkStatusRow: View {
    @ObservedObject var network = NetworkState.shared
    var body: some View {
        Label(network.connected ? (network.wifi ? "Wi-Fi" : "Мобильная или другая сеть") : "Нет сети",
              systemImage:network.connected ? "network" : "wifi.slash")
    }
}

struct HiddenRoomsView: View {
    @EnvironmentObject var store: ChatStore
    var body: some View {
        Group {
            if store.revealedHiddenRooms {
                List(store.state.rooms.filter { store.extended.hiddenRooms.contains($0.id) }) { room in
                    NavigationLink(room.title) { ChatView(roomID:room.id) }
                }
            } else {
                VStack(spacing:20) {
                    Image(systemName:"lock.fill").font(.largeTitle)
                    Button("Открыть с Face ID / кодом") { Task { await store.revealHidden() } }.buttonStyle(.bordered)
                }
            }
        }.navigationTitle("Скрытые чаты")
    }
}

struct FolderCenterView: View {
    @EnvironmentObject var store: ChatStore
    @State private var name = ""
    var body: some View {
        List {
            Section("Новая папка") {
                TextField("Название",text:$name)
                Button("Создать") { store.createFolder(name); name="" }
            }
            ForEach(store.extended.folders) { folder in
                Section {
                    TextField("Название папки",text:Binding(
                        get: { store.extended.folders.first { $0.id==folder.id }?.name ?? "" },
                        set: { value in store.changeExtended { if let i=$0.folders.firstIndex(where: { $0.id==folder.id }) { $0.folders[i].name=String(value.prefix(32)) } } }))
                    ForEach(store.state.rooms.filter { !store.extended.hiddenRooms.contains($0.id) }) { room in
                        Toggle(room.title,isOn:Binding(get: { folder.roomIDs.contains(room.id) },
                            set: { _ in store.folderToggle(folder.id,roomID:room.id) }))
                    }
                    Button("Удалить папку",role:.destructive) { store.changeExtended { $0.folders.removeAll { $0.id==folder.id } } }
                } header: { Text(folder.name) }
            }
        }.navigationTitle("Папки")
    }
}

struct DraftsView: View {
    @EnvironmentObject var store: ChatStore
    var body: some View {
        List(store.state.rooms.filter { !$0.draft.isEmpty && !store.extended.hiddenRooms.contains($0.id) }) { room in
            NavigationLink { ChatView(roomID:room.id) } label: {
                VStack(alignment:.leading) { Text(room.title); Text(room.draft).lineLimit(2).font(.caption).foregroundStyle(.secondary) }
            }.swipeActions {
                Button("Очистить",role:.destructive) { store.updateRoom(room.id) { $0.draft="" } }
            }
        }.navigationTitle("Черновики")
    }
}

struct MessageLibraryView: View {
    let mode: String
    @EnvironmentObject var store: ChatStore
    @State private var rescheduling: ChatMessage?
    private var messages: [ChatMessage] {
        store.state.messages.filter { message in
            guard !store.extended.hiddenRooms.contains(message.roomID) else { return false }
            if mode=="bookmarks" { return store.extended.bookmarks.contains(message.id) }
            if mode=="scheduled" { return message.state=="scheduled" }
            return store.state.outbox.contains { $0.messageID==message.id } || ["failed","expired","cancelled"].contains(message.state)
        }.sorted { ($0.scheduledAt ?? $0.createdAt) > ($1.scheduledAt ?? $1.createdAt) }
    }
    var body: some View {
        List {
            ForEach(messages) { message in
                VStack(alignment:.leading,spacing:8) {
                    NavigationLink { ChatView(roomID:message.roomID,initialMessageID:message.id) } label: {
                        VStack(alignment:.leading) {
                            Text(store.state.rooms.first { $0.id==message.roomID }?.title ?? "Чат").font(.headline)
                            Text(message.text.isEmpty ? message.attachment?.name ?? "Сообщение" : message.text).lineLimit(3)
                        }
                    }
                    if mode != "bookmarks" {
                        Text(message.state).font(.caption.monospaced())
                        ForEach(store.state.outbox.filter { $0.messageID==message.id }) { pending in
                            if let issue=store.deliveryIssues[pending.id] {
                                Text("\(issue.detail) · попыток: \(issue.attempts)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            if message.state=="scheduled" {
                                Button("Изменить время") { rescheduling=message }
                                if let at=message.scheduledAt { Text(at,style:.relative).font(.caption) }
                            } else {
                                Button("Повторить") { store.retryDelivery(message.id) }
                            }
                            Button("Отменить") { store.cancelMessage(message.id) }
                        }.buttonStyle(.bordered)
                    }
                }.padding(.vertical,5)
            }
            if messages.isEmpty { Text("Пока пусто") }
        }
        .navigationTitle(mode=="bookmarks" ? "Закладки" : mode=="scheduled" ? "Отложенные" : "Очередь")
        .sheet(item:$rescheduling) { message in ScheduleEditor(message:message) }
    }
}

struct ScheduleEditor: View {
    let message: ChatMessage
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) var dismiss
    @State private var date = Date().addingTimeInterval(3600)
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Отправить",selection:$date,in:Date()...,displayedComponents:[.date,.hourAndMinute])
                Text("Сообщение отправится, когда приложение сможет выполнить синхронизацию. Это не серверный планировщик.")
                    .font(.caption)
                Button("Сохранить") { store.reschedule(message.id,at:date); dismiss() }
            }.navigationTitle("Время отправки").onAppear { date=message.scheduledAt ?? date }
        }
    }
}

struct SnippetsView: View {
    @EnvironmentObject var store: ChatStore
    @State private var text = ""
    var body: some View {
        List {
            Section("Новый шаблон") {
                TextField("Текст",text:$text,axis:.vertical)
                Button("Сохранить") {
                    let clean=String(text.trimmingCharacters(in:.whitespacesAndNewlines).prefix(2000))
                    if !clean.isEmpty { store.changeExtended { if $0.snippets.count<50 { $0.snippets.append(clean) } }; text="" }
                }
            }
            ForEach(Array(store.extended.snippets.enumerated()),id:\.offset) { index,snippet in
                Text(snippet).contextMenu { Button("Копировать") { SafeContent.copy(snippet,seconds:store.preferences.clipboardSeconds) } }
                    .swipeActions { Button("Удалить",role:.destructive) { store.changeExtended { $0.snippets.remove(at:index) } } }
            }
        }.navigationTitle("Шаблоны")
    }
}

struct RemindersView: View {
    @EnvironmentObject var store: ChatStore
    var body: some View {
        List(store.extended.reminders.filter { !store.extended.hiddenRooms.contains($0.roomID) }) { reminder in
            VStack(alignment:.leading) {
                NavigationLink("Открыть сообщение") { ChatView(roomID:reminder.roomID,initialMessageID:reminder.messageID) }
                Text(reminder.at,style:.date); Text(reminder.at,style:.time)
            }.swipeActions {
                Button("Удалить",role:.destructive) {
                    UserNotifications.UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers:[reminder.id])
                    store.changeExtended { $0.reminders.removeAll { $0.id==reminder.id } }
                }
            }
        }.navigationTitle("Напоминания")
    }
}

struct StorageCenterView: View {
    @EnvironmentObject var store: ChatStore
    @State private var selected: Room?
    @State private var clearAll = false
    @State private var server: RelayStorage?
    var body: some View {
        List {
            Section("На устройстве") {
                Text(ByteCountFormatter.string(fromByteCount:Int64(store.localStorageBytes()),countStyle:.file))
                Text("Размер текста и локальных вложений; системные кэши и служебные поля сюда не входят.").font(.caption)
                ForEach(store.state.rooms.filter { !store.extended.hiddenRooms.contains($0.id) }) { room in
                    HStack {
                        Text(room.title); Spacer()
                        Text(ByteCountFormatter.string(fromByteCount:Int64(store.localStorageBytes(room.id)),countStyle:.file)).font(.caption)
                        Button("Очистить медиа") { selected=room }
                    }
                }
                Button("Очистить все локальные медиа",role:.destructive) { clearAll=true }
            }
            if let server {
                Section("На relay") {
                    Text("В очереди: \(server.queuedMessages)")
                    Text("Зашифрованных файлов: \(server.files)")
                    Text(ByteCountFormatter.string(fromByteCount:Int64(server.fileBytes+server.mailboxBytes),countStyle:.file))
                }
            }
        }
        .navigationTitle("Память")
        .task { if let api=store.api { server=try? await api.request("v1/storage") } }
        .confirmationDialog("Удалить локальные вложения?",isPresented:Binding(get:{ selected != nil || clearAll },set:{ if !$0 { selected=nil; clearAll=false } }),titleVisibility:.visible) {
            Button("Очистить",role:.destructive) { store.clearMedia(clearAll ? nil : selected?.id); selected=nil; clearAll=false }
        } message: { Text("Встроенные вложения без серверной копии восстановить нельзя. Текст сообщений останется.") }
    }
}

struct SessionCenterView: View {
    @EnvironmentObject var store: ChatStore
    @State private var sessions: [RelaySession] = []
    @State private var status = ""
    var body: some View {
        List {
            ForEach(sessions) { session in
                VStack(alignment:.leading) {
                    Text(session.current ? "Эта сессия" : "Другая сессия")
                    Text("Истекает: \(Date(timeIntervalSince1970:Double(session.expiresAt)).formatted())").font(.caption)
                }
            }
            Button("Завершить остальные сессии") {
                Task {
                    do {
                        let _: APIClient.OK? = try await store.api?.request("v1/sessions/revoke",method:"POST",body:Data("{}".utf8))
                        await refresh()
                    } catch { status=error.localizedDescription }
                }
            }
            Text("Устройство с копией приватных ключей может войти заново. Отзыв сессии не отзывает украденные ключи.").font(.caption)
            if !status.isEmpty { Text(status).font(.caption) }
        }.navigationTitle("Сессии").task { await refresh() }
    }
    private func refresh() async {
        struct Response: Decodable { var sessions: [RelaySession] }
        do { let response: Response? = try await store.api?.request("v1/sessions"); sessions=response?.sessions ?? [] }
        catch { status=error.localizedDescription }
    }
}

struct RoomToolsView: View {
    let roomID: String
    @EnvironmentObject var store: ChatStore
    @State private var note = ""
    var body: some View {
        Form {
            Section("Локальная заметка к чату") {
                TextEditor(text:$note).frame(minHeight:90)
                Button("Сохранить") { store.changeExtended { $0.roomNotes[roomID]=String(note.prefix(2000)) } }
            }
            Section("Приватность") {
                if let room=store.state.rooms.first(where: { $0.id==roomID }),store.isGroupOwner(room),room.isChannel==true {
                    Toggle("Скрытый список подписчиков",isOn:Binding(get:{ room.privateRoster==true },set:{ value in
                        do { try store.setPrivateRoster(roomID,enabled:value) } catch { store.error=error.localizedDescription }
                    }))
                    Text("Подписчик получает только свой ключ и ключ владельца. Состав уже раскрытых старых сообщений скрыть задним числом нельзя.").font(.caption)
                }
                Toggle("Не отправлять прочтение и доставку",isOn:Binding(
                    get:{ store.extended.receiptExceptions.contains(roomID) },
                    set:{ value in store.changeExtended { if value { if !$0.receiptExceptions.contains(roomID) { $0.receiptExceptions.append(roomID) } } else { $0.receiptExceptions.removeAll { $0==roomID } } } }))
                Button(store.extended.hiddenRooms.contains(roomID) ? "Убрать из скрытых" : "Скрыть чат") { Task { await store.toggleHidden(roomID) } }
            }
            Section("Локальный вид") {
                Slider(value:Binding(get:{ store.extended.roomFontSize[roomID] ?? store.preferences.fontSize },
                    set:{ value in store.changeExtended { $0.roomFontSize[roomID]=value } }),in:13...24,step:1)
                Picker("Хранить локально",selection:Binding(get:{ store.extended.roomRetention[roomID] ?? store.preferences.localRetentionDays },
                    set:{ value in store.changeExtended { $0.roomRetention[roomID]=value } })) {
                    Text("Всегда").tag(0); Text("7 дней").tag(7); Text("30 дней").tag(30); Text("90 дней").tag(90)
                }
            }
            Section("Папки") {
                ForEach(store.extended.folders) { folder in
                    Toggle(folder.name,isOn:Binding(get:{ folder.roomIDs.contains(roomID) },set:{ _ in store.folderToggle(folder.id,roomID:roomID) }))
                }
            }
        }.navigationTitle("Настройки чата").onAppear { note=store.extended.roomNotes[roomID] ?? "" }
    }
}

struct ChatLinksView: View {
    let roomID: String
    @EnvironmentObject var store: ChatStore
    var body: some View {
        List {
            ForEach(store.messages(roomID).filter { !SafeContent.links(in:$0.text).isEmpty }) { message in
                Section {
                    ForEach(SafeContent.links(in:message.text),id:\.absoluteString) { url in
                        Link(destination:store.preferences.cleanLinks ? SafeContent.cleanURL(url) : url) { Text(url.host ?? "Ссылка") }
                    }
                    NavigationLink("Перейти к сообщению") { ChatView(roomID:roomID,initialMessageID:message.id) }
                }
            }
        }.navigationTitle("Ссылки чата")
    }
}
