import SwiftUI

struct BotFatherView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var name = ""
    @State private var username = ""
    @State private var failure: String?
    var body: some View {
        List {
            Section("@vo1d_bot_father") {
                Text("Создавай ботов с отдельными ключами, именами и командами. Управление доступно только владельцу.")
                Text("Встроенный исполнитель работает при открытом VO1D на устройстве владельца. Для работы круглосуточно нужен отдельный исполнитель с libsignal и ключами бота. Relay хранит шифротекст; одного токена недостаточно для расшифровки.").font(.caption).foregroundStyle(.secondary)
            }
            Section("/newbot · создать бота") {
                TextField("Имя бота", text: $name)
                TextField("Username, например my_helper_bot", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Создать бота", systemImage: "plus") {
                    do { try store.createBot(name: name, username: username); name = ""; username = ""; failure = nil }
                    catch { failure = error.localizedDescription }
                }.disabled(name.isEmpty || username.isEmpty)
            }
            Section("/mybots · мои боты") {
                ForEach(store.state.managedBots ?? []) { bot in
                    NavigationLink { BotManagementView(botID: bot.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("@" + bot.username).font(.headline)
                            Text(store.botStatuses[bot.id] ?? (bot.registered ? "Готов к запуску" : "Регистрация в очереди")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if (store.state.managedBots ?? []).isEmpty { Text("Пока нет ботов").foregroundStyle(.secondary) }
            }
            if let failure { Text(failure).font(.callout) }
        }.navigationTitle("BotFather")
            .onChange(of: store.generation) { _, _ in name = ""; username = ""; failure = nil }
    }
}

struct BotManagementView: View {
    var botID: String
    @EnvironmentObject private var store: ChatStore
    @State private var command = ""
    @State private var response = ""
    @State private var failure: String?
    @State private var rotating = false
    @State private var deleting = false
    @State private var room: Room?
    private var bot: ManagedBot? { store.state.managedBots?.first { $0.id == botID } }
    var body: some View {
        List {
            if let bot {
                Section("Личность бота") {
                    Text(bot.name).font(.headline)
                    Text("@" + bot.username)
                    Text(bot.id).font(.caption.monospaced()).textSelection(.enabled)
                    Text(store.botStatuses[bot.id] ?? "Ожидает проверки соединения").font(.caption)
                    Toggle("Бот включён", isOn: Binding(get: { self.bot?.enabled ?? false }, set: { value in update { $0.enabled = value } }))
                    Button("Проверить соединение") { Task { await store.sync() } }
                    Button("Открыть чат с ботом") {
                        do {
                            guard let contact = store.state.contacts.first(where: { $0.id == botID }) else { throw MessengerError.invalid("Сначала дождись регистрации бота") }
                            room = try store.direct(contact)
                        } catch { failure = error.localizedDescription }
                    }.disabled(!bot.registered)
                }
                Section("/setcommands · команды") {
                    ForEach(bot.commands.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("/" + key).font(.body.monospaced())
                            Text(bot.commands[key] ?? "").font(.caption).lineLimit(4)
                            if key != "start" && key != "help" { Button("Удалить команду", role: .destructive) { update { $0.commands[key] = nil } } }
                        }
                    }
                    TextField("Команда без /", text: $command).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Ответ бота", text: $response, axis: .vertical).lineLimit(3...8)
                    Button("Сохранить команду") {
                        let key = command.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                        guard key.range(of: "^[a-z][a-z0-9_]{0,31}$", options: .regularExpression) != nil,
                              !response.isEmpty, response.count <= 4000,
                              bot.commands.count < 32 || bot.commands[key] != nil else { failure = "Нужны команда a-z/0-9/_, ответ до 4000 символов; максимум 32 команды"; return }
                        update { $0.commands[key] = response }; command = ""; response = ""
                    }
                }
                Section("/token · доступ исполнителя") {
                    NavigationLink("Приватные приглашения бота") { PrivateLinksView(botID: bot.id) }
                    Text("Токен разрешает работу только с шифротекстом этого бота. Для внешнего исполнителя нужны отдельные ключи и состояние E2EE. Не публикуй токен.").font(.caption)
                    Button("Скопировать токен на 30 секунд") { SafeContent.copy(bot.token, seconds: 30) }
                    Button("Отозвать и заменить токен", role: .destructive) { rotating = true }.disabled(!bot.registered)
                }
                Section("/deletebot") {
                    Button("Удалить бота и его ключи", role: .destructive) { deleting = true }
                    Text("Сохранённые у собеседников сообщения останутся. Удалённое имя может быть занято другой новой личностью.").font(.caption)
                }
            }
            if let failure { Text(failure).font(.callout) }
        }
        .navigationTitle(bot.map { "@" + $0.username } ?? "Бот")
        .navigationDestination(item: $room) { ChatView(roomID: $0.id) }
        .onChange(of: store.generation) { _, _ in command = ""; response = ""; failure = nil; room = nil }
        .confirmationDialog("Старый токен сразу перестанет работать", isPresented: $rotating, titleVisibility: .visible) {
            Button("Заменить токен", role: .destructive) { rotate() }
        }
        .confirmationDialog("Удалить бота без восстановления ключей?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { Task { do { try await store.deleteManagedBot(botID) } catch { failure = error.localizedDescription } } }
        }
    }
    private func update(_ change: (inout ManagedBot) -> Void) {
        guard let index = store.state.managedBots?.firstIndex(where: { $0.id == botID }), var bot = self.bot else { return }
        change(&bot); bot.settingsPending = true
        store.state.managedBots?[index] = bot; store.persist()
        Task { await store.sync() }
    }
    private func rotate() {
        guard let api = store.api else { return }
        let current = store.generation
        Task {
            do {
                let replacement = try Crypto.random(32).base64URL
                guard let index = store.state.managedBots?.firstIndex(where: { $0.id == botID }) else { return }
                store.state.managedBots?[index].token = replacement
                store.state.managedBots?[index].tokenRotationPending = true
                try store.save()
                try await api.rotateBotToken(id: botID, token: replacement)
                guard current == store.generation, let updated = store.state.managedBots?.firstIndex(where: { $0.id == botID && $0.token == replacement }) else { return }
                store.state.managedBots?[updated].tokenRotationPending = false; try store.save(); failure = nil
            } catch { if current == store.generation { failure = error.localizedDescription } }
        }
    }
}
