import Foundation
import CryptoKit

struct OwnedPrivateBlob: Codable {
    var deleteToken: String
    var expiresAt: Int
}

enum WorkProof {
    static func solve(prefix: String, bits: Int) throws -> String {
        guard (18...24).contains(bits) else { throw MessengerError.invalid("Неподдерживаемая сложность защиты от спама") }
        let data = Data(prefix.utf8), fullBytes = bits / 8, remaining = bits % 8
        var nonce: UInt64 = 0
        while true {
            if nonce % 4096 == 0 { try Task.checkCancellation() }
            let hash = Array(SHA256.hash(data: data + Data(String(nonce).utf8)))
            if hash.prefix(fullBytes).allSatisfy({ $0 == 0 }) && (remaining == 0 || hash[fullBytes] < (1 << (8 - remaining))) { return String(nonce) }
            nonce += 1
        }
    }
    static func token() throws -> String { try Crypto.random(32).base64URL }
    static func validateToken(_ token: String) throws {
        guard token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { throw MessengerError.invalid("Недействительный ключ доступа к файлу") }
    }
}

private struct BlobFailure: Decodable { var error: String }

extension APIClient {
    private struct Capabilities: Decodable { var protocolVersion: Int; var workBits: Int
        enum CodingKeys: String, CodingKey { case protocolVersion = "protocol", workBits }
    }
    func publicWorkBits() async throws -> Int {
        let result: Capabilities = try await blobRequest("v2/capabilities")
        guard result.protocolVersion == 2, (18...24).contains(result.workBits) else { throw MessengerError.invalid("Сервер не поддерживает приватный протокол v2") }
        return result.workBits
    }
    private func blobRequest<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, capability: String? = nil, binary: Bool = false) async throws -> T {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = binary ? 120 : 30
        request.setValue(binary ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
        if let capability { try WorkProof.validateToken(capability); request.setValue("BlobCapability \(capability)", forHTTPHeaderField: "Authorization") }
        let scope = "blob:" + String(path.split(separator:"/").last ?? "public")
        let (data,response) = try await capabilitySession(scope:scope).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MessengerError.invalid("Нет ответа сервера") }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPFailure(status: http.statusCode, detail: (try? Wire.decoder.decode(BlobFailure.self, from: data).error) ?? "Ошибка приватного файла")
        }
        return try Wire.decoder.decode(T.self, from: data)
    }
    func uploadPrivateBlob(_ ciphertext: Data) async throws -> BlobReceipt {
        struct Ticket: Encodable {
            var id: String; var uploadToken: String; var readToken: String; var deleteToken: String
            var size: Int; var digest: String; var expiresAt: Int; var proof: String
        }
        let bits = try await publicWorkBits()
        var ticket = Ticket(id: try WorkProof.token(), uploadToken: try WorkProof.token(), readToken: try WorkProof.token(), deleteToken: try WorkProof.token(),
                            size: ciphertext.count, digest: Crypto.hex(SHA256.hash(data: ciphertext)), expiresAt: Int(Date().timeIntervalSince1970) + 6 * 86400, proof: "")
        let prefix = "VO1D-BLOB-WORK-2\n\(ticket.id)\n\(ticket.size)\n\(ticket.digest)\n\(ticket.expiresAt)\n"
        ticket.proof = try await Task.detached(priority: .utility) { try WorkProof.solve(prefix: prefix, bits: bits) }.value
        let _: BlobReceipt = try await blobRequest("v2/blobs/ticket", method: "POST", body: Wire.encoder.encode(ticket))
        do {
            var receipt: BlobReceipt = try await blobRequest("v2/blobs/" + ticket.id, method: "PUT", body: ciphertext, capability: ticket.uploadToken, binary: true)
            guard receipt.id == ticket.id, receipt.size == ticket.size, receipt.digest == ticket.digest, receipt.expiresAt == ticket.expiresAt else {
                throw MessengerError.invalid("Сервер изменил метаданные файла")
            }
            receipt.readToken = ticket.readToken; receipt.deleteToken = ticket.deleteToken
            return receipt
        } catch {
            try? await deletePrivateBlob(ticket.id, token: ticket.deleteToken)
            throw error
        }
    }
    func downloadPrivateBlob(_ id: String, token: String) async throws -> Data {
        try WorkProof.validateToken(id); try WorkProof.validateToken(token)
        var request = URLRequest(url: base.appendingPathComponent("v2/blobs/" + id))
        request.setValue("BlobCapability \(token)", forHTTPHeaderField: "Authorization")
        return try await ResumableDownload().download(request, id: id, configuration: try capabilitySession(scope:"blob:"+id).configuration)
    }
    func deletePrivateBlob(_ id: String, token: String) async throws {
        try WorkProof.validateToken(id)
        do { let _: OK = try await blobRequest("v2/blobs/" + id, method: "DELETE", capability: token) }
        catch let failure as HTTPFailure where failure.status == 403 || failure.status == 404 { return }
    }
}

extension ChatStore {
    func revokePrivateFiles() async throws {
        guard let api else { throw MessengerError.invalid("Нет соединения для удаления файлов") }
        for (id,record) in extended.privateBlobDeletes {
            if record.expiresAt > Int(Date().timeIntervalSince1970) { try await api.deletePrivateBlob(id,token:record.deleteToken) }
            var local = extended; local.privateBlobDeletes[id] = nil; state.extended = local; try save()
        }
    }
    func erasePrivateRelayStorage() async throws {
        guard let api else { return }
        for mailbox in extended.ownMailboxes { try await api.deleteMailbox(mailbox) }
        try await revokePrivateFiles()
    }
}
