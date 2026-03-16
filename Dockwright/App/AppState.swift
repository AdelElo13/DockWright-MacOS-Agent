import Foundation
import SwiftUI
import os

/// Central app state — @Observable for SwiftUI, @MainActor by default.
@Observable
final class AppState {
    // Current conversation
    var currentConversation: Conversation = Conversation()
    var conversations: [ConversationSummary] = []

    // Chat state
    var isProcessing = false
    var streamingText = ""
    var currentActivity: StreamActivity?

    // Settings
    var selectedModel = "claude-opus-4-6"
    var showSidebar = true
    var showSettings = false
    var showSkillsAutomations = false

    // Services (nonisolated Sendable types)
    let llm = LLMService()
    let tools = ToolRegistry.shared
    let toolExecutor = ToolExecutor()
    let tokenCounter = TokenCounter()
    let conversationStore = ConversationStore()

    // Scheduler services
    let cronStore = CronStore()
    private(set) var cronRunner: CronRunner!
    private let multiChannel = MultiChannel()

    // Goals
    let goalStore = GoalStore()

    // Model registry
    let modelRegistry = ModelRegistry.shared

    // Memory
    let memoryStore = MemoryStore()

    // Auth
    let authManager = AuthManager()

    // Heartbeat
    private(set) var heartbeat: HeartbeatRunner!

    // Parallel agent executor
    let parallelExecutor = ParallelAgentExecutor()

    // Skills
    let skillLoader = SkillLoader()

    // Sensory
    let worldModel = WorldModel.shared

    // Voice
    let voiceService = VoiceService.shared
    let ttsService = TTSService.shared
    let voiceCoordinator = VoiceSessionCoordinator.shared

    // Voice UI state
    var voiceMode = false
    var voiceState: VoiceState = .idle
    var voiceLiveText = ""
    private var voicePollTask: Task<Void, Never>?

    enum VoiceState: Equatable {
        case idle
        case listening
        case transcribing
        case speaking
    }

    // Scheduler UI
    var showScheduler = false

    // Cancellation
    private var streamTask: Task<Void, Never>?

    // MARK: - Agent Mode

    let agentExecutor = AgentExecutor()
    var agentMode = false
    var agentState: AgentExecutor.AgentState = .idle

    // MARK: - Vision: pending images to include in next message

    var pendingImages: [ImageContent] = []
    var pendingFileContents: [(name: String, content: String)] = []

    // MARK: - Slash Commands

    var showSlashCommands = false
    var slashFilter = ""

    struct SlashCommand: Identifiable {
        let id = UUID()
        let command: String
        let label: String
        let icon: String
    }

    let slashCommands: [SlashCommand] = [
        SlashCommand(command: "/clear", label: "Clear conversation", icon: "trash"),
        SlashCommand(command: "/export", label: "Export conversation", icon: "square.and.arrow.up"),
        SlashCommand(command: "/voice", label: "Toggle voice mode", icon: "mic"),
        SlashCommand(command: "/model", label: "Switch model", icon: "cpu"),
        SlashCommand(command: "/schedule", label: "Open scheduler", icon: "clock.arrow.circlepath"),
        SlashCommand(command: "/agent", label: "Toggle agent mode", icon: "brain"),
        SlashCommand(command: "/clipboard", label: "Read clipboard", icon: "doc.on.clipboard"),
        SlashCommand(command: "/watch", label: "Watch a directory", icon: "eye"),
        SlashCommand(command: "/system", label: "System info & control", icon: "desktopcomputer"),
        SlashCommand(command: "/dark", label: "Toggle dark mode", icon: "moon"),
        SlashCommand(command: "/goals", label: "View goals & daily actions", icon: "target"),
        SlashCommand(command: "/email", label: "Check email inbox", icon: "envelope"),
        SlashCommand(command: "/calendar", label: "Today's calendar events", icon: "calendar"),
        SlashCommand(command: "/browser", label: "Current browser tab", icon: "safari"),
        SlashCommand(command: "/project", label: "Analyze current project", icon: "folder.badge.gearshape"),
        SlashCommand(command: "/skills", label: "List available skills", icon: "wand.and.stars"),
        SlashCommand(command: "/screenshot", label: "Capture screen or window", icon: "camera.viewfinder"),
        SlashCommand(command: "/contacts", label: "Search contacts", icon: "person.crop.circle"),
        SlashCommand(command: "/notes", label: "Read or create Apple Notes", icon: "note.text"),
        SlashCommand(command: "/reminders", label: "View or create reminders", icon: "checklist"),
        SlashCommand(command: "/finder", label: "File management", icon: "folder"),
        SlashCommand(command: "/apps", label: "Launch or quit apps", icon: "app.badge"),
        SlashCommand(command: "/music", label: "Control music playback", icon: "music.note"),
        SlashCommand(command: "/shortcuts", label: "Run Apple Shortcuts", icon: "bolt.circle"),
        SlashCommand(command: "/volume", label: "Get or set volume", icon: "speaker.wave.3"),
        SlashCommand(command: "/battery", label: "Battery status", icon: "battery.100"),
    ]

