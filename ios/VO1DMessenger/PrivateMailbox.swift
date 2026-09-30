import Foundation
import CryptoKit

struct MailboxAddress: Codable, Hashable {
    var id: String
    var writeToken: String
    var expiresAt: Int
    func validate() throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        guard id.count == 43, writeToken.count == 43,
              id.unicodeScalars.allSatisfy({ allowed.contains($0) }), writeToken.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              expiresAt > Int(Date().timeIntervalSince1970), expiresAt <= Int(Date().timeIntervalSince1970) + 31 * 86400 else {
            throw MessengerError.invalid("Недействительный приватный адрес")
        }
    }
}
struct LocalMailbox: Codable, Identifiable {
    var address: MailboxAddress
    var readToken: String
    var peerID: String?
    var registered = false
    var proof: String
    var id: String { address.id }
    static func create(peerID: String?, bits: Int = 18) throws -> Self {
        func token() throws -> String { try Crypto.random(32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let address = MailboxAddress(id: try token(), writeToken: try token(), expiresAt: Int(Date().timeIntervalSince1970) + 29 * 86400)
        let proof = try WorkProof.solve(prefix: "VO1D-MAILBOX-WORK-2\n\(address.id)\n\(address.expiresAt)\n", bits: bits)
        return Self(address: address, readToken: try token(), peerID: peerID, proof: proof)
    }
}
struct OpaqueEnvelope: Codable, Identifiable {
    var id: String
    var mailbox: String
    var ephemeralKey: String
    var salt: String
    var expiresAt: Int
    var ciphertext: String
    // Local queue only; removed from the body before sending via a capability header.
    var writeToken: String? = nil
    var header: Data { Data("VO1D-OPAQUE-2\n\(id)\n\(mailbox)\n\(ephemeralKey)\n\(salt)\n\(expiresAt)".utf8) }
}
private struct OpaqueContent: Codable {
    var sender: ContactCard
    var recipient: String
    var packet: Data
    var signature: String
}

enum PrivateMailboxCrypto {
    static let buckets = [2048,8192,32768,131072,524288,2097152,5242880]
    static func seal(_ packet: Data, from identity: LocalIdentity, to recipient: ContactCard, route: MailboxAddress, id: String, expiry: Date?) throws -> OpaqueEnvelope {
        try route.validate(); try Crypto.validate(recipient)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey(), salt = try Crypto.random(32)
        var envelope = OpaqueEnvelope(id: id, mailbox: route.id, ephemeralKey: ephemeral.publicKey.rawRepresentation.base64EncodedString(),
            salt: salt.base64EncodedString(), expiresAt: min(route.expiresAt, Int(Date().timeIntervalSince1970) + 7 * 86400), ciphertext: "", writeToken: route.writeToken)
        if let expiry { envelope.expiresAt = min(envelope.expiresAt, Int(expiry.timeIntervalSince1970)) }
        let signed = envelope.header + Data([10]) + Data(recipient.id.utf8) + Data([10]) + packet
        let content = OpaqueContent(sender: try identity.card, recipient: recipient.id, packet: packet,
            signature: try identity.signingPrivate.signature(for: signed).base64EncodedString())
        let clear = try Wire.encoder.encode(content)
        guard let bucket = buckets.first(where: { $0 >= clear.count + 4 }) else { throw MessengerError.invalid("Для большого вложения используй загрузку файла") }
        var padded = Data([UInt8((clear.count >> 24) & 255),UInt8((clear.count >> 16) & 255),UInt8((clear.count >> 8) & 255),UInt8(clear.count & 255)])
        padded.append(clear); padded.append(try Crypto.random(bucket - padded.count))
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: Crypto.decode(recipient.agreementKey, count: 32)))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: envelope.header, outputByteCount: 32)
        let box = try AES.GCM.seal(padded, using: key, authenticating: envelope.header)
        guard let combined = box.combined else { throw MessengerError.invalid("Ошибка приватного конверта") }
        envelope.ciphertext = combined.base64EncodedString()
        return envelope
    }
    static func open(_ envelope: OpaqueEnvelope, identity: LocalIdentity, mailbox: LocalMailbox) throws -> (ContactCard, Data) {
        guard envelope.mailbox == mailbox.id, envelope.expiresAt > Int(Date().timeIntervalSince1970) else { throw MessengerError.invalid("Неверный или истёкший адрес доставки") }
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Crypto.decode(envelope.ephemeralKey, count: 32))
        let shared = try identity.agreementPrivate.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: try Crypto.decode(envelope.salt, count: 32), sharedInfo: envelope.header, outputByteCount: 32)
        let encrypted = try Crypto.decode(envelope.ciphertext)
        guard buckets.contains(encrypted.count - 28) else { throw MessengerError.invalid("Неподдерживаемый размер конверта") }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key, authenticating: envelope.header)
        guard clear.count >= 4 else { throw MessengerError.invalid("Повреждённый конверт") }
        let length = clear.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= clear.count - 4 else { throw MessengerError.invalid("Неверная длина конверта") }
        let content = try Wire.decoder.decode(OpaqueContent.self, from: clear.subdata(in: 4..<(4 + length)))
        try Crypto.validate(content.sender)
        guard content.recipient == (try identity.card.id), mailbox.peerID == nil || mailbox.peerID == content.sender.id else { throw MessengerError.invalid("Неверный получатель или собеседник") }
        let signed = envelope.header + Data([10]) + Data(content.recipient.utf8) + Data([10]) + content.packet
        let signer = try Curve25519.Signing.PublicKey(rawRepresentation: Crypto.decode(content.sender.signingKey, count: 32))
        guard try signer.isValidSignature(Crypto.decode(content.signature, count: 64), for: signed) else { throw MessengerError.invalid("Подпись приватного сообщения неверна") }
        return (content.sender, content.packet)
    }
}

