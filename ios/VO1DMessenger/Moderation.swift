import Foundation
import CryptoKit

enum ReportReason: String, CaseIterable, Codable, Identifiable {
    case spam, harassment, threats, impersonation, illegal_content, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .spam: return "Спам или мошенничество"
        case .harassment: return "Преследование и оскорбления"
        case .threats: return "Угрозы"
        case .impersonation: return "Выдаёт себя за другого"
        case .illegal_content: return "Недопустимый контент"
        case .other: return "Другая причина"
        }
    }
}

struct ReportTarget: Identifiable {
    var subject: String
    var source: String
    var roomID: String? = nil
    var messageID: String? = nil
    var id: String { subject + source + (messageID ?? "") }
}

struct ReportAttachment: Codable {
    var name: String
    var mime: String
    var data: Data
}

struct ReportEvidence: Codable, Identifiable {
    var id: String
    var sender: String
    var text: String
    var createdAt: Date
    var attachment: ReportAttachment? = nil
}

struct ReportContent: Codable {
    var kind = "VO1D-REPORT-1"
    var reportID: String
    var subject: String
    var reason: ReportReason
    var source: String
    var comment: String
    var messages: [ReportEvidence]
    var appealFor: String? = nil
    var createdAt = Date()
    func validated(for envelope: Envelope) throws -> ReportContent {
        guard kind == "VO1D-REPORT-1", reportID == envelope.id, comment.count <= 4000,
              messages.count <= 10, ["profile", "chat", "message", "appeal"].contains(source),
              subject.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              Set(messages.map(\.id)).count == messages.count,
              messages.allSatisfy({ $0.id.count <= 160 && $0.text.count <= 20000 && ($0.attachment?.data.count ?? 0) <= 65536 && ($0.attachment?.name.count ?? 0) <= 255 && ($0.attachment?.mime.count ?? 0) <= 120 }) else {
            throw MessengerError.invalid("Содержимое жалобы не прошло проверку")
        }
        if let appealFor, UUID(uuidString: appealFor) == nil { throw MessengerError.invalid("Неверный номер исходного решения") }
        return self
    }
}

struct ReportSubmission: Codable {
    var subject: String
    var reason: String
    var source: String
    var consent: Bool
    var envelope: Envelope
}

struct PendingReport: Codable, Identifiable {
    var submission: ReportSubmission
    var appealFor: String? = nil
    var nextAttempt = Date()
    var attempts = 0
    var failure: String? = nil
    var stopped = false
    var id: String { submission.envelope.id }
}

struct ReportReceipt: Codable, Identifiable {
    var id: String
    var reason: String
    var source: String
    var status: String
    var created: Int
    var expires: Int
}

struct ReportConfig: Decodable {
    var username: String
    var card: ContactCard?
    var maxEvidenceBytes: Int
    var retentionSeconds: Int
}
struct ModerationAccess: Decodable { var role: String?; var mfaEnabled: Bool }
struct ModeratorLogin: Decodable { var token: String; var expiresAt: Int }
struct ModeratorSetup: Decodable { var secret: String; var expiresAt: Int }
struct ModerationCase: Decodable, Identifiable {
    var id: String
    var subject: String
    var reason: String
    var source: String
    var status: String
    var created: Int
    var expires: Int
    var updated: Int
}
struct ModerationNotice: Decodable, Identifiable { var id: String; var action: String; var expires: Int; var created: Int }
struct ModerationAppeal: Decodable, Identifiable { var id: String; var identity: String; var report: String; var created: Int; var expires: Int; var status: String }
struct SealedReport: Decodable { var id: String; var envelope: Envelope; var senderCard: ContactCard }
struct ModerationAudit: Decodable, Identifiable {
    var seq: Int; var entry: String; var previous: String; var digest: String
    var id: Int { seq }
}

