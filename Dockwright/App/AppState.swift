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

    // Central preferences (single source of truth)
    let prefs = AppPreferences.shared

    // Settings
    var selectedModel: String {
        get { prefs.selectedModel }
        set { prefs.selectedModel = newValue }
    }
    var showSidebar: Bool
    var showSettings = false
    var showSkillsAutomations = false
    var showGoals = false

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
    var goalCount = 0
    var cronJobCount = 0

    // Model registry
    let modelRegistry = ModelRegistry.shared

    // Memory
    let memoryStore = MemoryStore()
    private(set) var memoryFormation: MemoryFormation!
    let errorMemory = ErrorMemoryBank.shared

    // Auth
    let authManager = AuthManager()

    // Heartbeat
    private(set) var heartbeat: HeartbeatRunner!

    // Parallel agent executor
    let parallelExecutor = ParallelAgentExecutor()

    // Bot services
    let telegramBot = TelegramBotService.shared
    let whatsAppBot = WhatsAppBotService.shared

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

    // Tool approval dialog
    var showToolApproval = false
    var toolApprovalDescription = ""
    var toolApprovalContinuation: CheckedContinuation<Bool, Never>?

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

    // Provider-aware auth check: true if ANY provider is configured.
    // This gates onboarding — once the user has any credential, they're "in".
    var hasAPIKey: Bool {
        _ = authManager.keychainVersion  // trigger re-render on auth changes
        return prefs.hasAnyConfiguredProvider(authManager: authManager)
    }

    /// True only if the currently selected model's provider specifically is configured.
    var isActiveProviderConfigured: Bool {
        _ = authManager.keychainVersion
        return prefs.isCurrentProviderConfigured(authManager: authManager)
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
        // Load sidebar state from preferences
        showSidebar = AppPreferences.shared.sidebarDefaultOpen

        // Set up scheduler — routes through MultiChannel (respects notification prefs)
        // Wire tool approval dialog — respects autonomy level from Agent Settings
        toolExecutor.onApprovalNeeded = { [weak self] toolName, description in
            let autonomy = UserDefaults.standard.string(forKey: "autonomyLevel") ?? "suggest"
            switch autonomy {
            case "autonomous":
                // Execute everything automatically
                return true
            case "off":
                // No autonomous actions at all
                return false
            case "proactive":
                // Safe tools auto-approved, risky ones (shell, file write) need approval
                let riskyTools: Set<String> = ["shell", "file", "browser_action"]
                if !riskyTools.contains(toolName) { return true }
                fallthrough
            default: // "suggest"
                // Show approval dialog
                await MainActor.run {
                    guard let self else { return }
                    self.toolApprovalDescription = description
                    self.showToolApproval = true
                }
                return await withCheckedContinuation { continuation in
                    Task { @MainActor [weak self] in
                        self?.toolApprovalContinuation = continuation
                    }
                }
            }
        }

        cronRunner = CronRunner(store: cronStore, channel: multiChannel)
        tools.register(CronTool(store: cronStore))

        // Wire cron job execution to send actions through the LLM
        cronRunner.onExecuteAction = { [weak self] jobName, actionText in
            Task { @MainActor in
                guard let self else { return }
                await self.sendMessage(actionText)
            }
        }

        cronRunner.start()

        // Set up heartbeat — also through MultiChannel
        heartbeat = HeartbeatRunner(channel: multiChannel, cronStore: cronStore)
        heartbeat.start()

        // Set up memory -- failure is non-fatal, app works without it
        do {
            try memoryStore.setup()
            memoryFormation = MemoryFormation(store: memoryStore)
            tools.register(MemoryTool(store: memoryStore))
            log.info("[Memory] Memory store + auto-formation initialized")
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
        tools.register(iMessageTool())
        tools.register(UIAutomationTool())
        tools.register(DecomposeTaskTool())

        // Start sensory ambient loop (screen capture + OCR every 15s)
        // This is non-fatal -- if screen capture permission is denied, it degrades gracefully
        worldModel.startAmbientLoop()

        // Start ProcessSymbiosis — live AX event monitoring for frontmost app
        ProcessSymbiosis.shared.start()

        // Import Claude Code OAuth token if available
        authManager.importClaudeCodeTokenIfNeeded()
        AuthManager.startProactiveTokenSync()

        // Sync model to an available provider after auth bootstrap
        // (e.g., if selectedModel was Anthropic but user only has Gemini key now)
        prefs.syncModelToAvailableProvider(authManager: authManager)

        loadConversations()
        refreshBadgeCounts()

        // Prune expired conversations on launch (respect retention setting)
        pruneExpiredConversations()

        // Start AI-to-AI server on port 8766 for programmatic testing
        startAIToAIServer()

        // Start MCP server on port 8767 for standard tool discovery/execution
        startMCPServer()

        // Start bot services (Telegram + WhatsApp) if configured
        telegramBot.onChatMessage = { [weak self] from, userText, response in
            guard let self else { return }
            // Show the Telegram exchange in the current conversation
            let header = "📩 **Telegram** from \(from)"
            self.currentConversation.messages.append(
                ChatMessage(role: .user, content: "\(header)\n\(userText)")
            )
            self.currentConversation.messages.append(
                ChatMessage(role: .assistant, content: response)
            )
        }
        telegramBot.start()
        whatsAppBot.start()

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
        - Read and send iMessages via Messages.app (read chats, send texts, search messages, list conversations)
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

        UI AUTOMATION (ProcessSymbiosis — UNIQUE CAPABILITY):
        - Click any button, menu item, or link in ANY running app by name or meaning
        - Type text into any text field, fill forms, press keyboard shortcuts
        - Read UI element values, labels, and state from any app
        - Live AX event stream — you see focus changes, window creation, value changes in real-time
        - Find elements semantically ("the save button", "email field") — not just by coordinates
        - This works with EVERY macOS app: Mail, Safari, Chrome, Outlook, Finder, Notes, Terminal, etc.

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
        - Analyze images (vision tool) — users can drop/paste images into chat

        SCREEN AWARENESS (ALWAYS ON):
        - You have an ambient loop that captures and OCRs the screen every 15 seconds automatically
        - You always know what's on screen, which app is active, and which browser tabs are open
        - This happens continuously in the background — you don't need to be asked
        - The current screen context is included below — reference it naturally when relevant

        INTELLIGENCE:
        - Save and recall persistent memories about the user
        - Run multiple agent tasks in parallel
        - Deliver notifications via macOS, Telegram, and Discord
        - Brain dump → structured goals → daily tasks pipeline
        - Auto-learns from tool errors and adapts (error memory bank)

        Current context:
        \(context)

        Active scheduled jobs: \(cronRunner.activeJobsSummary())
        """

        // Inject live UI state from ProcessSymbiosis
        let symbContext = ProcessSymbiosis.shared.contextString()
        if !symbContext.isEmpty {
            prompt += "\n\nLive UI state (ProcessSymbiosis):\n\(symbContext)"
        }

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
        """

        // Language preference: use voice language setting to determine response language
        let sttLang = VoiceService.effectiveLanguage
        if sttLang.hasPrefix("nl") {
            prompt += "\n- IMPORTANT: Always respond in Dutch (Nederlands). All your responses must be in Dutch."
        } else if sttLang.hasPrefix("de") {
            prompt += "\n- IMPORTANT: Always respond in German (Deutsch). All your responses must be in German."
        } else if sttLang.hasPrefix("fr") {
            prompt += "\n- IMPORTANT: Always respond in French (Français). All your responses must be in French."
        } else if sttLang.hasPrefix("es") {
            prompt += "\n- IMPORTANT: Always respond in Spanish (Español). All your responses must be in Spanish."
        } else if !sttLang.hasPrefix("en") {
            prompt += "\n- IMPORTANT: Always respond in the language matching locale: \(sttLang)."
        }

        // Response style from preferences
        let styleFragment = prefs.responseStylePrompt
        if !styleFragment.isEmpty {
            prompt += styleFragment
        }

        // Inject skill descriptions
        let skillsFragment = skillLoader.systemPromptFragment()
        if !skillsFragment.isEmpty {
            prompt += skillsFragment
        }

        // Inject error memory (tool mistakes to avoid)
        let errorHints = errorMemory.systemPromptFragment()
        if !errorHints.isEmpty {
            prompt += errorHints
        }

        // Custom system prompt from advanced settings
        let custom = prefs.customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            prompt += "\n\nUser custom instructions:\n\(custom)"
        }

        return prompt
    }

    // MARK: - Send Message

    /// Ensures the API key is fresh — if it's an expired OAuth token, refreshes it first.
    /// For Ollama (no key needed), returns empty string to signal "proceed without auth".
    /// Cooldown: don't re-attempt refresh if it failed recently.
    private var _lastRefreshFailure: Date = .distantPast
    private let _refreshFailureCooldown: TimeInterval = 300  // 5 minutes

    private func ensureFreshAPIKey() async -> String? {
        // Ollama needs no API key — let it through with an empty string
        let provider = LLMModels.provider(for: selectedModel)
        if provider == .ollama { return "" }

        guard let key = currentAPIKey, !key.isEmpty else { return nil }

        // Provider-specific OAuth token refresh
        switch provider {
        case .anthropic:
            if LLMService.isOAuthToken(key),
               let expiresStr = KeychainHelper.read(key: "claude_token_expires"),
               let expiresEpoch = Int(expiresStr) {
                let expiresAt = Date(timeIntervalSince1970: Double(expiresEpoch))
                if Date() >= expiresAt,
                   KeychainHelper.exists(key: "claude_refresh_token"),
                   Date().timeIntervalSince(_lastRefreshFailure) >= _refreshFailureCooldown {
                    if let freshToken = await AuthManager.refreshClaudeOAuthToken() {
                        KeychainHelper.save(key: "anthropic_api_key", value: freshToken)
                        KeychainHelper.save(key: "claude_oauth_token", value: freshToken)
                        AuthManager.invalidateOAuthCache()
                        return freshToken
                    } else {
                        _lastRefreshFailure = Date()
                        KeychainHelper.delete(key: "claude_token_expires")
                    }
                }
            }
        case .openai:
            if let expiresStr = KeychainHelper.read(key: "openai_token_expires"),
               let expiresEpoch = Int(expiresStr) {
                let expiresAt = Date(timeIntervalSince1970: Double(expiresEpoch))
                if Date() >= expiresAt,
                   KeychainHelper.exists(key: "openai_refresh_token"),
                   Date().timeIntervalSince(_lastRefreshFailure) >= _refreshFailureCooldown {
                    if await authManager.refreshOpenAITokenIfNeeded() {
                        AuthManager.invalidateOAuthCache()
                        return authManager.openaiApiKey
                    } else {
                        _lastRefreshFailure = Date()
                    }
                }
            }
        default:
            break
        }
        return key
    }

    func sendMessage(_ text: String, images: [ImageContent]? = nil) async {
        log.info("[SendMessage] Called with text: \(text.prefix(50))")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log.warning("[SendMessage] Empty text, returning")
            return
        }

        // Cancel any in-flight request before starting a new one
        if let existing = streamTask {
            log.info("[SendMessage] Cancelling previous stream task")
            existing.cancel()
            streamTask = nil
            // Finalize the previous streaming message so it doesn't hang
            if let lastIndex = currentConversation.messages.indices.last,
               currentConversation.messages[lastIndex].isStreaming {
                currentConversation.messages[lastIndex].isStreaming = false
                if currentConversation.messages[lastIndex].content.isEmpty {
                    currentConversation.messages[lastIndex].content = "*(cancelled)*"
                }
            }
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

        // Show user message + activity IMMEDIATELY (before any async work)
        let userMessage = ChatMessage(role: .user, content: fullText)
        currentConversation.messages.append(userMessage)
        currentConversation.touch()

        // Auto-title from first message
        if currentConversation.title == "New Chat" {
            currentConversation.title = String(text.prefix(50))
        }

        ExportDataBridge.shared.currentConversation = currentConversation
        isProcessing = true
        currentActivity = .thinking

        guard let apiKey = await ensureFreshAPIKey() else {
            let provider = LLMModels.provider(for: selectedModel)
            appendError("No API key configured for \(provider.rawValue). Go to Settings > API Keys.")
            isProcessing = false
            currentActivity = nil
            return
        }

        // Create streaming assistant message
        let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
        currentConversation.messages.append(assistantMessage)
        let assistantIndex = currentConversation.messages.count - 1

        streamTask = Task {
            await runLLMLoop(apiKey: apiKey, assistantIndex: assistantIndex, images: allImages.isEmpty ? nil : allImages)
        }
    }

    private func runLLMLoop(apiKey: String, assistantIndex: Int, images: [ImageContent]? = nil) async {
        log.info("[RunLLMLoop] Starting. model=\(self.selectedModel) keyPrefix=\(apiKey.prefix(15))... assistantIndex=\(assistantIndex)")
        var apiKey = apiKey
        var llmMessages = buildLLMMessages(images: images)
        log.info("[RunLLMLoop] Built \(llmMessages.count) messages")
        let maxRetries = 3
        var retryCount = 0

        // Auto-summarize if conversation is long
        await autoSummarizeIfNeeded()

        // Tool use loop — keeps calling LLM until no more tool calls
        let tokenBudget = UserDefaults.standard.object(forKey: "agentTokenBudget") as? Int ?? 50000
        while true {
            if Task.isCancelled { break }

            // Enforce token budget from Agent Settings
            if tokenCounter.totalTokens > tokenBudget {
                log.info("[AppState] Token budget exhausted (\(self.tokenCounter.totalTokens)/\(tokenBudget))")
                break
            }

            do {
                let toolDefs = tools.anthropicToolDefinitions()
                log.info("[RunLLMLoop] Calling streamChat with \(toolDefs.count) tools")
                streamingText = ""
                currentActivity = .thinking

                let response = try await llm.streamChat(
                    messages: llmMessages,
                    tools: toolDefs.isEmpty ? nil : toolDefs,
                    model: selectedModel,
                    apiKey: apiKey,
                    systemPrompt: systemPrompt,
                    temperature: prefs.temperature,
                    maxTokens: prefs.maxTokens
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

                        // Record tool errors so we don't repeat the same mistakes
                        if result.isError {
                            errorMemory.record(toolName: tc.function.name, arguments: args, errorOutput: result.output)
                        }

                        // Inject error memory hints into tool result so LLM learns
                        var enrichedOutput = result.output
                        if result.isError, let hints = errorMemory.hintsForTool(tc.function.name, arguments: args) {
                            enrichedOutput += "\n\n" + hints
                        }

                        // Add tool output to UI (bounds-checked)
                        let toolOutput = ToolOutput(
                            toolName: tc.function.name,
                            output: result.output,
                            isError: result.isError
                        )
                        if assistantIndex < currentConversation.messages.count {
                            currentConversation.messages[assistantIndex].toolOutputs.append(toolOutput)
                        }

                        // Add tool result to LLM messages (with hints if error)
                        llmMessages.append(.tool(callId: tc.id, content: enrichedOutput))
                    }

                    // Refresh sidebar badges (goals/jobs may have changed via tools)
                    refreshBadgeCounts()

                    // Reset streaming text for next LLM response
                    streamingText = ""
                    currentConversation.messages[assistantIndex].content = ""
                    continue // Loop back for next LLM response
                }

                // No tool calls — done
                break

            } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
                log.error("[RunLLMLoop] Network error: \(error.localizedDescription)")
                if Task.isCancelled { break }
                // Preserve any partial streaming content before showing error
                if !streamingText.isEmpty, assistantIndex < currentConversation.messages.count {
                    currentConversation.messages[assistantIndex].content = streamingText + "\n\n⚠️ [Connection lost — partial response preserved]"
                    currentConversation.messages[assistantIndex].isStreaming = false
                } else {
                    appendError("No internet connection. Check your network and try again.")
                }
                break
            } catch LLMError.unauthorized {
                if Task.isCancelled { break }
                // Token expired mid-request — refresh and retry once
                log.info("[LLM] 401 Unauthorized — refreshing token and retrying")
                AuthManager.invalidateOAuthCache()
                if await authManager.refreshClaudeTokenIfNeeded(),
                   let freshKey = await ensureFreshAPIKey() {
                    apiKey = freshKey
                    streamingText = ""
                    if assistantIndex < currentConversation.messages.count {
                        currentConversation.messages[assistantIndex].content = ""
                    }
                    continue // Retry with fresh token
                }
                appendError("Session expired. Please sign in again.")
                break
            } catch let error as LLMError where error.isRetryable {
                if Task.isCancelled { break }
                retryCount += 1
                if retryCount <= maxRetries {
                    let delay = pow(2.0, Double(retryCount - 1))
                    log.info("[LLM] Retrying (\(retryCount)/\(maxRetries)) after \(Int(delay))s: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                // Preserve partial content on final retry failure
                if !streamingText.isEmpty, assistantIndex < currentConversation.messages.count {
                    currentConversation.messages[assistantIndex].content = streamingText + "\n\n⚠️ [Stream interrupted — partial response preserved]"
                    currentConversation.messages[assistantIndex].isStreaming = false
                } else {
                    appendError("Failed after \(maxRetries) retries: \(error.localizedDescription)")
                }
                break
            } catch {
                log.error("[RunLLMLoop] Unexpected error: \(error)")
                if Task.isCancelled { break }
                // Preserve partial content on any error
                if !streamingText.isEmpty, assistantIndex < currentConversation.messages.count {
                    currentConversation.messages[assistantIndex].content = streamingText + "\n\n⚠️ [Error: \(error.localizedDescription) — partial response preserved]"
                    currentConversation.messages[assistantIndex].isStreaming = false
                } else {
                    appendError(error.localizedDescription)
                }
                break
            }
        }

        // Finalize — flush buffered text if streaming was off
        if assistantIndex < currentConversation.messages.count {
            if !prefs.streamResponses && !streamingText.isEmpty {
                currentConversation.messages[assistantIndex].content = streamingText
            }
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

        // Auto-extract facts from user messages
        memoryFormation?.processLastUserMessage(in: currentConversation.messages)

        // Save conversation (respect privacy setting)
        currentConversation.touch()
        ExportDataBridge.shared.currentConversation = currentConversation
        if prefs.saveConversations {
            conversationStore.save(currentConversation)
            loadConversations()
        }
    }

    private func handleChunk(_ chunk: StreamChunk, assistantIndex: Int) {
        guard assistantIndex < currentConversation.messages.count else { return }

        let isStreaming = prefs.streamResponses

        switch chunk {
        case .textDelta(let text):
            streamingText += text
            if isStreaming {
                // Live update — push every delta to UI
                currentConversation.messages[assistantIndex].content = streamingText
            }
            // When !isStreaming the text accumulates in streamingText silently;
            // the final flush happens when the loop finishes (see runLLMLoop).
            currentActivity = .generating

        case .thinking(let text):
            currentConversation.messages[assistantIndex].thinkingContent += text
            currentActivity = .thinking

        case .activity(let activity):
            currentActivity = activity

        case .toolStarted(let name):
            currentActivity = .executing(name)

        case .done:
            // Flush buffered text when streaming is off
            if !isStreaming {
                currentConversation.messages[assistantIndex].content = streamingText
            }
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
        // Save current if it has messages and saving is enabled
        if !currentConversation.messages.isEmpty && prefs.saveConversations {
            conversationStore.save(currentConversation)
        }
        currentConversation = Conversation()
        streamingText = ""
        conversationSummary = ""
        lastSummarizedCount = 0
        loadConversations()
    }

    func loadConversation(_ id: String) {
        // Save current — only if privacy toggle allows it
        if !currentConversation.messages.isEmpty && prefs.saveConversations {
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

    /// Refresh sidebar badge counts for goals and cron jobs.
    func refreshBadgeCounts() {
        goalCount = goalStore.listGoals(activeOnly: true).count
        cronJobCount = cronStore.listAll().count
    }

    /// Clear all conversation data — store, in-memory, sidebar. Called from privacy settings.
    func clearAllConversations() {
        for summary in conversationStore.listAll() {
            conversationStore.delete(id: summary.id)
        }
        currentConversation = Conversation()
        conversations = []
        streamingText = ""
        conversationSummary = ""
        lastSummarizedCount = 0
    }

    /// Prune conversations older than the retention period.
    func pruneExpiredConversations() {
        let days = prefs.conversationRetentionDays
        guard days > 0 else { return } // 0 = never delete
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for summary in conversationStore.listAll() {
            if summary.updatedAt < cutoff {
                conversationStore.delete(id: summary.id)
            }
        }
        loadConversations()
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
        // Respect user's "Enable Voice Mode" preference toggle (defaults to true)
        guard UserDefaults.standard.object(forKey: "voiceEnabled") as? Bool ?? true else {
            appendError("Voice mode is disabled. Enable it in Settings → Voice.")
            return
        }

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
        ttsService.onSpeakingComplete = nil
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

    // MARK: - AI-to-AI Server

    private func startAIToAIServer() {
        Task { @MainActor in
            let server = AIToAIServer.shared
            await server.setOnRequest { [weak self] text, reply in
                Task { @MainActor [weak self] in
                    guard let self else {
                        reply("Error: AppState unavailable")
                        return
                    }
                    let result = await self.executeA2ARequest(text)
                    reply(result)
                }
            }
            do {
                try await server.start()
                log.info("[A2A] Server started on port 8766")
            } catch {
                log.error("[A2A] Failed to start: \(error)")
            }
        }
    }

    private func startMCPServer() {
        let executor = toolExecutor
        Task {
            let mcp = MCPServer.shared
            await mcp.setExecutor(executor)
            await mcp.start()
        }
        log.info("[MCP] Server queued on port 8767")
    }

    /// Runs the full LLM + tool loop in isolation — same as the UI chat but without touching UI state.
    private func executeA2ARequest(_ text: String) async -> String {
        guard let apiKey = await ensureFreshAPIKey() else {
            return "Error: No API key configured"
        }

        log.info("[A2A] Request: \(text.prefix(200))")

        // Start with the user message
        var llmMessages: [LLMMessage] = [.user(text)]
        let toolDefs = tools.anthropicToolDefinitions()
        let maxToolRounds = 10
        var round = 0
        var finalText = ""

        while round < maxToolRounds {
            round += 1

            do {
                var streamedText = ""

                let response = try await llm.streamChat(
                    messages: llmMessages,
                    tools: toolDefs.isEmpty ? nil : toolDefs,
                    model: selectedModel,
                    apiKey: apiKey,
                    systemPrompt: systemPrompt,
                    temperature: prefs.temperature,
                    maxTokens: prefs.maxTokens
                ) { chunk in
                    if case .textDelta(let delta) = chunk {
                        streamedText += delta
                    }
                }

                tokenCounter.recordUsage(input: response.inputTokens, output: response.outputTokens)
                finalText = response.content ?? streamedText

                // Handle tool calls — execute and loop back, same as runLLMLoop
                guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                    break // No tool calls — done
                }

                // Add assistant message with tool calls
                llmMessages.append(.assistant(finalText, toolCalls: toolCalls))

                // Execute each tool
                var toolResults: [String] = []
                for tc in toolCalls {
                    let args = toolExecutor.parseArguments(tc.function.arguments)
                    log.info("[A2A] Executing tool: \(tc.function.name)")

                    let result = await toolExecutor.executeTool(name: tc.function.name, arguments: args)
                    llmMessages.append(.tool(callId: tc.id, content: result.output))
                    toolResults.append("[\(tc.function.name)] \(result.isError ? "ERROR: " : "")\(result.output.prefix(500))")
                }

                log.info("[A2A] Tool round \(round) completed: \(toolResults.count) tools")
                finalText = "" // Reset — next LLM response will be the final text
                continue

            } catch {
                log.error("[A2A] Error in round \(round): \(error)")
                return "Error: \(error.localizedDescription)"
            }
        }

        log.info("[A2A] Done after \(round) round(s), response length: \(finalText.count)")
        return finalText.isEmpty ? "No response generated" : finalText
    }

    // MARK: - Helpers

    func appendError(_ message: String) {
        let errorMessage = ChatMessage(role: .error, content: message)
        currentConversation.messages.append(errorMessage)
    }
}
