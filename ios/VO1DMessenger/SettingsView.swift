import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: ChatStore
    @State var name = ""
    @State var server = ""
    @State var deleting = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { MyIdentityView() } label: {
                        HStack(spacing: 16) {
                            Avatar(name: store.state.nickname, size: 64)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(store.state.nickname).font(.title2.weight(.semibold))
                                Text(store.ownCard?.shortID ?? "").font(.caption.monospaced()).foregroundStyle(Theme.secondary)
                                Text("Моя личность и QR-код").font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }.padding(.vertical, 12)
                    }
                }
                Section("Профиль") {
                    TextField("Никнейм", text: $name)
                    Button("Сохранить") { store.state.nickname = String(name.prefix(40)); store.persist() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Приватность") {
                    Toggle("Face ID / код устройства", isOn: Binding(get: { store.state.appLock }, set: { value in Task { await store.setLock(value) } }))
                    Toggle("Отправлять прочтения", isOn: Binding(get: { store.state.readReceipts }, set: { store.state.readReceipts = $0; store.persist() }))
                    NavigationLink("Как защищены сообщения") { PrivacyView() }
                }
                Section {
                    TextField("https://chat.example.com", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(store.busy ? "Подключение…" : "Подключить сервер") { Task { await store.configure(name: name, server: server) } }
                        .disabled(store.busy || (!store.state.server.isEmpty && server != store.state.server))
                    LabeledContent("Состояние", value: store.connection)
                    LabeledContent("В очереди", value: "\(store.state.outbox.count)")
                    Text("Для нового сервера создай новую личность после удаления текущей. Это защищает очередь и контакты от случайного переноса.").font(.caption).foregroundStyle(Theme.secondary)
                } header: { Text("Сервер") }
                Section {
                    Button("Удалить аккаунт и данные", role: .destructive) { deleting = true }.disabled(store.busy || store.state.server.isEmpty)
                } footer: { Text("Удаляются ключи, локальная переписка, аккаунт и очередь сервера. Копии у собеседников остаются.") }
                Section {
                    HStack { Spacer(); VStack(spacing: 8) { Text("VO1D").font(.headline.monospaced()).tracking(5); Text("MESSENGER 1.0").font(.caption2.monospaced()).foregroundStyle(Theme.secondary) }; Spacer() }.padding(.vertical, 10).listRowBackground(Color.clear)
                }
            }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Твоё пространство")
                .onAppear { name = store.state.nickname; server = store.state.server }
                .confirmationDialog("Удалить личность навсегда?", isPresented: $deleting, titleVisibility: .visible) {
                    Button("Удалить навсегда", role: .destructive) { Task { await store.deleteAccount() } }
                } message: { Text("Без приватных ключей восстановить переписку нельзя. Удаление необратимо.") }
        }
    }
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                Image(systemName: "lock.shield").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(Theme.accent)
                Text("Приватность\nбез громких обещаний.").font(.system(size: 32, weight: .semibold))
                item("Без телефона и почты", "Аккаунт — случайная криптографическая личность. Никнейм передаётся внутри зашифрованных сообщений. Адресная книга не загружается.")
                item("Содержимое шифруется", "Текст, файлы, голосовые, реакции и приглашения в группы шифруются на устройстве. ID контакта связан с его публичным ключом.")
                item("Что видит сервер", "Сервер видит сетевой IP, ID отправителя и получателя, размер и время доставки. Сквозное шифрование не скрывает эти метаданные и само по себе не делает сеть анонимной.")
                item("Ключи и устройство", "Ключи находятся в Keychain. Локальная история зашифрована и исключена из резервного копирования приложения. Потеря ключей означает потерю доступа.")
                item("Удаление и таймеры", "Получатель может сохранить содержимое или сделать скриншот. Удаление у всех и таймер не могут отозвать такие копии.")
                item("Текущая версия", "Переписка обновляется, пока приложение открыто. Фоновые push-уведомления, звонки, несколько устройств и восстановление аккаунта не подключены. Протокол не проходил независимый аудит; forward secrecy для скомпрометированного ключа получателя не заявляется.")
            }.padding(26)
        }.background(Theme.background).navigationTitle("Приватность").navigationBarTitleDisplayMode(.inline)
    }
    func item(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); Text(text).font(.subheadline).foregroundStyle(Theme.secondary).lineSpacing(5) }
    }
}
