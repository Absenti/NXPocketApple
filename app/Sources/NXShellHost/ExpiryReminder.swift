import Foundation
import UserNotifications

/// The reminders that a sideloaded app's signature is about to run out. A free account's certificate and profile last seven days;
/// when they end the games stop opening, and the first sign is a game that refuses to start. The reminders are local
/// notifications set from the dates the app can read itself (the certificate the player imported, the profile SideStore
/// embedded), so they move by themselves when SideStore renews the profile and nothing is sent anywhere.
enum ExpiryReminder {
    struct Moment: Equatable {
        enum Kind: String { case dayBefore = "expiry-1d", hoursBefore = "expiry-2h" }
        var kind: Kind
        var at: Date
    }

    /// What ends the app's ability to sign and run: whichever of the two ends first.
    static func expiry(certificate: Date?, profile: Date?) -> Date? {
        [certificate, profile].compactMap { $0 }.min()
    }

    /// A day before and two hours before `expiry`, the ones still ahead. A reminder less than a minute away is not set: it
    /// would arrive while the player is reading the screen that explains it.
    static func moments(expiry: Date?, now: Date = Date()) -> [Moment] {
        guard let expiry else { return [] }
        return [Moment(kind: .dayBefore, at: expiry.addingTimeInterval(-24 * 3600)),
                Moment(kind: .hoursBefore, at: expiry.addingTimeInterval(-2 * 3600))]
            .filter { $0.at.timeIntervalSince(now) > 60 }
    }

    /// Replaces every reminder with the ones `moments` names. Asking for the system's permission is part of the first one.
    static func schedule(_ moments: [Moment], title: String, body: (Moment.Kind) -> String) {
        guard NotificationsAvailable.inApp else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Moment.Kind.dayBefore.rawValue, Moment.Kind.hoursBefore.rawValue])
        guard !moments.isEmpty else { return }
        // The texts are made now: the permission answer comes later, on another thread.
        let bodies = Dictionary(uniqueKeysWithValues: moments.map { ($0.kind, body($0.kind)) })
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for moment in moments {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = bodies[moment.kind] ?? ""
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(moment.at.timeIntervalSinceNow, 1), repeats: false)
                center.add(UNNotificationRequest(identifier: moment.kind.rawValue, content: content, trigger: trigger))
            }
        }
    }
}

enum NotificationsAvailable {
    /// The notification centre exists only in an app: a test process has none, and asking for it ends the test.
    static var inApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }
}
