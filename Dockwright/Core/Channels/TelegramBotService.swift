import Foundation
import os

// MARK: - Nonisolated Helpers

private func escapeHTMLBot(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func buildProgressHTML(tools: [TGToolProgress], phase: String, elapsed: Int) -> String {
    var html = "🔄 <b>\(escapeHTMLBot(phase))</b>\n━━━━━━━━━━━━━━━━━━━\n"
    if !tools.isEmpty {
        html += "⚡ <b>Tools:</b>\n"
        for tool in tools.suffix(8) {
            let name = escapeHTMLBot(tool.name)
            let preview = escapeHTMLBot(String(tool.preview.prefix(55)).replacingOccurrences(of: "\n", with: " "))
            switch tool.status {
            case .running:   html += "  ⚙️ <code>\(name)</code> → <i>Running...</i>\n"
            case .completed: html += "  ✅ <code>\(name)</code> → <i>\(preview)</i>\n"
            case .failed:    html += "  ❌ <code>\(name)</code> → <i>\(preview)</i>\n"
            }
        }
        if tools.count > 8 { html += "  ... +\(tools.count - 8) more\n" }
    }
    html += "⏱ \(elapsed)s"
    return html
}

private func fireEditHTML(token: String, chatId: String, messageId: Int, html: String) {
    Task.detached {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/editMessageText") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        let body: [String: Any] = ["chat_id": chatId, "message_id": messageId, "text": html, "parse_mode": "HTML"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}

// MARK: - Types

enum TGMediaType: Sendable { case text, photo, document, voice, audio, video }

struct TGUpdate: Sendable {
    let chatId: String
    let text: String
    let from: String
    let mediaType: TGMediaType
    let fileId: String?
    let fileName: String?
}

struct TGCallbackQuery: Sendable {
    let id: String
    let chatId: String
    let messageId: Int
    let data: String
    let from: String
}

struct TGInlineButton: Sendable {
    let text: String
    let callbackData: String
}

nonisolated enum TGToolStatus: Sendable, Equatable { case running, completed, failed }

struct TGToolProgress: Sendable {
    let name: String
    var status: TGToolStatus
    var preview: String
}

// MARK: - TelegramBotService

/// Full bidirectional Telegram bot: polls for messages, routes through LLM with tools,
/// sends real-time progress updates. Ported from JarvisMac TelegramBotService.
@MainActor
final class TelegramBotService {
    static let shared = TelegramBotService()
    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "telegram-bot")

    private(set) var isRunning = false
    private var pollTask: Task<Void, Never>?
    private var lastUpdateId: Int = 0

    // Credentials
    private var botToken: String = ""
    private var allowedChatIds: Set<String> = []
    private(set) var isDiscoveryMode: Bool = false

    // Per-chat task tracking
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var lastUserTextPerChat: [String: String] = [:]

    // Message history ring buffer for LLM context
    private var messageHistory: [(timestamp: Date, from: String, text: String)] = []
    private let maxMessageHistory = 20

    // Uptime
    private var startupTime = Date()

    // Exponential backoff: 100ms → 500ms → 1s → 2s → 3s → 5s
    private var pollBackoffMs: Int = 100
    private let pollBackoffSteps = [100, 500, 1000, 2000, 3000, 5000]
    private var consecutiveEmptyPolls = 0

    // Media directory
    private var mediaDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dockwright/media/inbound", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Callback for displaying messages in main app UI
    var onChatMessage: ((_ from: String, _ userText: String, _ response: String) -> Void)?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else {
            NSLog("[TelegramBot] Already running, skipping start")
            return
        }
        guard let token = KeychainHelper.read(key: "telegram_bot_token"), !token.isEmpty else {
            NSLog("[TelegramBot] No bot token found — skipping start")
            logger.warning("No bot token — skipping Telegram bot start")
            return
        }

        self.botToken = token
        NSLog("[TelegramBot] Token loaded (\(token.prefix(8))...)")

        // Load chat IDs or enter discovery mode
        let chatIdStr = UserDefaults.standard.string(forKey: "telegram_chat_id") ?? ""
        if !chatIdStr.isEmpty {
            let ids = chatIdStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            self.allowedChatIds = Set(ids.filter { Int64($0) != nil })
            self.isDiscoveryMode = false
            NSLog("[TelegramBot] Starting with \(self.allowedChatIds.count) allowed chat(s): \(self.allowedChatIds)")
        } else {
            self.allowedChatIds = []
            self.isDiscoveryMode = true
            NSLog("[TelegramBot] Starting in DISCOVERY mode — will auto-learn chat ID")
        }

        self.isRunning = true
        self.startupTime = Date()

        pollTask = Task { [weak self] in
            NSLog("[TelegramBot] Poll task started")
            await self?.pollLoop()
            NSLog("[TelegramBot] Poll task ended")
        }
        NSLog("[TelegramBot] start() complete — polling launched")
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        for (_, task) in activeTasks { task.cancel() }
        activeTasks.removeAll()
        logger.info("Telegram bot stopped")
    }

    // MARK: - Context for LLM

    func contextString(limit: Int = 5) -> String {
        let msgs = messageHistory.suffix(limit)
        guard !msgs.isEmpty else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let lines = msgs.map { "[\(fmt.string(from: $0.timestamp))] \($0.from): \($0.text)" }
        return "[TELEGRAM INBOX]\n\(lines.joined(separator: "\n"))"
    }

    // MARK: - Polling Loop

    private func pollLoop() async {
        // Register commands and send startup greeting
        Task { [weak self] in
            await self?.setupCommands()
            guard let self else { return }
            for chatId in self.allowedChatIds {
                _ = await self.sendHTMLMessage(chatId: chatId, html: "🟢 <b>Dockwright is online!</b>\nType /help for commands.")
            }
        }

        NSLog("[TelegramBot] Entering poll loop, isRunning=\(isRunning)")
        while isRunning && !Task.isCancelled {
            do {
                let (updates, callbacks) = try await getUpdates()
                let hasActivity = !updates.isEmpty || !callbacks.isEmpty
                if hasActivity { NSLog("[TelegramBot] Got \(updates.count) updates, \(callbacks.count) callbacks") }

                if hasActivity {
                    consecutiveEmptyPolls = 0
                    pollBackoffMs = pollBackoffSteps[0]
                } else {
                    consecutiveEmptyPolls += 1
                    let idx = min(consecutiveEmptyPolls, pollBackoffSteps.count - 1)
                    pollBackoffMs = pollBackoffSteps[idx]
                }

                for update in updates { await handleUpdate(update) }
                for cb in callbacks { await handleCallbackQuery(cb) }
            } catch {
                NSLog("[TelegramBot] Poll error: \(error.localizedDescription)")
                logger.error("Poll error: \(error.localizedDescription)")
                pollBackoffMs = 2000
            }
            try? await Task.sleep(for: .milliseconds(pollBackoffMs))
            guard !Task.isCancelled else { return }
        }
    }

    // MARK: - Setup Commands

    private func setupCommands() async {
        let commands: [[String: String]] = [
            ["command": "start",   "description": "Welcome & overview"],
            ["command": "help",    "description": "All commands"],
            ["command": "status",  "description": "Live dashboard"],
            ["command": "stop",    "description": "Stop current task"],
            ["command": "clear",   "description": "Clear chat history"],
            ["command": "model",   "description": "Current model info"],
            ["command": "tools",   "description": "Available tools"],
            ["command": "dice",    "description": "Roll a die"],
        ]
        _ = await postJSON("setMyCommands", body: ["commands": commands])
        for chatId in allowedChatIds {
            _ = await postJSON("setChatMenuButton", body: [
                "chat_id": chatId, "menu_button": ["type": "commands"]
            ])
        }
    }

    // MARK: - Telegram API

    private func getUpdates() async throws -> ([TGUpdate], [TGCallbackQuery]) {
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/getUpdates?offset=\(lastUpdateId + 1)&timeout=5&allowed_updates=[\"message\",\"callback_query\"]") else { return ([], []) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool, ok,
              let results = json["result"] as? [[String: Any]] else {
            let raw = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            NSLog("[TelegramBot] getUpdates parse failed: %@", raw)
            return ([], [])
        }
        if !results.isEmpty { NSLog("[TelegramBot] getUpdates raw: %d results", results.count) }

        var updates: [TGUpdate] = []
        var callbacks: [TGCallbackQuery] = []

        for r in results {
            let updateId = r["update_id"] as? Int ?? 0
            if updateId > lastUpdateId { lastUpdateId = updateId }

            if let cbq = r["callback_query"] as? [String: Any] {
                let cbId = cbq["id"] as? String ?? ""
                let cbData = cbq["data"] as? String ?? ""
                let cbFrom = (cbq["from"] as? [String: Any])?["first_name"] as? String ?? "User"
                if let cbMsg = cbq["message"] as? [String: Any],
                   let cbChat = cbMsg["chat"] as? [String: Any],
                   let cbChatId = cbChat["id"] as? Int {
                    callbacks.append(TGCallbackQuery(
                        id: cbId, chatId: String(cbChatId),
                        messageId: cbMsg["message_id"] as? Int ?? 0,
                        data: cbData, from: cbFrom
                    ))
                }
                continue
            }

            guard let msg = r["message"] as? [String: Any],
                  let chat = msg["chat"] as? [String: Any],
                  let chatId = chat["id"] as? Int else { continue }

            let from = (msg["from"] as? [String: Any])?["first_name"] as? String ?? "User"
            let chatIdStr = String(chatId)
            let caption = msg["caption"] as? String

            if let photos = msg["photo"] as? [[String: Any]], let largest = photos.last,
               let fileId = largest["file_id"] as? String {
                updates.append(TGUpdate(chatId: chatIdStr, text: caption ?? "", from: from, mediaType: .photo, fileId: fileId, fileName: nil))
                continue
            }
            if let doc = msg["document"] as? [String: Any], let fileId = doc["file_id"] as? String {
                updates.append(TGUpdate(chatId: chatIdStr, text: caption ?? "", from: from, mediaType: .document, fileId: fileId, fileName: doc["file_name"] as? String))
                continue
            }
            if let voice = msg["voice"] as? [String: Any], let fileId = voice["file_id"] as? String {
                updates.append(TGUpdate(chatId: chatIdStr, text: caption ?? "", from: from, mediaType: .voice, fileId: fileId, fileName: nil))
                continue
            }
            if let audio = msg["audio"] as? [String: Any], let fileId = audio["file_id"] as? String {
                updates.append(TGUpdate(chatId: chatIdStr, text: caption ?? "", from: from, mediaType: .audio, fileId: fileId, fileName: audio["file_name"] as? String))
                continue
            }
            if let video = msg["video"] as? [String: Any], let fileId = video["file_id"] as? String {
                updates.append(TGUpdate(chatId: chatIdStr, text: caption ?? "", from: from, mediaType: .video, fileId: fileId, fileName: video["file_name"] as? String))
                continue
            }
            if let text = msg["text"] as? String {
                updates.append(TGUpdate(chatId: chatIdStr, text: text, from: from, mediaType: .text, fileId: nil, fileName: nil))
            }
        }
        return (updates, callbacks)
    }

    @discardableResult
    private func sendMessage(chatId: String, text: String) async -> Int? {
        let body: [String: Any] = ["chat_id": chatId, "text": text]
        guard let json = await postJSON("sendMessage", body: body),
              let result = json["result"] as? [String: Any] else { return nil }
        return result["message_id"] as? Int
    }

    @discardableResult
    private func sendHTMLMessage(chatId: String, html: String, replyMarkup: [[TGInlineButton]]? = nil) async -> Int? {
        var body: [String: Any] = ["chat_id": chatId, "text": html, "parse_mode": "HTML"]
        if let markup = replyMarkup {
            body["reply_markup"] = ["inline_keyboard": markup.map { row in row.map { ["text": $0.text, "callback_data": $0.callbackData] } }]
        }
        guard let json = await postJSON("sendMessage", body: body),
              let result = json["result"] as? [String: Any] else {
            // Fallback without HTML
            return await sendMessage(chatId: chatId, text: html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        }
        return result["message_id"] as? Int
    }

    private func editHTMLMessage(chatId: String, messageId: Int, html: String, replyMarkup: [[TGInlineButton]]? = nil) async {
        var body: [String: Any] = ["chat_id": chatId, "message_id": messageId, "text": html, "parse_mode": "HTML"]
        if let markup = replyMarkup {
            body["reply_markup"] = ["inline_keyboard": markup.map { row in row.map { ["text": $0.text, "callback_data": $0.callbackData] } }]
        }
        _ = await postJSON("editMessageText", body: body)
    }

    private func sendChatAction(chatId: String) async {
        _ = await postJSON("sendChatAction", body: ["chat_id": chatId, "action": "typing"])
    }

    private func answerCallbackQuery(id: String, text: String? = nil) async {
        var body: [String: Any] = ["callback_query_id": id]
        if let t = text { body["text"] = t }
        _ = await postJSON("answerCallbackQuery", body: body)
    }

    private func postJSON(_ endpoint: String, body: [String: Any]) async -> [String: Any]? {
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/\(endpoint)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool, ok else { return nil }
        return json
    }

    // MARK: - Media Download

    // MARK: - Typing Loop

    private func startTypingLoop(chatId: String) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendChatAction(chatId: chatId)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    // MARK: - Message Routing

    private func handleUpdate(_ update: TGUpdate) async {
        // Discovery mode: auto-learn chat ID
        if isDiscoveryMode && !update.chatId.isEmpty {
            logger.info("Discovery: auto-learned chat ID \(update.chatId) from \(update.from)")
            allowedChatIds.insert(update.chatId)
            UserDefaults.standard.set(update.chatId, forKey: "telegram_chat_id")
            isDiscoveryMode = false
            _ = await sendHTMLMessage(chatId: update.chatId, html: "🟢 <b>Chat linked!</b>\nYour chat ID has been saved. You're connected to Dockwright.")
        }

        guard allowedChatIds.contains(update.chatId) else { return }

        // Slash commands
        if update.mediaType == .text && update.text.hasPrefix("/") {
            let parts = update.text.split(separator: " ", maxSplits: 1)
            var cmd = String(parts[0]).lowercased()
            if let at = cmd.firstIndex(of: "@") { cmd = String(cmd[..<at]) }
            let args = parts.count > 1 ? String(parts[1]) : ""
            await handleCommand(chatId: update.chatId, command: cmd, args: args, from: update.from)
            return
        }

        // Record history
        if !update.text.isEmpty {
            messageHistory.append((timestamp: Date(), from: update.from, text: String(update.text.prefix(200))))
            if messageHistory.count > maxMessageHistory {
                messageHistory.removeFirst(messageHistory.count - maxMessageHistory)
            }
        }

        // Cancel existing task for this chat (prompt injection prevention)
        if let existing = activeTasks[update.chatId] {
            existing.cancel()
            activeTasks.removeValue(forKey: update.chatId)
            _ = await sendHTMLMessage(chatId: update.chatId, html: "🔄 <b>Previous task cancelled</b>, processing new request...")
        }

        let chatId = update.chatId
        let userText = update.text

        if update.mediaType == .text { lastUserTextPerChat[chatId] = userText }

        activeTasks[chatId] = Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor [weak self] in self?.activeTasks.removeValue(forKey: chatId) } }
            await self.processMessage(chatId: chatId, text: userText)
        }
    }

    // MARK: - Commands

    private func handleCommand(chatId: String, command: String, args: String, from: String) async {
        switch command {
        case "/start":
            let toolCount = ToolRegistry.shared.allTools.count
            _ = await sendHTMLMessage(chatId: chatId, html: """
            🟢 <b>Welcome to Dockwright!</b>

            I'm your macOS AI assistant with <b>\(toolCount) tools</b>.
            I can run shell commands, manage files, search the web, schedule tasks, and more.

            Type /help for all commands, or just send me a message!
            """)

        case "/help":
            _ = await sendHTMLMessage(chatId: chatId, html: """
            📖 <b>Commands</b>

            /start — Welcome & overview
            /status — Live dashboard
            /stop — Stop current task
            /clear — Clear message history
            /model — Current model info
            /tools — Available tools
            /dice — Roll a die 🎲

            Or just type a message — I'll handle the rest!
            """)

        case "/status":
            let uptime = Int(Date().timeIntervalSince(startupTime))
            let hours = uptime / 3600
            let mins = (uptime % 3600) / 60
            let model = AppPreferences.shared.selectedModel
            let toolCount = ToolRegistry.shared.allTools.count
            _ = await sendHTMLMessage(chatId: chatId, html: """
            📊 <b>Dockwright Status</b>

            🟢 Online
            🤖 Model: <code>\(escapeHTMLBot(model))</code>
            🔧 Tools: \(toolCount)
            ⏱ Uptime: \(hours)h \(mins)m
            """, replyMarkup: [[TGInlineButton(text: "🔄 Refresh", callbackData: "cmd_status")]])

        case "/stop":
            if let task = activeTasks[chatId] {
                task.cancel()
                activeTasks.removeValue(forKey: chatId)
                _ = await sendMessage(chatId: chatId, text: "⛔ Task stopped.")
            } else {
                _ = await sendMessage(chatId: chatId, text: "No active task to stop.")
            }

        case "/clear":
            messageHistory.removeAll()
            _ = await sendMessage(chatId: chatId, text: "🗑 Message history cleared.")

        case "/model":
            let model = AppPreferences.shared.selectedModel
            _ = await sendHTMLMessage(chatId: chatId, html: "🤖 Current model: <code>\(escapeHTMLBot(model))</code>")

        case "/tools":
            let names = ToolRegistry.shared.allTools.map(\.name).sorted()
            let list = names.map { "• <code>\($0)</code>" }.joined(separator: "\n")
            _ = await sendHTMLMessage(chatId: chatId, html: "🔧 <b>Available Tools (\(names.count))</b>\n\n\(list)")

        case "/dice":
            _ = await postJSON("sendDice", body: ["chat_id": chatId, "emoji": "🎲"])

        default:
            _ = await sendMessage(chatId: chatId, text: "Unknown command: \(command)\nType /help for available commands.")
        }
    }

    // MARK: - Callback Queries

    private func handleCallbackQuery(_ cb: TGCallbackQuery) async {
        switch cb.data {
        case "stop_processing":
            if let task = activeTasks[cb.chatId] {
                task.cancel()
                activeTasks.removeValue(forKey: cb.chatId)
            }
            await answerCallbackQuery(id: cb.id, text: "⛔ Stopped")

        case "retry_last":
            if let lastText = lastUserTextPerChat[cb.chatId] {
                await answerCallbackQuery(id: cb.id, text: "🔄 Retrying...")
                let chatId = cb.chatId
                activeTasks[chatId] = Task { [weak self] in
                    guard let self else { return }
                    defer { Task { @MainActor [weak self] in self?.activeTasks.removeValue(forKey: chatId) } }
                    await self.processMessage(chatId: chatId, text: lastText)
                }
            } else {
                await answerCallbackQuery(id: cb.id, text: "No previous message to retry")
            }

        case "cmd_status":
            await answerCallbackQuery(id: cb.id)
            await handleCommand(chatId: cb.chatId, command: "/status", args: "", from: cb.from)

        default:
            await answerCallbackQuery(id: cb.id)
        }
    }

    // MARK: - Process Message (LLM + Tools + Progress)

    private func processMessage(chatId: String, text: String) async {
        guard !Task.isCancelled else { return }

        let typingTask = startTypingLoop(chatId: chatId)
        let statusMsgId = await sendHTMLMessage(chatId: chatId, html: "🧠 <b>Thinking...</b>", replyMarkup: [
            [TGInlineButton(text: "⛔️ Stop", callbackData: "stop_processing")]
        ])
        let startTime = Date()
        let token = botToken

        // Thread-safe progress tracking
        let streamLock = NSLock()
        nonisolated(unsafe) var toolProgress: [TGToolProgress] = []
        nonisolated(unsafe) var currentPhase: String = "Thinking..."
        nonisolated(unsafe) var lastEditTime = Date.distantPast
        nonisolated(unsafe) var finalText = ""
        nonisolated(unsafe) var toolsUsed: [String] = []
        let capturedChatId = chatId
        let capturedMsgId = statusMsgId

        // Get API key and model
        let prefs = AppPreferences.shared
        let model = prefs.selectedModel
        guard let apiKey = resolveAPIKey(model: model) else {
            typingTask.cancel()
            _ = await sendMessage(chatId: chatId, text: "❌ No API key configured for current model.")
            return
        }

        // Build messages
        let systemPrompt = buildSystemPrompt()
        var llmMessages: [LLMMessage] = [.user(text)]
        let llm = LLMService()
        let toolDefs = ToolRegistry.shared.anthropicToolDefinitions()
        let toolExecutor = ToolExecutor()
        let maxLoops = 10
        var loopCount = 0

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
                ) { chunk in
                    guard let msgId = capturedMsgId else { return }
                    streamLock.lock()
                    defer { streamLock.unlock() }
                    var htmlToFire: String?

                    switch chunk {
                    case .toolStarted(let name):
                        currentPhase = "Processing..."
                        toolsUsed.append(name)
                        toolProgress.append(TGToolProgress(name: name, status: .running, preview: ""))
                        if Date().timeIntervalSince(lastEditTime) > 1.2 {
                            lastEditTime = Date()
                            htmlToFire = buildProgressHTML(tools: toolProgress, phase: currentPhase, elapsed: Int(Date().timeIntervalSince(startTime)))
                        }
                    case .toolCompleted(let name, let preview, _):
                        let short = String(preview.prefix(60)).replacingOccurrences(of: "\n", with: " ")
                        if let idx = toolProgress.lastIndex(where: { $0.name == name && $0.status == .running }) {
                            toolProgress[idx] = TGToolProgress(name: name, status: .completed, preview: short)
                        }
                        if Date().timeIntervalSince(lastEditTime) > 1.2 {
                            lastEditTime = Date()
                            htmlToFire = buildProgressHTML(tools: toolProgress, phase: currentPhase, elapsed: Int(Date().timeIntervalSince(startTime)))
                        }
                    case .toolFailed(let name, let error):
                        if let idx = toolProgress.lastIndex(where: { $0.name == name && $0.status == .running }) {
                            toolProgress[idx] = TGToolProgress(name: name, status: .failed, preview: String(error.prefix(50)))
                        }
                        lastEditTime = Date()
                        htmlToFire = buildProgressHTML(tools: toolProgress, phase: currentPhase, elapsed: Int(Date().timeIntervalSince(startTime)))
                    case .textDelta(let delta):
                        finalText += delta
                        if currentPhase != "Writing response..." {
                            currentPhase = "Writing response..."
                        }
                    case .thinking:
                        currentPhase = "Thinking..."
                    case .activity(let state):
                        switch state {
                        case .searching(let q): currentPhase = "Searching: \(q)"
                        case .reading(let f):   currentPhase = "Reading: \(f)"
                        case .executing(let t):  currentPhase = "Running: \(t)"
                        default: break
                        }
                    case .done:
                        break
                    }

                    if let html = htmlToFire {
                        fireEditHTML(token: token, chatId: capturedChatId, messageId: msgId, html: html)
                    }
                }

                if let content = response.content, !content.isEmpty {
                    streamLock.withLock { finalText = content }
                }

                // Handle tool calls
                guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else { break }

                llmMessages.append(.assistant(response.content ?? "", toolCalls: toolCalls))

                for tc in toolCalls {
                    if Task.isCancelled { break }
                    let args = toolExecutor.parseArguments(tc.function.arguments)
                    let result = await toolExecutor.executeTool(name: tc.function.name, arguments: args)
                    llmMessages.append(.tool(callId: tc.id, content: result.output))
                }
            }

            typingTask.cancel()
            let (usedTools, responseText) = streamLock.withLock { (toolsUsed, finalText) }
            let duration = String(format: "%.1f", Date().timeIntervalSince(startTime))

            // Send final response
            await sendFinalResponse(chatId: chatId, text: responseText)

            // Update status to completion summary
            if let msgId = statusMsgId {
                var summary = "✅ <b>Done in \(duration)s</b>"
                if !usedTools.isEmpty {
                    let unique = Array(Set(usedTools))
                    summary += "\n🔧 \(usedTools.count) tool\(usedTools.count == 1 ? "" : "s"): <code>\(escapeHTMLBot(unique.joined(separator: ", ")))</code>"
                }
                await editHTMLMessage(chatId: chatId, messageId: msgId, html: summary, replyMarkup: [
                    [TGInlineButton(text: "🔄 Retry", callbackData: "retry_last"),
                     TGInlineButton(text: "📊 Status", callbackData: "cmd_status")]
                ])
            }

            onChatMessage?(chatId, text, responseText)

        } catch is CancellationError {
            typingTask.cancel()
            if let msgId = statusMsgId {
                await editHTMLMessage(chatId: chatId, messageId: msgId, html: "🔄 <b>Cancelled</b>")
            }
        } catch {
            typingTask.cancel()
            _ = await sendHTMLMessage(chatId: chatId, html: "❌ <b>Error:</b> \(escapeHTMLBot(error.localizedDescription))")
            if let msgId = statusMsgId {
                await editHTMLMessage(chatId: chatId, messageId: msgId, html: "❌ <b>Failed</b>", replyMarkup: [
                    [TGInlineButton(text: "🔄 Retry", callbackData: "retry_last")]
                ])
            }
        }
    }

    // MARK: - Helpers

    private func sendFinalResponse(chatId: String, text: String) async {
        guard !text.isEmpty else { return }
        if text.count <= 3800 {
            // Convert basic markdown to Telegram HTML
            let html = markdownToHTML(text)
            _ = await sendHTMLMessage(chatId: chatId, html: html)
        } else {
            // Split long messages
            let chunks = splitMessage(text, maxLen: 4000)
            for chunk in chunks {
                _ = await sendMessage(chatId: chatId, text: chunk)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func markdownToHTML(_ text: String) -> String {
        var html = escapeHTMLBot(text)
        // ```code``` → <pre><code>
        html = html.replacingOccurrences(of: "```([\\s\\S]*?)```", with: "<pre><code>$1</code></pre>", options: .regularExpression)
        // `code` → <code>
        html = html.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)
        // **bold** → <b>
        html = html.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<b>$1</b>", options: .regularExpression)
        return html
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
            // 1. Real API key
            if let key = KeychainHelper.read(key: "anthropic_api_key"), !key.isEmpty,
               !key.hasPrefix("sk-ant-oat") { return key }
            // 2. Dockwright OAuth token
            if let oauth = KeychainHelper.read(key: "claude_oauth_token"), !oauth.isEmpty { return oauth }
            // 3. Claude Code's OAuth token
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

    private func buildSystemPrompt() -> String {
        let prefs = AppPreferences.shared
        var prompt = """
        You are Dockwright, a powerful macOS AI assistant responding via Telegram.
        You have access to tools for shell commands, file management, web search, scheduling, and more.
        Be concise — Telegram messages should be short and clear.
        Use markdown formatting sparingly (bold for emphasis, code blocks for commands/output).
        """
        let style = prefs.responseStylePrompt
        if !style.isEmpty { prompt += style }
        let custom = prefs.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { prompt += "\n\nUser instructions:\n\(custom)" }

        // Language preference
        let sttLang = VoiceService.effectiveLanguage
        if sttLang.hasPrefix("nl") {
            prompt += "\n\nIMPORTANT: Always respond in Dutch (Nederlands)."
        } else if sttLang.hasPrefix("de") {
            prompt += "\n\nIMPORTANT: Always respond in German (Deutsch)."
        } else if sttLang.hasPrefix("fr") {
            prompt += "\n\nIMPORTANT: Always respond in French (Français)."
        } else if sttLang.hasPrefix("es") {
            prompt += "\n\nIMPORTANT: Always respond in Spanish (Español)."
        } else if !sttLang.hasPrefix("en") {
            prompt += "\n\nIMPORTANT: Always respond in the language matching locale: \(sttLang)."
        }
        return prompt
    }

}
