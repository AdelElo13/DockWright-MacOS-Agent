import Foundation
import os

// MARK: - LLM Message (API-level)

nonisolated struct LLMMessage: Codable, Sendable {
    let role: String  // "system", "user", "assistant", "tool"
    var content: String?
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    var images: [ImageContent]?

    // Convenience constructors
    static func system(_ text: String) -> LLMMessage {
        LLMMessage(role: "system", content: text)
    }

    static func user(_ text: String, images: [ImageContent]? = nil) -> LLMMessage {
        LLMMessage(role: "user", content: text, images: images)
    }

    static func assistant(_ text: String, toolCalls: [ToolCall]? = nil) -> LLMMessage {
        LLMMessage(role: "assistant", content: text, toolCalls: toolCalls)
    }

    static func tool(callId: String, content: String) -> LLMMessage {
        LLMMessage(role: "tool", content: content, toolCallId: callId)
    }
}

// MARK: - Tool Call

nonisolated struct ToolCall: Codable, Sendable {
    let id: String
    let type: String  // always "function"
    let function: ToolCallFunction
}

nonisolated struct ToolCallFunction: Codable, Sendable {
    let name: String
    let arguments: String  // JSON string
}

// MARK: - Image Content

nonisolated struct ImageContent: Codable, Sendable {
    let type: String       // "base64"
    let mediaType: String  // "image/png"
    let data: String
}

// MARK: - LLM Response

nonisolated struct LLMResponse: Sendable {
    let content: String?
    let toolCalls: [ToolCall]?
    let finishReason: String?
    let inputTokens: Int
    let outputTokens: Int
    var thinkingContent: String?
}

// MARK: - Stream Events

nonisolated enum StreamChunk: Sendable {
    case textDelta(String)
    case toolStarted(String)
    case toolCompleted(name: String, preview: String, output: String)
    case toolFailed(name: String, error: String)
    case thinking(String)
    case activity(StreamActivity)
    case done(String)
}

nonisolated enum StreamActivity: Sendable, Equatable {
    case thinking
    case searching(String)
    case reading(String)
    case executing(String)
    case generating
}

// MARK: - Chat Message (UI Display)

nonisolated struct ChatMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date
    var isStreaming: Bool
    var toolOutputs: [ToolOutput]
    var thinkingContent: String

    init(role: MessageRole, content: String, isStreaming: Bool = false) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isStreaming = isStreaming
        self.toolOutputs = []
        self.thinkingContent = ""
    }
}

nonisolated enum MessageRole: String, Codable, Sendable {
    case user, assistant, system, error
}

// MARK: - Tool Output

nonisolated struct ToolOutput: Identifiable, Codable, Sendable {
    let id: UUID
    let toolName: String
    let output: String
    let isError: Bool
    let timestamp: Date

    init(toolName: String, output: String, isError: Bool = false) {
        self.id = UUID()
        self.toolName = toolName
        self.output = output
        self.isError = isError
        self.timestamp = Date()
    }
}

// MARK: - Conversation

