import Foundation
import Security
import SwiftUI

enum ProfileScope: String, Codable, CaseIterable, Identifiable {
    case general, contact, group
    var id: String { rawValue }
    var title: String {
        switch self { case .general: return "Обычная личность"; case .contact: return "Только один контакт"; case .group: return "Только одна группа" }
    }
}
struct LocalProfile: Codable, Identifiable, Hashable {
    var id: String
    var label: String
    var scope: ProfileScope? = nil
    var boundID: String? = nil
}
struct ProfileRegistry: Codable {
    var activeID = "default"
    var profiles = [LocalProfile(id: "default", label: "Основная личность")]
    private static let service = "io.vo1d.messenger.profiles.v2"
    static func load() throws -> Self {
        var item: CFTypeRef?
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"index",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        let result = SecItemCopyMatching(query as CFDictionary,&item)
        if result == errSecItemNotFound { return Self() }
        guard result == errSecSuccess, let data = item as? Data else { throw MessengerError.invalid("Список личностей защищён Keychain") }
        let registry = try Wire.decoder.decode(Self.self,from:data)
        guard registry.profiles.contains(where: { $0.id == registry.activeID }), registry.profiles.count <= 12,
              Set(registry.profiles.map(\.id)).count == registry.profiles.count,
              registry.profiles.allSatisfy({ $0.id == "default" || UUID(uuidString: $0.id) != nil }) else { throw MessengerError.invalid("Повреждённый список личностей") }
        return registry
    }
    func save() throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:Self.service,kSecAttrAccount as String:"index"]
        let data = try Wire.encoder.encode(self)
        let status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary,nil) == errSecSuccess else { throw MessengerError.invalid("Не удалось сохранить список личностей") }
        } else if status != errSecSuccess { throw MessengerError.invalid("Список личностей недоступен") }
    }
}
extension ChatStore {
    func createProfile(label: String, scope: ProfileScope = .general) async throws {
        guard profileRegistry.profiles.count < 12 else { throw MessengerError.invalid("Доступно до 12 независимых личностей") }
        let cleaned = label.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 40 else { throw MessengerError.invalid("Укажи локальное имя до 40 символов") }
        let id = UUID().uuidString
        let newIdentity = try Keychain.load(profileID:id), newVault = try Vault(profileID:id)
        var initial = VaultState()
        initial.server = state.server
        var settings = preferences
        settings.streamIsolation = ""; settings.backgroundCalls = false
        if scope != .general { settings.discoverable = false; settings.requirePrivateDelivery = true }
        var local = ExtendedState(); local.privacy = settings; initial.extended = local
        try newVault.write(initial,key:newIdentity.storage)
        var registry = profileRegistry
        registry.profiles.append(LocalProfile(id:id,label:cleaned,scope:scope)); try registry.save(); profileRegistry = registry
        try await switchProfile(id)
    }
    func switchProfile(_ id: String) async throws {
        guard id != profileID else { return }
        guard profileRegistry.profiles.contains(where: { $0.id == id }) else { throw MessengerError.invalid("Личность отсутствует") }
        let nextIdentity = try Keychain.load(profileID:id), nextVault = try Vault(profileID:id)
        var nextState = try nextVault.read(key:nextIdentity.storage)
        if nextState.extended == nil { nextState.extended = ExtendedState() }
        try save()
        var registry = profileRegistry; registry.activeID = id; try registry.save()
        generation += 1
        CallManager.shared.disconnect(); api?.invalidate(); api = nil
        BackgroundCalls.clear(); MediaFiles.clear(); ResumableDownload.clear(); NotificationCoordinator.shared.clearAll()
        profileRegistry = registry; identity = nextIdentity; ownCard = try nextIdentity.card; vault = nextVault; state = nextState
        deliveryIssues = [:]; typing = [:]; activeRoomID = nil; notificationRoomID = nil
        revealedHiddenRooms = false; locked = state.appLock; sessionUnlocked = !state.onboarded; error = nil
        connection = state.onboarded ? "Подключение…" : "Новая независимая личность"
        if state.onboarded { await connectProductionRelay() }
    }
    func renameProfile(_ id: String, label: String) throws {
        let name = label.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, let index = profileRegistry.profiles.firstIndex(where: { $0.id == id }) else { throw MessengerError.invalid("Недействительное имя личности") }
        var registry = profileRegistry; registry.profiles[index].label = name
        try registry.save(); profileRegistry = registry
    }
    func deleteInactiveProfile(_ id: String) throws {
        guard id != profileID, profileRegistry.profiles.contains(where: { $0.id == id }) else { throw MessengerError.invalid("Сначала переключись на другую личность") }
        try Vault(profileID:id).delete(); try Keychain.delete(profileID:id)
        var registry = profileRegistry; registry.profiles.removeAll { $0.id == id }
        try registry.save(); profileRegistry = registry
    }
}
struct ProfilesView: View {
    @EnvironmentObject var store: ChatStore
    @State private var label = ""
    @State private var scope = ProfileScope.general
    @State private var busy = false
    @State private var deleting: LocalProfile?
    var body: some View {
        Form {
            Section("Независимые личности") {
                ForEach(store.profileRegistry.profiles) { profile in
                    HStack {
                        VStack(alignment:.leading,spacing:4) {
                            Text(profile.label)
                            Text((profile.scope ?? .general).title).font(.caption).foregroundStyle(.secondary)
                            if profile.id == store.profileID { Text("Сейчас активна").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if profile.id == store.profileID { Image(systemName:"checkmark.circle.fill") }
                        else {
                            Button("Открыть") { switchTo(profile.id) }.disabled(busy)
                            Button(role:.destructive) { deleting = profile } label: { Image(systemName:"trash") }.disabled(busy)
                        }
                    }
                }
                Text("У каждой личности свои ключи, контакты, история, очередь и настройки. Фоновые звонки и push доступны для активной личности. Общий IP и время переключения могут связывать профили на сервере.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Новая личность") {
                TextField("Локальное имя",text:$label)
                Picker("Назначение", selection:$scope) { ForEach(ProfileScope.allCases) { Text($0.title).tag($0) } }
                Text("Для одного контакта или группы создаются отдельные ключи и ID. Личность привязывается к первому принятому контакту или группе. Передай её новое приватное приглашение; старый публичный ID сюда не переносится.").font(.caption).foregroundStyle(.secondary)
                Button("Создать отдельные ключи") {
                    busy = true
                    Task {
                        do { try await store.createProfile(label:label,scope:scope); label = "" } catch { store.error = error.localizedDescription }
                        busy = false
                    }
                }.disabled(busy || label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.navigationTitle("Личности")
        .confirmationDialog("Удалить только эту локальную личность?",isPresented:Binding(get:{ deleting != nil },set:{ if !$0 { deleting = nil } }),titleVisibility:.visible) {
            if let profile = deleting {
                Button("Удалить \(profile.label)",role:.destructive) {
                    do { try store.deleteInactiveProfile(profile.id) } catch { store.error = error.localizedDescription }
                    deleting = nil
                }
            }
        } message: { Text("Ключи и локальная история выбранной личности исчезнут. Для удаления серверного аккаунта открой эту личность и используй удаление аккаунта.") }
    }
    private func switchTo(_ id: String) {
        busy = true
        Task { do { try await store.switchProfile(id) } catch { store.error = error.localizedDescription }; busy = false }
    }
}

extension ChatStore {
    var activeProfile: LocalProfile? { profileRegistry.profiles.first { $0.id == profileID } }
    func validateScopedContact(_ peerID: String) throws {
        if activeProfile?.scope == .contact, let bound = activeProfile?.boundID, bound != peerID {
            throw MessengerError.invalid("У этой личности один контакт. Создай другую личность для нового собеседника.")
        }
    }
    func validateScopedRoom(_ room: Room) throws {
        switch activeProfile?.scope ?? .general {
        case .general: return
        case .contact:
            guard !room.isGroup, let peer = room.members.first(where: { $0.id != myID }) else { throw MessengerError.invalid("Личность для одного контакта не участвует в группах") }
            try validateScopedContact(peer.id)
        case .group:
            guard room.isGroup, activeProfile?.boundID == nil || activeProfile?.boundID == room.id else { throw MessengerError.invalid("Эта личность используется только в своей группе") }
        }
    }
    func bindScopedID(_ id: String, scope: ProfileScope) throws {
        guard let index = profileRegistry.profiles.firstIndex(where: { $0.id == profileID }), profileRegistry.profiles[index].scope == scope else { return }
        if let bound = profileRegistry.profiles[index].boundID {
            guard bound == id else { throw MessengerError.invalid("Личность уже привязана к другому чату") }; return
        }
        var registry = profileRegistry; registry.profiles[index].boundID = id
        try registry.save(); profileRegistry = registry
    }
}
