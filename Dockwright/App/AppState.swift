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
    private var streamBuffer: StreamTextBuffer?

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

    // MARK: - Inspector & Event Log

    let eventLog = AgentEventLog()
    var showInspector = false

    // Active plan for visualization (set during agent execution)
    var activePlan: AgentExecutor.AgentPlan?
    var activePlanResults: [AgentExecutor.StepResult] = []
    var activePlanCurrentStep: Int?

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

        // Set up memory without blocking initial UI rendering.
        initializeMemoryStoreAsync()

        // Register core tools
        tools.register(VisionTool())
        tools.register(ClipboardTool())
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
        // NOTE: SystemTool removed — SystemControlTool + AppLauncherTool cover all its actions.
        // AppLauncherTool handles open_app/open_url/running_apps, SystemControlTool handles volume/dark_mode/system_info.
        tools.register(ScreenshotTool())
        tools.register(SystemControlTool())
        tools.register(ContactsTool())
        tools.register(FinderTool())
        tools.register(AppLauncherTool())
        tools.register(MusicTool())
        tools.register(ShortcutsTool())
        tools.register(iMessageTool())
        tools.register(TelegramTool())
        tools.register(WhatsAppTool())
        tools.register(DiscordTool())
        tools.register(UIAutomationTool())
        tools.register(DecomposeTaskTool())
        tools.register(ChromeCDPTool())

        // Ambient sensory loop: screen capture + OCR every 15s, browser tab polling,
        // system state updates. All nonisolated services, runs on background queues.
        worldModel.startAmbientLoop()

        // ProcessSymbiosis: start lazily after 3s to avoid starving the main run loop at launch.
        // AX observer callbacks are throttled (4x/sec flush) on a background run loop thread.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            ProcessSymbiosis.shared.start()
        }

        // Import Claude Code OAuth token if available
        authManager.importClaudeCodeTokenIfNeeded()
        AuthManager.startProactiveTokenSync()

        // Sync model to an available provider after auth bootstrap
        // (e.g., if selectedModel was Anthropic but user only has Gemini key now)
        prefs.syncModelToAvailableProvider(authManager: authManager)

        // Load persisted UI data and prune old conversations off the main thread.
        bootstrapConversationAndBadgeDataAsync()

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

    /// Initialize SQLite-backed memory on a background task so launch remains responsive.
    private func initializeMemoryStoreAsync() {
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try self.memoryStore.setup()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.memoryFormation = MemoryFormation(store: self.memoryStore)
                    self.tools.register(MemoryTool(store: self.memoryStore))
                }
                log.info("[Memory] Memory store + auto-formation initialized")
                // Run lightweight consolidation (dedup + prune) on launch
                self.memoryStore.consolidate()
            } catch {
                log.error("[Memory] Failed to initialize (non-fatal, memory features disabled): \(error.localizedDescription)")
            }
        }
    }

    /// Loads conversation/sidebar badge state after launch and prunes retention data in one pass.
    private func bootstrapConversationAndBadgeDataAsync() {
        let retentionDays = prefs.conversationRetentionDays

        Task(priority: .utility) { [weak self] in
            guard let self else { return }

            if retentionDays > 0 {
                let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
                let removed = self.conversationStore.prune(olderThan: cutoff)
                if removed > 0 {
                    log.info("[Conversations] Pruned \(removed) expired conversations on launch")
                }
            }

            let loadedConversations = self.conversationStore.listAll()
            let loadedGoalCount = self.goalStore.listGoals(activeOnly: true).count
            let loadedCronCount = self.cronStore.listAll().count

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.conversations = loadedConversations
                self.goalCount = loadedGoalCount
                self.cronJobCount = loadedCronCount
            }
        }
    }

    // MARK: - System Prompt

    private var systemPrompt: String {
        let context = worldModel.contextString()
        var prompt = """
        You are \(prefs.assistantName), a macOS AI assistant. You have tools for communication, files, system control, UI automation, browser, media, scheduling, and memory — use them when needed. Your available tools are described in the tool definitions.\(prefs.assistantName != "Dockwright" ? " The user has named you \(prefs.assistantName) — always use this name when referring to yourself." : "")

        You have ambient screen awareness: every 15 seconds a screenshot is captured and OCR'd. The current screen context is below — reference it naturally.

        Current context:
        \(context)

        Active scheduled jobs: \(cronRunner.activeJobsSummary())
        """

        // Inject user profile if set
        let userName = prefs.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let userBio = prefs.userBio.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userName.isEmpty || !userBio.isEmpty {
            prompt += "\n\nUser profile:"
            if !userName.isEmpty { prompt += "\n- Name: \(userName)" }
            if !userBio.isEmpty { prompt += "\n- About: \(userBio)" }
        }

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

        // Inject user profile if available (for checkout, personalization)
        let p = prefs
        var profileParts: [String] = []
        if !p.userName.isEmpty { profileParts.append("Name: \(p.userName)") }
        if !p.userEmail.isEmpty { profileParts.append("Email: \(p.userEmail)") }
        if !p.userPhone.isEmpty { profileParts.append("Phone: \(p.userPhone)") }
        if !p.userAddress.isEmpty { profileParts.append("Address: \(p.userAddress)") }
        if !p.userCity.isEmpty { profileParts.append("City: \(p.userCity)") }
        if !p.userPostalCode.isEmpty { profileParts.append("Postal code: \(p.userPostalCode)") }
        if !p.userCountry.isEmpty { profileParts.append("Country: \(p.userCountry)") }
        if !profileParts.isEmpty {
            prompt += "\n\nUser profile:\n" + profileParts.joined(separator: "\n")
        }

        prompt += """

        Guidelines:
        - Be concise and direct
        - Only use tools when clearly needed — fewer precise calls over many speculative ones
        - For code questions: read the source code, don't screenshot
        - For screenshots: use the "screenshot" tool, NOT chrome_cdp screenshot. Chrome CDP is only for Chrome browser automation.
        - Use screen context to understand "this file" or "this page" references

        Shopping & checkout:
        - When the user asks you to buy/order something, DO IT. Open the website, find the product, add to cart, go to checkout.
        - Fill checkout forms (name, email, phone, address) using the user profile above. This is explicitly authorized by the user.
        - NEVER enter credit card numbers, CVV, or bank details. Stop before the payment step.
        - After filling the form, tell the user: "Checkout is ready — just confirm payment (Apple Pay / Touch ID / click Pay)."
        - You are NOT refusing to shop. The user trusts you to navigate websites and fill forms. Only the final payment confirmation is theirs.

        RESOURCEFULNESS — CRITICAL:
        - NEVER say "I can't do that." If one approach fails, try another.
        - If a CLI tool is missing, install it: `brew install [tool]`, `pip3 install [package]`, `npm install -g [package]`.
        - Useful tools to install when needed: yt-dlp, ffmpeg, jq, ripgrep (rg), pandoc, imagemagick, wget, httpie.
        - If a tool fails, try alternatives: curl instead of wget, python3 script instead of missing CLI, AppleScript instead of shell.
        - You have full access to brew, pip3, npm. Use them proactively to get the job done.
        - Think like a power user: chain tools, pipe outputs, write quick scripts. The goal is DONE, not excuses.
        """

        // Dynamic integrations: only mention messaging services that are configured
        var integrations: [String] = []
        if let t = KeychainHelper.read(key: "telegram_bot_token"), !t.isEmpty {
            integrations.append("Telegram (bidirectional — bot receives AND sends messages. Use 'telegram' tool to send proactively)")
        }
        if let url = UserDefaults.standard.string(forKey: "discord_webhook_url"), !url.isEmpty {
            integrations.append("Discord (use 'discord' tool to send messages via webhook)")
        }
        if let t = KeychainHelper.read(key: "whatsapp_token"), !t.isEmpty {
            integrations.append("WhatsApp (bidirectional — bot receives AND sends. Use 'whatsapp' tool to send proactively)")
        }
        if !integrations.isEmpty {
            prompt += "\n\nConfigured messaging integrations: \(integrations.joined(separator: ", ")). Use the appropriate tool when the user asks to send messages via these platforms. Incoming messages from these services are automatically processed — you don't need tools to receive them."
        }

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

    /// Auto-inject relevant memory facts for the current user message.
    /// Returns a concise string to prepend to the system prompt, or empty if nothing relevant.
    func memoryContextForMessage(_ message: String) -> String {
        let facts = memoryStore.topRelevant(forMessage: message, limit: 5)
        guard !facts.isEmpty else { return "" }

        var lines = ["\nWhat you know about this user:"]
        for fact in facts {
            lines.append("- \(fact.content)")
        }
        return lines.joined(separator: "\n")
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
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImages = !(images ?? []).isEmpty || !pendingImages.isEmpty
        guard hasText || hasImages else {
            log.warning("[SendMessage] Empty text and no images, returning")
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
        var fullText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasImages
            ? "What's in this image?"
            : text
        for file in pendingFileContents {
            fullText += "\n\n--- File: \(file.name) ---\n\(file.content)"
        }
        pendingFileContents.removeAll()

        // Combine explicit images with pending images
        var allImages = images ?? []
        allImages.append(contentsOf: pendingImages)
        pendingImages.removeAll()

        // Show user message + activity IMMEDIATELY (before any async work)
        let userMessage = ChatMessage(role: .user, content: fullText, images: allImages)
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

        // Auto-inject relevant memory facts into the system message
        if let lastUserMsg = currentConversation.messages.last(where: { $0.role == .user }) {
            let memCtx = memoryContextForMessage(lastUserMsg.content)
            if !memCtx.isEmpty,
               let sysIdx = llmMessages.firstIndex(where: { $0.role == "system" }) {
                llmMessages[sysIdx].content = (llmMessages[sysIdx].content ?? "") + memCtx
                log.info("[Memory] Injected \(memCtx.components(separatedBy: "\n").count - 1) relevant facts into system prompt")
            }
        }
        let maxRetries = 3
        var retryCount = 0

        // Auto-summarize if conversation is long
        await autoSummarizeIfNeeded()

        // Tool use loop — keeps calling LLM until no more tool calls
        // Budget is per-message (tool loop), dynamic based on model context window
        let tokenBudget: Int = {
            let custom = UserDefaults.standard.object(forKey: "agentTokenBudget") as? Int ?? 0
            if custom > 0 { return custom }
            // Auto-detect based on model — use 80% of context window as budget
            let model = selectedModel.lowercased()
            if model.contains("opus") || model.contains("gemini") { return 800_000 }  // 1M context
            if model.contains("sonnet") { return 160_000 }  // 200K context
            if model.contains("haiku") { return 160_000 }   // 200K context
            if model.contains("gpt-5") || model.contains("o3") || model.contains("o4") { return 200_000 }  // 256K context
            if model.contains("gpt-4") { return 100_000 }   // 128K context
            if model.contains("deepseek") { return 100_000 } // 128K context
            if model.contains("grok") { return 100_000 }     // 128K context
            if model.contains("mistral") { return 100_000 }  // 128K context
            if model.contains("kimi") { return 100_000 }     // 128K context
            return 100_000  // safe default for unknown models
        }()
        var messageTokens = 0
        let maxToolLoops = UserDefaults.standard.object(forKey: "agentMaxSteps") as? Int ?? 50
        var toolLoopCount = 0
        while true {
            if Task.isCancelled { break }

            // Enforce token budget per message/tool-loop
            if messageTokens > tokenBudget {
                log.info("[AppState] Token budget exhausted for this message (\(messageTokens)/\(tokenBudget))")
                let idx = currentConversation.messages.count - 1
                if idx >= 0 && currentConversation.messages[idx].role == .assistant {
                    currentConversation.messages[idx].content += "\n\n⚠️ Token budget bereikt (\(messageTokens)/\(tokenBudget)). Stuur een nieuw bericht of start een nieuwe thread."
                    currentConversation.messages[idx].isStreaming = false
                } else {
                    currentConversation.messages.append(ChatMessage(role: .error, content: "⚠️ Token budget bereikt (\(messageTokens)/\(tokenBudget)). Stuur een nieuw bericht of start een nieuwe thread."))
                }
                break
            }

            do {
                let toolDefs = tools.anthropicToolDefinitions()
                log.info("[RunLLMLoop] Calling streamChat with \(toolDefs.count) tools")
                streamingText = ""
                currentActivity = .thinking

                // Typewriter mode for providers that send large chunks (Anthropic, Gemini)
                // Direct mode for providers that already send small tokens (OpenAI, etc.)
                let provider = LLMModels.provider(for: selectedModel)
                let useTypewriter = provider == .anthropic || provider == .google
                let idx = assistantIndex
                streamBuffer = StreamTextBuffer(typewriter: useTypewriter) { [weak self] fullText in
                    guard let self, idx < self.currentConversation.messages.count else { return }
                    self.currentConversation.messages[idx].content = fullText
                }

                // Log LLM request to inspector
                eventLog.llmRequest(model: selectedModel, messageCount: llmMessages.count)

                let response = try await llm.streamChat(
                    messages: llmMessages,
                    tools: toolDefs.isEmpty ? nil : toolDefs,
                    model: selectedModel,
                    apiKey: apiKey,
                    systemPrompt: systemPrompt,
                    temperature: prefs.temperature,
                    maxTokens: prefs.maxTokens
                ) { [weak self] chunk in
                    DispatchQueue.main.async { [weak self] in
                        self?.handleChunk(chunk, assistantIndex: assistantIndex)
                    }
                }
                // Force final flush so no text is lost
                streamBuffer?.flush()
                streamBuffer = nil

                // Record tokens (both per-message and cumulative for cost display)
                messageTokens += response.inputTokens + response.outputTokens
                tokenCounter.recordUsage(input: response.inputTokens, output: response.outputTokens)

                // Log LLM response to inspector
                eventLog.llmResponse(
                    model: selectedModel,
                    tokens: response.inputTokens + response.outputTokens,
                    toolCalls: response.toolCalls?.count ?? 0
                )

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

                        // Log tool start to inspector
                        eventLog.toolStarted(name: tc.function.name, args: args)
                        let toolStartTime = Date()

                        // Set export bridge before export tool runs
                        if tc.function.name == "export" {
                            ExportDataBridge.shared.currentConversation = currentConversation
                        }

                        let result = await toolExecutor.executeTool(name: tc.function.name, arguments: args)

                        // Log tool completion/failure to inspector
                        let toolDurationMs = Int(Date().timeIntervalSince(toolStartTime) * 1000)
                        if result.isError {
                            eventLog.toolFailed(name: tc.function.name, error: String(result.output.prefix(200)))
                        } else {
                            eventLog.toolCompleted(name: tc.function.name, output: result.output, durationMs: toolDurationMs)
                        }

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
                    toolLoopCount += 1
                    if toolLoopCount >= maxToolLoops {
                        log.info("[RunLLMLoop] Max tool loops reached (\(maxToolLoops))")
                        break
                    }
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
                currentConversation.messages[assistantIndex].content = ChatMessage.cleanMarkdown(streamingText)
            } else {
                // Final clean pass on streamed content
                currentConversation.messages[assistantIndex].content = ChatMessage.cleanMarkdown(currentConversation.messages[assistantIndex].content)
            }
            currentConversation.messages[assistantIndex].isStreaming = false
        }
        isProcessing = false
        currentActivity = nil
        streamTask = nil

        // Voice mode: speak response via TTS, or restart wake word if no TTS
        if voiceMode, assistantIndex < currentConversation.messages.count {
            let responseText = currentConversation.messages[assistantIndex].content
            if !responseText.isEmpty {
                speakResponse(responseText)
            } else if prefs.wakeWordEnabled {
                // No response to speak — restart wake word immediately
                startWakeWordListening()
            } else {
                startListening()
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
                // Throttled at 30Hz via StreamTextBuffer — no cleanMarkdown during streaming
                streamBuffer?.append(text)
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
                currentConversation.messages[assistantIndex].content = ChatMessage.cleanMarkdown(streamingText)
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
                // Use images from ChatMessage if available, or from parameter for latest message
                let msgImages: [ImageContent]?
                if !msg.images.isEmpty {
                    msgImages = msg.images
                } else if idx == recentMessages.count - 1, let images, !images.isEmpty {
                    msgImages = images
                } else {
                    msgImages = nil
                }
                messages.append(.user(msg.content, images: msgImages))
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
        tokenCounter.reset()
        loadConversations()
    }

    func loadConversation(_ id: String) {
        // Save current — only if privacy toggle allows it
        if !currentConversation.messages.isEmpty && prefs.saveConversations {
            conversationStore.save(currentConversation)
        }

        if let conv = conversationStore.load(id: id) {
            currentConversation = conv
            tokenCounter.reset()
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

    func togglePin(_ id: String) {
        if var conv = conversationStore.load(id: id) {
            conv.isPinned.toggle()
            conversationStore.save(conv)
            if currentConversation.id == id {
                currentConversation.isPinned = conv.isPinned
            }
            loadConversations()
        }
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
        let removed = conversationStore.prune(olderThan: cutoff)
        if removed > 0 {
            loadConversations()
        }
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
        if prefs.wakeWordEnabled {
            startWakeWordListening()
        } else {
            startListening()
        }
    }

    /// Start wake word detector — passively listens for "Hey Doc" then activates voice.
    func startWakeWordListening() {
        guard voiceMode else { return }
        voiceState = .idle
        voiceLiveText = ""

        let wakeWord = WakeWordDetector.shared
        wakeWord.onWakeWord = { [weak self] in
            guard let self, self.voiceMode else { return }
            log.info("[WakeWord] Activated — starting voice listening")
            self.startListening()
        }
        wakeWord.start()
        log.info("[Voice] Wake word detector active — say 'Hey Doc' to activate")
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
        WakeWordDetector.shared.stop()
        WakeWordDetector.shared.onWakeWord = nil
        voiceCoordinator.release(.mainChat)
    }

    /// Called after LLM responds with text — speak it via TTS then go back to listening.
    func speakResponse(_ text: String) {
        guard voiceMode else { return }
        voiceState = .speaking
        voiceLiveText = ""

        // Stop mic before TTS — prevents Dockwright hearing itself
        voiceService.stopListening()
        WakeWordDetector.shared.stop()

        ttsService.onSpeakingComplete = { [weak self] in
            guard let self, self.voiceMode else { return }
            // Short cooldown after TTS — 0.5s is enough to avoid echo
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.voiceMode else { return }
                if self.prefs.wakeWordEnabled {
                    self.startWakeWordListening()
                } else {
                    self.startListening()
                }
            }
        }

        ttsService.speak(text: Self.cleanForTTS(text))
    }

    /// Clean text for TTS — removes markdown, emojis, collapses whitespace.
    /// Works for both macOS system TTS and ElevenLabs.
    static func cleanForTTS(_ text: String) -> String {
        var s = text
        // Remove markdown bold/italic
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        // Remove markdown headers
        s = s.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        // Remove markdown bullets
        s = s.replacingOccurrences(of: #"^[\-\*]\s+"#, with: "", options: .regularExpression)
        // Remove numbered list prefixes but keep the text
        s = s.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
        // Remove markdown links [text](url) → text
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
        // Remove code blocks
        s = s.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "code block omitted.", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        // Remove table syntax
        s = s.replacingOccurrences(of: #"\|[\-\s\|]+\|"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\|"#, with: ", ", options: .regularExpression)
        // Remove emojis (they get spelled out by TTS)
        s = s.unicodeScalars.filter { !($0.properties.isEmoji && $0.properties.isEmojiPresentation) }
            .map { String($0) }.joined()
        // Collapse multiple whitespace/newlines into single space
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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
