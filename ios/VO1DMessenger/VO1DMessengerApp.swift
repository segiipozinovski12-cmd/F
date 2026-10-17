import SwiftUI

@main
struct VO1DMessengerApp: App {
    @UIApplicationDelegateAdaptor(MessengerAppDelegate.self) var appDelegate
    @StateObject private var store = ChatStore()
    @StateObject private var calls = CallManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var leftAt: Date?

    init() {
        UITableView.appearance().backgroundColor = .clear
        UICollectionView.appearance().backgroundColor = .clear
        MediaFiles.clear()
        NotificationCoordinator.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(calls)
                .environment(\.voidPalette, store.appearance.appTheme.palette)
                .preferredColorScheme(.dark)
                .tint(store.appearance.appTheme.palette.accent)
                .buttonStyle(RoundedActionStyle())
                .buttonBorderShape(.capsule)
                .scrollContentBackground(.hidden)
                .presentationCornerRadius(30)
                .task {
                    PushCoordinator.shared.mailboxes = { store.extended.ownMailboxes }
                    PushCoordinator.shared.wake = {
                        await store.reloadProtectedData()
                        await store.connectProductionRelay()
                        await store.sync()
                    }
                    PushCoordinator.shared.openRoom = { id in store.notificationRoomID=id }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        NearbyTransport.shared.stop()
                        leftAt=Date()
                        store.revealedHiddenRooms=false
                        if store.state.appLock && store.preferences.autoLockSeconds==0 { store.locked=true }
                        if !store.busy && store.fatalError == nil { store.persist() }
                        MediaFiles.clear()
                    } else if phase == .active, store.state.appLock, let leftAt,
                        Date().timeIntervalSince(leftAt)>=Double(store.preferences.autoLockSeconds) {
                        store.locked=true
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var calls: CallManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var splash = true
    @State private var incomingContact: String?
    @State private var pendingLink: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var captured = UIScreen.main.isCaptured
    @ObservedObject private var network = NetworkState.shared
    private var canRunForegroundSession: Bool { scenePhase == .active && store.fatalError == nil && store.sessionUnlocked && !store.locked }

    var body: some View {
        ZStack {
            VoidBackground()

            Group {
                if splash {
                    SplashView()
                } else if let failure = store.fatalError {
                    ContentUnavailableView("Хранилище недоступно", systemImage: "lock.trianglebadge.exclamationmark", description: Text(failure))
                        .overlay(alignment: .bottom) {
                            Button("Повторить после разблокировки") {
                                Task { await store.reloadProtectedData() }
                            }.padding(32)
                        }
                } else if !store.state.onboarded {
                    WelcomeView()
                } else if store.state.credentialsAcknowledged != true {
                    CredentialRevealView()
                } else if !store.sessionUnlocked {
                    AccessKeyGateView()
                } else if store.locked {
                    BiometricGateView()
                } else if store.serverResetRequired {
                    VStack(spacing: 22) {
                        BrandMark(size: 90)
                        Text("Новый старт VO1D").font(.largeTitle.bold())
                        Text("Серверные аккаунты были сброшены. Локальная зашифрованная история, маршрут и выбранные разрешения поиска сохранятся. Режим защиты можно изменить в настройках после регистрации.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button(store.busy ? "Регистрируем…" : "Зарегистрироваться заново") {
                            Task {
                                await store.configure(name: store.state.nickname, server: store.state.server)
                            }
                        }.buttonStyle(PrimaryButton()).disabled(store.busy)
                    }.padding(28)
                } else {
                    MainShell().id(store.profileID).softAppear()
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.985)))

            if let call = calls.session {
                if calls.isCallScreenExpanded {
                    CallScreen(session: call)
                        .environmentObject(calls)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                        .zIndex(20)
                } else {
                    VStack(spacing: 0) {
                        CallMiniBanner(session: call)
                            .environmentObject(calls)
                        Spacer(minLength: 0)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(20)
                }
            }

            if calls.preparingCall && calls.session == nil && store.sessionUnlocked && !store.locked {
                VStack {
                    HStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Подключаем звонок…").font(.subheadline.weight(.semibold))
                    }.padding(18).background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }.padding(.top, 12).transition(.move(edge: .top).combined(with: .opacity)).zIndex(15)
            }

            if scenePhase == .background || (captured && store.preferences.protectRecording) {
                Color.black.ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 18) {
                            BrandMark(size: 88)
                            Text("VO1D").font(.headline.monospaced()).tracking(6)
                        }
                    }
                    .accessibilityLabel("Содержимое скрыто")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for:UIScreen.capturedDidChangeNotification)) { _ in captured=UIScreen.main.isCaptured }
        .environment(\.openURL,OpenURLAction { url in
            guard ["http","https"].contains(url.scheme?.lowercased() ?? ""), url.user==nil, url.password==nil else { return .discarded }
            let clean=store.preferences.cleanLinks ? SafeContent.cleanURL(url) : url
            if store.preferences.confirmLinks || store.preferences.proxyEnabled || store.preferences.embeddedTor || !SafeContent.linkWarnings(clean).isEmpty { pendingLink=clean; return .handled }
            return .systemAction(clean)
        })
        .confirmationDialog("Открыть внешний сайт?",isPresented:Binding(get:{ pendingLink != nil },set:{ if !$0 { pendingLink=nil } }),titleVisibility:.visible) {
            if let url=pendingLink { Button("Открыть \(url.host ?? "сайт")") { UIApplication.shared.open(url); pendingLink=nil } }
        } message: { Text((["Сайт увидит адрес подключения браузера. Прокси VO1D не распространяется на браузер."] + (pendingLink.map { SafeContent.linkWarnings($0) } ?? [])).joined(separator: "\n")) }
        .onOpenURL { url in
            if url.scheme=="vo1d", ["contact","invite","private"].contains(url.host ?? "") { incomingContact=url.absoluteString }
        }
        .sheet(isPresented:Binding(get:{ incomingContact != nil && store.sessionUnlocked && !store.locked },set:{ if !$0 { incomingContact=nil } })) {
            AddContactView(initialValue:incomingContact ?? "")
        }
        .sheet(isPresented:Binding(get:{ store.notificationRoomID != nil && store.sessionUnlocked && !store.locked },set:{ if !$0 { store.notificationRoomID=nil } })) {
            if let id=store.notificationRoomID, !store.extended.hiddenRooms.contains(id) { NavigationStack { ChatView(roomID:id) } }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: splash)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.38), value: store.sessionUnlocked)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: store.locked)
        .animation(reduceMotion ? nil : Motion.layout, value: calls.preparingCall)
        .transaction { transaction in
            // Hiding sensitive content never waits for an exit animation.
            if store.locked || !store.sessionUnlocked || reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .onChange(of: network.connected) { _, available in
            guard canRunForegroundSession, store.state.onboarded else { return }
            if available {
                store.resumeNetworkQueue()
                Task { await store.connectProductionRelay(); await store.sync() }
            } else { store.connection = "Нет сети · отправим автоматически" }
        }
        .onChange(of: calls.lastFailure) { _, value in if let value { store.error = value } }
        .onChange(of: store.locked) { _, locked in if locked { NearbyTransport.shared.stop() } }
        .task {
            try? await Task.sleep(for: .milliseconds(650))
            splash = false
        }
        .alert("VO1D", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Понятно") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
        .task(id: canRunForegroundSession) {
            guard scenePhase == .active else { return }
            await store.reloadProtectedData()
            guard !Task.isCancelled, canRunForegroundSession else { return }
            store.beginActiveSession()
            NotificationCoordinator.shared.clearDelivered()

            if store.state.onboarded {
                await store.connectProductionRelay()
            }

            while !Task.isCancelled {
                if store.state.onboarded && store.sessionUnlocked && !store.locked && !store.busy {
                    if store.api == nil { await store.connectProductionRelay() }
                    await store.sync()
                }
                try? await Task.sleep(for: .seconds(store.preferences.lowData ? 8 : 2))
            }
        }
    }
}

