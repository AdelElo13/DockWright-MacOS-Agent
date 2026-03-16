import Foundation
import os

/// Delivers messages via Discord webhook.
/// Webhook URL is stored in UserDefaults under "discord_webhook_url".
nonisolated final class DiscordChannel: DeliveryChannel, @unchecked Sendable {
    let name = "discord"

    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "DiscordChannel")
    private let session: URLSession

    nonisolated init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    /// Send a notification to the configured Discord webhook.
    func send(title: String, body: String) async throws {
        guard let webhookURL = UserDefaults.standard.string(forKey: "discord_webhook_url"),
              !webhookURL.isEmpty else {
            logger.warning("Discord notification skipped: no webhook URL configured.")
            return
        }

        try await sendEmbed(title: title, body: body, webhookURL: webhookURL)
    }

    /// Send a notification to a specific Discord webhook URL.
    func send(title: String, body: String, webhookURL: String) async throws {
        guard !webhookURL.isEmpty else {
            throw DiscordError.noWebhookURL
        }
        try await sendEmbed(title: title, body: body, webhookURL: webhookURL)
    }

    // MARK: - Private

    private func sendEmbed(title: String, body: String, webhookURL: String) async throws {
        guard let url = URL(string: webhookURL) else {
            throw DiscordError.invalidURL
        }

        // Validate it looks like a Discord webhook URL
        guard webhookURL.contains("discord.com/api/webhooks/") ||
              webhookURL.contains("discordapp.com/api/webhooks/") else {
            throw DiscordError.invalidURL
        }

        let safeTitle = String(title.prefix(256))
        let safeBody = String(body.prefix(4096)) // Discord embed description limit

        // ISO 8601 timestamp for Discord embed
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let timestamp = isoFormatter.string(from: Date())

        let embed: [String: Any] = [
            "title": safeTitle,
            "description": safeBody,
            "color": 5814783, // #58B9FF — a pleasant blue
            "timestamp": timestamp,
            "footer": [
                "text": "Dockwright"
            ] as [String: Any]
        ]

        let payload: [String: Any] = [
            "embeds": [embed]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DiscordError.invalidResponse
        }

        // Discord returns 204 No Content on success, or 200 with wait=true
        if http.statusCode != 204 && http.statusCode != 200 {
            let errorBody = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            logger.error("Discord webhook failed (HTTP \(http.statusCode)): \(errorBody)")

            if http.statusCode == 429 {
                throw DiscordError.rateLimited
            }
            throw DiscordError.apiFailed(http.statusCode, errorBody)
        }

        logger.info("Discord notification sent: \(safeTitle)")
    }
}

// MARK: - Errors

enum DiscordError: Error, LocalizedError {
    case noWebhookURL
    case invalidURL
    case invalidResponse
    case rateLimited
    case apiFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .noWebhookURL:
            return "No Discord webhook URL configured. Go to Settings > API Keys."
        case .invalidURL:
            return "Invalid Discord webhook URL. It should start with https://discord.com/api/webhooks/"
        case .invalidResponse:
            return "Invalid response from Discord API."
        case .rateLimited:
            return "Discord rate limit reached. Try again in a few seconds."
        case .apiFailed(let code, let body):
            return "Discord API error (HTTP \(code)): \(body)"
        }
    }
}
