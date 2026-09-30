import Foundation
import CryptoKit

/// Fresh ephemeral keys per call; signed offers bind both identities and call ID.
final class CallSecrets {
    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var ownID: String?
    private var peerID: String?

    private static func offerBytes(callID: String,from: String,to: String,key: String) -> Data {
        Data("VO1D-CALL-KEY-2\n\(callID)\n\(from)\n\(to)\n\(key)".utf8)
    }

    func offer(identity: LocalIdentity,callID: String,to peerID: String) throws -> [String:String] {
        let ownID=try identity.card.id
        let key=ephemeral.publicKey.rawRepresentation.base64EncodedString()
        let bytes=Self.offerBytes(callID:callID,from:ownID,to:peerID,key:key)
        return ["key":key,"keySignature":try identity.signingPrivate.signature(for:bytes).base64EncodedString()]
    }

    func accept(key: String,signature: String,identity: LocalIdentity,peer: ContactCard,callID: String) throws -> SymmetricKey {
        try Crypto.validate(peer)
        let ownID=try identity.card.id
        let bytes=Self.offerBytes(callID:callID,from:peer.id,to:ownID,key:key)
        let signing=try Curve25519.Signing.PublicKey(rawRepresentation:Crypto.decode(peer.signingKey,count:32))
        guard try signing.isValidSignature(Crypto.decode(signature,count:64),for:bytes) else {
            throw MessengerError.invalid("Подпись ключа звонка не совпала")
        }
        let publicKey=try Curve25519.KeyAgreement.PublicKey(rawRepresentation:Crypto.decode(key,count:32))
        let shared=try ephemeral.sharedSecretFromKeyAgreement(with:publicKey)
        self.ownID=ownID
        self.peerID=peer.id
        let salt=Data(SHA256.hash(data:Data(callID.utf8)))
        let context=Data(("VO1D-CALL-2\n"+[ownID,peer.id].sorted().joined(separator:"\n")).utf8)
        return shared.hkdfDerivedSymmetricKey(using:SHA256.self,salt:salt,sharedInfo:context,outputByteCount:32)
    }

    func seal(_ frame: Data,key: SymmetricKey,callID: String) throws -> (Data,String) {
        guard let ownID,let peerID else { throw MessengerError.invalid("Ключи звонка не согласованы") }
        guard sent<UInt64.max else { throw MessengerError.invalid("Лимит кадров звонка") }
        sent += 1
        let sequence=String(sent)
        let aad=Data("VO1D-CALL-AUDIO-2\n\(callID)\n\(ownID)\n\(peerID)\n\(sequence)".utf8)
        let box=try AES.GCM.seal(frame,using:key,authenticating:aad)
        guard let bytes=box.combined else { throw MessengerError.invalid("Ошибка аудиокадра") }
        return (bytes,sequence)
    }

    func open(_ frame: Data,sequence: String,key: SymmetricKey,callID: String) throws -> Data? {
        guard let ownID,let peerID else { throw MessengerError.invalid("Ключи звонка не согласованы") }
        guard let number=UInt64(sequence),number>received else { return nil }
        let aad=Data("VO1D-CALL-AUDIO-2\n\(callID)\n\(peerID)\n\(ownID)\n\(sequence)".utf8)
        let result=try AES.GCM.open(AES.GCM.SealedBox(combined:frame),using:key,authenticating:aad)
        received=number
        return result
    }
}
