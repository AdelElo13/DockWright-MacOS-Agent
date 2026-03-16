import Foundation
import os

/// Delivers messages via Telegram Bot API.
/// Bot token is stored in Keychain under "telegram_bot_token".
/// Chat ID is stored in UserDefaults under "telegram_chat_id".
final class TelegramChannel: DeliveryChannel, @unchecked Sendable {
    let name = "telegram"

    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "TelegramChannel")
    private let session: URLSession

    nonisolated init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    /// Send a notification to the configured Telegram chat.
    /// - Parameters:
    ///   - title: Message title (shown bold in Telegram).
    ///   - body: Message body text.
    func send(title: String, body: String) async throws {
        guard let token = KeychainHelper.read(key: "telegram_bot_token"), !token.isEmpty else {
            logger.warning("Telegram notification skipped: no bot token configured.")
            return
        }

        let chatId = UserDefaults.standard.string(forKey: "telegram_chat_id") ?? ""
        guard !chatId.isEmpty else {
            logger.warning("Telegram notification skipped: no chat ID configured.")
            return
        }

        try await sendMessage(title: title, body: body, chatId: chatId, token: token)
    }

    /// Send a message to a specific Telegram chat.
    /// - Parameters:
    ///   - title: Message title (rendered bold via HTML).
    ///   - body: Message body.
    ///   - chatId: Telegram chat ID (user, group, or channel).
    ///   - token: Bot API token (optional, reads from Keychain if nil).
    func send(title: String, body: String, chatId: String, token: String? = nil) async throws {
        let resolvedToken: String
        if let token, !token.isEmpty {
            resolvedToken = token
        } else if let stored = KeychainHelper.read(key: "telegram_bot_token"), !stored.isEmpty {
            resolvedToken = stored
        } else {
            throw TelegramError.noToken
        }

        try await sendMessage(title: title, body: body, chatId: chatId, token: resolvedToken)
    }

    // MARK: - Private

    private func sendMessage(title: String, body: String, chatId: String, token: String) async throws {
        let urlStr = "https://api.telegram.org/bot\(token)/sendMessage"
        guard let url = URL(string: urlStr) else {
            throw TelegramError.invalidURL
        }

        // Format as HTML for bold title
        let safeTitle = escapeHTML(String(title.prefix(256)))
        let safeBody = escapeHTML(String(body.prefix(4000)))
        let text = "<b>\(safeTitle)</b>\n\(safeBody)"

        let payload: [String: Any] = [
            "chat_id": chatId,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": true
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TelegramError.invalidResponse
        }

        if http.statusCode != 200 {
            let errorBody = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            logger.error("Telegram sendMessage failed (HTTP \(http.statusCode)): \(errorBody)")
            throw TelegramError.apiFailed(http.statusCode, errorBody)
        }

        logger.info("Telegram notification sent: \(title)")
    }

    /// Escape HTML entities for Telegram's HTML parse mode.
    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - Errors

enum TelegramError: Error, LocalizedError {
    case noToken
    case noChatId
    case invalidURL
    case invalidResponse
    case apiFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .noToken: return "No Telegram bot token configured. Go to Settings > API Keys."
        case .noChatId: return "No Telegram chat ID configured. Go to Settings > API Keys."
        case .invalidURL: return "Invalid Telegram API URL."
        case .invalidResponse: return "Invalid response from Telegram API."
        case .apiFailed(let code, let body): return "Telegram API error (HTTP \(code)): \(body)"
        }
    }
}
