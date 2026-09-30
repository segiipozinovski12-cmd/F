import Foundation
import UserNotifications

final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()

    private override init() {
        super.init()
    }

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func postMessage(title: String, body: String, roomID: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = roomID
        content.userInfo = ["roomID": roomID]

        let request = UNNotificationRequest(
            identifier: "message-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    func scheduleReminder(_ reminder: LocalReminder) {
        let content=UNMutableNotificationContent()
        content.title="VO1D"; content.body="Напоминание о сообщении"; content.sound = .default
        content.userInfo=["roomID":reminder.roomID]
        let trigger=UNTimeIntervalNotificationTrigger(timeInterval:max(1,reminder.at.timeIntervalSinceNow),repeats:false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:reminder.id,content:content,trigger:trigger))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let roomID=response.notification.request.content.userInfo["roomID"] as? String
        Task { @MainActor in PushCoordinator.shared.openRoom?(roomID) }
        completionHandler()
    }

    func clearDelivered() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

