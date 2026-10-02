import Foundation
import CryptoKit

@MainActor
final class APIClient {
    private struct Failure: Decodable { var error: String }
    struct OK: Decodable { var ok: Bool }
    private struct CodeResponse: Decodable { var code: String }
    struct UsernameCheck: Decodable { var username: String; var available: Bool; var valid: Bool }
    private struct UsernameResponse: Decodable { var username: String }
    private struct UsernameLookup: Decodable { var username: String; var card: ContactCard }
    struct BlobReceipt: Decodable {
        var id: String
        var size: Int
        var digest: String
        var expiresAt: Int
        var readToken: String? = nil
        var deleteToken: String? = nil
    }

    var base: URL
    private(set) var token: String?
    let session: URLSession
    let privacy: PrivacyPreferences
    private let identity: LocalIdentity
    private let authenticationCard: ContactCard?
    private var capabilitySessions: [String:URLSession] = [:]
    private let capabilityNamespace = UUID().uuidString
    private let callToken: String?

    init(server: String, identity: LocalIdentity, privacy: PrivacyPreferences = PrivacyPreferences(),authenticationCard: ContactCard? = nil, callToken: String? = nil) throws {
        base = try Self.validateURL(server,privacy:privacy)
        self.privacy = privacy
        self.identity = identity
        self.authenticationCard = authenticationCard
        self.callToken = callToken
        let config = try TransportConfiguration.make(privacy)
        session = URLSession(configuration: config,delegate:NoRedirectSessionDelegate(),delegateQueue:nil)
    }

    func capabilitySession(scope: String) throws -> URLSession {
        if let session = capabilitySessions[scope] { return session }
        var isolated = privacy
        if isolated.embeddedTor || isolated.proxyUsesTor {
            isolated.streamIsolation = Crypto.hex(SHA256.hash(data:Data("VO1D-STREAM-2\n\(privacy.streamIsolation)\n\(capabilityNamespace)\n\(scope)".utf8)))
        }
        let configuration = try TransportConfiguration.make(isolated)
        let session = URLSession(configuration:configuration,delegate:NoRedirectSessionDelegate(),delegateQueue:nil)
        if capabilitySessions.count >= 64, let key = capabilitySessions.keys.first {
            capabilitySessions.removeValue(forKey:key)?.finishTasksAndInvalidate()
        }
        capabilitySessions[scope] = session
        return session
    }
    func invalidate() {
        session.invalidateAndCancel()
        for client in capabilitySessions.values { client.invalidateAndCancel() }
        capabilitySessions = [:]
    }

    nonisolated static func validateURL(_ string: String, privacy: PrivacyPreferences? = nil) throws -> URL {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw MessengerError.invalid("Укажи адрес сервера, например https://chat.example.com")
        }
        if host.hasSuffix(".onion") {
            guard ["http","https"].contains(url.scheme ?? ""), let privacy, privacy.embeddedTor || (privacy.proxyEnabled && privacy.proxyUsesTor),
                  host.range(of:"^[a-z2-7]{56}\\.onion$",options:.regularExpression) != nil else { throw MessengerError.invalid("v3 onion требует маршрута Tor") }
            return url
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
        guard callToken == nil else { throw MessengerError.invalid("Фоновое разрешение доступно только для звонков") }
        let (data, status) = try await raw(path, method: method, body: body)
        if status == 401 && retry {
            try await authenticate()
            return try await request(path, method: method, body: body, retry: false)
        }
        guard (200..<300).contains(status) else {
            let detail = (try? Wire.decoder.decode(Failure.self, from: data).error) ?? "Ошибка сервера \(status)"
            throw HTTPFailure(status:status,detail:detail)
        }
        return try Wire.decoder.decode(T.self, from: data)
    }

    func authenticate() async throws {
        guard callToken == nil else { throw MessengerError.invalid("Разрешение звонков не авторизует аккаунт") }
        token = nil
        let card: ContactCard
        if let authenticationCard { card = authenticationCard }
        else { card = try identity.card }
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

    func checkUsername(_ value: String) async throws -> UsernameCheck {
        let username = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        guard username.count >= 1,
              username.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return UsernameCheck(username: username, available: false, valid: false)
        }
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        let result: UsernameCheck = try await request("v1/username/check/\(encoded)")
        return result
    }

    func claimUsername(_ value: String) async throws -> String {
        struct Body: Encodable { var username: String }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let result: UsernameResponse = try await request(
            "v1/username",
            method: "POST",
            body: Wire.encoder.encode(Body(username: clean))
        )
        return result.username
    }

