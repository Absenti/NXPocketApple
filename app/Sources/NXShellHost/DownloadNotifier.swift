import Foundation
import UserNotifications

/// The notification that says downloads stopped while the app was not in front. Local, with no server and no token: nothing
/// leaves the phone. The system's permission is asked for the first time a download starts, because that is the moment its
/// reason is clear; a refusal costs nothing, the notification is simply not shown.
enum DownloadNotifier {
    static func requestPermission() {
        guard NotificationsAvailable.inApp else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard NotificationsAvailable.inApp else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // One identifier: a second notice replaces the first instead of stacking up.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "downloads", content: content, trigger: nil))
    }
}