extension APIClient {
    func reportConfig() async throws -> ReportConfig { try await request("v2/reports/config") }
    func submitReport(_ pending: PendingReport) async throws {
        if let appeal = pending.appealFor {
            struct Body: Encodable { var report: String; var consent: Bool; var envelope: Envelope }
            _ = try await request("v2/appeals", method: "POST", body: Wire.encoder.encode(Body(report: appeal, consent: true, envelope: pending.submission.envelope))) as OK
        } else {
            _ = try await request("v2/reports", method: "POST", body: Wire.encoder.encode(pending.submission)) as OK
        }
    }
    func myReports() async throws -> [ReportReceipt] {
        struct Response: Decodable { var reports: [ReportReceipt] }
        let result: Response = try await request("v2/reports/mine")
        return result.reports
    }
    func moderationNotices() async throws -> [ModerationNotice] {
        struct Response: Decodable { var notices: [ModerationNotice] }
        let result: Response = try await request("v2/reports/notices")
        return result.notices
    }
    func moderationAccess() async throws -> ModerationAccess { try await request("v2/moderation/access") }
    func setupModeratorMFA() async throws -> ModeratorSetup { try await request("v2/moderation/mfa/setup", method: "POST", body: Data("{}".utf8)) }
    func loginModerator(code: String) async throws -> ModeratorLogin {
        try await request("v2/moderation/mfa/verify", method: "POST", body: Wire.encoder.encode(["code": code]))
    }
    func moderationQueue(token: String) async throws -> [ModerationCase] {
        struct Response: Decodable { var reports: [ModerationCase] }
        let result: Response = try await request("v2/moderation/queue", moderationToken: token)
        return result.reports
    }
    func moderationAppeals(token: String) async throws -> [ModerationAppeal] {
        struct Response: Decodable { var appeals: [ModerationAppeal] }
        let result: Response = try await request("v2/moderation/appeals", moderationToken: token)
        return result.appeals
    }
    func moderationEvidence(_ id: String, appeal: Bool = false, token: String) async throws -> SealedReport {
        guard UUID(uuidString: id) != nil else { throw MessengerError.invalid("Неверный номер жалобы") }
        return try await request("v2/moderation/\(appeal ? "appeal" : "report")/\(id)", moderationToken: token)
    }
    func decide(_ item: ModerationCase, status: String, action: String, token: String) async throws {
        struct Body: Encodable { var report: String; var status: String; var action: String; var seconds: Int; var expectedUpdated: Int }
        let _: OK = try await request("v2/moderation/decision", method: "POST", body: Wire.encoder.encode(Body(report: item.id, status: status, action: action, seconds: 86400, expectedUpdated: item.updated)), moderationToken: token)
    }
    func assignModerator(identity: String, role: String, token: String) async throws {
        let _: OK = try await request("v2/moderation/roles", method: "POST", body: Wire.encoder.encode(["identity": identity, "role": role]), moderationToken: token)
    }
    func moderationAudit(token: String) async throws -> [ModerationAudit] {
        struct Response: Decodable { var events: [ModerationAudit] }
        let result: Response = try await request("v2/moderation/audit", moderationToken: token)
        return result.events
    }
    func logoutModerator(token: String) async throws {
        let _: OK = try await request("v2/moderation/logout", method: "POST", body: Data("{}".utf8), moderationToken: token)
    }
}

