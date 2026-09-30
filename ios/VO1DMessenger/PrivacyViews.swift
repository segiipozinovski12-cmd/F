import SwiftUI
import UIKit

struct PrivacyCenterView: View {
    @EnvironmentObject var store: ChatStore
    @State private var status = ""
    @State private var saving = false
    var body: some View {
        Form {
            Section("Общение") {
                Toggle("Запросы от незнакомцев",isOn:store.preferenceBinding(\.requireRequests))
                Toggle("Принимать группы без приглашения",isOn:store.preferenceBinding(\.allowGroupInvites))
                Toggle("Находить меня по нику и коду",isOn:store.preferenceBinding(\.discoverable))
                Toggle("Показывать, что я печатаю",isOn:store.preferenceBinding(\.typingSignals))
                Toggle("Отправлять доставку",isOn:store.preferenceBinding(\.deliveryReceipts))
                Toggle("Звонки на заблокированном iPhone",isOn:store.preferenceBinding(\.backgroundCalls))
                Text("Работает после первого разблокирования после перезагрузки. Для авторизации звонков сохраняется ключ подписи; ключи расшифровки переписки и истории остаются доступны только при разблокированном устройстве.").font(.caption).foregroundStyle(.secondary)
                Toggle("Звонки только от проверенных",isOn:store.preferenceBinding(\.verifiedOnlyCalls))
                Text("Время последней активности не публикуется. Поиск и разрешения звонков нужно сохранить на сервере.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Уведомления") {
                Toggle("Имя и текст в локальных уведомлениях",isOn:store.preferenceBinding(\.notificationPreview))
                Toggle("Тихие часы",isOn:store.preferenceBinding(\.quietHours))
                Stepper("Начало: \(store.preferences.quietStart):00",value:store.preferenceBinding(\.quietStart),in:0...23)
                Stepper("Конец: \(store.preferences.quietEnd):00",value:store.preferenceBinding(\.quietEnd),in:0...23)
                Text("Серверные push всегда нейтральные. Тихие часы применяются к локальным уведомлениям.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ссылки и содержимое") {
                Toggle("Нейтральные имена отправляемых файлов",isOn:store.preferenceBinding(\.anonymizeFilenames))
                Toggle("Убирать известные трекеры из ссылок",isOn:store.preferenceBinding(\.cleanLinks))
                Toggle("Подтверждать открытие сайтов",isOn:store.preferenceBinding(\.confirmLinks))
                Toggle("Локальные карточки ссылок",isOn:store.preferenceBinding(\.linkPreviews))
                Toggle("Скрывать фото до нажатия",isOn:store.preferenceBinding(\.hideMedia))
                Toggle("Скрывать содержимое при записи экрана",isOn:store.preferenceBinding(\.protectRecording))
                Toggle("Пересылать без имени автора",isOn:store.preferenceBinding(\.forwardWithoutName))
                Toggle("Хранить старый текст после редактирования",isOn:store.preferenceBinding(\.keepEditHistory))
                Picker("Буфер обмена",selection:store.preferenceBinding(\.clipboardSeconds)) {
                    Text("10 секунд").tag(10); Text("1 минута").tag(60); Text("5 минут").tag(300)
                }
                Text("Карточки ссылок строятся на устройстве и не запрашивают сайт. Отправитель и участники группы могут узнать автора по контексту.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Сроки") {
                Picker("Удалять локальную историю",selection:store.preferenceBinding(\.localRetentionDays)) {
                    Text("Не удалять").tag(0); Text("Через 7 дней").tag(7); Text("Через 30 дней").tag(30); Text("Через 90 дней").tag(90)
                }
                Picker("Исчезновение новых сообщений",selection:store.preferenceBinding(\.defaultDisappearing)) {
                    Text("Выключено").tag(0); Text("1 час").tag(3600); Text("24 часа").tag(86400); Text("7 дней").tag(604800)
                }
                Picker("Удалить аккаунт без активности",selection:store.preferenceBinding(\.inactivityDays)) {
                    Text("Никогда").tag(0); Text("30 дней").tag(30); Text("90 дней").tag(90); Text("180 дней").tag(180); Text("1 год").tag(365)
                }
                Text("Неактивность считает сервер. Автоматическая очистка локальных данных требует следующего запуска. Копии у собеседников остаются вне контроля VO1D.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Сеть") {
                Toggle("SOCKS5 / внешний Tor",isOn:store.preferenceBinding(\.proxyEnabled))
                TextField("Host, например 127.0.0.1",text:store.preferenceBinding(\.proxyHost))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Stepper("Порт: \(store.preferences.proxyPort)",value:store.preferenceBinding(\.proxyPort),in:1...65535)
                Toggle("Дополнять события случайными байтами",isOn:store.preferenceBinding(\.padding))
                Toggle("Экономить мобильный трафик",isOn:store.preferenceBinding(\.lowData))
                Toggle("Загружать большие файлы только по Wi-Fi",isOn:store.preferenceBinding(\.wifiOnlyUploads))
                Stepper("Лимит файла: \(store.preferences.maxUploadMB) МБ",value:store.preferenceBinding(\.maxUploadMB),in:1...50)
                Text("Нужен работающий внешний SOCKS5/Tor. При сбое прокси прямого обхода нет. APNs, внешние сайты и трафик других приложений этой настройкой не покрываются.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Интерфейс") {
                Toggle("Компактные строки чатов",isOn:store.preferenceBinding(\.compactRows))
                Picker("Сортировка чатов",selection:store.preferenceBinding(\.sortOrder)) {
                    Text("По активности").tag("recent"); Text("По имени").tag("name"); Text("Непрочитанные первыми").tag("unread")
                }
                Slider(value:store.preferenceBinding(\.fontSize),in:13...24,step:1) { Text("Размер текста") }
                Text("Текст сообщений: \(Int(store.preferences.fontSize))")
                Picker("Блокировать после ухода",selection:store.preferenceBinding(\.autoLockSeconds)) {
                    Text("Сразу").tag(0); Text("Через 30 секунд").tag(30); Text("Через 1 минуту").tag(60); Text("Через 5 минут").tag(300)
                }
            }
            Section {
                Button(saving ? "Сохранение…" : "СОХРАНИТЬ НА СЕРВЕРЕ И ПРИМЕНИТЬ СЕТЬ") {
                    saving = true
                    Task {
                        do {
                            try await store.reconfigureTransport()
                            try await store.applyPrivacy()
                            status = "Настройки применены"
                        } catch { status = error.localizedDescription }
                        saving = false
                    }
                }.disabled(saving)
                if !status.isEmpty { Text(status).font(.caption) }
            }
        }
        .navigationTitle("Приватность")
        .tint(.white)
    }
}

struct PrivacyDashboardView: View {
    @EnvironmentObject var store: ChatStore
    var body: some View {
        List {
            Section("Защищено") {
                Label("Содержимое сообщений зашифровано",systemImage:"lock.fill")
                Label("История зашифрована на устройстве",systemImage:"externaldrive.badge.checkmark")
                Label("Номер и почта не требуются",systemImage:"person.crop.circle")
                Label("Ключи контактов подписаны",systemImage:"signature")
            }
            Section("Текущие настройки") {
                row("Запросы от незнакомцев",store.preferences.requireRequests)
                row("Подтверждение внешних ссылок",store.preferences.confirmLinks)
                row("Уборка трекеров",store.preferences.cleanLinks)
                row("Face ID / код",store.state.appLock)
                row("Превью уведомлений скрыты",!store.preferences.notificationPreview)
                row("Набор текста скрыт",!store.preferences.typingSignals)
                row("Прокси настроен",store.preferences.proxyEnabled)
                Text("Соединение: \(store.connection)")
            }
            Section("Границы") {
                Text("Relay видит ID отправителя и получателя, время и размер. При прямом подключении видит IP; с прокси видит адрес выхода.")
                Text("Протокол v1 не реализует Double Ratchet и не проходил внешний аудит.")
                Text("Скриншоты и сохранённые копии собеседника удалить невозможно.")
                Text("Код из 9 символов открывает это приложение и не восстанавливает криптографическую личность.")
                Text("Облачные push обрабатывает Apple. Tor встроенным не является.")
            }
        }.navigationTitle("Проверка приватности")
    }
    private func row(_ title: String,_ active: Bool) -> some View {
        HStack { Text(title); Spacer(); Image(systemName:active ? "checkmark.circle" : "circle") }
    }
}

struct MessageRequestsView: View {
    @EnvironmentObject var store: ChatStore
    var body: some View {
        List {
            if store.requestRooms.isEmpty { Text("Новых запросов нет") }
            ForEach(store.requestRooms) { room in
                VStack(alignment:.leading,spacing:12) {
                    Label(String(room.title.prefix(60)),systemImage:room.isGroup ? "person.2" : "person")
                    Text(room.isGroup ? "Приглашение в группу · \(room.members.count) участников" : "Запрос на переписку")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Вложения скрыты до принятия. Содержимое запроса хранится зашифрованным локально.")
                        .font(.caption)
                    HStack {
                        Button("Принять") { Task { do { try await store.acceptRequest(room.id) } catch { store.error=error.localizedDescription } } }
                        Button("Отклонить") { Task { await store.declineRequest(room.id,block:false) } }
                        Button("Блокировать") { Task { await store.declineRequest(room.id,block:true) } }
                    }.buttonStyle(.bordered)
                }.padding(.vertical,8)
            }
        }.navigationTitle("Запросы")
    }
}

struct InvitationCenterView: View {
    @EnvironmentObject var store: ChatStore
    @State private var ttl = 3600
    @State private var uses = 1
    @State private var result: InviteReceipt?
    @State private var invites: [InviteReceipt] = []
    @State private var failure = ""
    var body: some View {
        Form {
            Section("Новое приглашение") {
                Picker("Срок",selection:$ttl) {
                    Text("10 минут").tag(600); Text("1 час").tag(3600); Text("1 день").tag(86400); Text("7 дней").tag(604800)
                }
                Stepper("Использований: \(uses)",value:$uses,in:1...100)
                Button("Создать") {
                    Task { do { result=try await store.createInvite(seconds:ttl,uses:uses); await refresh() } catch { failure=error.localizedDescription } }
                }
                if let token=result?.token {
                    let link="vo1d://invite/\(token)"
                    Text(link).font(.caption.monospaced())
                    ShareLink(item:link)
                    Button("Копировать безопасно") { SafeContent.copy(link,seconds:store.preferences.clipboardSeconds) }
                    QRCodeView(text:link).frame(height:180)
                }
            }
            Section("Действующие ссылки") {
                ForEach(invites) { invite in
                    HStack {
                        VStack(alignment:.leading) {
                            Text("Осталось использований: \(invite.remaining)")
                            Text(Date(timeIntervalSince1970:Double(invite.expiresAt)),style:.relative).font(.caption)
                        }
                        Spacer()
                        Button("Отозвать") { Task { do { try await store.revokeInvite(invite.id); await refresh() } catch { failure=error.localizedDescription } } }
                    }
                }
            }
            Section("Публичный код") {
                Text(store.state.publicCode ?? "—").font(.title.monospaced())
                Button("Заменить код поиска") { Task { do { try await store.rotatePublicCode() } catch { failure=error.localizedDescription } } }
                Text("Старый короткий код перестанет работать. Существующие контакты сохранятся. Обычные приглашения с полным ID остаются действующими.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !failure.isEmpty { Text(failure).font(.caption) }
        }.navigationTitle("Приглашения").task { await refresh() }
    }
    private func refresh() async {
        do { invites=try await store.listInvites() } catch { failure=error.localizedDescription }
    }
}

struct ContactPrivacyView: View {
    let contactID: String
    @EnvironmentObject var store: ChatStore
    @State private var myAlias = ""
    @State private var note = ""
    @State private var scanning = false
    @State private var check = ""
    private var contact: Contact? { store.state.contacts.first { $0.id == contactID } }
    var body: some View {
        Form {
            Section("Мой псевдоним для этого человека") {
                TextField("Имя, которое я отправляю ему",text:$myAlias)
                Text("Для личного чата. В группах участники видят общее имя отправителя. Профиль и старые сообщения не переименовываются.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Локальная заметка") { TextEditor(text:$note).frame(minHeight:80) }
            Section {
                Button("Сохранить") { store.changeExtended { $0.aliases[contactID]=String(myAlias.prefix(40)); $0.notes[contactID]=String(note.prefix(2000)) } }
                Button(store.extended.favorites.contains(contactID) ? "Убрать из избранных контактов" : "Избранный контакт") {
                    store.changeExtended { if $0.favorites.contains(contactID) { $0.favorites.removeAll { $0 == contactID } } else { $0.favorites.append(contactID) } }
                }
            }
            if let contact, let own=store.ownCard {
                Section("Проверка ключей") {
                    let payload=SafeContent.fingerprint(own,contact.card)
                    QRCodeView(text:payload).frame(height:210)
                    Text([own.id,contact.id].sorted().joined(separator:"\n")).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Сканировать QR собеседника") { scanning=true }
                    Text(check).font(.caption)
                }
            }
        }
        .navigationTitle("Приватность контакта")
        .onAppear { myAlias=store.extended.aliases[contactID] ?? ""; note=store.extended.notes[contactID] ?? "" }
        .sheet(isPresented:$scanning) {
            QRScanner { value in
                scanning=false
                guard let own=store.ownCard, let contact else { return }
                if value==SafeContent.fingerprint(own,contact.card) {
                    if let i=store.state.contacts.firstIndex(where: { $0.id==contactID }) {
                        store.state.contacts[i].verified=true; store.persist()
                        Task { try? await store.trustOnServer(contactID,trusted:store.extended.trustedIDs.contains(contactID)) }
                    }
                    check="Ключи совпадают"
                } else { check="QR не совпал. Личность не подтверждена." }
            }.ignoresSafeArea()
        }
    }
}
