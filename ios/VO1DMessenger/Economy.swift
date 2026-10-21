import Foundation
import StoreKit

struct CoinWallet: Decodable {
    var balance: Int
    var refundDebt: Int
    var premiumUntil: Int
    var premium: Bool
    var appAccountToken: String
    var isPremium: Bool { premium && Date().timeIntervalSince1970 < Double(premiumUntil) }
}
struct ArtifactCollection: Decodable, Identifiable {
    var id: String
    var title: String
    var description: String
    var supply: Int
    var minted: Int
    var price: Int
    var upgradePrice: Int
    var published: Bool
    var upgrades: Bool
    var remaining: Int { max(0, supply - minted) }
    static let titles = ["singularity": "Singularity", "sovereign": "Sovereign", "prism": "Prism", "orbit": "Orbit", "nova": "Nova"]
}
struct ArtifactTrait: Decodable, Hashable {
    var id: String
    var title: String
    var weight: Int
    var probability: String { (Double(weight) / 100).formatted(.number.precision(.fractionLength(0...2))) + "%" }
}
struct ArtifactTraits: Decodable, Hashable {
    var backdrop: ArtifactTrait
    var pattern: ArtifactTrait
    var model: ArtifactTrait
}
struct CollectibleArtifact: Decodable, Identifiable, Hashable {
    var id: String
    var collection: String
    var serial: Int
    var owner: String?
    var ownerUsername: String?
    var pricePaid: Int
    var lastPricePaid: Int?
    var acquired: Int
    var visible: Bool
    var traits: ArtifactTraits?
    var listingID: String?
    var salePrice: Int?
    var title: String { ArtifactCollection.titles[collection] ?? collection }
    var number: String { "#" + serial.formatted(.number.locale(Locale(identifier: "en_US"))) }
}
struct ArtifactPage: Decodable {
    var artifacts: [CollectibleArtifact]
    var nextCursor: String?
    var premium: Bool?
    var total: Int?
    var visibleCount: Int?
}
struct EconomyCatalog: Decodable {
    var collections: [ArtifactCollection]
    var wallet: CoinWallet
    var admin: Bool
    var products: [String]
    var premiumProduct: String
    var paymentsConfigured: Bool? = nil
}
struct EconomyMutation: Decodable {
    var ok: Bool
    var wallet: CoinWallet
    var artifact: CollectibleArtifact?
}
struct EconomyState {
    var owner = ""
    var catalog: EconomyCatalog?
    var artifacts: [CollectibleArtifact] = []
    var nextCursor: String?
    var total = 0
    var visibleCount = 0
}
struct ArtifactCommand: Encodable {
    var requestID = UUID().uuidString.lowercased()
    var collection: String?
    var artifactID: String?
    var expectedPrice: Int?
    var recipient: String?
    var price: Int?
    var visible: Bool?
    var listingID: String?
    var confirmed: Bool?
}

extension ChatStore {
    var coinWallet: CoinWallet? { economy.owner == myID ? economy.catalog?.wallet : nil }
    var hasPremium: Bool { coinWallet?.isPremium == true }
    var canStartApplePayment: Bool { economy.owner == myID && economy.catalog?.paymentsConfigured == true && !locked && sessionUnlocked }

    func refreshEconomy() async throws {
        guard let api, !locked, sessionUnlocked else { throw MessengerError.invalid("Подключись к VO1D") }
        let fence = sessionFence
        let catalog: EconomyCatalog = try await api.request("v3/economy/catalog")
        try requireCurrentSession(fence)
        let inventory: ArtifactPage = try await api.request("v3/economy/inventory")
        try requireCurrentSession(fence)
        guard !locked, sessionUnlocked else { throw CancellationError() }
        economy = EconomyState(owner: myID, catalog: catalog, artifacts: inventory.artifacts, nextCursor: inventory.nextCursor,
                               total: inventory.total ?? inventory.artifacts.count, visibleCount: inventory.visibleCount ?? inventory.artifacts.filter(\.visible).count)
    }