    func card(username: String) async throws -> ContactCard {
        let clean = username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard clean.count >= 4 && clean.count <= 20 else {
            throw MessengerError.invalid("Username должен содержать 4–20 символов")
        }
        let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? clean
        let result: UsernameLookup = try await request("v1/username/\(encoded)")
        try Crypto.validate(result.card)
        return result.card
    }

    func uploadBlob(_ ciphertext: Data, retry: Bool = true) async throws -> BlobReceipt {
        if token == nil {
            try await authenticate()
        }

        var request = URLRequest(url: base.appendingPathComponent("v1/blob"))
        request.httpMethod = "PUT"
        request.httpBody = ciphertext
        request.timeoutInterval = 120
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MessengerError.invalid("Нет ответа VO1D")
        }

        if http.statusCode == 401 && retry {
            try await authenticate()
            return try await uploadBlob(ciphertext, retry: false)
        }

        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? Wire.decoder.decode(Failure.self, from: data).error) ?? "Ошибка upload \(http.statusCode)"
            throw MessengerError.invalid(detail)
        }

        return try Wire.decoder.decode(BlobReceipt.self, from: data)
    }

    func downloadBlob(_ id: String,retry: Bool = true) async throws -> Data {
        guard (40...64).contains(id.count),id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }) else {
            throw MessengerError.invalid("Некорректный blob ID")
        }
        if token==nil { try await authenticate() }
        var request=URLRequest(url:base.appendingPathComponent("v1/blob/"+id))
        if let token { request.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization") }
        do { return try await ResumableDownload().download(request,id:id,configuration:session.configuration) }
        catch let error as HTTPFailure {
            if error.status==401 && retry { try await authenticate(); return try await downloadBlob(id,retry:false) }
            throw error
        }
    }

    func deleteBlob(_ id: String, retry: Bool = true) async throws {
        if token == nil {
            try await authenticate()
        }

        var request = URLRequest(url: base.appendingPathComponent("v1/blob/\(id)"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MessengerError.invalid("Нет ответа VO1D")
        }

        if http.statusCode == 401 && retry {
            try await authenticate()
            return try await deleteBlob(id, retry: false)
        }

        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? Wire.decoder.decode(Failure.self, from: data).error) ?? "Ошибка удаления blob \(http.statusCode)"
            throw MessengerError.invalid(detail)
        }
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
        let code = publicCode.uppercased().filter { $0.isLetter || $0.isNumber }
        guard code.count == 4 else { throw MessengerError.invalid("VO1D ID должен состоять из 4 символов") }
        let result: ContactCard = try await request("v1/code/\(code)")
        try Crypto.validate(result)
        return result
    }

    func send(_ envelope: Envelope) async throws {
        guard envelope.deferredEvent == nil else { throw MessengerError.invalid("Локальное сообщение ещё не зашифровано протоколом v2") }
        if let opaque = envelope.opaque { try await sendOpaque(opaque); return }
        guard !envelope.ciphertext.isEmpty else { throw MessengerError.invalid("Пустой шифротекст") }
        let _: OK = try await request("v1/envelopes", method: "POST", body: Wire.encoder.encode(envelope))
    }
    func publishPrekeys(_ publication: SignalPublication) async throws {
        let _: OK = try await request("v2/prekeys", method: "POST", body: Wire.encoder.encode(publication))
    }
    func prekey(_ target: ContactCard) async throws -> SignalBundle {
        try await request("v2/prekeys/\(target.id)", method: "POST", body: Data("{}".utf8))
    }
    func prekeyCount() async throws -> Int {
        struct Count: Decodable { var available: Int }
        let response: Count = try await request("v2/prekeys")
        return response.available
    }

    func ack(_ ids: [String]) async throws {
        let _: OK = try await request("v1/ack", method: "POST", body: Wire.encoder.encode(["ids": ids]))
    }

    func block(_ id: String, blocked: Bool) async throws {
        struct Block: Encodable { var id: String; var blocked: Bool }
        let _: OK = try await request("v1/block", method: "POST", body: Wire.encoder.encode(Block(id: id, blocked: blocked)))
    }

    func callSocketRequest() throws -> URLRequest {
        let authorization: String
        if let callToken { authorization = "CallCapability \(callToken)" }
        else if let token { authorization = "Bearer \(token)" }
        else { throw MessengerError.invalid("Сессия relay ещё не готова") }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw MessengerError.invalid("Некорректный адрес relay")
        }
        components.scheme = base.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/call/socket"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw MessengerError.invalid("Не удалось создать адрес звонка")
        }

        var request = URLRequest(url: url)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        return request
    }

    func deleteAccount() async throws {
        let _: OK = try await request("v1/account", method: "DELETE")
    }
}


struct HTTPFailure: LocalizedError {
    var status: Int
    var detail: String
    var errorDescription: String? { detail }
}
