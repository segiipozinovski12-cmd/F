import SwiftUI

@main
struct VO1DMessengerApp: App {
    @StateObject private var store = ChatStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).preferredColorScheme(.dark).tint(.white)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        if store.state.appLock { store.locked = true }
                        store.persist()
                        MediaFiles.clear()
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.scenePhase) var scenePhase
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let failure = store.fatalError {
                ContentUnavailableView("Хранилище недоступно", systemImage: "lock.trianglebadge.exclamationmark", description: Text(failure))
            } else if !store.state.onboarded {
                WelcomeView()
            } else if store.locked {
                VStack(spacing: 28) {
                    BrandMark(size: 100)
                    Text("Только для тебя.").font(.largeTitle.bold())
                    Button("Открыть VO1D", systemImage: "faceid") { Task { await store.unlock() } }.buttonStyle(PrimaryButton())
                }.padding(32)
            } else {
                TabView {
                    InboxView().tabItem { Label("Чаты", systemImage: "bubble.left.and.bubble.right") }
                    ContactsView().tabItem { Label("Контакты", systemImage: "person.2") }
                    SettingsView().tabItem { Label("Профиль", systemImage: "person.crop.circle") }
                }.toolbarBackground(Theme.background, for: .tabBar).toolbarBackground(.visible, for: .tabBar)
            }
            if scenePhase != .active {
                Theme.background.ignoresSafeArea().overlay { BrandMark(size: 90) }.accessibilityLabel("Содержимое скрыто")
            }
        }
        .alert("VO1D", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Понятно") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.sync()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
