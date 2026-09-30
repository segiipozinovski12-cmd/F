import Foundation
import CryptoKit
import LibSignalClient

/// Serialized libsignal records live only inside the device's authenticated encrypted vault.
/// Every protocol operation uses a disposable store; callers commit the returned snapshot
/// with the exact outbox ciphertext before making a network request.
struct SignalSnapshot: Codable {
    var identity: Data
    var registration: UInt32
    var nextKey: UInt32 = 1
    var prekeys: [String: Data] = [:]
    var signedKeys: [String: Data] = [:]
    var kyberKeys: [String: Data] = [:]
    var sessions: [String: Data] = [:]
    var trusted: [String: Data] = [:]
    var senderKeys: [String: Data] = [:]
    var publishedAt: Date? = nil
    var pendingPublication: SignalPublication? = nil

    static func create() throws -> Self {
        let random = try Crypto.random(2)
        let registration = (UInt32(random[0]) << 8 | UInt32(random[1])) % 16380 + 1
        return Self(identity: Data(IdentityKeyPair.generate().serialize()), registration: registration)
    }
}

final class SignalVaultStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore, SessionStore, SenderKeyStore {
    var state: SignalSnapshot
    init(_ state: SignalSnapshot) { self.state = state }
    private func key(_ address: ProtocolAddress) -> String { "\(address.name):\(address.deviceId)" }
    func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair { try IdentityKeyPair(bytes: state.identity) }
    func localRegistrationId(context: StoreContext) throws -> UInt32 { state.registration }
    func saveIdentity(_ identity: IdentityKey, for address: ProtocolAddress, context: StoreContext) throws -> Bool {
        let value = Data(identity.serialize()), old = state.trusted[key(address)]
        if let old, old != value { throw MessengerError.invalid("Ключ контакта изменился. Сначала проверь отпечаток.") }
        state.trusted[key(address)] = value
        return old != nil && old != value
    }
    func isTrustedIdentity(_ identity: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext) throws -> Bool {
        state.trusted[key(address)].map { $0 == Data(identity.serialize()) } ?? true
    }
    func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        try state.trusted[key(address)].map { try IdentityKey(bytes: $0) }
    }
    func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        guard let bytes = state.prekeys[String(id)] else { throw MessengerError.invalid("Одноразовый ключ уже использован или отсутствует") }
        return try PreKeyRecord(bytes: bytes)
    }
    func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws { state.prekeys[String(id)] = Data(record.serialize()) }
    func removePreKey(id: UInt32, context: StoreContext) throws { state.prekeys[String(id)] = nil }
    func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        guard let bytes = state.signedKeys[String(id)] else { throw MessengerError.invalid("Подписанный ключ отсутствует") }
        return try SignedPreKeyRecord(bytes: bytes)
    }
    func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws { state.signedKeys[String(id)] = Data(record.serialize()) }
    func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        guard let bytes = state.kyberKeys[String(id)] else { throw MessengerError.invalid("Одноразовый PQ-ключ уже использован или отсутствует") }
        return try KyberPreKeyRecord(bytes: bytes)
    }
    func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws { state.kyberKeys[String(id)] = Data(record.serialize()) }
    func markKyberPreKeyUsed(id: UInt32, context: StoreContext) throws { state.kyberKeys[String(id)] = nil }
    func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        try state.sessions[key(address)].map { try SessionRecord(bytes: $0) }
    }
    func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        try addresses.map { address in
            guard let record = try loadSession(for: address, context: context) else { throw MessengerError.invalid("Сессия отсутствует") }
            return record
        }
    }
    func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws { state.sessions[key(address)] = Data(record.serialize()) }
    func storeSenderKey(from sender: ProtocolAddress, distributionId: UUID, record: SenderKeyRecord, context: StoreContext) throws { state.senderKeys[key(sender) + distributionId.uuidString] = Data(record.serialize()) }
    func loadSenderKey(from sender: ProtocolAddress, distributionId: UUID, context: StoreContext) throws -> SenderKeyRecord? {
        try state.senderKeys[key(sender) + distributionId.uuidString].map { try SenderKeyRecord(bytes: $0) }
    }
}

