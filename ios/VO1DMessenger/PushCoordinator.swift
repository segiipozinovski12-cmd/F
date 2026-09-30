import UIKit
import PushKit
import UserNotifications

@MainActor
final class PushCoordinator: NSObject, @preconcurrency PKPushRegistryDelegate {
    static let shared = PushCoordinator()
    private var registry: PKPushRegistry?
    private var alertToken: String?
    private var voipToken: String?
    private weak var api: APIClient?
    private var enabled = false
    var wake: (() async -> Void)?
    var openRoom: ((String?) -> Void)?

    func start() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue:.main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    func setAlertToken(_ data: Data) {
        alertToken = Crypto.hex(data)
        if let api { Task { try? await register(api:api,enabled:enabled) } }
    }

    func register(api: APIClient, enabled: Bool) async throws {
        self.api = api
        self.enabled = enabled
        if enabled { UIApplication.shared.registerForRemoteNotifications(); if api.privacy.backgroundCalls { start() } }
        else { let _: APIClient.OK = try await api.request("v1/push",method:"DELETE") }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        struct Body: Encodable { var token: String; var kind: String; var environment: String; var enabled: Bool }
        for (token,kind) in [(alertToken,"alert"),(voipToken,"voip")] {
            if let token {
                let _: APIClient.OK = try await api.request("v1/push",method:"POST",
                    body:Wire.encoder.encode(Body(token:token,kind:kind,environment:environment,enabled:enabled && (kind != "voip" || api.privacy.backgroundCalls))))
            }
        }
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        voipToken = Crypto.hex(pushCredentials.token)
        if let api { Task { try? await register(api:api,enabled:enabled) } }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        if let api, let token=voipToken {
            struct Body: Encodable { var token: String; var kind = "voip"; var environment: String; var enabled = false }
            #if DEBUG
            let environment="sandbox"
            #else
            let environment="production"
            #endif
            Task { let _: APIClient.OK? = try? await api.request("v1/push",method:"POST",
                body:Wire.encoder.encode(Body(token:token,environment:environment))) }
        }
        voipToken=nil
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        // CallKit is notified in this callback, before fetching keys or opening the network.
        let callID=payload.dictionaryPayload["callID"] as? String ?? UUID().uuidString
        let peer=payload.dictionaryPayload["from"] as? String ?? ""
        CallManager.shared.reportPushedCall(peerID:peer,callID:callID,completion:completion)
        Task { await BackgroundCalls.resume(peerID:peer); await wake?() }
    }
}

@MainActor
final class MessengerAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCoordinator.shared.setAlertToken(deviceToken)
    }

    func application(_ application: UIApplication,didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { await PushCoordinator.shared.wake?(); completionHandler(.newData) }
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        Task { await PushCoordinator.shared.wake?() }
    }
}
