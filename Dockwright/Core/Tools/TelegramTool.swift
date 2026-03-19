import Foundation
import os

nonisolated private let telegramToolLogger = Logger(subsystem: "com.Aatje.Dockwright", category: "telegram-tool")

/// LLM tool for sending messages and photos via the Telegram Bot API.
/// Actions: send_message, send_photo.
nonisolated struct TelegramTool: Tool, @unchecked Sendable {
    let name = "telegram"
    let description = "Send and receive messages via Telegram Bot API. The bot runs bidirectionally — incoming messages are automatically processed and replied to. Use this tool to proactively send messages or photos. Actions: send_message (send a text message), send_photo (send a photo with optional caption)."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: send_message, send_photo",
        ] as [String: Any],
        "message": [
            "type": "string",
            "description": "Text message to send (for send_message)",
            "optional": true,
        ] as [String: Any],
        "photo_path": [
            "type": "string",
            "description": "Absolute path to the image file to send (for send_photo)",
            "optional": true,
        ] as [String: Any],
        "caption": [
            "type": "string",
            "description": "Caption for the photo (for send_photo)",
            "optional": true,
        ] as [String: Any],
        "chat_id": [
            "type": "string",
            "description": "Telegram chat ID to send to. If omitted, uses the default configured chat ID.",
            "optional": true,
        ] as [String: Any],
    ]

    let requiredParams: [String] = ["action"]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing 'action' parameter. Must be one of: send_message, send_photo", isError: true)
        }

        // Resolve bot token
        guard let botToken = KeychainHelper.read(key: "telegram_bot_token"), !botToken.isEmpty else {
            return ToolResult("Telegram not configured. Go to Settings → Integrations to set up your bot token.", isError: true)
        }

        // Resolve chat ID: explicit argument > UserDefaults default
        let chatId: String
        if let explicitId = arguments["chat_id"] as? String, !explicitId.isEmpty {
            chatId = explicitId
        } else if let defaultId = UserDefaults.standard.string(forKey: "telegram_chat_id"), !defaultId.isEmpty {
            chatId = defaultId
        } else {
            return ToolResult("No chat_id provided and no default chat ID configured. Go to Settings → Integrations to set your Telegram Chat ID, or pass chat_id explicitly.", isError: true)
        }

        switch action {
        case "send_message":
            return await sendMessage(botToken: botToken, chatId: chatId, arguments: arguments)
        case "send_photo":
            return await sendPhoto(botToken: botToken, chatId: chatId, arguments: arguments)
        default:
            return ToolResult("Unknown action '\(action)'. Use: send_message, send_photo", isError: true)
        }
    }

    // MARK: - Send Message

    private func sendMessage(botToken: String, chatId: String, arguments: [String: Any]) async -> ToolResult {
        guard let message = arguments["message"] as? String, !message.isEmpty else {
            return ToolResult("Missing 'message' — provide the text to send.", isError: true)
        }

        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage") else {
            return ToolResult("Invalid bot token format.", isError: true)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "chat_id": chatId,
            "text": message,
            "parse_mode": "Markdown",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = json["ok"] as? Bool else {
                let raw = String(data: data.prefix(500), encoding: .utf8) ?? "<unreadable>"
                telegramToolLogger.error("Telegram sendMessage failed: \(raw)")
                return ToolResult("Telegram API returned invalid response: \(raw)", isError: true)
            }
            if ok {
                return ToolResult("Message sent to Telegram chat \(chatId).")
            } else {
                let desc = json["description"] as? String ?? "Unknown error"
                return ToolResult("Telegram API error: \(desc)", isError: true)
            }
        } catch {
            telegramToolLogger.error("Telegram sendMessage network error: \(error.localizedDescription)")
            return ToolResult("Network error sending Telegram message: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Send Photo

    private func sendPhoto(botToken: String, chatId: String, arguments: [String: Any]) async -> ToolResult {
        guard let photoPath = arguments["photo_path"] as? String, !photoPath.isEmpty else {
            return ToolResult("Missing 'photo_path' — provide the absolute path to the image file.", isError: true)
        }

        let fileURL = URL(fileURLWithPath: photoPath)
        guard FileManager.default.fileExists(atPath: photoPath) else {
            return ToolResult("File not found at path: \(photoPath)", isError: true)
        }

        guard let imageData = try? Data(contentsOf: fileURL) else {
            return ToolResult("Could not read file at path: \(photoPath)", isError: true)
        }

        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendPhoto") else {
            return ToolResult("Invalid bot token format.", isError: true)
        }

        let caption = arguments["caption"] as? String
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()

        // chat_id field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(chatId)\r\n".data(using: .utf8)!)

        // caption field (optional)
        if let caption = caption, !caption.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(caption)\r\n".data(using: .utf8)!)
        }

        // photo file
        let filename = fileURL.lastPathComponent
        let mimeType = mimeTypeForExtension(fileURL.pathExtension)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)

        // closing boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = json["ok"] as? Bool else {
                let raw = String(data: data.prefix(500), encoding: .utf8) ?? "<unreadable>"
                telegramToolLogger.error("Telegram sendPhoto failed: \(raw)")
                return ToolResult("Telegram API returned invalid response: \(raw)", isError: true)
            }
            if ok {
                let msg = caption != nil ? "Photo sent to Telegram chat \(chatId) with caption." : "Photo sent to Telegram chat \(chatId)."
                return ToolResult(msg)
            } else {
                let desc = json["description"] as? String ?? "Unknown error"
                return ToolResult("Telegram API error: \(desc)", isError: true)
            }
        } catch {
            telegramToolLogger.error("Telegram sendPhoto network error: \(error.localizedDescription)")
            return ToolResult("Network error sending Telegram photo: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Helpers

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        default: return "image/jpeg"
        }
    }
}
