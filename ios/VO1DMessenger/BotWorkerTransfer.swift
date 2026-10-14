import Foundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct BotWorkerPayload: Codable {
    var version = 1
    var bot: ManagedBot
    var identity: LocalIdentity
    var state: VaultState
    var executorID: String
}
enum BotWorkerTransfer {
    static let format = "VO1D-BOT-WORKER-1"
    static func validate(_ payload: BotWorkerPayload) throws {
        try payload.identity.validate(); try Crypto.validate(payload.bot.card)
        guard payload.version == 1, payload.executorID.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              payload.bot.card.hasSameKeys(as: try payload.identity.card), payload.bot.registered,
              payload.bot.token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              payload.state.extended?.signal != nil, (payload.state.managedBots ?? []).isEmpty,
              (payload.state.pendingReports ?? []).isEmpty, payload.state.contacts.count <= 1000, payload.state.outbox.count <= 1000,
              try Wire.encoder.encode(payload).count <= 16*1024*1024 else { throw MessengerError.invalid("Некорректное состояние исполнителя бота") }
        for contact in payload.state.contacts { try Crypto.validate(contact.card) }
        guard let signal = payload.state.extended?.signal, signal.registration > 0, signal.nextKey > 0,
              signal.prekeys.count <= 512, signal.kyberKeys.count <= 512, signal.signedKeys.count <= 512,
              signal.sessions.count <= 1000, signal.trusted.count <= 1000,
              (signal.pendingPublication?.bundles.count ?? 0) <= 48 else { throw MessengerError.invalid("Повреждённое или слишком большое состояние libsignal") }
    }
    static func export(_ payload: BotWorkerPayload, password: String) throws -> Data {
        try validate(payload)
        let salt = try Crypto.random(16), key = try SecureBackup.key(password: password, salt: salt, rounds: 600_000)
        let sealed = try AES.GCM.seal(Wire.encoder.encode(payload), using: key, authenticating: Data(format.utf8))
        guard let combined = sealed.combined else { throw MessengerError.invalid("Не удалось зашифровать исполнителя") }
        var envelope = BackupEnvelope(salt: salt, ciphertext: combined); envelope.format = format
        return try Wire.encoder.encode(envelope)
    }
    static func open(_ data: Data, password: String) throws -> BotWorkerPayload {
        guard data.count <= 24*1024*1024 else { throw MessengerError.invalid("Файл исполнителя больше 24 МБ") }
        let envelope = try Wire.decoder.decode(BackupEnvelope.self, from: data)
        guard envelope.format == format else { throw MessengerError.invalid("Нужен файл исполнителя бота") }
        let key = try SecureBackup.key(password: password, salt: envelope.salt, rounds: envelope.rounds)
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext), using: key, authenticating: Data(format.utf8))
        let payload = try Wire.decoder.decode(BotWorkerPayload.self, from: clear); try validate(payload); return payload
    }
}
extension ChatStore {
    func exportBotWorker(_ id: String, password: String) async throws -> Data {
        guard !botsSyncing, !locked, let api, let index = state.managedBots?.firstIndex(where: { $0.id == id }), var bot = state.managedBots?[index], bot.registered else { throw MessengerError.invalid("Дождись регистрации и завершения работы бота") }
        botsSyncing = true; defer { botsSyncing = false }; let expected = generation
        if bot.externalExecution == true {
            guard let data = bot.handoffData else { throw MessengerError.invalid("Исполнитель уже передан. Для возврата нужен его последний файл") }
            _ = try BotWorkerTransfer.open(data, password: password)
            if bot.executorPending == true, let executor = bot.executorID { try await api.configureBotExecutor(id: id, executor: executor, external: true) }
            guard expected == generation, !locked else { throw CancellationError() }
            return data
        }
        let keys = try Keychain.load(profileID: bot.keyProfileID), workerState = try Vault(profileID: bot.keyProfileID).read(key: keys.storage)
        let executor = try Crypto.random(32).base64URL
        bot.externalExecution = true; bot.executorID = executor; bot.executorPending = true; bot.handoffData = nil
        let data = try BotWorkerTransfer.export(BotWorkerPayload(bot: bot, identity: keys, state: workerState, executorID: executor), password: password)
        bot.handoffData = data
        let previous = state; state.managedBots?[index] = bot
        do { try save() } catch { state = previous; throw error }
        let current = generation
        try await api.configureBotExecutor(id: id, executor: executor, external: true)
        guard current == generation, !locked, let updated = state.managedBots?.firstIndex(where: { $0.id == id && $0.executorID == executor }) else { throw CancellationError() }
        state.managedBots?[updated].executorPending = false; try save(); return data
    }
    func importBotWorker(_ id: String, data: Data, password: String) async throws {
        guard !botsSyncing, !locked, let api, let index = state.managedBots?.firstIndex(where: { $0.id == id }), var bot = state.managedBots?[index], bot.externalExecution == true else { throw MessengerError.invalid("Бот не передан внешнему исполнителю") }
        botsSyncing = true; defer { botsSyncing = false }
        let payload = try BotWorkerTransfer.open(data, password: password)
        guard payload.bot.card.hasSameKeys(as: bot.card), payload.executorID == bot.executorID,
              payload.bot.server == bot.server else { throw MessengerError.invalid("Нужен последний файл текущего исполнителя и той же личности") }
        let current = generation, executor = try Crypto.random(32).base64URL
        // Replacing the epoch fences ordinary requests from the previous process.
        try await api.configureBotExecutor(id: id, executor: executor, external: false)
        guard current == generation, !locked, state.managedBots?[index].id == id,
              state.managedBots?[index].token == bot.token, state.managedBots?[index].executorID == bot.executorID else { throw CancellationError() }
        let keys = try Keychain.load(profileID: bot.keyProfileID)
        guard try keys.card.hasSameKeys(as: payload.bot.card) else { throw MessengerError.invalid("Ключи бота отсутствуют") }
        try Vault(profileID: bot.keyProfileID).write(payload.state, key: keys.storage)
        bot.externalExecution = false; bot.executorID = executor; bot.executorPending = false; bot.handoffData = nil
        state.managedBots?[index] = bot; try save()
        Task { await sync() }
    }
}