nonisolated struct Conversation: Identifiable, Codable, Sendable {
    let id: String
    var title: String
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date

    init(title: String = "New Chat") {
        self.id = "conv_\(UUID().uuidString.prefix(12).lowercased())"
        self.title = title
        self.messages = []
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    mutating func touch() {
        updatedAt = Date()
    }
}

// MARK: - Conversation Summary

nonisolated struct ConversationSummary: Identifiable, Codable, Sendable {
    let id: String
    var title: String
    var preview: String
    var messageCount: Int
    var createdAt: Date
    var updatedAt: Date

    init(from conversation: Conversation) {
        self.id = conversation.id
        self.title = conversation.title
        self.preview = conversation.messages.last(where: { $0.role == .user })?.content.prefix(100).description ?? ""
        self.messageCount = conversation.messages.count
        self.createdAt = conversation.createdAt
        self.updatedAt = conversation.updatedAt
    }
}

// MARK: - LLM Provider

/// LLM provider types supported by Dockwright.
enum LLMProvider: String, CaseIterable, Sendable, Codable {
    case anthropic = "Anthropic"
    case openai = "OpenAI"
    case google = "Google"
    case xai = "xAI"
    case ollama = "Ollama"
    case mistral = "Mistral"
    case deepseek = "DeepSeek"
    case kimi = "Kimi"

    /// Whether this provider uses the OpenAI-compatible chat/completions API format.
    var isOpenAICompatible: Bool {
        switch self {
        case .openai, .xai, .mistral, .deepseek, .kimi, .ollama:
            return true
        case .anthropic, .google:
            return false
        }
    }

    /// Base URL for the chat completions endpoint.
    var chatEndpoint: String {
        switch self {
        case .anthropic:
            return "https://api.anthropic.com/v1/messages"
        case .openai:
            return "https://api.openai.com/v1/chat/completions"
        case .google:
            return "https://generativelanguage.googleapis.com/v1beta/models"
        case .xai:
            return "https://api.x.ai/v1/chat/completions"
        case .ollama:
            return "http://localhost:11434/v1/chat/completions"
        case .mistral:
            return "https://api.mistral.ai/v1/chat/completions"
        case .deepseek:
            return "https://api.deepseek.com/chat/completions"
        case .kimi:
            return "https://api.moonshot.cn/v1/chat/completions"
        }
    }

    /// URL for the models list API (nil if provider has none).
    nonisolated var modelsListEndpoint: String? {
        switch self {
        case .anthropic:
            return nil  // No list API
        case .openai:
            return "https://api.openai.com/v1/models"
        case .google:
            return "https://generativelanguage.googleapis.com/v1beta/models"
        case .xai:
            return "https://api.x.ai/v1/models"
        case .ollama:
            return "http://localhost:11434/api/tags"
        case .mistral:
            return "https://api.mistral.ai/v1/models"
        case .deepseek:
            return "https://api.deepseek.com/models"
        case .kimi:
            return "https://api.moonshot.cn/v1/models"
        }
    }

    /// Keychain key for this provider's API key.
    nonisolated var keychainKey: String {
        switch self {
        case .anthropic: return "anthropic_api_key"
        case .openai:    return "openai_api_key"
        case .google:    return "gemini_api_key"
        case .xai:       return "xai_api_key"
        case .ollama:    return ""
        case .mistral:   return "mistral_api_key"
        case .deepseek:  return "deepseek_api_key"
        case .kimi:      return "kimi_api_key"
        }
    }
}

// MARK: - Model Info

/// A single model entry with provider mapping.
nonisolated struct LLMModelInfo: Sendable, Codable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let provider: LLMProvider

    static func == (lhs: LLMModelInfo, rhs: LLMModelInfo) -> Bool {
        lhs.id == rhs.id && lhs.provider == rhs.provider
    }
}

// MARK: - LLMModels (Static Defaults + Lookup)

