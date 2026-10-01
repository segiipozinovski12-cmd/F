import Foundation

enum AppConfig {
    static var pushEnabled: Bool { Bundle.main.object(forInfoDictionaryKey: "VO1DPushEnabled") as? Bool == true }
    static let productionRelay = "https://f-production-bdfe.up.railway.app"
    static let productionRelayHost = "f-production-bdfe.up.railway.app"
}