    var filteredSlashCommands: [SlashCommand] {
        if slashFilter.isEmpty { return slashCommands }
        let q = slashFilter.lowercased()
        return slashCommands.filter {
            $0.command.lowercased().contains(q) || $0.label.lowercased().contains(q)
        }
    }

    // MARK: - Conversation Summarization

    private var conversationSummary: String = ""
    private var lastSummarizedCount = 0

    // API key convenience — checks AuthManager for OAuth tokens too
    var hasAPIKey: Bool {
        _ = authManager.keychainVersion  // trigger re-render on auth changes
        let provider = LLMModels.provider(for: selectedModel)
        if provider == .ollama { return true }
        return !authManager.anthropicApiKey.isEmpty ||
               !authManager.openaiApiKey.isEmpty ||
               KeychainHelper.read(key: "anthropic_api_key") != nil ||
               KeychainHelper.read(key: "openai_api_key") != nil ||
               KeychainHelper.read(key: provider.keychainKey) != nil
    }

    /// Get the API key for the currently selected model's provider.
    /// Checks AuthManager first (OAuth tokens), then falls back to Keychain.
    var currentAPIKey: String? {
        let provider = LLMModels.provider(for: selectedModel)
        switch provider {
        case .anthropic:
            let key = authManager.anthropicApiKey
            if !key.isEmpty { return key }
            return KeychainHelper.read(key: "anthropic_api_key")
        case .openai:
            let key = authManager.openaiApiKey
            if !key.isEmpty { return key }
            return KeychainHelper.read(key: "openai_api_key")
        case .ollama:
            return ""  // Ollama needs no key
        case .google, .xai, .mistral, .deepseek, .kimi:
            return KeychainHelper.read(key: provider.keychainKey)
        }
    }

