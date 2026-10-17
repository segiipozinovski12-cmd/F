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
    func selectPrivacyProfile(_ profile: PrivacyProfile) throws {
        var local = extended
        switch profile {
        case .everyday:
            local.privacy.discoverable = true; local.privacy.requirePrivateDelivery = false
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
    }
    func usePrivacyProfile(_ profile: PrivacyProfile) async throws {
        try selectPrivacyProfile(profile)
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
        case .privateDelivery: return "Только приватные приглашения: поиск по коду и username отключён. Скрывает отправителя в очереди; relay видит соединения и время."
        case .tor: return "Встроенный Tor и приватные приглашения без публичного поиска и APNs. Подключение медленнее, расход батареи выше; фоновые вызовы выключены."
        }
    }
    var tradeoffs: [String] {
        switch self {
        case .everyday: return []
        case .privateDelivery: return [
            "Тебя не найдут по четырёхсимвольному ID или @username. Для знакомства нужен QR или приватная ссылка.",
            "Обычная отправка запрещена: без приватного адреса получателя сообщение останется в очереди.",
            "Отметки доставки и индикатор набора выключены. Если push не включён отдельно, новые сообщения приходят при открытом VO1D.",
            "Этот режим сам по себе не скрывает IP: при прямом подключении узел видит адрес и время соединений. Tor выбирается отдельно."
        ]
        case .tor: return [
            "Поиск по ID и @username отключён. Обменивайся QR или приватными ссылками.",
            "Подключение и передача файлов могут идти дольше; возможны блокировки сети и больший расход батареи. При сбое Tor прямое подключение не включится.",
            "Push и фоновые звонки выключены. Для переписки и звонков держи VO1D открытым; звонкам через Tor может мешать задержка.",
            "Отметки доставки и набор выключены; очередь ждёт приватного адреса получателя. Включён экономный опрос раз в 8 секунд.",
            "Tor не защищает разблокированный телефон и не исключает анализ времени трафика. Внешние ссылки открываются отдельным браузером с его сетевыми настройками."
        ]
        }
    }
}

struct PrivacyTradeoffsView: View {
    let profile: PrivacyProfile
    var body: some View {
        if !profile.tradeoffs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Что изменится", systemImage: "info.circle.fill").font(.subheadline.bold())
                ForEach(profile.tradeoffs, id: \.self) { item in
                    HStack(alignment: .top, spacing: 9) {
                        Circle().fill(.white.opacity(0.5)).frame(width: 4, height: 4).padding(.top, 6)
                        Text(item).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .foregroundStyle(Theme.secondary)
            .padding(14).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
            .transition(.opacity.combined(with: .move(edge: .top)))
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
                Label(store.activeNetworkRoute,systemImage:store.api?.privacy.embeddedTor == true ? "network" : "point.3.connected.trianglepath.dotted")
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
                    Button { apply(profile) } label: { VStack(alignment:.leading,spacing:5) { Text(profile.title); Text(profile.detail).font(.caption).foregroundStyle(.secondary); PrivacyTradeoffsView(profile: profile) } }.disabled(applying)
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
