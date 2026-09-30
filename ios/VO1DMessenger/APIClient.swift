import Foundation

@MainActor
final class APIClient {
    private struct Failure: Decodable { var error: String }
    struct OK: Decodable { var ok: Bool }
    private struct CodeResponse: Decodable { var code: String }

    var base: URL
    private var token: String?
    private let session: URLSession
    private let identity: LocalIdentity

    init(server: String, identity: LocalIdentity) throws {
        base = try Self.validateURL(server)
        self.identity = identity
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.urlCache = nil
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }

    static func validateURL(_ string: String) throws -> URL {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw MessengerError.invalid("Укажи адрес сервера, например https://chat.example.com")
        }
        if url.scheme == "https" { return url }
        #if DEBUG
        if url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host) { return url }
        #endif
        throw MessengerError.invalid("Для подключения нужен HTTPS. HTTP доступен только для localhost в Debug.")
    }

    private func raw(_ path: String, method: String, body: Data?) async throws -> (Data, Int) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MessengerError.invalid("Нет ответа сервера") }
        return (data, http.statusCode)
    }

    func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, retry: Bool = true) async throws -> T {
        let (data, status) = try await raw(path, method: method, body: body)
        if status == 401 && retry {
            try await authenticate()
            return try await request(path, method: method, body: body, retry: false)
        }
        guard (200..<300).contains(status) else {
            let detail = (try? Wire.decoder.decode(Failure.self, from: data).error) ?? "Ошибка сервера \(status)"
            throw MessengerError.invalid(detail)
        }
        return try Wire.decoder.decode(T.self, from: data)
    }

    func authenticate() async throws {
        token = nil
        let card = try identity.card
        let _: OK = try await request("v1/register", method: "POST", body: Wire.encoder.encode(card), retry: false)
        struct Challenge: Decodable { var nonce: String }
        let challenge: Challenge = try await request("v1/challenge", method: "POST", body: Wire.encoder.encode(["id": card.id]), retry: false)
        let bytes = Data("VO1D-AUTH-1\n\(card.id)\n\(challenge.nonce)".utf8)
        let signature = try identity.signingPrivate.signature(for: bytes).base64EncodedString()
        struct Session: Decodable { var token: String }
        let result: Session = try await request("v1/session", method: "POST", body: Wire.encoder.encode(["id": card.id, "nonce": challenge.nonce, "signature": signature]), retry: false)
        token = result.token
    }

    func ensurePublicCode() async throws -> String {
        let response: CodeResponse = try await request("v1/code", method: "POST", body: Data("{}".utf8))
        return response.code
    }

    func inbox() async throws -> [Envelope] {
        struct Inbox: Decodable { var envelopes: [Envelope] }
        let result: Inbox = try await request("v1/inbox")
        return result.envelopes
    }

    func card(_ id: String) async throws -> ContactCard {
        guard id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { throw MessengerError.invalid("Некорректный ID") }
        let result: ContactCard = try await request("v1/identity/\(id)")
        try Crypto.validate(result)
        guard result.id == id else { throw MessengerError.invalid("Сервер вернул другой ключ контакта") }
        return result
    }

    func card(publicCode: String) async throws -> ContactCard {
        let code = publicCode.uppercased()
        guard code.count == 4 else { throw MessengerError.invalid("VO1D ID должен состоять из 4 символов") }
        let result: ContactCard = try await request("v1/code/\(code)")
        try Crypto.validate(result)
        return result
    }

    func send(_ envelope: Envelope) async throws {
        let _: OK = try await request("v1/envelopes", method: "POST", body: Wire.encoder.encode(envelope))
    }

    func ack(_ ids: [String]) async throws {
        let _: OK = try await request("v1/ack", method: "POST", body: Wire.encoder.encode(["ids": ids]))
    }

    func block(_ id: String, blocked: Bool) async throws {
        struct Block: Encodable { var id: String; var blocked: Bool }
        let _: OK = try await request("v1/block", method: "POST", body: Wire.encoder.encode(Block(id: id, blocked: blocked)))
    }

    func deleteAccount() async throws {
        let _: OK = try await request("v1/account", method: "DELETE")
    }
}