struct SignalBundle: Codable {
    var owner: String
    var identityKey: String
    var identityBinding: String
    var registrationId: UInt32
    var deviceId: UInt32 = 1
    var signedPrekeyId: UInt32
    var signedPrekey: String
    var signedPrekeySignature: String
    var prekeyId: UInt32
    var prekey: String
    var kyberPrekeyId: UInt32
    var kyberPrekey: String
    var kyberPrekeySignature: String
    var expiresAt: Int
    var signature: String = ""
    var signedBytes: Data {
        Data("VO1D-PREKEY-2\n\(owner)\n\(identityKey)\n\(identityBinding)\n\(registrationId)\n\(deviceId)\n\(signedPrekeyId)\n\(signedPrekey)\n\(signedPrekeySignature)\n\(prekeyId)\n\(prekey)\n\(kyberPrekeyId)\n\(kyberPrekey)\n\(kyberPrekeySignature)\n\(expiresAt)".utf8)
    }
    func validated(for card: ContactCard) throws -> PreKeyBundle {
        try Crypto.validate(card)
        guard owner == card.id, deviceId == 1, expiresAt > Int(Date().timeIntervalSince1970),
              expiresAt <= Int(Date().timeIntervalSince1970) + 8 * 86400 else { throw MessengerError.invalid("Неверный или истёкший набор ключей") }
        try SignalProtocol.validateBinding(identityKey, binding: identityBinding, card: card)
        let signer = try Curve25519.Signing.PublicKey(rawRepresentation: Crypto.decode(card.signingKey, count: 32))
        guard try signer.isValidSignature(Crypto.decode(signature, count: 64), for: signedBytes) else { throw MessengerError.invalid("Подмена набора ключей") }
        return try PreKeyBundle(registrationId: registrationId, deviceId: deviceId,
            prekeyId: prekeyId, prekey: PublicKey(Crypto.decode(prekey, count: 33)),
            signedPrekeyId: signedPrekeyId, signedPrekey: PublicKey(Crypto.decode(signedPrekey, count: 33)),
            signedPrekeySignature: Crypto.decode(signedPrekeySignature, count: 64), identity: IdentityKey(bytes: Crypto.decode(identityKey, count: 33)),
            kyberPrekeyId: kyberPrekeyId, kyberPrekey: KEMPublicKey(Crypto.decode(kyberPrekey)), kyberPrekeySignature: Crypto.decode(kyberPrekeySignature, count: 64))
    }
}
struct SignalPublication: Codable { var bundles: [SignalBundle] }
struct SignalPacket: Codable {
    var version = 2
    var identityKey: String
    var identityBinding: String
    var type: UInt8
    var ciphertext: Data
}

