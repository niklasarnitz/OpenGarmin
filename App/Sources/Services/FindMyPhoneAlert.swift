import UserNotifications

/// Shows a sound notification while the watch is ringing the phone (Find my phone), and removes it when the watch
/// stops. The alert is time sensitive and needs no extra entitlement. While OpenGarmin is in the foreground iOS
/// shows no banner for it, so the alert is heard only when the app is in the background.
enum FindMyPhoneAlert {
    private static let identifier = "com.niklasarnitz.opengarmin.find-my-phone"

    static func update(started: Bool) {
        let center = UNUserNotificationCenter.current()
        guard started else {
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Your watch is looking for your phone"
        content.body = "Find my phone was started on the watch."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task { try? await center.add(request) }
    }
}