struct BotWorkerTransferView: View {
    var botID: String
    @EnvironmentObject private var store: ChatStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var password = ""
    @State private var consent = false
    @State private var stopped = false
    @State private var exporting = false
    @State private var importing = false
    @State private var busy = false
    @State private var document = BackupDocument(data: Data())
    @State private var detail: String?
    var body: some View {
        Form {
            Text("Круглосуточный исполнитель в папке bot-worker использует официальный libsignal. Ему передаются только отдельные ключи, очередь и приватные адреса этого бота. Исполнитель читает сообщения, адресованные боту; доверяй его серверу и обработчику.").font(.caption)
            SecureField("Пароль файла, от 12 символов", text: $password)
            Toggle("Согласен передать ключи этого бота выбранному исполнителю", isOn: $consent)
            Button("Приостановить встроенный и сохранить файл") {
                busy = true
                Task { defer { busy = false }; do { document = BackupDocument(data: try await store.exportBotWorker(botID, password: password)); exporting = true; detail = "Встроенный исполнитель приостановлен. Повторное сохранение выдаёт исходный файл передачи; для восстановления используй последний файл с сервера." } catch { detail = error.localizedDescription } }
            }.disabled(!consent || password.count < 12 || busy)
            Toggle("Внешний процесс остановлен; выбираю его последний обновлённый файл", isOn: $stopped)
            Button("Вернуть выполнение на iPhone") { importing = true }.disabled(!stopped || password.count < 12 || busy)
            Text("Не запускай копии файла на разных компьютерах. Серверная аренда останавливает конкурирующий исполнитель; приватные адреса сохраняют независимые разрешения. Старый снимок файла не восстанавливает уже изменившуюся сессию.").font(.caption).foregroundStyle(.secondary)
            if let detail { Text(detail) }
        }.navigationTitle("Внешний исполнитель")
        .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: "VO1D-bot.vo1dbot") { result in if case .failure(let error) = result { detail = error.localizedDescription } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }; busy = true
            Task {
                defer { busy = false }; let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                do { let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0; guard size > 0, size <= 24*1024*1024 else { throw MessengerError.invalid("Файл больше 24 МБ") }; let data = try Data(contentsOf: url); try await store.importBotWorker(botID, data: data, password: password); detail = "Исполнитель возвращён на iPhone" } catch { detail = error.localizedDescription }
            }
        }
        .onChange(of: store.generation) { _, _ in clear() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { clear() } }
    }
    private func clear() { password = ""; consent = false; stopped = false; document = BackupDocument(data: Data()); exporting = false; importing = false; detail = nil }
}
