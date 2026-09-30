import Foundation
import CryptoKit
import Security

/// The background key has a signed call-only certificate and no account authority.
enum BackgroundCalls {
    static let service = "io.vo1d.messenger.calls.v3"
    struct Descriptor: Codable {
        var delegatedSigning: Data
        var certificate: CallAuthority
        var token: String
        var card: ContactCard
        var server: String
        var preferences: PrivacyPreferences
        var allowedIDs: [String]
        var blockedIDs: [String]
        var enabled: Bool
    }
    @MainActor static func prepare(_ store: ChatStore, api: APIClient) async throws {
        let expectedGeneration = store.generation, expectedProfile = store.profileID
        guard store.preferences.backgroundCalls, store.state.notificationsEnabled == true,
              let identity = store.identity, let card = store.ownCard else {
            clear()
            let _: APIClient.OK = try await api.request("v2/call-authority", method: "DELETE")
            return
        }
        if var existing = try? load(), existing.card == card, existing.server == api.base.absoluteString,
           existing.certificate.expiresAt > Int(Date().timeIntervalSince1970) + 3600 {
            existing.preferences = permissions(store.preferences,route:api.privacy)
            existing.allowedIDs = allowed(store); existing.blockedIDs = store.state.contacts.filter { $0.blocked }.map(\.id)
            try write(existing); return
        }
        let delegate = Curve25519.Signing.PrivateKey()
        var certificate = CallAuthority(owner: card.id, key: delegate.publicKey.rawRepresentation.base64EncodedString(), expiresAt: Int(Date().timeIntervalSince1970) + 23 * 3600)
        certificate.signature = try identity.signingPrivate.signature(for: certificate.bytes).base64EncodedString()
        struct Issued: Decodable { var token: String }
        let issued: Issued = try await api.request("v2/call-authority", method: "POST", body: Wire.encoder.encode(certificate))
        guard expectedGeneration == store.generation, expectedProfile == store.profileID,
              store.ownCard == card, store.preferences.backgroundCalls, store.state.notificationsEnabled == true else { throw CancellationError() }
        let descriptor = Descriptor(delegatedSigning: delegate.rawRepresentation, certificate: certificate, token: issued.token, card: card,
            server: api.base.absoluteString, preferences: permissions(store.preferences,route:api.privacy), allowedIDs: allowed(store), blockedIDs: store.state.contacts.filter { $0.blocked }.map(\.id), enabled: true)
        try write(descriptor)
    }
    private static func permissions(_ current: PrivacyPreferences, route: PrivacyPreferences) -> PrivacyPreferences {
        var result = current
        result.proxyEnabled = route.proxyEnabled; result.proxyUsesTor = route.proxyUsesTor
        result.proxyHost = route.proxyHost; result.proxyPort = route.proxyPort
        result.embeddedTor = route.embeddedTor; result.torBridges = route.torBridges
        result.streamIsolation = route.streamIsolation
        return result
    }
    @MainActor private static func allowed(_ store: ChatStore) -> [String] {
        store.extended.trustedIDs.filter { id in
            guard let contact = store.state.contacts.first(where: { $0.id == id }) else { return false }
            return !contact.blocked && (!store.preferences.verifiedOnlyCalls || contact.verified)
        }
    }
    @MainActor static func save(_ store: ChatStore) {
        // Remove the old full-account background signing key during migration.
        SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"io.vo1d.messenger.calls.v2"] as CFDictionary)
        guard store.preferences.backgroundCalls, store.state.notificationsEnabled == true,
              var descriptor = try? load(), descriptor.card == store.ownCard else { clear(); return }
        // Editing a route is not applying it. Background requests retain the last
        // authenticated route until prepare binds a successfully connected client.
        descriptor.preferences = permissions(store.preferences,route:descriptor.preferences); descriptor.allowedIDs = allowed(store)
        descriptor.blockedIDs = store.state.contacts.filter { $0.blocked }.map(\.id)
        try? write(descriptor)
    }
    private static func write(_ descriptor: Descriptor) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"calls"]
        let data = try Wire.encoder.encode(descriptor)
        let status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary,nil) == errSecSuccess else { throw MessengerError.invalid("Не удалось сохранить разрешение звонков") }
        } else if status != errSecSuccess { throw MessengerError.invalid("Keychain звонков недоступен") }
    }
    static func clear() {
        for oldService in [service,"io.vo1d.messenger.calls.v2"] {
            SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:oldService] as CFDictionary)
        }
    }
    static func load() throws -> Descriptor {
        var item: CFTypeRef?
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"calls",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary,&item) == errSecSuccess, let data = item as? Data else { throw MessengerError.invalid("Фоновое разрешение звонков недоступно") }
        let descriptor = try Wire.decoder.decode(Descriptor.self,from:data)
        let delegated = try descriptor.certificate.validate(for:descriptor.card)
        guard try Curve25519.Signing.PrivateKey(rawRepresentation:descriptor.delegatedSigning).publicKey.rawRepresentation == delegated.rawRepresentation else { throw MessengerError.invalid("Ключ разрешения звонков повреждён") }
        return descriptor
    }
    @MainActor static func resume(peerID: String) async {
        guard CallManager.shared.transport != "WSS" else { return }
        do {
            let descriptor = try load()
            guard descriptor.enabled else { return }
            let allowed: (String) -> Bool = { id in
                !descriptor.blockedIDs.contains(id) && (!descriptor.preferences.requireRequests || descriptor.allowedIDs.contains(id)) && (!descriptor.preferences.verifiedOnlyCalls || descriptor.allowedIDs.contains(id))
            }
            if !peerID.isEmpty, !allowed(peerID) { return }
            let identity = LocalIdentity(signing:descriptor.delegatedSigning,agreement:try Crypto.random(32),storage:try Crypto.random(32))
            let api = try APIClient(server:descriptor.server,identity:identity,privacy:descriptor.preferences,authenticationCard:descriptor.card,callToken:descriptor.token)
            CallManager.shared.allowedPeer = allowed
            CallManager.shared.configure(api:api,identity:identity,ownerCard:descriptor.card,nameResolver:{ _ in "VO1D" },recordSink:{ _ in })
        } catch { /* CallKit times out while chat keys remain protected. */ }
    }
}