    func loadMoreArtifacts() async throws {
        guard let api, let cursor = economy.nextCursor, economy.owner == myID else { return }
        let fence = sessionFence
        let page: ArtifactPage = try await api.request("v3/economy/inventory", query: [URLQueryItem(name: "cursor", value: cursor)])
        try requireCurrentSession(fence)
        let existing = Set(economy.artifacts.map(\.id))
        economy.artifacts.append(contentsOf: page.artifacts.filter { !existing.contains($0.id) })
        economy.nextCursor = page.nextCursor
    }

    func artifactCommand(_ route: String, _ command: ArtifactCommand) async throws -> CollectibleArtifact? {
        guard let api, !locked, sessionUnlocked else { throw MessengerError.invalid("Подключись к VO1D") }
        let fence = sessionFence
        let result: EconomyMutation = try await api.request("v3/economy/" + route, method: "POST", body: Wire.encoder.encode(command))
        try requireCurrentSession(fence)
        guard !locked else { throw CancellationError() }
        economy.catalog?.wallet = result.wallet
        if let gift = result.artifact {
            economy.artifacts.removeAll { $0.id == gift.id }
            if gift.owner == myID { economy.artifacts.insert(gift, at: 0) }
        }
        // A refresh failure after a committed operation must not report the
        // successful purchase/upgrade as failed or encourage another purchase.
        try? await refreshEconomy()
        try requireCurrentSession(fence)
        return result.artifact
    }

    func buyStoreProduct(_ product: Product) async throws {
        let fence = sessionFence
        try await refreshEconomy()
        try requireCurrentSession(fence)
        guard canStartApplePayment else { throw MessengerError.invalid("Покупки Apple ещё не настроены на сервере. Оплата не начата.") }
        guard let catalog = economy.catalog, catalog.products.contains(product.id) || catalog.premiumProduct == product.id else {
            throw MessengerError.invalid("Этот товар недоступен в VO1D")
        }
        guard let token = coinWallet?.appAccountToken, let account = UUID(uuidString: token) else {
            throw MessengerError.invalid("Не удалось получить платёжный аккаунт")
        }
        let result = try await product.purchase(options: [.appAccountToken(account)])
        try requireCurrentSession(fence)
        switch result {
        case .success(let verification): try await acceptStoreTransaction(verification)
        case .pending: throw MessengerError.invalid("Покупка ожидает подтверждения App Store. Она появится в VO1D после оплаты.")
        case .userCancelled: break
        @unknown default: break
        }
    }

    func acceptStoreTransaction(_ result: VerificationResult<StoreKit.Transaction>) async throws {
        guard case .verified(let transaction) = result else { throw MessengerError.invalid("App Store не подтвердил покупку") }
        guard let api, !locked, sessionUnlocked else { return }
        let fence = sessionFence
        if coinWallet == nil { try await refreshEconomy() }
        try requireCurrentSession(fence)
        guard transaction.appAccountToken?.uuidString.lowercased() == coinWallet?.appAccountToken.lowercased() else { return }
        let response: EconomyMutation = try await api.request("v3/economy/payment", method: "POST", body: Wire.encoder.encode(["transactionID": String(transaction.id)]))
        try requireCurrentSession(fence)
        economy.catalog?.wallet = response.wallet
        // Finish only after the server credited this exact transaction.
        await transaction.finish()
    }

    func recoverStorePurchases() async {
        guard economyRecoveryGeneration != generation else { return }
        let recoveryGeneration = generation
        economyRecoveryGeneration = recoveryGeneration
        defer { if economyRecoveryGeneration == recoveryGeneration { economyRecoveryGeneration = nil } }
        let fence = sessionFence
        do {
            try await refreshEconomy()
            for await result in StoreKit.Transaction.unfinished {
                try requireCurrentSession(fence)
                try await acceptStoreTransaction(result)
            }
            for await result in StoreKit.Transaction.currentEntitlements {
                try requireCurrentSession(fence)
                try await acceptStoreTransaction(result)
            }
        } catch is CancellationError { return }
        catch { /* Storefront displays connection failures and offers retry. */ }
    }
}