private struct MainShell: View {
    @Environment(\.voidPalette) private var palette
    var body: some View {
        TabView {
            InboxView()
                .tabItem { Label("Чаты", systemImage: "bubble.left.and.bubble.right.fill") }
            ContactsView()
                .tabItem { Label("Люди", systemImage: "person.2.fill") }
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "slider.horizontal.3") }
        }
        .toolbarBackground(palette.background.opacity(0.98), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

private struct CredentialRevealView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var entered = false

    var body: some View {
        ZStack {
            VoidBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Wordmark(compact: true)
                        Spacer()
                        Text("IDENTITY READY").font(.caption2.monospaced()).tracking(2).foregroundStyle(Theme.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Твои два ключа.")
                            .font(.system(size: 39, weight: .black, design: .rounded))
                            .tracking(-1.5)
                        Text("Сейчас они показываются один раз. После этого — только в настройках.")
                            .foregroundStyle(Theme.secondary)
                            .lineSpacing(4)
                    }

                    credential(title: "VO1D ID", value: store.state.publicCode ?? "----", detail: "4 символа · по нему тебя находят друзья")
                    credential(title: "КЛЮЧ ДОСТУПА", value: store.state.accessKey ?? "---------", detail: "9 символов · нужен для входа в приложение")

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.shield.fill")
                        Text("Сохрани ключ доступа отдельно. Он не заменяет криптографические ключи и не восстанавливает аккаунт на другом устройстве.")
                            .font(.caption).foregroundStyle(Theme.secondary).lineSpacing(4)
                    }
                    .panel()

                    Button("Я СОХРАНИЛ КЛЮЧИ") {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) { entered = true }
                        store.acknowledgeCredentials()
                        if store.state.notificationsEnabled == nil && store.preferences.allowDiscoveryRequests {
                            Task { await store.setNotifications(true) }
                        }
                    }
                    .buttonStyle(PrimaryButton())
                }
                .padding(26)
                .padding(.top, 14)
                .opacity(entered ? 0 : 1)
            }
        }
    }

    private func credential(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.caption2.monospaced()).tracking(2.4).foregroundStyle(Theme.secondary)
                Spacer()
                Image(systemName: "key.fill").foregroundStyle(.white.opacity(0.72))
            }
            Text(value)
                .font(.system(size: 31, weight: .black, design: .monospaced))
                .tracking(5)
                .textSelection(.enabled)
            Text(detail).font(.caption).foregroundStyle(Theme.secondary)
        }
        .panel()
    }
}

