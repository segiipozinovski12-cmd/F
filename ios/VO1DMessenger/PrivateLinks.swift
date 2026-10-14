import Foundation
import CryptoKit
import SwiftUI

struct PrivateLinkRecord: Codable, Identifiable {
    var token: String
    var key: Data
    var ciphertext: Data
    var mailboxID: String
    var expiresAt: Int
    var published = false
    var revocationPending = false
    var failure: String? = nil
    var nextAttempt: Date? = nil
    var stopped: Bool? = nil
    var id: String { token }
    var url: String { "vo1d://private/\(token)/\(key.base64URL)" }
    static func create(invitation: Invite, mailbox: LocalMailbox) throws -> Self {
        let token = try Crypto.random(32).base64URL, key = try Crypto.random(32)
        let box = try AES.GCM.seal(Wire.encoder.encode(invitation), using: SymmetricKey(data: key), authenticating: Data("VO1D-PRIVATE-INVITE-2\n\(token)".utf8))
        guard let encrypted = box.combined else { throw MessengerError.invalid("Ошибка приглашения") }
        return Self(token: token, key: key, ciphertext: encrypted, mailboxID: mailbox.id, expiresAt: min(mailbox.address.expiresAt, Int(Date().timeIntervalSince1970) + 3600))
    }
}

extension ChatStore {
    func flushPrivateLinks(api: APIClient, generation expected: Int) async throws {
        var local = extended
        local.privateLinks.removeAll { $0.expiresAt <= Int(Date().timeIntervalSince1970) }
        state.extended = local
        for record in extended.privateLinks.filter({ (!$0.published || $0.revocationPending) && $0.stopped != true && ($0.nextAttempt ?? .distantPast) <= Date() }).prefix(8) {
            guard expected == generation, !locked, let mailbox = extended.ownMailboxes.first(where: { $0.id == record.mailboxID }) else { return }
            do {
                if record.revocationPending { try await api.revokePrivateInvite(record.token, mailbox: mailbox) }
                else { try await api.publishPrivateInvite(token: record.token, ciphertext: record.ciphertext, mailbox: mailbox, expiresAt: record.expiresAt) }
            } catch {
                guard expected == generation, !locked else { throw CancellationError() }
                local = extended
                if let index = local.privateLinks.firstIndex(where: { $0.id == record.id }) {
                    local.privateLinks[index].failure = error.localizedDescription
                    local.privateLinks[index].nextAttempt = Date().addingTimeInterval(60)
                    local.privateLinks[index].stopped = (error as? HTTPFailure).map { [400,403,404,409,413].contains($0.status) } ?? false
                }
                state.extended = local; try save(); continue
            }
            guard expected == generation, !locked else { throw CancellationError() }
            local = extended
            if record.revocationPending { local.privateLinks.removeAll { $0.id == record.id } }
            else if let index = local.privateLinks.firstIndex(where: { $0.id == record.id }) { local.privateLinks[index].published = true; local.privateLinks[index].failure = nil; local.privateLinks[index].nextAttempt = nil }
            state.extended = local; try save()
        }
    }
    func revokePrivateLink(_ id: String, botID: String? = nil) throws {
        guard !locked else { throw MessengerError.invalid("Хранилище заблокировано") }
        if let botID {
            guard !botsSyncing, let bot = state.managedBots?.first(where: { $0.id == botID }) else { throw MessengerError.invalid("Дождись завершения работы бота") }
            let worker = try NativeBotWorker(bot: bot, preferences: preferences)
            defer { worker.api.invalidate() }
            if let index = worker.state.extended?.privateLinks.firstIndex(where: { $0.id == id }) {
                worker.state.extended?.privateLinks[index].revocationPending = true; try worker.save()
                worker.state.extended?.privateLinks[index].stopped = false; worker.state.extended?.privateLinks[index].nextAttempt = nil; try worker.save()
            }
        } else {
            var local = extended
            if let index = local.privateLinks.firstIndex(where: { $0.id == id }) { local.privateLinks[index].revocationPending = true; local.privateLinks[index].stopped = false; local.privateLinks[index].nextAttempt = nil }
            local.privateInviteLink = nil; local.privateInvite = nil
            state.extended = local; try save()
        }
        Task { await sync() }
    }
    func privateLinks(botID: String?) throws -> [PrivateLinkRecord] {
        guard !locked else { return [] }
        if let botID {
            guard let bot = state.managedBots?.first(where: { $0.id == botID }) else { return [] }
            let worker = try NativeBotWorker(bot: bot, preferences: preferences)
            defer { worker.api.invalidate() }
            return worker.state.extended?.privateLinks ?? []
        }
        return extended.privateLinks
    }
    func prepareBotPrivateInvite(_ id: String) async throws {
        guard !locked, !botsSyncing, let bot = state.managedBots?.first(where: { $0.id == id && $0.registered && $0.enabled }) else { throw MessengerError.invalid("Бот должен быть включён и свободен; повтори после синхронизации") }
        botsSyncing = true
        defer { botsSyncing = false }
        let expected = generation
        let worker = try NativeBotWorker(bot: bot, preferences: preferences)
        defer { worker.api.invalidate() }
        try await worker.preparePrivateInvite { expected == self.generation && !self.locked && !Task.isCancelled && self.state.managedBots?.contains(where: { $0.id == id && $0.enabled && $0.token == bot.token }) == true }
    }
}

