import Foundation
import UserNotifications

/// Meldet neu im Netz aufgetauchte Geräte per macOS-Benachrichtigung.
/// Funktioniert nur im App-Bundle — bei `swift run` gibt es keines, und
/// UNUserNotificationCenter crasht ohne Bundle; daher der Guard.
@MainActor
enum NewDeviceNotifier {

    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// Beim Aktivieren des Auto-Scans einmalig die Berechtigung anfordern.
    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(about devices: [Device]) {
        guard available, !devices.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        for d in devices {
            let content = UNMutableNotificationContent()
            content.title = "Neues Gerät im Netzwerk"
            content.body = "\(d.displayName) (\(d.ip))"
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "new-device-\(d.ip)",
                                             content: content, trigger: nil))
        }
    }
}