private struct AccessKeyGateView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var value = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            VoidBackground()
            VStack(spacing: 28) {
                Spacer()
                BrandMark(size: 116)
                VStack(spacing: 8) {
                    Text("ВОЙТИ В VO1D")
                        .font(.system(size: 27, weight: .black, design: .monospaced))
                        .tracking(5)
                    Text("9-символьный ключ доступа")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }

                SecureField("---------", text: $value)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .tracking(4)
                    .multilineTextAlignment(.center)
                    .keyboardType(.asciiCapable)
                    .privacySensitive()
                    .voidField()
                    .focused($focused)
                    .onChange(of: value) { _, newValue in
                        value = String(newValue.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(9))
                    }

                Button("ОТКРЫТЬ") {
                    if store.unlockWithAccessKey(value) { value = "" }
                }
                .buttonStyle(PrimaryButton())
                .disabled(value.count != 9)
                Spacer()
            }
            .padding(28)
        }
        .onAppear { focused = true }
    }
}

private struct BiometricGateView: View {
    @EnvironmentObject private var store: ChatStore
    var body: some View {
        ZStack {
            VoidBackground()
            VStack(spacing: 28) {
                BrandMark(size: 100)
                Text("Дополнительная защита")
                    .font(.title2.bold())
                Button("Открыть через устройство", systemImage: "faceid") {
                    Task { await store.unlock() }
                }
                .buttonStyle(PrimaryButton())
            }
            .padding(32)
        }
    }
}
