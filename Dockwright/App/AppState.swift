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
    var selectedModel = "claude-sonnet-4-20250514"
    var showSidebar = true
    var showSettings = false

    // Services (nonisolated Sendable types)
    let llm = LLMService()
    let tools = ToolRegistry.shared
    let toolExecutor = ToolExecutor()
    let tokenCounter = TokenCounter()
    let conversationStore = ConversationStore()

    // Scheduler services
    let cronStore = CronStore()
    private(set) var cronRunner: CronRunner!
    private let notificationChannel = NotificationChannel()

    // Memory
    let memoryStore = MemoryStore()

    // Sensory
    let worldModel = WorldModel.shared

    // Voice
    let voiceService = VoiceService.shared
    let ttsService = TTSService.shared
    let voiceCoordinator = VoiceSessionCoordinator.shared

    // Voice UI state
    var voiceMode = false
    var voiceState: VoiceState = .idle

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

    // API key convenience
    var hasAPIKey: Bool {
        // Has at least one provider key or is using Ollama
        KeychainHelper.read(key: "anthropic_api_key") != nil ||
        KeychainHelper.read(key: "openai_api_key") != nil ||
        LLMModels.provider(for: selectedModel) == .ollama
    }

    /// Get the API key for the currently selected model's provider.
    var currentAPIKey: String? {
        let provider = LLMModels.provider(for: selectedModel)
        let keyName = LLMModels.apiKeyName(for: provider)
        if keyName.isEmpty { return "" } // Ollama needs no key
        return KeychainHelper.read(key: keyName)
    }

    init() {
        // Set up scheduler
        cronRunner = CronRunner(store: cronStore, channel: notificationChannel)
        tools.register(CronTool(store: cronStore))
        cronRunner.start()

        // Set up memory -- failure is non-fatal, app works without it
        do {
            try memoryStore.setup()
            tools.register(MemoryTool(store: memoryStore))
            log.info("[Memory] Memory store initialized successfully")
        } catch {
            log.error("[Memory] Failed to initialize (non-fatal, memory features disabled): \(error.localizedDescription)")
        }

        // Start sensory ambient loop (screen capture + OCR every 15s)
        // This is non-fatal -- if screen capture permission is denied, it degrades gracefully
        worldModel.startAmbientLoop()

        loadConversations()
    }

    // MARK: - System Prompt

    private var systemPrompt: String {
        let context = worldModel.contextString()
        return """
        You are Dockwright, a powerful macOS AI assistant. You have access to tools that let you:
        - Run shell commands on the user's Mac
        - Read and write files
        - Search the web
        - Set reminders and schedule recurring tasks
        - See what's on the user's screen
        - Know which apps and browser tabs are open

        Current context:
        \(context)

        Active scheduled jobs: \(cronRunner.activeJobsSummary())

        Guidelines:
        - Be concise and direct
        - Use tools proactively when they'd help answer the question
        - For reminders/scheduling, use the scheduler tool with create_reminder action
        - When the user mentions something on screen, reference your screen awareness
        - When showing code, use markdown code blocks with language tags
        - Speak Dutch if the user speaks Dutch
        """
    }

    // MARK: - Send Message

    func sendMessage(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        guard let apiKey = currentAPIKey else {
            let provider = LLMModels.provider(for: selectedModel)
            appendError("No API key configured for \(provider.rawValue). Go to Settings > API Keys.")
            return
        }

        // Append user message
        let userMessage = ChatMessage(role: .user, content: text)
        currentConversation.messages.append(userMessage)
        currentConversation.touch()

        // Auto-title from first message
        if currentConversation.title == "New Chat" {
            currentConversation.title = String(text.prefix(50))
        }

        isProcessing = true

        // Create streaming assistant message
        var assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
        currentConversation.messages.append(assistantMessage)
        let assistantIndex = currentConversation.messages.count - 1

        streamTask = Task {
            await runLLMLoop(apiKey: apiKey, assistantIndex: assistantIndex)
        }
    }

    private func runLLMLoop(apiKey: String, assistantIndex: Int) async {
        var llmMessages = buildLLMMessages()
        let maxRetries = 3
        var retryCount = 0

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
                        guard let self else { return }
                        self.handleChunk(chunk, assistantIndex: assistantIndex)
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

    private func buildLLMMessages() -> [LLMMessage] {
        var messages: [LLMMessage] = []

        // Limit to last 20 messages to prevent token overflow
        let recentMessages = currentConversation.messages.suffix(20)

        for msg in recentMessages {
            switch msg.role {
            case .user:
                messages.append(.user(msg.content))
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

        voiceService.onFinalTranscription = { [weak self] text in
            guard let self else { return }
            self.voiceState = .transcribing
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { [weak self] in
                    guard let self else { return }
                    await self.sendMessage(text)
                }
            } else {
                self.voiceState = .idle
            }
        }

        voiceService.startListening()
    }

    func stopVoice() {
        voiceMode = false
        voiceState = .idle
        voiceService.stopListening()
        ttsService.stopSpeaking()
        voiceCoordinator.release(.mainChat)
    }

    /// Called after LLM responds with text — speak it via TTS then go back to listening.
    func speakResponse(_ text: String) {
        guard voiceMode else { return }
        voiceState = .speaking

        ttsService.onSpeakingComplete = { [weak self] in
            guard let self, self.voiceMode else { return }
            self.startListening()
        }

        ttsService.speak(text: text)
    }

    // MARK: - Helpers

    private func appendError(_ message: String) {
        let errorMessage = ChatMessage(role: .error, content: message)
        currentConversation.messages.append(errorMessage)
    }
}
