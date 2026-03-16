import Foundation
import UserNotifications
import os

/// Delivers messages via macOS UNUserNotificationCenter.
final class NotificationChannel: DeliveryChannel, @unchecked Sendable {
    let name = "notification"

    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "NotificationChannel")
    private var permissionGranted = false

    /// Request notification permission. Safe to call multiple times.
    func requestPermission() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            permissionGranted = granted
            if granted {
                logger.info("Notification permission granted.")
            } else {
                logger.warning("Notification permission denied by user.")
            }
        } catch {
            logger.error("Failed to request notification permission: \(error.localizedDescription)")
        }
    }

    func send(title: String, body: String) async throws {
        // Ensure permission on first use
        if !permissionGranted {
            await requestPermission()
        }

        guard permissionGranted else {
            logger.warning("Notification not sent (permission denied): \(title)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(256)) // Cap title length
        content.body = String(body.prefix(4096))   // Cap body length
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // Deliver immediately
        )

        do {
            try await center.add(request)
            logger.info("Notification sent: \(title)")
        } catch {
            logger.error("Failed to send notification: \(error.localizedDescription)")
        }
    }
}
