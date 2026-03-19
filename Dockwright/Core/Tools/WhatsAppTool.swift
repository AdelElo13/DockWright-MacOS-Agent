import Foundation
import os

nonisolated private let whatsappToolLogger = Logger(subsystem: "com.Aatje.Dockwright", category: "whatsapp-tool")

/// LLM tool for sending messages via WhatsApp Cloud API.
nonisolated struct WhatsAppTool: Tool, @unchecked Sendable {
    let name = "whatsapp"
    let description = "Send and receive messages via WhatsApp Cloud API. The bot runs bidirectionally — incoming messages are automatically processed and replied to. Use this tool to proactively send messages. Actions: send_message (send a text message to a phone number)."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: send_message",
        ] as [String: Any],
        "message": [
            "type": "string",
            "description": "Text message to send",
        ] as [String: Any],
        "phone_number": [
            "type": "string",
            "description": "Recipient phone number with country code (e.g. +31612345678). If omitted, uses the default allowed number.",
            "optional": true,
        ] as [String: Any],
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing 'action' parameter.", isError: true)
        }

        guard let token = KeychainHelper.read(key: "whatsapp_token"), !token.isEmpty else {
            return ToolResult("WhatsApp not configured. Go to Settings → Integrations to set up your access token.", isError: true)
        }

        let phoneNumberId = UserDefaults.standard.string(forKey: "whatsapp_phone_number_id") ?? ""
        guard !phoneNumberId.isEmpty else {
            return ToolResult("WhatsApp Phone Number ID not configured. Go to Settings → Integrations.", isError: true)
        }

        switch action {
        case "send_message":
            return await sendMessage(token: token, phoneNumberId: phoneNumberId, arguments: arguments)
        default:
            return ToolResult("Unknown action '\(action)'. Use: send_message", isError: true)
        }
    }

    private func sendMessage(token: String, phoneNumberId: String, arguments: [String: Any]) async -> ToolResult {
        guard let message = arguments["message"] as? String, !message.isEmpty else {
            return ToolResult("Missing 'message' parameter.", isError: true)
        }

        // Resolve phone number
        let phone: String
        if let p = arguments["phone_number"] as? String, !p.isEmpty {
            phone = p.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: " ", with: "")
        } else if let allowed = UserDefaults.standard.string(forKey: "whatsapp_allowed_numbers"), !allowed.isEmpty {
            phone = allowed.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
        } else {
            return ToolResult("No phone_number provided and no default configured. Go to Settings → Integrations.", isError: true)
        }

        guard !phone.isEmpty else {
            return ToolResult("No valid phone number.", isError: true)
        }

        let graphVersion = UserDefaults.standard.string(forKey: "whatsapp_graph_version") ?? "v21.0"
        guard let url = URL(string: "https://graph.facebook.com/\(graphVersion)/\(phoneNumberId)/messages") else {
            return ToolResult("Invalid WhatsApp API URL.", isError: true)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "messaging_product": "whatsapp",
            "to": phone,
            "type": "text",
            "text": ["body": message]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let messages = json["messages"] as? [[String: Any]],
               let _ = messages.first?["id"] {
                return ToolResult("WhatsApp message sent to +\(phone).")
            } else {
                let raw = String(data: data.prefix(500), encoding: .utf8) ?? "<unreadable>"
                whatsappToolLogger.error("WhatsApp send failed: \(raw)")
                return ToolResult("WhatsApp API error: \(raw)", isError: true)
            }
        } catch {
            return ToolResult("Network error: \(error.localizedDescription)", isError: true)
        }
    }
}
