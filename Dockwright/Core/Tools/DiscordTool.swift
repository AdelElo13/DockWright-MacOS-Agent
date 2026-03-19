import Foundation
import os

nonisolated private let discordToolLogger = Logger(subsystem: "com.Aatje.Dockwright", category: "discord-tool")

/// LLM tool for sending messages via Discord webhook.
nonisolated struct DiscordTool: Tool, @unchecked Sendable {
    let name = "discord"
    let description = "Send messages to Discord via webhook. Actions: send_message (send a text or embed message)."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: send_message",
        ] as [String: Any],
        "message": [
            "type": "string",
            "description": "Text message to send",
        ] as [String: Any],
        "title": [
            "type": "string",
            "description": "Optional embed title (sends as rich embed instead of plain text)",
            "optional": true,
        ] as [String: Any],
        "webhook_url": [
            "type": "string",
            "description": "Discord webhook URL. If omitted, uses the default configured webhook.",
            "optional": true,
        ] as [String: Any],
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing 'action' parameter.", isError: true)
        }

        // Resolve webhook URL
        let webhookURL: String
        if let url = arguments["webhook_url"] as? String, !url.isEmpty {
            webhookURL = url
        } else if let url = UserDefaults.standard.string(forKey: "discord_webhook_url"), !url.isEmpty {
            webhookURL = url
        } else {
            return ToolResult("Discord not configured. Go to Settings → Integrations to set up your webhook URL.", isError: true)
        }

        switch action {
        case "send_message":
            return await sendMessage(webhookURL: webhookURL, arguments: arguments)
        default:
            return ToolResult("Unknown action '\(action)'. Use: send_message", isError: true)
        }
    }

    private func sendMessage(webhookURL: String, arguments: [String: Any]) async -> ToolResult {
        guard let message = arguments["message"] as? String, !message.isEmpty else {
            return ToolResult("Missing 'message' parameter.", isError: true)
        }

        guard let url = URL(string: webhookURL),
              webhookURL.contains("discord.com/api/webhooks/") || webhookURL.contains("discordapp.com/api/webhooks/") else {
            return ToolResult("Invalid Discord webhook URL.", isError: true)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any]
        if let title = arguments["title"] as? String, !title.isEmpty {
            // Send as embed
            body = [
                "embeds": [[
                    "title": title,
                    "description": message,
                    "color": 562367 // Dockwright teal
                ]]
            ]
        } else {
            // Send as plain text
            body = ["content": message]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                return ToolResult("Discord message sent.")
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return ToolResult("Discord API error (HTTP \(code)).", isError: true)
            }
        } catch {
            return ToolResult("Network error: \(error.localizedDescription)", isError: true)
        }
    }
}
