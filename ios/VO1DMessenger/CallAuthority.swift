import Foundation
import CryptoKit

struct CallAuthority: Codable {
    var owner: String
    var key: String
    var expiresAt: Int
    var signature: String = ""
    var bytes: Data { Data("VO1D-CALL-CAPABILITY-2\n\(owner)\n\(key)\n\(expiresAt)\ncalls".utf8) }
    func validate(for card: ContactCard) throws -> Curve25519.Signing.PublicKey {
        try Crypto.validate(card)
        guard owner == card.id, expiresAt > Int(Date().timeIntervalSince1970), expiresAt <= Int(Date().timeIntervalSince1970) + 86400 else {
            throw MessengerError.invalid("Разрешение звонков истекло")
        }
        let signer = try Curve25519.Signing.PublicKey(rawRepresentation: Crypto.decode(card.signingKey, count: 32))
        guard try signer.isValidSignature(Crypto.decode(signature, count: 64), for: bytes) else { throw MessengerError.invalid("Неверная подпись разрешения звонков") }
        return try Curve25519.Signing.PublicKey(rawRepresentation: Crypto.decode(key, count: 32))
    }
}
