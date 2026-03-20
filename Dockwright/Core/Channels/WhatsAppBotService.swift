import Foundation
import Network
import os

// MARK: - WhatsAppBotService

/// Full bidirectional WhatsApp bot using Meta Cloud API.
/// Receives messages via webhook server (NWListener on port 9879),
/// routes through LLM with tools, sends responses back via Graph API.
/// Ported from JarvisMac WhatsAppBotService.
@MainActor
final class WhatsAppBotService {
    static let shared = WhatsAppBotService()
    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "whatsapp-bot")

    private(set) var isRunning = false
    private var webhookTask: Task<Void, Never>?

    // WhatsApp Cloud API credentials
    private var accessToken: String = ""
    private var phoneNumberId: String = ""
    private var verifyToken: String = ""
    private var graphAPIVersion: String = "v21.0"
    private var allowedPhoneNumbers: Set<String> = []

    // Per-sender task tracking
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var lastUserTextPerSender: [String: String] = [:]

    // Per-sender LLM conversation history
    private var chatConversations: [String: [LLMMessage]] = [:]
    private let maxConversationMessages = 20

    // Webhook listener
    private var listener: NWListener?

    // Uptime
    private var startupTime = Date()

    // Callback for main app UI
    var onChatMessage: ((_ from: String, _ userText: String, _ response: String) -> Void)?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        guard let token = KeychainHelper.read(key: "whatsapp_token"), !token.isEmpty else {
            logger.warning("WhatsApp: No access token — skipping")
            return
        }
        let phoneId = UserDefaults.standard.string(forKey: "whatsapp_phone_number_id") ?? ""
        guard !phoneId.isEmpty else {
            logger.warning("WhatsApp: No phone_number_id — skipping")
            return
        }

        self.accessToken = token
        self.phoneNumberId = phoneId
        self.verifyToken = UserDefaults.standard.string(forKey: "whatsapp_verify_token") ?? "dockwright_wa_verify"
        self.graphAPIVersion = UserDefaults.standard.string(forKey: "whatsapp_graph_api_version") ?? "v21.0"

        // Allowed numbers (comma-separated E.164)
        let allowedRaw = UserDefaults.standard.string(forKey: "whatsapp_allowed_numbers") ?? ""
        if !allowedRaw.isEmpty {
            self.allowedPhoneNumbers = Set(allowedRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }

        self.isRunning = true
        self.startupTime = Date()

        logger.info("WhatsApp: Starting with phoneNumberId=\(phoneId), \(self.allowedPhoneNumbers.count) allowed numbers")

        webhookTask = Task { [weak self] in
            await self?.startWebhookServer()
        }
    }

    func stop() {
        isRunning = false
        webhookTask?.cancel()
        webhookTask = nil
        for (_, task) in activeTasks { task.cancel() }
        activeTasks.removeAll()
        listener?.cancel()
        listener = nil
        logger.info("WhatsApp: Stopped")
    }

    // MARK: - Webhook Server (NWListener on port 9879)

    private func startWebhookServer() async {
        do {
            let params = NWParameters.tcp
            let port = NWEndpoint.Port(rawValue: 9879)!
            let nwListener = try NWListener(using: params, on: port)

            nwListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handleConnection(connection)
                }
            }
            nwListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.logger.info("WhatsApp webhook server listening on port 9879")
                case .failed(let error):
                    self?.logger.error("WhatsApp webhook server failed: \(error.localizedDescription)")
                default: break
                }
            }

            self.listener = nwListener
            nwListener.start(queue: .global(qos: .userInitiated))

            // Keep alive
            while isRunning && !Task.isCancelled {
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            logger.error("WhatsApp: Failed to start webhook server: \(error.localizedDescription)")
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, let data else { return }
                let raw = String(data: data, encoding: .utf8) ?? ""
                let response = self.handleHTTPRequest(raw)
                let responseData = Data(response.utf8)
                connection.send(content: responseData, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func handleHTTPRequest(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return httpResponse(400, body: "Bad Request") }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return httpResponse(400, body: "Bad Request") }

        let method = String(parts[0])
        let path = String(parts[1])

        // CORS preflight
        if method == "OPTIONS" {
            return "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nContent-Length: 0\r\n\r\n"
        }

        // Webhook verification (GET)
        if method == "GET" && path.contains("/webhook") {
            return handleVerification(path: path)
        }

        // Incoming message (POST)
        if method == "POST" && path.contains("/webhook") {
            // Extract body after \r\n\r\n
            if let bodyRange = raw.range(of: "\r\n\r\n") {
                let body = String(raw[bodyRange.upperBound...])
                handleWebhookPayload(body)
            }
            return httpResponse(200, body: "OK")
        }

        // Health check
        if method == "GET" && path.contains("/health") {
            return httpResponse(200, body: "{\"status\":\"ok\",\"uptime\":\(Int(Date().timeIntervalSince(startupTime)))}")
        }

        return httpResponse(404, body: "Not Found")
    }

    private func handleVerification(path: String) -> String {
        // Parse query params from path
        guard let queryStart = path.firstIndex(of: "?") else {
            return httpResponse(403, body: "Missing params")
        }
        let query = String(path[path.index(after: queryStart)...])
        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let val = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                params[key] = val
            }
        }

        let mode = params["hub.mode"] ?? ""
        let token = params["hub.verify_token"] ?? ""
        let challenge = params["hub.challenge"] ?? ""

        if mode == "subscribe" && token == verifyToken {
            logger.info("WhatsApp webhook verified")
            return httpResponse(200, body: challenge)
        }
        logger.warning("WhatsApp webhook verification failed: mode=\(mode)")
        return httpResponse(403, body: "Forbidden")
    }

    private func httpResponse(_ code: Int, body: String) -> String {
        let statusText: String
        switch code {
        case 200: statusText = "OK"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        default: statusText = "Error"
        }
        return "HTTP/1.1 \(code) \(statusText)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nAccess-Control-Allow-Origin: *\r\n\r\n\(body)"
    }

    // MARK: - Webhook Payload

    private func handleWebhookPayload(_ body: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (json["entry"] as? [[String: Any]])?.first,
              let changes = (entry["changes"] as? [[String: Any]])?.first,
              let value = changes["value"] as? [String: Any],
              let messages = value["messages"] as? [[String: Any]] else { return }

        for msg in messages {
            guard let from = msg["from"] as? String,
                  let type = msg["type"] as? String else { continue }

            // Authorization check
            if !allowedPhoneNumbers.isEmpty && !allowedPhoneNumbers.contains(from) && !allowedPhoneNumbers.contains("+\(from)") {
                logger.warning("WhatsApp: Ignoring message from unauthorized number: \(from)")
                continue
            }

            var text = ""
            var mediaId: String?
            var mediaType: String?
            switch type {
            case "text":
                text = (msg["text"] as? [String: Any])?["body"] as? String ?? ""
            case "image", "video", "document", "audio":
                let mediaObj = msg[type] as? [String: Any]
                text = mediaObj?["caption"] as? String ?? ""
                mediaId = mediaObj?["id"] as? String
                mediaType = type
            case "location":
                if let loc = msg["location"] as? [String: Any],
                   let lat = loc["latitude"], let lon = loc["longitude"] {
                    text = "Location: \(lat), \(lon)"
                }
            default:
                text = "[\(type) message received]"
            }

            guard !text.isEmpty || mediaId != nil else { continue }

            // Cancel existing task for this sender
            if let existing = activeTasks[from] {
                existing.cancel()
                activeTasks.removeValue(forKey: from)
            }

            lastUserTextPerSender[from] = text
            let sender = from
            let messageText = text
            let capturedMediaId = mediaId
            let capturedMediaType = mediaType

            activeTasks[sender] = Task { [weak self] in
                guard let self else { return }
                defer { Task { @MainActor [weak self] in self?.activeTasks.removeValue(forKey: sender) } }
                if let mid = capturedMediaId, let mtype = capturedMediaType {
                    await self.processMediaMessage(from: sender, text: messageText, mediaId: mid, mediaType: mtype)
                } else {
                    await self.processMessage(from: sender, text: messageText)
                }
            }
        }
    }

    // MARK: - Media Processing

    /// Download WhatsApp media by media ID via Graph API
    private func downloadWhatsAppMedia(mediaId: String) async -> URL? {
        guard !accessToken.isEmpty else { return nil }
        let token = accessToken
        // Step 1: Get media URL
        guard let infoURL = URL(string: "https://graph.facebook.com/v18.0/\(mediaId)") else { return nil }
        var infoReq = URLRequest(url: infoURL)
        infoReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: infoReq),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mediaURL = json["url"] as? String,
              let dlURL = URL(string: mediaURL) else { return nil }
        // Step 2: Download actual file
        var dlReq = URLRequest(url: dlURL)
        dlReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (fileData, _) = try? await URLSession.shared.data(for: dlReq) else { return nil }
        let ext = (json["mime_type"] as? String)?.components(separatedBy: "/").last ?? "bin"
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("wa_\(UUID().uuidString).\(ext)")
        try? fileData.write(to: localURL)
        return localURL
    }

    /// Process media from WhatsApp — images go to vision, files go to tools
    private func processMediaMessage(from: String, text: String, mediaId: String, mediaType: String) async {
        guard !Task.isCancelled else { return }
        _ = await sendTextMessage(to: from, text: "📥 Downloading \(mediaType)...")

        guard let localURL = await downloadWhatsAppMedia(mediaId: mediaId) else {
            _ = await sendTextMessage(to: from, text: "❌ Could not download \(mediaType)")
            return
        }

        if mediaType == "image" {
            // Image → base64 → LLM vision
            guard let imageData = try? Data(contentsOf: localURL) else {
                _ = await sendTextMessage(to: from, text: "❌ Could not read image")
                return
            }
            let base64 = imageData.base64EncodedString()
            let ext = localURL.pathExtension.lowercased()
            let mime = ext == "png" ? "image/png" : ext == "gif" ? "image/gif" : "image/jpeg"
            let imageContent = ImageContent(type: "base64", mediaType: mime, data: base64)
            try? FileManager.default.removeItem(at: localURL)
            let prompt = text.isEmpty ? "What's in this image?" : text
            await processMessage(from: from, text: prompt, images: [imageContent])
        } else {
            // Document/audio/video → save and tell LLM the path
            let destDir = NSHomeDirectory() + "/.dockwright/downloads"
            try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            let destPath = destDir + "/" + localURL.lastPathComponent
            try? FileManager.default.moveItem(at: localURL, to: URL(fileURLWithPath: destPath))
            let prompt = text.isEmpty
                ? "The user sent a \(mediaType). It's saved at \(destPath). Analyze or process it."
                : "\(text)\n\nFile saved at: \(destPath)"
            await processMessage(from: from, text: prompt)
        }
    }

    // MARK: - Process Message

    private func processMessage(from: String, text: String, images: [ImageContent]? = nil) async {
        guard !Task.isCancelled else { return }

        // Send "thinking" indicator
        await sendTextMessage(to: from, text: "🧠 Thinking...")

        let startTime = Date()
        let prefs = AppPreferences.shared
        let model = prefs.selectedModel

        guard let apiKey = resolveAPIKey(model: model) else {
            await sendTextMessage(to: from, text: "❌ No API key configured.")
            return
        }

        var systemPrompt = """
        You are Dockwright, a powerful macOS AI assistant responding via WhatsApp.
        Be very concise — WhatsApp messages should be short and clear.
        Avoid code blocks unless specifically asked. Use plain text formatting.
        \(prefs.responseStylePrompt)
        """

        let custom = prefs.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { systemPrompt += "\n\nUser instructions:\n\(custom)" }

        // Language preference
        let sttLang = VoiceService.effectiveLanguage
        if sttLang.hasPrefix("nl") {
            systemPrompt += "\n\nIMPORTANT: Always respond in Dutch (Nederlands)."
        } else if sttLang.hasPrefix("de") {
            systemPrompt += "\n\nIMPORTANT: Always respond in German (Deutsch)."
        } else if sttLang.hasPrefix("fr") {
            systemPrompt += "\n\nIMPORTANT: Always respond in French (Français)."
        } else if sttLang.hasPrefix("es") {
            systemPrompt += "\n\nIMPORTANT: Always respond in Spanish (Español)."
        } else if !sttLang.hasPrefix("en") {
            systemPrompt += "\n\nIMPORTANT: Always respond in the language matching locale: \(sttLang)."
        }

        var userMsg = LLMMessage.user(text)
        if let imgs = images, !imgs.isEmpty { userMsg.images = imgs }

        // Load conversation history for this sender
        var history = chatConversations[from] ?? []
        history.append(userMsg)
        if history.count > maxConversationMessages {
            history = Array(history.suffix(maxConversationMessages))
        }
        var llmMessages: [LLMMessage] = history
        let llm = LLMService()
        let toolDefs = ToolRegistry.shared.anthropicToolDefinitions()
        let toolExecutor = ToolExecutor()
        let maxLoops = 10
        var loopCount = 0
        var finalText = ""

        do {
            while loopCount < maxLoops {
                if Task.isCancelled { break }
                loopCount += 1

                let response = try await llm.streamChat(
                    messages: llmMessages,
                    tools: toolDefs.isEmpty ? nil : toolDefs,
                    model: model,
                    apiKey: apiKey,
                    systemPrompt: systemPrompt,
                    temperature: prefs.temperature,
                    maxTokens: prefs.maxTokens
                ) { _ in } // WhatsApp can't edit messages, so no progress updates

                if let content = response.content, !content.isEmpty {
                    finalText = content
                }

                guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else { break }

                llmMessages.append(.assistant(response.content ?? "", toolCalls: toolCalls))

                for tc in toolCalls {
                    if Task.isCancelled { break }
                    let args = toolExecutor.parseArguments(tc.function.arguments)
                    let result = await toolExecutor.executeTool(name: tc.function.name, arguments: args)
                    llmMessages.append(.tool(callId: tc.id, content: result.output))
                }
            }

            let duration = String(format: "%.1f", Date().timeIntervalSince(startTime))

            // Send final response (split if needed)
            await sendFinalResponse(to: from, text: finalText)

            logger.info("WhatsApp: Completed for \(from) in \(duration)s")
            // Save conversation history
            history.append(LLMMessage.assistant(finalText))
            if history.count > maxConversationMessages {
                history = Array(history.suffix(maxConversationMessages))
            }
            chatConversations[from] = history

            onChatMessage?(from, text, finalText)

        } catch {
            await sendTextMessage(to: from, text: "❌ Error: \(error.localizedDescription)")
        }
    }

    // MARK: - WhatsApp Cloud API

    private func sendTextMessage(to phone: String, text: String) async {
        guard !text.isEmpty else { return }
        guard let url = URL(string: "https://graph.facebook.com/\(graphAPIVersion)/\(phoneNumberId)/messages") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "messaging_product": "whatsapp",
            "to": phone,
            "type": "text",
            "text": ["body": String(text.prefix(4096))]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let errBody = String(data: data.prefix(200), encoding: .utf8) ?? ""
                logger.error("WhatsApp sendMessage failed (HTTP \(http.statusCode)): \(errBody)")
            }
        } catch {
            logger.error("WhatsApp sendMessage error: \(error.localizedDescription)")
        }
    }

    private func sendFinalResponse(to phone: String, text: String) async {
        guard !text.isEmpty else { return }
        if text.count <= 4000 {
            await sendTextMessage(to: phone, text: text)
        } else {
            let chunks = splitMessage(text, maxLen: 4000)
            for chunk in chunks {
                await sendTextMessage(to: phone, text: chunk)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func splitMessage(_ text: String, maxLen: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if current.count + line.count + 1 > maxLen && !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func resolveAPIKey(model: String) -> String? {
        let provider = LLMModels.provider(for: model)
        switch provider {
        case .anthropic:
            if let key = KeychainHelper.read(key: "anthropic_api_key"), !key.isEmpty,
               !key.hasPrefix("sk-ant-oat") { return key }
            if let oauth = KeychainHelper.read(key: "claude_oauth_token"), !oauth.isEmpty { return oauth }
            if let ccToken = AuthManager.readFreshClaudeCodeOAuthToken() { return ccToken }
            return nil
        case .openai:
            if let oauth = KeychainHelper.read(key: "openai_oauth_token"), !oauth.isEmpty { return oauth }
            return KeychainHelper.read(key: "openai_api_key")
        case .ollama:
            return ""
        case .google, .xai, .mistral, .deepseek, .kimi:
            return KeychainHelper.read(key: provider.keychainKey)
        }
    }
}
