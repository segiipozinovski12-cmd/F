import Foundation
import CryptoKit
import Security

/// Background calls need signing authority, not the message agreement or vault key.
enum BackgroundCalls {
    static let service = "io.vo1d.messenger.calls.v2"
    struct Descriptor: Codable {
        var signing: Data
        var card: ContactCard
        var server: String
        var preferences: PrivacyPreferences
        var allowedIDs: [String]
        var blockedIDs: [String]? = nil
        var enabled: Bool
    }

    @MainActor static func save(_ store: ChatStore) {
        guard store.preferences.backgroundCalls,store.state.notificationsEnabled==true,
              let identity=store.identity,let card=store.ownCard else { clear(); return }
        let allowed=store.extended.trustedIDs.filter { id in
            guard let contact=store.state.contacts.first(where: { $0.id==id }) else { return false }
            return !contact.blocked && (!store.preferences.verifiedOnlyCalls || contact.verified)
        }
        do {
            let descriptor=Descriptor(signing:identity.signing,card:card,server:store.state.server,
                preferences:store.preferences,allowedIDs:allowed,blockedIDs:store.state.contacts.filter { $0.blocked }.map(\.id),enabled:true)
            let query: [String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"calls"]
            let data=try Wire.encoder.encode(descriptor)
            let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
            if status==errSecItemNotFound {
                var insert=query
                insert[kSecValueData as String]=data
                insert[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                _=SecItemAdd(insert as CFDictionary,nil)
            }
        } catch { /* History protection is not weakened if call preparation fails. */ }
    }

    static func clear() {
        SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service] as CFDictionary)
    }

    static func load() throws -> Descriptor {
        var item: CFTypeRef?
        let query: [String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
            kSecAttrAccount as String:"calls",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary,&item)==errSecSuccess,let data=item as? Data else {
            throw MessengerError.invalid("Фоновый доступ звонков недоступен")
        }
        let descriptor=try Wire.decoder.decode(Descriptor.self,from:data)
        try Crypto.validate(descriptor.card)
        guard Crypto.hex(CryptoKit.SHA256.hash(data:try Curve25519.Signing.PrivateKey(rawRepresentation:descriptor.signing).publicKey.rawRepresentation))==descriptor.card.id else {
            throw MessengerError.invalid("Ключ звонков повреждён")
        }
        return descriptor
    }

    @MainActor static func resume(peerID: String) async {
        guard CallManager.shared.transport != "WSS" else { return }
        do {
            let descriptor=try load()
            guard descriptor.enabled,!(descriptor.blockedIDs ?? []).contains(peerID),(!descriptor.preferences.requireRequests || descriptor.allowedIDs.contains(peerID)),(!descriptor.preferences.verifiedOnlyCalls || descriptor.allowedIDs.contains(peerID)) else { return }
            // Dummy values are not persisted and never authenticate message decryption.
            let identity=LocalIdentity(signing:descriptor.signing,agreement:try Crypto.random(32),storage:try Crypto.random(32))
            let api=try APIClient(server:descriptor.server,identity:identity,privacy:descriptor.preferences,authenticationCard:descriptor.card)
            try await api.authenticate()
            CallManager.shared.allowedPeer={ id in !(descriptor.blockedIDs ?? []).contains(id) && (!descriptor.preferences.requireRequests || descriptor.allowedIDs.contains(id)) && (!descriptor.preferences.verifiedOnlyCalls || descriptor.allowedIDs.contains(id)) }
            CallManager.shared.configure(api:api,identity:identity,nameResolver:{ _ in "VO1D" },recordSink:{ _ in })
        } catch { /* CallKit times out without exposing protected chat keys. */ }
    }
}
