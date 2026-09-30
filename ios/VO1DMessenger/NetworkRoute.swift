import Foundation
import SwiftUI

extension ChatStore {
    func prepareNetworkRoute() async throws {
        if (preferences.embeddedTor || preferences.proxyUsesTor), preferences.streamIsolation.isEmpty {
            var local = extended; local.privacy.streamIsolation = try Crypto.random(24).base64URL; state.extended = local
            try save()
        }
        if preferences.embeddedTor {
            connection = "Tor подключается"
            try await EmbeddedTorManager.shared.start(bridges:preferences.torBridges)
        }
    }
    var configuredRoute: String {
        if preferences.embeddedTor { return EmbeddedTorManager.shared.ready ? "Tor · встроенный" : "Tor · подключается" }
        if preferences.proxyEnabled { return preferences.proxyUsesTor ? "Tor через внешний SOCKS5 · не проверен" : "SOCKS5 · \(preferences.proxyHost)" }
        return "Прямое соединение"
    }
    func usePrivacyProfile(_ profile: PrivacyProfile) async throws {
        var local = extended
        switch profile {
        case .everyday:
            local.privacy.requireRequests = true; local.privacy.typingSignals = false; local.privacy.notificationPreview = false
        case .privateDelivery:
            local.privacy.requirePrivateDelivery = true; local.privacy.discoverable = false
            local.privacy.requireRequests = true; local.privacy.typingSignals = false
            local.privacy.deliveryReceipts = false; local.privacy.notificationPreview = false
        case .tor:
            local.privacy.embeddedTor = true; local.privacy.requirePrivateDelivery = true
            local.privacy.discoverable = false; local.privacy.requireRequests = true
            local.privacy.typingSignals = false; local.privacy.deliveryReceipts = false
            local.privacy.lowData = true; local.privacy.backgroundCalls = false
            state.notificationsEnabled = false
        }
        state.extended = local; try save()
        try await reconfigureTransport(); try await applyPrivacy()
    }
}
enum PrivacyProfile: String, CaseIterable, Identifiable {
    case everyday, privateDelivery, tor
    var id: String { rawValue }
    var title: String {
        switch self { case .everyday: return "Повседневный"; case .privateDelivery: return "Приватная доставка"; case .tor: return "Tor и приватные адреса" }
    }
    var detail: String {
        switch self {
        case .everyday: return "Сохраняет выбранный маршрут. Новые сообщения используют libsignal; для первого контакта можно использовать код."
        case .privateDelivery: return "Требует приватного приглашения. Скрывает отправителя в очереди; relay продолжает видеть сетевые соединения и время."
        case .tor: return "Включает встроенный Tor, приватные адреса и работу без APNs. Подключение медленнее, расход батареи выше; фоновые вызовы выключены."
        }
    }
}
struct NetworkRouteView: View {
    @EnvironmentObject var store: ChatStore
    @ObservedObject private var tor = EmbeddedTorManager.shared
    @State private var relay = ""
    @State private var status = ""
    @State private var applying = false
    @State private var leaveProtection = false
    var body: some View {
        Form {
            Section("Маршрут сейчас") {
                Label(store.configuredRoute,systemImage:store.preferences.embeddedTor ? "network" : "point.3.connected.trianglepath.dotted")
                if store.preferences.embeddedTor { ProgressView(value:Double(tor.progress),total:100); Text(tor.status).font(.caption) }
                Text(store.api == nil ? "Запросы к relay не выполняются" : "Авторизация, сообщения, файлы и звонки используют одну конфигурацию маршрута. Внешний браузер и APNs используют сеть iOS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tor") {
                Toggle("Встроенный Tor",isOn:store.preferenceBinding(\.embeddedTor))
                TextEditor(text:store.preferenceBinding(\.torBridges)).frame(minHeight:80)
                Text("Необязательные обычные мосты: IPv4:порт и отпечаток, по одному на строку. obfs4 и Snowflake требуют отдельной интеграции. Мосты применяются при запуске Tor.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Relay") {
                TextField("https://relay.example или http://…onion",text:$relay).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("HTTP разрешён только для v3 onion при маршруте Tor. При сбое прокси или Tor прямое подключение не включается.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Профили") {
                ForEach(PrivacyProfile.allCases) { profile in
                    Button { apply(profile) } label: { VStack(alignment:.leading,spacing:5) { Text(profile.title); Text(profile.detail).font(.caption).foregroundStyle(.secondary) } }.disabled(applying)
                }
            }
            Section {
                Button("Применить маршрут") {
                    if store.api?.privacy.embeddedTor == true && !store.preferences.embeddedTor { leaveProtection = true }
                    else { reconnect() }
                }.disabled(applying)
                if !status.isEmpty { Text(status).font(.caption) }
            }
        }.navigationTitle("Сеть и защита")
        .onAppear { relay = store.state.server }
        .confirmationDialog("Перейти с Tor на выбранный маршрут?",isPresented:$leaveProtection,titleVisibility:.visible) {
            Button("Применить выбранный маршрут") { reconnect() }
        } message: { Text("При прямом подключении relay видит сетевой IP. Очередь сообщений сохранится.") }
    }
    private func reconnect() {
        applying = true
        Task {
            do {
                _ = try APIClient.validateURL(relay,privacy:store.preferences)
                store.state.server = relay; try store.save(); try await store.reconfigureTransport()
                status = "Подключено: \(store.configuredRoute)"
            } catch { status = error.localizedDescription }
            applying = false
        }
    }
    private func apply(_ profile: PrivacyProfile) {
        applying = true
        Task { do { try await store.usePrivacyProfile(profile); status = "Профиль применён" } catch { status = error.localizedDescription }; applying = false }
    }
}
