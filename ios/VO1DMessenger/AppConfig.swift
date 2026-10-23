import Foundation

enum AppConfig {
    static var pushEnabled: Bool { Bundle.main.object(forInfoDictionaryKey: "VO1DPushEnabled") as? Bool == true }
    static let productionRelay = "https://f-production-448b.up.railway.app"
    static let productionRelayHost = "f-production-448b.up.railway.app"

    /// Only the retired first-party endpoint is moved. Custom and onion relays
    /// keep their original address and transport policy.
    static func relayAfterUpgrade(_ saved: String) -> String {
        if saved.isEmpty { return productionRelay }
        guard let url = URLComponents(string: saved),
              url.scheme?.lowercased() == "https",
              ["f-production-bdfe.up.railway.app", "f-production-5715.up.railway.app"].contains(url.host?.lowercased() ?? ""),
              url.port == nil || url.port == 443,
              url.path.isEmpty || url.path == "/",
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return saved }
        return productionRelay
    }
}