extension ChatStore {
    func reportCandidates(target: ReportTarget) -> [ChatMessage] {
        let rooms = Set(state.rooms.filter { $0.members.contains(where: { $0.id == target.subject }) }.map(\.id))
        return state.messages.filter {
            (target.roomID == nil ? rooms.contains($0.roomID) : $0.roomID == target.roomID) &&
            ($0.expiresAt ?? .distantFuture) > Date() && !isLocalUtilityRoom($0.roomID)
        }
    }
    func queueReport(target: ReportTarget, reason: ReportReason, comment: String, selected: Set<String>, attachments: Set<String>, config: ReportConfig, consent: Bool, appealFor: String? = nil) throws {
        guard consent, !locked, let identity, let api, let moderator = config.card,
              config.username == "vo1d", (state.pendingReports ?? []).count < 32,
              comment.count <= 4000, selected.count <= 10 else {
            throw MessengerError.invalid("Нужны согласие, доступное хранилище и адрес администратора")
        }
        try Crypto.validate(moderator)
        let origin = api.base.absoluteString
        if let pinned = state.moderationPins?[origin], !pinned.hasSameKeys(as: moderator) {
            throw MessengerError.invalid("Ключ @vo1d изменился. Отправка остановлена; проверь администратора по независимому каналу.")
        }
        let available = reportCandidates(target: target)
        guard selected.isSubset(of: Set(available.map(\.id))), attachments.isSubset(of: selected) else {
            throw MessengerError.invalid("Выбранные сообщения уже недоступны")
        }
        let evidence = try available.filter { selected.contains($0.id) }.map { message -> ReportEvidence in
            guard message.text.count <= 20000 else { throw MessengerError.invalid("Сообщение слишком длинное для доказательства") }
            var attachment: ReportAttachment?
            if attachments.contains(message.id) {
                guard let item = message.attachment, item.blobID == nil, item.data.count <= 65536 else {
                    throw MessengerError.invalid("В доказательства можно включить локальный файл до 64 КБ")
                }
                attachment = ReportAttachment(name: item.name, mime: item.mime, data: item.data)
            }
            return ReportEvidence(id: message.id, sender: message.sender, text: message.text, createdAt: message.createdAt, attachment: attachment)
        }
        let id = UUID().uuidString
        let content = ReportContent(reportID: id, subject: target.subject, reason: reason, source: target.source, comment: comment, messages: evidence, appealFor: appealFor)
        let clear = try Wire.encoder.encode(content)
        guard clear.count + 28 <= min(config.maxEvidenceBytes, 256 * 1024) else { throw MessengerError.invalid("Уменьши число выбранных доказательств") }
        let envelope = try Crypto.sealPayload(clear, from: identity, to: moderator, id: id)
        _ = try content.validated(for: envelope)
        let pending = PendingReport(submission: ReportSubmission(subject: target.subject, reason: reason.rawValue, source: target.source, consent: true, envelope: envelope), appealFor: appealFor)
        let previous = state
        state.moderationPins = (state.moderationPins ?? [:]).merging([origin: moderator]) { old, _ in old }
        state.pendingReports = (state.pendingReports ?? []) + [pending]
        do { try save() } catch { state = previous; throw error }
        Task { await sync() }
    }

    func flushReports(api: APIClient, generation current: Int) async throws {
        for pending in (state.pendingReports ?? []).filter({ !$0.stopped && $0.nextAttempt <= Date() }).prefix(8) {
            guard current == generation, !locked else { return }
            do {
                guard pending.submission.envelope.expiresAt > Int(Date().timeIntervalSince1970) else { throw HTTPFailure(status: 400, detail: "Срок жалобы истёк; выбери доказательства заново") }
                try await api.submitReport(pending)
                guard current == generation, !locked else { return }
                state.pendingReports?.removeAll { $0.id == pending.id }
                let receipt = ReportReceipt(id: pending.id, reason: pending.submission.reason, source: pending.submission.source, status: "open", created: Int(Date().timeIntervalSince1970), expires: pending.submission.envelope.expiresAt)
                state.submittedReports = Array(((state.submittedReports ?? []) + [receipt]).suffix(100))
            } catch {
                guard current == generation, !locked else { return }
                if let index = state.pendingReports?.firstIndex(where: { $0.id == pending.id }) {
                    let stopped = (error as? HTTPFailure).map { [400,403,404,409,413].contains($0.status) } ?? false
                    state.pendingReports?[index].attempts += 1
                    state.pendingReports?[index].stopped = stopped
                    state.pendingReports?[index].failure = error.localizedDescription
                    state.pendingReports?[index].nextAttempt = Date().addingTimeInterval(min(3600, pow(2, Double(min(pending.attempts + 1, 10)))) + Double.random(in: 0...5))
                }
            }
            try save()
        }
    }
}