enum SignalProtocol {
    static func address(_ card: ContactCard) throws -> ProtocolAddress { try ProtocolAddress(name: card.id, deviceId: 1) }
    static func bindingBytes(_ publicKey: String, owner: String) -> Data { Data("VO1D-SIGNAL-IDENTITY-2\n\(owner)\n\(publicKey)".utf8) }
    static func validateBinding(_ key: String, binding: String, card: ContactCard) throws {
        let signer = try Curve25519.Signing.PublicKey(rawRepresentation: Crypto.decode(card.signingKey, count: 32))
        guard try signer.isValidSignature(Crypto.decode(binding, count: 64), for: bindingBytes(key, owner: card.id)) else { throw MessengerError.invalid("Неверная привязка ключа Signal") }
        _ = try IdentityKey(bytes: Crypto.decode(key, count: 33))
    }
    static func publication(state: SignalSnapshot, identity: LocalIdentity, count: Int = 24) throws -> (SignalSnapshot, SignalPublication) {
        guard (1...48).contains(count) else { throw MessengerError.invalid("Неверное число ключей") }
        let store = SignalVaultStore(state), pair = try store.identityKeyPair(context: NullContext()), owner = try identity.card.id
        let publicIdentity = Data(pair.identityKey.serialize()).base64EncodedString()
        let binding = try identity.signingPrivate.signature(for: bindingBytes(publicIdentity, owner: owner)).base64EncodedString()
        let signedID = store.state.nextKey
        store.state.nextKey += 1
        let signedPrivate = PrivateKey.generate()
        let signedSignature = try pair.privateKey.generateSignature(message: Data(signedPrivate.publicKey.serialize()))
        let signed = try SignedPreKeyRecord(id: signedID, timestamp: UInt64(Date().timeIntervalSince1970 * 1000), privateKey: signedPrivate, signature: Data(signedSignature))
        try store.storeSignedPreKey(signed, id: signedID, context: NullContext())
        var bundles: [SignalBundle] = []
        for _ in 0..<count {
            let preID = store.state.nextKey; store.state.nextKey += 1
            let kyberID = store.state.nextKey; store.state.nextKey += 1
            let pre = try PreKeyRecord(id: preID, privateKey: PrivateKey.generate()), kyberPair = KEMKeyPair.generate()
            let kyberSignature = try pair.privateKey.generateSignature(message: Data(kyberPair.publicKey.serialize()))
            let kyber = try KyberPreKeyRecord(id: kyberID, timestamp: UInt64(Date().timeIntervalSince1970 * 1000), keyPair: kyberPair, signature: Data(kyberSignature))
            try store.storePreKey(pre, id: preID, context: NullContext())
            try store.storeKyberPreKey(kyber, id: kyberID, context: NullContext())
            var bundle = SignalBundle(owner: owner, identityKey: publicIdentity, identityBinding: binding, registrationId: state.registration,
                signedPrekeyId: signedID, signedPrekey: Data(signedPrivate.publicKey.serialize()).base64EncodedString(), signedPrekeySignature: Data(signedSignature).base64EncodedString(),
                prekeyId: preID, prekey: try Data(pre.publicKey().serialize()).base64EncodedString(), kyberPrekeyId: kyberID,
                kyberPrekey: Data(kyberPair.publicKey.serialize()).base64EncodedString(), kyberPrekeySignature: Data(kyberSignature).base64EncodedString(), expiresAt: Int(Date().timeIntervalSince1970) + 7 * 86400)
            bundle.signature = try identity.signingPrivate.signature(for: bundle.signedBytes).base64EncodedString()
            bundles.append(bundle)
        }
        // A signed key survives for pending offline messages, then is discarded.
        for (id, bytes) in store.state.signedKeys {
            let key = try SignedPreKeyRecord(bytes: bytes)
            if key.timestamp + UInt64(8 * 86400 * 1000) < UInt64(Date().timeIntervalSince1970 * 1000) { store.state.signedKeys[id] = nil }
        }
        guard store.state.prekeys.count <= 512, store.state.kyberKeys.count <= 512 else { throw MessengerError.invalid("Нужно завершить обработку старых ключей перед обновлением") }
        let publication = SignalPublication(bundles: bundles)
        store.state.pendingPublication = publication
        return (store.state, publication)
    }
    static func encrypt(_ clear: Data, to target: ContactCard, identity: LocalIdentity, state: SignalSnapshot, bundle: SignalBundle? = nil) throws -> (SignalSnapshot, Data) {
        let store = SignalVaultStore(state), destination = try address(target)
        if try store.loadSession(for: destination, context: NullContext())?.hasCurrentState != true {
            guard let bundle else { throw MessengerError.invalid("Контакт ещё не опубликовал ключи v2. Сообщение сохранено в очереди.") }
            try processPreKeyBundle(bundle.validated(for: target), for: destination, sessionStore: store, identityStore: store, context: NullContext())
        }
        let encrypted = try signalEncrypt(message: clear, for: destination, sessionStore: store, identityStore: store, context: NullContext())
        let publicIdentity = try Data(store.identityKeyPair(context: NullContext()).identityKey.serialize()).base64EncodedString()
        let binding = try identity.signingPrivate.signature(for: bindingBytes(publicIdentity, owner: identity.card.id)).base64EncodedString()
        let packet = SignalPacket(identityKey: publicIdentity, identityBinding: binding, type: encrypted.messageType.rawValue, ciphertext: Data(encrypted.serialize()))
        return (store.state, try Wire.encoder.encode(packet))
    }
    static func decrypt(_ packet: SignalPacket, from sender: ContactCard, state: SignalSnapshot) throws -> (SignalSnapshot, Data) {
        guard packet.version == 2, packet.ciphertext.count <= 7 * 1024 * 1024 else { throw MessengerError.invalid("Неподдерживаемый протокол") }
        try validateBinding(packet.identityKey, binding: packet.identityBinding, card: sender)
        let store = SignalVaultStore(state), source = try address(sender), pinned = try IdentityKey(bytes: Crypto.decode(packet.identityKey, count: 33))
        guard try store.isTrustedIdentity(pinned, for: source, direction: .receiving, context: NullContext()) else { throw MessengerError.invalid("Ключ контакта изменился") }
        let clear: [UInt8]
        if packet.type == CiphertextMessage.MessageType.preKey.rawValue {
            let message = try PreKeySignalMessage(bytes: packet.ciphertext)
            guard Data(message.identityKey.serialize()) == Data(pinned.serialize()) else { throw MessengerError.invalid("Ключ сообщения не совпадает с сертификатом") }
            clear = try signalDecryptPreKey(message: message, from: source, sessionStore: store, identityStore: store, preKeyStore: store, signedPreKeyStore: store, kyberPreKeyStore: store, context: NullContext())
        } else if packet.type == CiphertextMessage.MessageType.whisper.rawValue {
            clear = try signalDecrypt(message: SignalMessage(bytes: packet.ciphertext), from: source, sessionStore: store, identityStore: store, context: NullContext())
        } else { throw MessengerError.invalid("Неподдерживаемый тип шифротекста") }
        _ = try store.saveIdentity(pinned, for: source, context: NullContext())
        return (store.state, Data(clear))
    }
}