struct PrivateLinksView: View {
    var botID: String? = nil
    @EnvironmentObject private var store: ChatStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var links: [PrivateLinkRecord] = []
    @State private var failure: String?
    @State private var working = false
    var body: some View {
        List {
            Section {
                Text("Одноразовая ссылка действует час. Отзыв прекращает получение приглашения после подтверждения relay; до этого он остаётся в очереди. Уже полученный адрес чата отзывается отдельно в профиле контакта.").font(.caption)
                Button("Создать приватную ссылку") {
                    let current = store.generation
                    working = true
                    Task {
                        defer { working = false }
                        do {
                            if let botID { try await store.prepareBotPrivateInvite(botID) } else { try await store.preparePrivateInvite() }
                            guard current == store.generation, !store.locked, scenePhase == .active else { return }
                            reload()
                        } catch { if current == store.generation, !store.locked { failure = error.localizedDescription; reload() } }
                    }
                }.disabled(working)
                Button("Обновить и отправить очередь") { Task { await store.sync(); reload() } }
            }
            ForEach(links) { link in
                Section("До \(Date(timeIntervalSince1970: Double(link.expiresAt)).formatted())") {
                    Text(link.revocationPending ? "Отзыв ожидает связи" : (link.published ? "Опубликована · одноразовая" : "Ожидает публикации"))
                    if let failure = link.failure { Text(failure).font(.caption) }
                    if link.published && !link.revocationPending && link.expiresAt > Int(Date().timeIntervalSince1970) {
                        QRCodeView(text: link.url).frame(maxWidth: 240)
                        ShareLink(item: link.url) { Label("Поделиться ссылкой", systemImage: "square.and.arrow.up") }
                        Button("Скопировать на 30 секунд") { SafeContent.copy(link.url, seconds: 30) }
                    }
                    Button("Отозвать ссылку", role: .destructive) {
                        do { try store.revokePrivateLink(link.id, botID: botID); reload() } catch { failure = error.localizedDescription }
                    }.disabled(link.revocationPending)
                }
            }
            if let failure { Text(failure) }
        }.navigationTitle(botID == nil ? "Приватные ссылки" : "Ссылки бота")
            .task { reload() }
            .onChange(of: store.generation) { _, _ in links = []; failure = nil }
            .onChange(of: store.locked) { _, locked in if locked { links = [] } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { links = [] } else { reload() } }
    }
    private func reload() {
        guard !store.locked, scenePhase == .active else { links = []; return }
        do { links = try store.privateLinks(botID: botID) } catch { failure = error.localizedDescription }
    }
}