    init() {
        // Set up scheduler with multi-channel delivery
        cronRunner = CronRunner(store: cronStore, channel: NotificationChannel())
        tools.register(CronTool(store: cronStore))
        cronRunner.start()

        // Set up heartbeat
        heartbeat = HeartbeatRunner(channel: NotificationChannel(), cronStore: cronStore)
        heartbeat.start()

        // Set up memory -- failure is non-fatal, app works without it
        do {
            try memoryStore.setup()
            tools.register(MemoryTool(store: memoryStore))
            log.info("[Memory] Memory store initialized successfully")
        } catch {
            log.error("[Memory] Failed to initialize (non-fatal, memory features disabled): \(error.localizedDescription)")
        }

        // Register core tools
        tools.register(VisionTool())
        tools.register(ClipboardTool())
        tools.register(SystemTool())
        tools.register(FileWatcherTool())
        tools.register(ExportTool())
        tools.register(RemindersTool())
        tools.register(NotesTool())

        // Register integration tools
        tools.register(EmailTool())
        tools.register(CalendarTool())
        tools.register(BrowserTool())
        tools.register(ProjectContextTool())
        tools.register(DataExportTool())
        tools.register(GoalTool(store: goalStore))
        tools.register(AutoSkillCreatorTool())

        // Register macOS power tools
        tools.register(ScreenshotTool())
        tools.register(SystemControlTool())
        tools.register(ContactsTool())
        tools.register(FinderTool())
        tools.register(AppLauncherTool())
        tools.register(MusicTool())
        tools.register(ShortcutsTool())

        // Start sensory ambient loop (screen capture + OCR every 15s)
        // This is non-fatal -- if screen capture permission is denied, it degrades gracefully
        worldModel.startAmbientLoop()

        // Import Claude Code OAuth token if available
        authManager.importClaudeCodeTokenIfNeeded()
        AuthManager.startProactiveTokenSync()

        loadConversations()

        // Refresh model registry in background (fetches from provider APIs)
        if !modelRegistry.isCacheFresh {
            Task.detached {
                await ModelRegistry.shared.refreshAll()
            }
        }
    }

    // MARK: - System Prompt

    private var systemPrompt: String {
        let context = worldModel.contextString()
        var prompt = """
        You are Dockwright, the most powerful macOS AI assistant ever built. You have deep integration with every part of macOS through these tools:

        COMMUNICATION:
        - Read and manage emails via Mail.app (inbox, draft, reply, send, search)
        - Search and browse contacts (name, email, phone, birthdays)
        - Read and create Apple Notes (list, read, create, search, delete)
        - Manage Apple Reminders (create, complete, delete, overdue, lists)

        PRODUCTIVITY:
        - Access calendar events (today, upcoming, create, search, delete)
        - Track goals with milestones and daily action items
        - Schedule recurring tasks and one-shot reminders (cron jobs)
        - Run Apple Shortcuts by name with custom input
        - Create and manage reusable AI skills (teach yourself new capabilities)
        - Export structured data (CSV, JSON, HTML reports) to Desktop

        SYSTEM CONTROL:
        - Control volume, brightness, Wi-Fi, Bluetooth, dark mode, Do Not Disturb
        - Get battery status, system info (CPU, memory, disk, uptime)
        - Put display to sleep, lock screen
        - Launch, quit, force-quit, hide, and activate any app
        - Capture screenshots (full screen, window, or selection)
        - Read and write the system clipboard

        FILES & CODE:
        - Advanced file management (move, copy, rename, trash, compress, decompress)
        - Spotlight search (mdfind) for finding anything on the Mac
        - Run shell commands, read/write files
        - Git integration (status, log, diff, branch, project structure)
        - Watch directories for file changes

        MEDIA & BROWSER:
        - Control Music.app and Spotify (play, pause, skip, search, volume, queue)
        - Control Safari and Chrome (tabs, navigate, read pages, search web)
        - See what's on the user's screen (ambient screen capture + OCR)
        - Analyze images (vision tool) — users can drop/paste images into chat

        INTELLIGENCE:
        - Save and recall persistent memories about the user
        - Run multiple agent tasks in parallel
        - Deliver notifications via macOS, Telegram, and Discord
        - Brain dump → structured goals → daily tasks pipeline

        Current context:
        \(context)

        Active scheduled jobs: \(cronRunner.activeJobsSummary())
        """

        if agentMode {
            prompt += """

            AGENT MODE IS ON. When the user gives you a goal:
            1. Break it down into numbered steps (max 20)
            2. Format each step as: "N. [tool:toolname] description | {\"arg\": \"value\"}"
            3. If no tool is needed, just describe the reasoning step
            4. Execute systematically, reporting progress
            """
        }

        if !conversationSummary.isEmpty {
            prompt += """

            Previous conversation summary (older messages):
            \(conversationSummary)
            """
        }

        prompt += """

        Guidelines:
        - Be concise and direct
        - Use tools proactively when they'd help answer the question
        - For reminders/scheduling, use the scheduler tool with create_reminder action
        - When the user mentions something on screen, reference your screen awareness
        - When showing code, use markdown code blocks with language tags
        - When the user says "this file" or "this page", use screen context to determine what they mean
        - If clipboard has code when the user pastes, offer to explain or fix it
        - Speak Dutch if the user speaks Dutch
        """

        // Inject skill descriptions
        let skillsFragment = skillLoader.systemPromptFragment()
        if !skillsFragment.isEmpty {
            prompt += skillsFragment
        }

        return prompt
    }

