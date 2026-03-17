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

    /// DeliveryChannel protocol conformance (default sound behavior).
    func send(title: String, body: String) async throws {
        try await send(title: title, body: body, playSound: true)
    }

    /// Send a notification with optional sound control.
    func send(title: String, body: String, playSound: Bool) async throws {
        if !permissionGranted {
            await requestPermission()
        }

        guard permissionGranted else {
            logger.warning("Notification not sent (permission denied): \(title)")
            throw NotificationError.permissionDenied
        }

        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(256))
        content.body = String(body.prefix(4096))
        content.sound = playSound ? .default : nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        try await center.add(request)
        logger.info("Notification sent: \(title)")
    }
}

enum NotificationError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Notification permission denied"
        }
    }
}
