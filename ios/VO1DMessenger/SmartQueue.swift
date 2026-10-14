import Foundation

enum SmartQueue {
    static func ready(_ pending: [PendingDelivery], issues: [String: DeliveryIssue], now: Date = Date(), limit: Int = 24) -> [PendingDelivery] {
        // Apply eligibility before limiting: a paused/failed head must not starve
        // independent recipients farther down the durable queue.
        Array(pending.lazy.filter {
            $0.envelope.expiresAt > Int(now.timeIntervalSince1970) &&
            ($0.notBefore ?? .distantPast) <= now &&
            (issues[$0.id]?.nextAttempt ?? .distantPast) <= now
        }.prefix(max(0, limit)))
    }
}