extension APIClient {
    private func capability<T: Decodable>(_ path: String, token: String?, method: String = "GET", body: Data? = nil) async throws -> T {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Capability \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MessengerError.invalid("Нет ответа приватного relay") }
        guard (200..<300).contains(http.statusCode) else { throw HTTPFailure(status: http.statusCode, detail: "Приватный relay: \(http.statusCode)") }
        return try Wire.decoder.decode(T.self, from: data)
    }
    func registerMailbox(_ mailbox: LocalMailbox) async throws {
        struct Create: Encodable { var id: String; var readToken: String; var writeToken: String; var expiresAt: Int; var proof: String }
        let body = Create(id: mailbox.id, readToken: mailbox.readToken, writeToken: mailbox.address.writeToken, expiresAt: mailbox.address.expiresAt, proof: mailbox.proof)
        let _: OK = try await capability("v2/mailboxes", token: nil, method: "POST", body: Wire.encoder.encode(body))
    }
    func sendOpaque(_ envelope: OpaqueEnvelope) async throws {
        guard let token = envelope.writeToken else { throw MessengerError.invalid("Нет права записи в приватный ящик") }
        var wire = envelope; wire.writeToken = nil
        let _: OK = try await capability("v2/mailboxes/\(wire.mailbox)/envelopes", token: token, method: "POST", body: Wire.encoder.encode(wire))
    }
    func privateInbox(_ mailbox: LocalMailbox) async throws -> [OpaqueEnvelope] {
        struct Inbox: Decodable { var envelopes: [OpaqueEnvelope] }
        let result: Inbox = try await capability("v2/mailboxes/\(mailbox.id)/inbox", token: mailbox.readToken)
        return result.envelopes
    }
    func privateAck(_ ids: [String], mailbox: LocalMailbox) async throws {
        let _: OK = try await capability("v2/mailboxes/\(mailbox.id)/ack", token: mailbox.readToken, method: "POST", body: Wire.encoder.encode(["ids": ids]))
    }
    func deleteMailbox(_ mailbox: LocalMailbox) async throws {
        let _: OK = try await capability("v2/mailboxes/\(mailbox.id)", token: mailbox.readToken, method: "DELETE")
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decodeURL(_ string: String) throws -> Data {
        var padded = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return try Crypto.decode(padded)
    }
}
extension APIClient {
    func publishPrivateInvite(token: String, ciphertext: Data, mailbox: LocalMailbox) async throws {
        struct Body: Encodable { var token: String; var ciphertext: String; var expiresAt: Int }
        let body = Body(token: token, ciphertext: ciphertext.base64EncodedString(), expiresAt: Int(Date().timeIntervalSince1970) + 3600)
        let _: OK = try await capability("v2/mailboxes/\(mailbox.id)/invites", token: mailbox.readToken, method: "POST", body: Wire.encoder.encode(body))
    }
    func redeemPrivateInvite(token: String) async throws -> Data {
        struct Response: Decodable { var ciphertext: String }
        let result: Response = try await capability("v2/private-invites/\(token)", token: nil)
        return try Crypto.decode(result.ciphertext)
    }
}
