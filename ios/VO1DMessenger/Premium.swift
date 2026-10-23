import SwiftUI
import StoreKit
import Speech

struct PremiumPlanView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var product: Product?
    @State private var busy = false
    @State private var loading = true
    @State private var notice: String?
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "sparkles")
                    .font(.system(size: 66, weight: .light)).foregroundStyle(LinearGradient(colors: [.white, .artifactHex(0xB69CE9)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 140, height: 140).background(RadialGradient(colors: [.artifactHex(0x6A458C).opacity(0.3), .clear], center: .center, startRadius: 0, endRadius: 90), in: Circle())
                VStack(spacing: 10) {
                    Text("VO1D_PREMIUM").font(.system(size: 26, weight: .bold, design: .rounded)).tracking(-0.5)
                    Text(store.hasPremium ? "Твоё пространство. Без границ." : "Больше выразительности.\nМеньше лишних действий.").font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if let notice { EconomyNotice(message: notice) }
                if store.hasPremium { NavigationLink { PremiumWorkspaceView() } label: { Label("Открыть возможности Premium", systemImage: "sparkles") }.buttonStyle(PrimaryButton()) }
                VStack(spacing: 24) {
                    feature("waveform", title: "Голос в текст", detail: "Расшифровка голосовых прямо в чате без отдельной оплаты. Аудио обрабатывается на устройстве и не загружается на сервер.")
                    feature("globe", title: "Перевод сообщений", detail: "Переводи текст из меню сообщения. Локальные языковые модели Apple, выбор языка и копирование результата. Требуется iOS 18 или новее.")
                    feature("folder.badge.gearshape", title: "Умные папки", detail: "Автоматически собирай личные чаты, группы и каналы. Добавляй условия по непрочитанным, уведомлениям и вложениям; исключай отдельные беседы.")
                    feature("tag", title: "Теги Избранного", detail: "Свои цветные теги, несколько тегов на сообщение и быстрый фильтр в Избранном. Всё хранится в твоём зашифрованном хранилище.")
                    feature("text.bubble", title: "Ответы с подстановками", detail: "До 100 готовых ответов. Команды /shortcut, имя собеседника, твоя подпись, текущая дата и время — сразу в поле ввода.")
                    feature("paintpalette", title: "Особенные темы", detail: "Шесть палитр: Aurora, Ember, Frost, Rose, Cobalt и Gold.")
                    feature("person.crop.rectangle", title: "Обложки профиля", detail: "Шесть дополнительных обложек с мягкими градиентами и орбитами.")
                    feature("moon.stars", title: "Статус с характером", detail: "Восемь значков настроения. Оставь навсегда или выбери, когда он исчезнет.")
                    feature("square.grid.3x3", title: "Обои для каждой беседы", detail: "Сетка, орбиты и кристаллы. Общий фон или отдельный рисунок для каждого чата.")
                    feature("seal", title: "Знак Premium", detail: "Аккуратный значок подписчика в твоём профиле.")
                }
                if store.hasPremium {
                    HStack(spacing: 12) {
                        NavigationLink { ProfileEditorView() } label: { Label("Мой стиль", systemImage: "person.crop.circle") }.buttonStyle(GhostButton())
                        NavigationLink { AppearanceSettingsView() } label: { Label("Темы", systemImage: "paintpalette") }.buttonStyle(GhostButton())
                    }
                    if store.coinWallet?.premiumLifetime == true {
                        Label("Premium навсегда · Основатель", systemImage: "crown.fill").foregroundStyle(Color.artifactHex(0xDDBB7D))
                    } else {
                        Label("Подписка активна", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        if let until = store.coinWallet?.premiumUntil { Text("Оплачено до \(Date(timeIntervalSince1970: Double(until)).formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                        Link("Управлять подпиской", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                    }
                } else if let product, store.canStartApplePayment {
                    Button("Подключить · \(product.displayPrice) / месяц") {
                        busy = true; notice = nil
                        Task {
                            defer { busy = false }
                            do { try await store.buyStoreProduct(product) }
                            catch is CancellationError { return }
                            catch { notice = error.localizedDescription }
                        }
                    }.buttonStyle(PrimaryButton()).disabled(busy)
                } else if loading { ProgressView() }
                else { Text(store.canStartApplePayment ? "Подписка появится после настройки товаров App Store." : "Оплата Apple ещё не подключена администратором. Списание пока недоступно.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                if !loading { Button("Обновить доступность") { Task { await load() } }.font(.caption).disabled(busy) }
                Button("Восстановить подписку") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await AppStore.sync(); await store.recoverStorePurchases() }
                        catch { notice = error.localizedDescription }
                    }
                }.disabled(busy)
                Text(store.coinWallet?.premiumLifetime == true ? "Бессрочный доступ выдан основателю VO1D. Он не зависит от подписки App Store." : "Ежемесячная подписка продлевается автоматически, пока ты её не отменишь в App Store. Итоговая цена указана в валюте твоего региона. Для локальной расшифровки требуется языковая модель iOS.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    NavigationLink("Условия") { TermsView() }
                    Text("·").foregroundStyle(.secondary)
                    NavigationLink("Конфиденциальность") { PrivacyPolicyView() }
                }.font(.caption)
            }.padding(24)
        }.background { VoidBackground() }.navigationTitle("Premium").navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .overlay { if busy { ProgressView().padding(24).background(.ultraThinMaterial, in: Circle()) } }
    }
    private func load() async {
        loading = true; notice = nil; product = nil
        defer { loading = false }
        let fence = store.sessionFence
        do {
            try await store.refreshEconomy()
            guard store.canStartApplePayment, let id = store.economy.catalog?.premiumProduct else { return }
            let products = try await Product.products(for: [id])
            try store.requireCurrentSession(fence); product = products.first
        } catch is CancellationError { return }
        catch { notice = error.localizedDescription }
    }
    private func feature(_ icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.artifactHex(0xC9B6EF)).frame(width: 48, height: 48).background(.white.opacity(0.045), in: Circle())
            VStack(alignment: .leading, spacing: 7) { Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary).lineSpacing(3) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
final class PremiumTranscriber: ObservableObject {
    @Published var text = ""
    @Published var busy = false
    @Published var failure: String?
    private var recognition: SFSpeechRecognitionTask?
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var file: URL?
    private var continuation: CheckedContinuation<String, Error>?

    func start(data: Data, locale: Locale, store: ChatStore) {
        guard !busy else { return }
        busy = true; failure = nil
        let fence = store.sessionFence
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                guard let api = store.api, !store.locked, store.sessionUnlocked else { throw MessengerError.invalid("Подключись к VO1D") }
                // Entitlement is checked by the server on every new transcription.
                let _: APIClient.OK = try await api.request("v3/economy/transcription-authorize", method: "POST", body: Data("{}".utf8))
                try store.requireCurrentSession(fence)
                let permission = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
                try store.requireCurrentSession(fence); try Task.checkCancellation()
                guard permission == .authorized else { throw MessengerError.invalid("Разреши распознавание речи в настройках iOS") }
                guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
                    throw MessengerError.invalid("Для этого языка недоступна локальная модель речи. Выбери другой язык в меню расшифровки.")
                }
                let url = try MediaFiles.transientURL()
                try data.write(to: url, options: [.atomic, .completeFileProtection]); file = url
                defer { removeFile() }
                let request = SFSpeechURLRecognitionRequest(url: url)
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = false
                let transcript: String = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { pending in
                        if Task.isCancelled { pending.resume(throwing: CancellationError()); return }
                        continuation = pending
                        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                if let error { finish(.failure(error)) }
                                else if let result, result.isFinal { finish(.success(result.bestTranscription.formattedString)) }
                            }
                        }
                        timeout = Task { @MainActor [weak self] in
                            do { try await Task.sleep(for: .seconds(90)) } catch { return }
                            self?.finish(.failure(MessengerError.invalid("Распознавание заняло слишком много времени. Попробуй ещё раз.")))
                        }
                    }
                } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
                try store.requireCurrentSession(fence)
                guard !store.locked, store.sessionUnlocked else { throw CancellationError() }
                text = transcript.isEmpty ? "Речь не распознана" : transcript
            } catch is CancellationError { return }
            catch { failure = error.localizedDescription }
        }
    }
    func cancel() { operation?.cancel(); operation = nil; finish(.failure(CancellationError())); removeFile(); text = ""; busy = false }
    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        recognition?.cancel(); recognition = nil
        continuation.resume(with: result)
    }
    private func removeFile() { if let file { try? FileManager.default.removeItem(at: file) }; file = nil }
}

