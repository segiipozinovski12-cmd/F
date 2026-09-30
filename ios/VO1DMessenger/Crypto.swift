import Foundation
import CryptoKit
import Security

struct LocalIdentity: Codable {
    let signing: Data
    let agreement: Data
    let storage: Data
    static func create() throws -> LocalIdentity {
        LocalIdentity(signing: Curve25519.Signing.PrivateKey().rawRepresentation,
                      agreement: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
                      storage: try Crypto.random(32))
    }
    var signingPrivate: Curve25519.Signing.PrivateKey { get throws { try .init(rawRepresentation: signing) } }
    var agreementPrivate: Curve25519.KeyAgreement.PrivateKey { get throws { try .init(rawRepresentation: agreement) } }
    var card: ContactCard {
        get throws {
            let sign = try signingPrivate
            let signData = sign.publicKey.rawRepresentation
            var card = ContactCard(id: Crypto.hex(SHA256.hash(data: signData)), signingKey: signData.base64EncodedString(),
                                   agreementKey: try agreementPrivate.publicKey.rawRepresentation.base64EncodedString(), binding: "")
            card.binding = try sign.signature(for: Crypto.cardBytes(card)).base64EncodedString()
            return card
        }
    }
}

enum Crypto {
    static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw MessengerError.invalid("Не удалось получить безопасные случайные данные")
        }
        return Data(bytes)
    }
    static func hex<D: Sequence>(_ data: D) -> String where D.Element == UInt8 {
        data.map { String(format: "%02x", $0) }.joined()
    }
    static func decode(_ string: String, count: Int? = nil) throws -> Data {
        guard let data = Data(base64Encoded: string), count == nil || data.count == count else {
            throw MessengerError.invalid("Повреждённые криптографические данные")
        }
        return data
    }
    static func cardBytes(_ card: ContactCard) -> Data {
        Data("VO1D-CARD-1\n\(card.id)\n\(card.signingKey)\n\(card.agreementKey)".utf8)
    }
    static func validate(_ card: ContactCard) throws {
        let signing = try decode(card.signingKey, count: 32)
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: decode(card.agreementKey, count: 32))
        guard hex(SHA256.hash(data: signing)) == card.id,
              try Curve25519.Signing.PublicKey(rawRepresentation: signing).isValidSignature(decode(card.binding, count: 64), for: cardBytes(card)) else {
            throw MessengerError.invalid("Отпечаток контакта или подпись не совпадают")
        }
    }
    static func seal(_ input: ChatEvent, from identity: LocalIdentity, to recipient: ContactCard) throws -> Envelope {
        var event = input
        event.room = input.room.wireCopy
        if event.room.privateRoster==true && event.room.isChannel==true && event.room.creator == (try identity.card.id) && recipient.id != event.room.creator {
            event.room.members = event.room.members.filter { $0.id==event.room.creator || $0.id==recipient.id }
        }
        if var message = event.message {
            message.editHistory = nil; message.readBy = []; message.deliveredTo = []
            message.reactions = [:]; message.openedAt = nil
            event.message = message
        }
        try validate(recipient)
        let own = try identity.card
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let salt = try random(32)
        var envelope = Envelope(id: UUID().uuidString, sender: own.id, recipient: recipient.id,
                                ephemeralKey: ephemeral.publicKey.rawRepresentation.base64EncodedString(), salt: salt.base64EncodedString(),
                                expiresAt: Int(Date().timeIntervalSince1970) + 7 * 86400, ciphertext: "", signature: "")
        if let expiry = event.message?.expiresAt {
            envelope.expiresAt = min(envelope.expiresAt, Int(expiry.timeIntervalSince1970))
        }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: decode(recipient.agreementKey, count: 32)))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: envelope.header, outputByteCount: 32)
        let sealed = try AES.GCM.seal(Wire.encoder.encode(event), using: key, authenticating: envelope.header)
        guard let combined = sealed.combined else { throw MessengerError.invalid("Ошибка шифрования") }
        envelope.ciphertext = combined.base64EncodedString()
        envelope.signature = try identity.signingPrivate.signature(for: envelope.header + Data([10]) + combined).base64EncodedString()
        return envelope
    }
    static func open(_ envelope: Envelope, identity: LocalIdentity, sender: ContactCard) throws -> ChatEvent {
        try validate(sender)
        guard envelope.sender == sender.id, envelope.recipient == (try identity.card.id), envelope.expiresAt > Int(Date().timeIntervalSince1970) else {
            throw MessengerError.invalid("Сообщение не адресовано этому устройству или истекло")
        }
        let ciphertext = try decode(envelope.ciphertext)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: decode(sender.signingKey, count: 32))
        guard try publicKey.isValidSignature(decode(envelope.signature, count: 64), for: envelope.header + Data([10]) + ciphertext) else {
            throw MessengerError.invalid("Подпись сообщения не прошла проверку")
        }
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: decode(envelope.ephemeralKey, count: 32))
        let shared = try identity.agreementPrivate.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: try decode(envelope.salt, count: 32), sharedInfo: envelope.header, outputByteCount: 32)
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key, authenticating: envelope.header)
        return try Wire.decoder.decode(ChatEvent.self, from: clear)
    }
}

enum Keychain {
    static let service = "io.vo1d.messenger.identity.v1"
    static func load() throws -> LocalIdentity {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "identity", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return try Wire.decoder.decode(LocalIdentity.self, from: data) }
        guard status == errSecItemNotFound else { throw MessengerError.invalid("Keychain недоступен (\(status))") }
        let identity = try LocalIdentity.create()
        let insert: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "identity", kSecValueData as String: try Wire.encoder.encode(identity),
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemAdd(insert as CFDictionary, nil)
        guard result == errSecSuccess else { throw MessengerError.invalid("Не удалось сохранить ключи (\(result))") }
        return identity
    }
    static func delete() throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MessengerError.invalid("Не удалось удалить ключи") }
    }
}

struct Vault {
    let url: URL
    init() throws {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("VO1D", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var excluded = dir
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        url = dir.appendingPathComponent("vault.aes")
    }
    func read(key: Data) throws -> VaultState {
        guard FileManager.default.fileExists(atPath: url.path) else { return VaultState() }
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        return try Wire.decoder.decode(VaultState.self, from: AES.GCM.open(sealed, using: SymmetricKey(data: key)))
    }
    func write(_ state: VaultState, key: Data) throws {
        let sealed = try AES.GCM.seal(Wire.encoder.encode(state), using: SymmetricKey(data: key))
        guard let data = sealed.combined else { throw MessengerError.invalid("Не удалось зашифровать хранилище") }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
    func delete() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