/// Static model definitions and provider lookup.
enum LLMModels {
    /// Hardcoded fallback models per provider (2026 latest).
    nonisolated static let defaultModels: [LLMModelInfo] = [
        // Anthropic
        LLMModelInfo(id: "claude-opus-4-6", displayName: "Claude Opus 4.6", provider: .anthropic),
        LLMModelInfo(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", provider: .anthropic),
        LLMModelInfo(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", provider: .anthropic),
        // OpenAI
        LLMModelInfo(id: "gpt-5.4", displayName: "GPT-5.4", provider: .openai),
        LLMModelInfo(id: "gpt-5", displayName: "GPT-5", provider: .openai),
        LLMModelInfo(id: "gpt-5-mini", displayName: "GPT-5 Mini", provider: .openai),
        LLMModelInfo(id: "o4-mini", displayName: "o4-mini", provider: .openai),
        LLMModelInfo(id: "o3", displayName: "o3", provider: .openai),
        LLMModelInfo(id: "gpt-4.1", displayName: "GPT-4.1", provider: .openai),
        LLMModelInfo(id: "gpt-4.1-mini", displayName: "GPT-4.1 Mini", provider: .openai),
        // Google Gemini
        LLMModelInfo(id: "gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro Preview", provider: .google),
        LLMModelInfo(id: "gemini-3-flash-preview", displayName: "Gemini 3 Flash Preview", provider: .google),
        LLMModelInfo(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", provider: .google),
        LLMModelInfo(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", provider: .google),
        // xAI (Grok)
        LLMModelInfo(id: "grok-4.20-beta-0309-reasoning", displayName: "Grok 4.20 Beta Reasoning", provider: .xai),
        LLMModelInfo(id: "grok-4-1-fast-reasoning", displayName: "Grok 4.1 Fast Reasoning", provider: .xai),
        LLMModelInfo(id: "grok-3-mini", displayName: "Grok 3 Mini", provider: .xai),
        // Mistral
        LLMModelInfo(id: "mistral-large-latest", displayName: "Mistral Large", provider: .mistral),
        LLMModelInfo(id: "mistral-small-latest", displayName: "Mistral Small", provider: .mistral),
        LLMModelInfo(id: "codestral-latest", displayName: "Codestral", provider: .mistral),
        // DeepSeek
        LLMModelInfo(id: "deepseek-chat", displayName: "DeepSeek Chat", provider: .deepseek),
        LLMModelInfo(id: "deepseek-reasoner", displayName: "DeepSeek Reasoner", provider: .deepseek),
        // Kimi (Moonshot)
        LLMModelInfo(id: "moonshot-v1-128k", displayName: "Moonshot v1 128K", provider: .kimi),
        LLMModelInfo(id: "moonshot-v1-32k", displayName: "Moonshot v1 32K", provider: .kimi),
        LLMModelInfo(id: "moonshot-v1-8k", displayName: "Moonshot v1 8K", provider: .kimi),
    ]

    /// Convenience accessor that returns the full registry (dynamic + defaults fallback).
    static var allModels: [LLMModelInfo] {
        ModelRegistry.shared.allModels
    }

    /// Determine provider for a model ID. Checks registry first, then falls back to defaults.
    static func provider(for modelId: String) -> LLMProvider {
        if let model = ModelRegistry.shared.allModels.first(where: { $0.id == modelId }) {
            return model.provider
        }
        if let model = defaultModels.first(where: { $0.id == modelId }) {
            return model.provider
        }
        // Infer from model ID prefix
        if modelId.hasPrefix("claude") { return .anthropic }
        if modelId.hasPrefix("gpt") || modelId.hasPrefix("o3") || modelId.hasPrefix("o4") { return .openai }
        if modelId.hasPrefix("gemini") { return .google }
        if modelId.hasPrefix("grok") { return .xai }
        if modelId.hasPrefix("mistral") || modelId.hasPrefix("codestral") { return .mistral }
        if modelId.hasPrefix("deepseek") { return .deepseek }
        if modelId.hasPrefix("moonshot") { return .kimi }
        // Default to anthropic for unknown
        return .anthropic
    }

    static func apiKeyName(for provider: LLMProvider) -> String {
        provider.keychainKey
    }
}

// MARK: - Model Registry (Dynamic + Cached)

/// Fetches available models from each provider's API at runtime,
/// caches results for 24 hours, and falls back to hardcoded defaults.
final class ModelRegistry: @unchecked Sendable {
    static let shared = ModelRegistry()

    private let lock = NSLock()
    nonisolated(unsafe) private var _cachedModels: [LLMProvider: [LLMModelInfo]] = [:]
    nonisolated(unsafe) private var _lastFetchDate: Date?

    private let cacheKey = "ModelRegistry.cachedModels"
    private let cacheTimestampKey = "ModelRegistry.cacheTimestamp"
    private let cacheDuration: TimeInterval = 86400  // 24 hours

    private let session: URLSession

    nonisolated init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
        loadFromDisk()
    }

    /// All models from cache + defaults, deduped per provider.
    var allModels: [LLMModelInfo] {
        lock.withLock {
            var result: [LLMModelInfo] = []
            var seenIds = Set<String>()

            // Add cached (fetched) models first, grouped by provider order
            for provider in LLMProvider.allCases {
                if let cached = _cachedModels[provider] {
                    for model in cached where !seenIds.contains(model.id) {
                        result.append(model)
                        seenIds.insert(model.id)
                    }
                }
            }

            // Fill in defaults for any providers that have no cached models
            for model in LLMModels.defaultModels where !seenIds.contains(model.id) {
                result.append(model)
                seenIds.insert(model.id)
            }

            return result
        }
    }

    /// Models for a specific provider.
    func models(for provider: LLMProvider) -> [LLMModelInfo] {
        lock.withLock {
            if let cached = _cachedModels[provider], !cached.isEmpty {
                return cached
            }
            return LLMModels.defaultModels.filter { $0.provider == provider }
        }
    }

    /// Whether the cache is still fresh.
    var isCacheFresh: Bool {
        lock.withLock {
            guard let lastFetch = _lastFetchDate else { return false }
            return Date().timeIntervalSince(lastFetch) < cacheDuration
        }
    }

    // MARK: - Fetch All Providers

    /// Refresh models from all providers that have API keys configured.
    /// Returns the total number of models fetched.
    @discardableResult
    nonisolated func refreshAll() async -> Int {
        var totalFetched = 0

        await withTaskGroup(of: (LLMProvider, [LLMModelInfo]).self) { group in
            for provider in LLMProvider.allCases {
                // Skip providers without API keys (except Ollama)
                if provider != .ollama && provider != .anthropic {
                    guard let key = KeychainHelper.read(key: provider.keychainKey), !key.isEmpty else {
                        continue
                    }
                }

                group.addTask { [self] in
                    let models = await self.fetchModels(for: provider)
                    return (provider, models)
                }
            }

            for await (provider, models) in group {
                if !models.isEmpty {
                    lock.withLock { _cachedModels[provider] = models }
                    totalFetched += models.count
                }
            }
        }

        // Anthropic has no list API; always use hardcoded
        let anthropicDefaults = LLMModels.defaultModels.filter { $0.provider == .anthropic }
        lock.withLock { _cachedModels[.anthropic] = anthropicDefaults }
        totalFetched += anthropicDefaults.count

        lock.withLock { _lastFetchDate = Date() }
        saveToDisk()

        log.info("[ModelRegistry] Refreshed all providers, total models: \(totalFetched)")
        return totalFetched
    }

    // MARK: - Per-Provider Fetch

    nonisolated func fetchModels(for provider: LLMProvider) async -> [LLMModelInfo] {
        switch provider {
        case .anthropic:
            return LLMModels.defaultModels.filter { $0.provider == .anthropic }

        case .ollama:
            return await fetchOllamaModels()

        case .google:
            return await fetchGeminiModels()

        case .openai, .xai, .mistral, .deepseek, .kimi:
            return await fetchOpenAICompatibleModels(provider: provider)
        }
    }

    // MARK: - Ollama

    private nonisolated func fetchOllamaModels() async -> [LLMModelInfo] {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return [] }
        do {
            let (data, _) = try await session.data(for: URLRequest(url: url))
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                return models.compactMap { entry -> LLMModelInfo? in
                    guard let name = entry["name"] as? String else { return nil }
                    let display = name.replacingOccurrences(of: ":latest", with: "")
                    return LLMModelInfo(id: name, displayName: "\(display) (Ollama)", provider: .ollama)
                }
            }
        } catch {
            log.debug("[ModelRegistry] Ollama not available: \(error.localizedDescription)")
        }
        return []
    }

    // MARK: - Google Gemini

    private nonisolated func fetchGeminiModels() async -> [LLMModelInfo] {
        guard let apiKey = KeychainHelper.read(key: LLMProvider.google.keychainKey), !apiKey.isEmpty else {
            return []
        }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)") else {
            return []
        }
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return [] }

            return models.compactMap { entry -> LLMModelInfo? in
                guard let name = entry["name"] as? String else { return nil }
                // name is like "models/gemini-2.5-pro"
                let modelId = name.replacingOccurrences(of: "models/", with: "")
                let displayName = entry["displayName"] as? String ?? modelId
                // Filter for generateContent-capable models only
                if let methods = entry["supportedGenerationMethods"] as? [String],
                   methods.contains("generateContent") {
                    return LLMModelInfo(id: modelId, displayName: displayName, provider: .google)
                }
                return nil
            }
        } catch {
            log.debug("[ModelRegistry] Gemini fetch failed: \(error.localizedDescription)")
        }
        return []
    }

    // MARK: - OpenAI-Compatible (OpenAI, xAI, Mistral, DeepSeek, Kimi)

    private nonisolated func fetchOpenAICompatibleModels(provider: LLMProvider) async -> [LLMModelInfo] {
        guard let endpoint = provider.modelsListEndpoint,
              let url = URL(string: endpoint) else { return [] }

        guard let apiKey = KeychainHelper.read(key: provider.keychainKey), !apiKey.isEmpty else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelList = json["data"] as? [[String: Any]] else { return [] }

            var results: [LLMModelInfo] = []
            for entry in modelList {
                guard let modelId = entry["id"] as? String else { continue }

                // For OpenAI, filter to chat models only
                if provider == .openai {
                    let validPrefixes = ["gpt-", "o3", "o4", "chatgpt-"]
                    guard validPrefixes.contains(where: { modelId.hasPrefix($0) }) else { continue }
                    // Skip snapshot/dated variants to keep list clean
                    if modelId.contains("-202") && !modelId.hasSuffix("-preview") { continue }
                }

                let displayName = modelId
                    .replacingOccurrences(of: "-", with: " ")
                    .split(separator: " ")
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined(separator: " ")

                results.append(LLMModelInfo(id: modelId, displayName: displayName, provider: provider))
            }
            return results
        } catch {
            log.debug("[ModelRegistry] \(provider.rawValue) model fetch failed: \(error.localizedDescription)")
        }
        return []
    }

    // MARK: - Persistence (UserDefaults)

    nonisolated private func saveToDisk() {
        let models = lock.withLock { _cachedModels }
        var flat: [LLMModelInfo] = []
        for (_, list) in models { flat.append(contentsOf: list) }

        if let data = try? JSONEncoder().encode(flat) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheTimestampKey)
    }

    nonisolated private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let models = try? JSONDecoder().decode([LLMModelInfo].self, from: data) else { return }

        let timestamp = UserDefaults.standard.double(forKey: cacheTimestampKey)
        let cacheDate = Date(timeIntervalSince1970: timestamp)
        guard Date().timeIntervalSince(cacheDate) < cacheDuration else { return }

        var grouped: [LLMProvider: [LLMModelInfo]] = [:]
        for model in models {
            grouped[model.provider, default: []].append(model)
        }
        lock.withLock {
            _cachedModels = grouped
            _lastFetchDate = cacheDate
        }
    }
}