    // MARK: - Send Message

    func sendMessage(_ text: String, images: [ImageContent]? = nil) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        guard let apiKey = currentAPIKey else {
            let provider = LLMModels.provider(for: selectedModel)
            appendError("No API key configured for \(provider.rawValue). Go to Settings > API Keys.")
            return
        }

        // Build the user message content, including any pending file contents
        var fullText = text
        for file in pendingFileContents {
            fullText += "\n\n--- File: \(file.name) ---\n\(file.content)"
        }
        pendingFileContents.removeAll()

        // Combine explicit images with pending images
        var allImages = images ?? []
        allImages.append(contentsOf: pendingImages)
        pendingImages.removeAll()

        // Append user message
        let userMessage = ChatMessage(role: .user, content: fullText)
        currentConversation.messages.append(userMessage)
        currentConversation.touch()

        // Auto-title from first message
        if currentConversation.title == "New Chat" {
            currentConversation.title = String(text.prefix(50))
        }

        // Update export bridge
        ExportDataBridge.shared.currentConversation = currentConversation

        isProcessing = true

        // Create streaming assistant message
        let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
        currentConversation.messages.append(assistantMessage)
        let assistantIndex = currentConversation.messages.count - 1

        streamTask = Task {
            await runLLMLoop(apiKey: apiKey, assistantIndex: assistantIndex, images: allImages.isEmpty ? nil : allImages)
        }
    }

    private func runLLMLoop(apiKey: String, assistantIndex: Int, images: [ImageContent]? = nil) async {
        var llmMessages = buildLLMMessages(images: images)
        let maxRetries = 3
        var retryCount = 0

        // Auto-summarize if conversation is long
        await autoSummarizeIfNeeded()

        // Tool use loop — keeps calling LLM until no more tool calls
        while true {
            if Task.isCancelled { break }

            do {
                let toolDefs = tools.anthropicToolDefinitions()
                streamingText = ""
                currentActivity = .thinking

                let response = try await llm.streamChat(
                    messages: llmMessages,
                    tools: toolDefs.isEmpty ? nil : toolDefs,
                    model: selectedModel,
                    apiKey: apiKey,
                    systemPrompt: systemPrompt
                ) { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        self?.handleChunk(chunk, assistantIndex: assistantIndex)
                    }
                }

                // Record tokens
                tokenCounter.recordUsage(input: response.inputTokens, output: response.outputTokens)

                // Handle tool calls
                if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
                    // Bounds check before modifying
                    guard assistantIndex < currentConversation.messages.count else { break }

                    // Update assistant message with tool calls info
                    currentConversation.messages[assistantIndex].isStreaming = true
                    currentActivity = nil

                    // Add assistant message with tool calls to LLM messages
                    llmMessages.append(.assistant(
                        response.content ?? "",
                        toolCalls: toolCalls
                    ))

                    // Execute each tool
                    for tc in toolCalls {
                        let args = toolExecutor.parseArguments(tc.function.arguments)
                        currentActivity = .executing(tc.function.name)

                        // Set export bridge before export tool runs
                        if tc.function.name == "export" {
                            ExportDataBridge.shared.currentConversation = currentConversation
                        }

                        let result = await toolExecutor.executeTool(name: tc.function.name, arguments: args)

                        // Add tool output to UI (bounds-checked)
                        let toolOutput = ToolOutput(
                            toolName: tc.function.name,
                            output: result.output,
                            isError: result.isError
                        )
                        if assistantIndex < currentConversation.messages.count {
                            currentConversation.messages[assistantIndex].toolOutputs.append(toolOutput)
                        }

                        // Add tool result to LLM messages
                        llmMessages.append(.tool(callId: tc.id, content: result.output))
                    }

                    // Reset streaming text for next LLM response
                    streamingText = ""
                    currentConversation.messages[assistantIndex].content = ""
                    continue // Loop back for next LLM response
                }

                // No tool calls — done
                break

            } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
                if Task.isCancelled { break }
                appendError("No internet connection. Check your network and try again.")
                break
            } catch let error as LLMError where error.isRetryable {
                if Task.isCancelled { break }
                retryCount += 1
                if retryCount <= maxRetries {
                    let delay = pow(2.0, Double(retryCount - 1))
                    appendError("Retrying (\(retryCount)/\(maxRetries)) after \(Int(delay))s: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                appendError("Failed after \(maxRetries) retries: \(error.localizedDescription)")
                break
            } catch {
                if Task.isCancelled { break }
                appendError(error.localizedDescription)
                break
            }
        }

        // Finalize
        if assistantIndex < currentConversation.messages.count {
            currentConversation.messages[assistantIndex].isStreaming = false
        }
        isProcessing = false
        currentActivity = nil
        streamTask = nil

        // Speak response in voice mode
        if voiceMode, assistantIndex < currentConversation.messages.count {
            let responseText = currentConversation.messages[assistantIndex].content
            if !responseText.isEmpty {
                speakResponse(responseText)
            }
        }

        // Save conversation
        currentConversation.touch()
        ExportDataBridge.shared.currentConversation = currentConversation
        conversationStore.save(currentConversation)
        loadConversations()
    }

    private func handleChunk(_ chunk: StreamChunk, assistantIndex: Int) {
        guard assistantIndex < currentConversation.messages.count else { return }

        switch chunk {
        case .textDelta(let text):
            streamingText += text
            currentConversation.messages[assistantIndex].content = streamingText
            currentActivity = .generating

        case .thinking(let text):
            currentConversation.messages[assistantIndex].thinkingContent += text
            currentActivity = .thinking

        case .activity(let activity):
            currentActivity = activity

        case .toolStarted(let name):
            currentActivity = .executing(name)

        case .done:
            currentActivity = nil

        case .toolCompleted, .toolFailed:
            break // Handled in the tool execution loop
        }
    }

    // MARK: - Build LLM Messages

    private func buildLLMMessages(images: [ImageContent]? = nil) -> [LLMMessage] {
        var messages: [LLMMessage] = []

        let allMessages = currentConversation.messages
        let windowSize = 20

        // If conversation is long, use sliding window with summary
        let recentMessages: ArraySlice<ChatMessage>
        if allMessages.count > windowSize && !conversationSummary.isEmpty {
            // Summary is injected via system prompt, use last windowSize messages
            recentMessages = allMessages.suffix(windowSize)
        } else {
            recentMessages = allMessages.suffix(windowSize)
        }

        for (idx, msg) in recentMessages.enumerated() {
            switch msg.role {
            case .user:
                if idx == recentMessages.count - 1, let images, !images.isEmpty {
                    // Last user message — attach images
                    messages.append(.user(msg.content, images: images))
                } else {
                    messages.append(.user(msg.content))
                }
            case .assistant:
                if !msg.content.isEmpty {
                    messages.append(.assistant(msg.content))
                }
            case .system, .error:
                break // Skip system/error messages in API calls
            }
        }

        return messages
    }

    // MARK: - Auto-Summarize

    private func autoSummarizeIfNeeded() async {
        let messageCount = currentConversation.messages.count
        guard messageCount > 30, messageCount - lastSummarizedCount >= 10 else { return }
        guard let apiKey = currentAPIKey else { return }

        // Summarize older messages (beyond the last 20)
        let olderMessages = currentConversation.messages.prefix(messageCount - 20)
        guard !olderMessages.isEmpty else { return }

        var transcript = ""
        for msg in olderMessages {
            let role = msg.role == .user ? "User" : "Assistant"
            if msg.role == .user || msg.role == .assistant {
                transcript += "\(role): \(String(msg.content.prefix(300)))\n"
            }
        }

        if transcript.count < 100 { return } // Not enough to summarize

        let summaryMessages: [LLMMessage] = [
            .user("Summarize this conversation in 3-5 bullet points, preserving key facts, decisions, and user preferences:\n\n\(String(transcript.prefix(8000)))")
        ]

        do {
            let response = try await llm.streamChat(
                messages: summaryMessages,
                model: selectedModel,
                apiKey: apiKey,
                systemPrompt: "You are a conversation summarizer. Be concise and factual."
            ) { _ in }

            if let content = response.content, !content.isEmpty {
                conversationSummary = content
                lastSummarizedCount = messageCount
                log.info("[Summary] Auto-summarized \(olderMessages.count) older messages")
            }
        } catch {
            log.warning("[Summary] Auto-summarize failed (non-fatal): \(error.localizedDescription)")
        }
    }

    // MARK: - Slash Command Execution

    func executeSlashCommand(_ command: String) async {
        switch command {
        case "/clear":
            newConversation()
        case "/export":
            ExportDataBridge.shared.currentConversation = currentConversation
            await sendMessage("Export this conversation as markdown to my Desktop")
        case "/voice":
            await toggleVoiceMode()
        case "/model":
            // Cycle through models
            let models = LLMModels.allModels
            if let currentIdx = models.firstIndex(where: { $0.id == selectedModel }) {
                let nextIdx = (currentIdx + 1) % models.count
                selectedModel = models[nextIdx].id
                appendError("Switched to \(models[nextIdx].displayName)")
            }
        case "/schedule":
            showScheduler.toggle()
        case "/agent":
            agentMode.toggle()
            appendError("Agent mode \(agentMode ? "enabled" : "disabled")")
        case "/clipboard":
            await sendMessage("Read my clipboard and tell me what's on it")
        case "/watch":
            await sendMessage("Watch my Downloads folder for new files")
        case "/system":
            await sendMessage("Show me my system info")
        case "/dark":
            await sendMessage("Toggle dark mode")
        case "/goals":
            await sendMessage("Show me my goals and today's daily actions")
        case "/email":
            await sendMessage("Check my email inbox and summarize the latest messages")
        case "/calendar":
            await sendMessage("What's on my calendar today?")
        case "/browser":
            await sendMessage("What page am I looking at in my browser?")
        case "/project":
            await sendMessage("Analyze the current project structure and git status")
        case "/skills":
            await sendMessage("List all available skills")
        case "/screenshot":
            await sendMessage("Take a screenshot of my screen")
        case "/contacts":
            await sendMessage("Search my contacts")
        case "/notes":
            await sendMessage("List my recent Apple Notes")
        case "/reminders":
            await sendMessage("Show my reminders and any overdue items")
        case "/finder":
            await sendMessage("Show me the contents of my Desktop")
        case "/apps":
            await sendMessage("List my currently running apps")
        case "/music":
            await sendMessage("What's currently playing?")
        case "/shortcuts":
            await sendMessage("List my available Apple Shortcuts")
        case "/volume":
            await sendMessage("What's my current volume level?")
        case "/battery":
            await sendMessage("Show my battery status")
        default:
            appendError("Unknown command: \(command)")
        }
    }

    // MARK: - Stop

    func stopProcessing() {
        streamTask?.cancel()
        streamTask = nil
        isProcessing = false
        currentActivity = nil

        // Finalize any streaming message
        if let lastIndex = currentConversation.messages.indices.last,
           currentConversation.messages[lastIndex].isStreaming {
            currentConversation.messages[lastIndex].isStreaming = false
            if currentConversation.messages[lastIndex].content.isEmpty {
                currentConversation.messages[lastIndex].content = "[Stopped]"
            }
        }
    }

    // MARK: - Conversation Management

    func newConversation() {
        // Save current if it has messages
        if !currentConversation.messages.isEmpty {
            conversationStore.save(currentConversation)
        }
        currentConversation = Conversation()
        streamingText = ""
        conversationSummary = ""
        lastSummarizedCount = 0
        loadConversations()
    }

    func loadConversation(_ id: String) {
        // Save current
        if !currentConversation.messages.isEmpty {
            conversationStore.save(currentConversation)
        }

        if let conv = conversationStore.load(id: id) {
            currentConversation = conv
            streamingText = ""
            conversationSummary = ""
            lastSummarizedCount = 0
        }
    }

    func deleteConversation(_ id: String) {
        conversationStore.delete(id: id)
        if currentConversation.id == id {
            currentConversation = Conversation()
            streamingText = ""
        }
        loadConversations()
    }

    func loadConversations() {
        conversations = conversationStore.listAll()
    }

    // MARK: - Voice

    func toggleVoiceMode() async {
        if voiceMode {
            stopVoice()
        } else {
            await startVoice()
        }
    }

    func startVoice() async {
        let authorized = await voiceService.ensureAuthorization()
        guard authorized else {
            appendError(voiceService.errorMessage ?? "Voice not authorized.")
            return
        }

        voiceCoordinator.claim(.mainChat)
        voiceMode = true
        startListening()
    }

    func startListening() {
        guard voiceMode else { return }
        voiceState = .listening
        voiceLiveText = ""

        // Use onTranscription — only fires from finalizeRecording() after silence + grace
        // (matches Jarvis exactly — onTranscription is NOT called on partial results)
        voiceService.onTranscription = { [weak self] text in
            guard let self else { return }

            // Clear callback immediately to prevent double-fires
            self.voiceService.onTranscription = nil
            self.voicePollTask?.cancel()
            self.voicePollTask = nil

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Empty transcription — re-listen after brief pause
                self.voiceLiveText = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.voiceMode else { return }
                    self.startListening()
                }
                return
            }

            // Show final text in field, then send
            self.voiceLiveText = text
            self.voiceState = .transcribing

            // Short delay for UI feedback, then send
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.voiceMode else { return }
                self.voiceLiveText = ""
                Task { [weak self] in
                    guard let self else { return }
                    await self.sendMessage(text)
                }
            }
        }

        voiceService.startListening()

        // Poll recognizedText every 100ms for live preview (like dictation)
        voicePollTask?.cancel()
        voicePollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.voiceMode, self.voiceState == .listening else { break }
                let live = self.voiceService.recognizedText
                if !live.isEmpty {
                    self.voiceLiveText = live
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func stopVoice() {
        voiceMode = false
        voiceState = .idle
        voiceLiveText = ""
        voicePollTask?.cancel()
        voicePollTask = nil
        voiceService.onTranscription = nil
        voiceService.onFinalTranscription = nil
        voiceService.stopListening()
        ttsService.stopSpeaking()
        voiceCoordinator.release(.mainChat)
    }

    /// Called after LLM responds with text — speak it via TTS then go back to listening.
    func speakResponse(_ text: String) {
        guard voiceMode else { return }
        voiceState = .speaking
        voiceLiveText = ""

        ttsService.onSpeakingComplete = { [weak self] in
            guard let self, self.voiceMode else { return }
            // Cooldown before re-listening (avoids TTS residual audio triggering mic)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.voiceMode else { return }
                self.startListening()
            }
        }

        ttsService.speak(text: text)
    }

    // MARK: - Helpers

    func appendError(_ message: String) {
        let errorMessage = ChatMessage(role: .error, content: message)
        currentConversation.messages.append(errorMessage)
    }
}