struct PremiumTranscriptView: View {
    var data: Data
    var tint: Color
    @EnvironmentObject private var store: ChatStore
    @StateObject private var transcriber = PremiumTranscriber()
    @State private var plan = false
    @State private var locale = Locale.current.identifier
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button {
                    if store.hasPremium { transcribe() } else { plan = true }
                } label: { Label(transcriber.busy ? "Распознаём…" : "В текст", systemImage: transcriber.busy ? "hourglass" : "text.bubble") }
                    .font(.caption.bold()).buttonStyle(MotionButtonStyle()).disabled(transcriber.busy)
                Spacer(minLength: 4)
                Menu {
                    ForEach([("ru-RU", "Русский"), ("en-US", "English"), ("uk-UA", "Українська"), ("de-DE", "Deutsch"), ("es-ES", "Español"), ("fr-FR", "Français"), ("it-IT", "Italiano"), ("pt-BR", "Português")], id: \.0) { item in
                        Button(item.1) { locale = item.0; if store.hasPremium { transcribe() } else { plan = true } }
                    }
                } label: { Image(systemName: "globe").font(.caption).frame(width: 30, height: 30) }.disabled(transcriber.busy).accessibilityLabel("Язык расшифровки")
            }
            if !transcriber.text.isEmpty { Text(transcriber.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if let failure = transcriber.failure { Text(failure).font(.caption).opacity(0.8) }
        }.foregroundStyle(tint)
        .sheet(isPresented: $plan) { NavigationStack { PremiumPlanView().toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { plan = false } } } } }
        .onDisappear { transcriber.cancel() }
        .onChange(of: store.locked) { _, value in if value { transcriber.cancel() } }
        .onChange(of: store.profileID) { _, _ in transcriber.cancel() }
    }
    private func transcribe() { transcriber.start(data: data, locale: Locale(identifier: locale), store: store) }
}
