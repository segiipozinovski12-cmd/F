import Foundation
import SwiftUI

enum GhostText {
    static func key(_ message: ChatMessage) -> String { message.sender + "|" + message.roomID + "|" + message.id }
    static func consume(_ id: String, state: inout VaultState, now: Date = Date()) throws -> (String, Int) {
        guard let index = state.messages.firstIndex(where: { $0.id == id }), let seconds = state.messages[index].viewOnceSeconds,
              (1...120).contains(seconds), state.messages[index].openedAt == nil,
              let expiry = state.messages[index].expiresAt, expiry > now else { throw MessengerError.invalid("Одноразовый текст уже открыт или истёк") }
        let message = state.messages[index]
        var local = state.extended ?? ExtendedState()
        local.consumedGhosts = local.consumedGhosts.filter { $0.value > now }
        guard local.consumedGhosts[key(message)] == nil, local.consumedGhosts.count < 5000 else { throw MessengerError.invalid("Повторное открытие запрещено или заполнен журнал одноразовых сообщений") }
        local.consumedGhosts[key(message)] = expiry
        local.ocrText[id] = nil; local.bookmarks.removeAll { $0 == id }; local.protectedMessages.removeAll { $0 == id }
        state.extended = local
        state.messages[index].text = ""; state.messages[index].editHistory = nil; state.messages[index].openedAt = now
        return (message.text, seconds)
    }
}

extension ChatStore {
    func consumeGhost(_ id: String) throws -> (String, Int) {
        guard !locked else { throw MessengerError.invalid("Хранилище заблокировано") }
        let previous = state
        let result = try GhostText.consume(id, state: &state)
        // Remove the persistent cleartext before handing it to the presentation.
        do { try save() } catch { state = previous; throw error }
        return result
    }
}

struct GhostTextView: View {
    var messageID: String
    @EnvironmentObject private var store: ChatStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var clear = ""
    @State private var showing = false
    @State private var deadline: Date?
    @State private var failure: String?
    private var message: ChatMessage? { store.state.messages.first { $0.id == messageID } }
    var body: some View {
        Button(message?.openedAt == nil ? "Открыть одноразовый текст" : "Текст уже открыт", systemImage: "eye.slash") {
            do {
                let content = try store.consumeGhost(messageID)
                clear = content.0; deadline = Date().addingTimeInterval(Double(content.1)); showing = true
            } catch { failure = error.localizedDescription }
        }.disabled(message?.openedAt != nil || store.locked)
            .sheet(isPresented: $showing, onDismiss: erase) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Закрытие окна или уход в фон завершает просмотр. Содержимое больше не хранится в истории приложения.").font(.caption)
                            Text(clear).font(.body).privacySensitive()
                            if let deadline { Text(deadline, style: .timer).font(.caption.monospaced()) }
                        }.padding()
                    }.navigationTitle("Одноразовый текст")
                        .toolbar { Button("Закрыть") { erase() } }
                }
            }
            .task(id: deadline) {
                guard let deadline else { return }
                do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
                erase()
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { erase() } }
            .onChange(of: store.generation) { _, _ in erase() }
            .onChange(of: store.locked) { _, locked in if locked { erase() } }
            .onDisappear { erase() }
            .alert("Не удалось открыть", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
    }
    private func erase() { clear = ""; deadline = nil; showing = false }
}
