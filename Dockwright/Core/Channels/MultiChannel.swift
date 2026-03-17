import Foundation
import os

/// Notification category — determines which user preferences apply.
nonisolated enum NotificationCategory: Sendable, Equatable {
    case scheduledTask  // Governed by notifyOnScheduledTask
    case completion     // Governed by notifyOnCompletion
    case error          // Governed by notifyOnError — bypasses quiet hours
    case general        // Always delivered (respects quiet hours)
}

/// Central notification routing layer.
/// Respects user preferences: channel toggles, quiet hours, sound, and category filters.
/// All notification delivery in Dockwright routes through this class.
nonisolated final class MultiChannel: @unchecked Sendable {
    private let notificationChannel = NotificationChannel()
    private let telegramChannel = TelegramChannel()
    private let discordChannel = DiscordChannel()

    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "MultiChannel")

    nonisolated init() {}

    /// Request permissions for system notification channel.
    func requestPermissions() async {
        await notificationChannel.requestPermission()
    }

    /// Snapshot of the MainActor-isolated preferences we need, captured on MainActor.
    private struct PrefsSnapshot: Sendable {
        let notifyOnScheduledTask: Bool
        let notifyOnCompletion: Bool
        let notifyOnError: Bool
        let isQuietHoursActive: Bool
        let useSystemNotifications: Bool
        let notifySound: Bool
        let useTelegramNotifications: Bool
        let useDiscordNotifications: Bool

        @MainActor static func capture() -> PrefsSnapshot {
            let p = AppPreferences.shared
            return PrefsSnapshot(
                notifyOnScheduledTask: p.notifyOnScheduledTask,
                notifyOnCompletion: p.notifyOnCompletion,
                notifyOnError: p.notifyOnError,
                isQuietHoursActive: p.isQuietHoursActive,
                useSystemNotifications: p.useSystemNotifications,
                notifySound: p.notifySound,
                useTelegramNotifications: p.useTelegramNotifications,
                useDiscordNotifications: p.useDiscordNotifications
            )
        }
    }

    /// Broadcast a notification through all enabled and configured channels.
    /// Respects: channel toggles, quiet hours, category preferences, and sound setting.
    func broadcast(title: String, body: String, category: NotificationCategory = .general) async {
        let prefs = await PrefsSnapshot.capture()

        // Category-level suppression
        switch category {
        case .scheduledTask:
            guard prefs.notifyOnScheduledTask else {
                logger.debug("Notification suppressed: notifyOnScheduledTask is off")
                return
            }
        case .completion:
            guard prefs.notifyOnCompletion else {
                logger.debug("Notification suppressed: notifyOnCompletion is off")
                return
            }
        case .error:
            // Errors bypass quiet hours but still respect the user's notifyOnError toggle
            guard prefs.notifyOnError else {
                logger.debug("Notification suppressed: notifyOnError is off")
                return
            }
        case .general:
            break
        }

        // Quiet hours check — errors bypass quiet hours
        if category != .error && prefs.isQuietHoursActive {
            logger.debug("Notification suppressed: quiet hours active")
            return
        }

        var deliveredCount = 0

        // System notifications
        if prefs.useSystemNotifications {
            do {
                try await notificationChannel.send(title: title, body: body, playSound: prefs.notifySound)
                deliveredCount += 1
            } catch {
                logger.error("NotificationChannel failed: \(error.localizedDescription)")
            }
        }

        // Telegram — only if toggle is on AND credentials exist
        if prefs.useTelegramNotifications && isTelegramConfigured {
            do {
                try await telegramChannel.send(title: title, body: body)
                deliveredCount += 1
            } catch {
                logger.error("TelegramChannel failed: \(error.localizedDescription)")
            }
        }

        // Discord — only if toggle is on AND webhook exists
        if prefs.useDiscordNotifications && isDiscordConfigured {
            do {
                try await discordChannel.send(title: title, body: body)
                deliveredCount += 1
            } catch {
                logger.error("DiscordChannel failed: \(error.localizedDescription)")
            }
        }

        if deliveredCount == 0 {
            logger.info("No channels delivered notification: \(title)")
        } else {
            logger.info("Notification delivered to \(deliveredCount) channel(s): \(title)")
        }
    }

    // MARK: - Credential Checks

    private var isTelegramConfigured: Bool {
        let hasToken = KeychainHelper.read(key: "telegram_bot_token") != nil
        let hasChatId = !(UserDefaults.standard.string(forKey: "telegram_chat_id") ?? "").isEmpty
        return hasToken && hasChatId
    }

    private var isDiscordConfigured: Bool {
        !(UserDefaults.standard.string(forKey: "discord_webhook_url") ?? "").isEmpty
    }
}
