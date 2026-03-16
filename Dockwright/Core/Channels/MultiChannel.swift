import Foundation
import os

/// Routes notifications to all configured delivery channels.
/// Checks each channel for valid credentials before sending and continues
/// if an individual channel fails, logging the error.
nonisolated final class MultiChannel: @unchecked Sendable {
    let channels: [any DeliveryChannel]

    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "MultiChannel")

    /// Initialize with all available channels.
    /// By default includes Notification Center, Telegram, and Discord.
    nonisolated init(channels: [any DeliveryChannel]? = nil) {
        self.channels = channels ?? [
            NotificationChannel(),
            TelegramChannel(),
            DiscordChannel()
        ]
    }

    /// Broadcast a notification to all channels that have credentials configured.
    /// Failures on individual channels are logged but do not stop delivery to others.
    func broadcast(title: String, body: String) async {
        let activeChannels = configuredChannels()

        if activeChannels.isEmpty {
            logger.info("No channels configured for broadcast.")
            return
        }

        logger.info("Broadcasting to \(activeChannels.count) channel(s): \(activeChannels.map(\.name).joined(separator: ", "))")

        await withTaskGroup(of: Void.self) { group in
            for channel in activeChannels {
                group.addTask {
                    do {
                        try await channel.send(title: title, body: body)
                    } catch {
                        self.logger.error("Channel '\(channel.name)' failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Returns channels that have their required credentials configured.
    private func configuredChannels() -> [any DeliveryChannel] {
        channels.filter { isConfigured($0) }
    }

    /// Check if a channel has its required credentials/configuration.
    private func isConfigured(_ channel: any DeliveryChannel) -> Bool {
        switch channel.name {
        case "notification":
            // Notification Center is always available on macOS
            return true

        case "telegram":
            let hasToken = KeychainHelper.read(key: "telegram_bot_token") != nil
            let hasChatId = !(UserDefaults.standard.string(forKey: "telegram_chat_id") ?? "").isEmpty
            return hasToken && hasChatId

        case "discord":
            let hasWebhook = !(UserDefaults.standard.string(forKey: "discord_webhook_url") ?? "").isEmpty
            return hasWebhook

        default:
            // Unknown channels are assumed configured — they can handle
            // missing credentials themselves by throwing in send().
            return true
        }
    }
}
