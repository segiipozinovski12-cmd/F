import Foundation

enum SmartQueue {
    static func ready(_ pending: [PendingDelivery], issues: [String: DeliveryIssue], now: Date = Date(), limit: Int = 24) -> [PendingDelivery] {
        // Apply eligibility before limiting: a paused/failed head must not starve
        // independent recipients farther down the durable queue.
        Array(pending.lazy.filter {
            $0.envelope.nearbyOnly != true &&
            $0.envelope.expiresAt > Int(now.timeIntervalSince1970) &&
            ($0.notBefore ?? .distantPast) <= now &&
            (issues[$0.id]?.nextAttempt ?? .distantPast) <= now
        }.prefix(max(0, limit)))
    }
}

extension ChatStore {
    func resumeNetworkQueue(now: Date = Date()) {
        // An actual connectivity transition can wake transient retries immediately.
        // Permanent failures, scheduled sends and privacy batching remain fenced.
        for id in Array(deliveryIssues.keys) {
            guard var issue = deliveryIssues[id], issue.nextAttempt != .distantFuture else { continue }
            issue.nextAttempt = now; deliveryIssues[id] = issue
        }
        persist()
    }
}
