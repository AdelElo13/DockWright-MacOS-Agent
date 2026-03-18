import Foundation
import Observation

/// Single source of truth for all user-facing settings.
/// Observable by SwiftUI views. Read by services. Persists to UserDefaults.
/// Eliminates dual-truth between `@State` + `UserDefaults` in settings views.
@Observable
final class AppPreferences {
    static let shared = AppPreferences()

    private let defaults = UserDefaults.standard

    // MARK: - Profile

    var userName: String {
        didSet { defaults.set(userName, forKey: "userName") }
    }
    var userBio: String {
        didSet { defaults.set(userBio, forKey: "userBio") }
    }
    var userEmail: String {
        didSet { defaults.set(userEmail, forKey: "userEmail") }
    }
    var userPhone: String {
        didSet { defaults.set(userPhone, forKey: "userPhone") }
    }
    var userAddress: String {
        didSet { defaults.set(userAddress, forKey: "userAddress") }
    }
    var userCity: String {
        didSet { defaults.set(userCity, forKey: "userCity") }
    }
    var userPostalCode: String {
        didSet { defaults.set(userPostalCode, forKey: "userPostalCode") }
    }
    var userCountry: String {
        didSet { defaults.set(userCountry, forKey: "userCountry") }
    }
    /// Custom name for the assistant (defaults to "Dockwright")
    var assistantName: String {
        didSet { defaults.set(assistantName, forKey: "assistantName") }
    }

    // MARK: - General

    var appearance: String {
        didSet { defaults.set(appearance, forKey: "appearance") }
    }
    var showMenuBarExtra: Bool {
        didSet { defaults.set(showMenuBarExtra, forKey: "showMenuBarExtra") }
    }
    var alwaysOnTop: Bool {
        didSet { defaults.set(alwaysOnTop, forKey: "alwaysOnTop") }
    }
    var sidebarDefaultOpen: Bool {
        didSet { defaults.set(sidebarDefaultOpen, forKey: "sidebarDefaultOpen") }
    }
    var sendWithReturn: Bool {
        didSet { defaults.set(sendWithReturn, forKey: "sendWithReturn") }
    }
    var streamResponses: Bool {
        didSet { defaults.set(streamResponses, forKey: "streamResponses") }
    }
    var showTokenCost: Bool {
        didSet { defaults.set(showTokenCost, forKey: "showTokenCost") }
    }
    var confirmDeletions: Bool {
        didSet { defaults.set(confirmDeletions, forKey: "confirmDeletions") }
    }
    var chatFontSize: Double {
        didSet { defaults.set(chatFontSize, forKey: "chatFontSize") }
    }

    // MARK: - Model / Auth

    var selectedModel: String {
        didSet { defaults.set(selectedModel, forKey: "selectedModel") }
    }

    // MARK: - Advanced LLM

    var temperature: Double {
        didSet { defaults.set(temperature, forKey: "temperature") }
    }
    var maxTokens: Int {
        didSet { defaults.set(maxTokens, forKey: "maxTokens") }
    }
    var customSystemPrompt: String {
        didSet { defaults.set(customSystemPrompt, forKey: "customSystemPrompt") }
    }
    var responseStyle: String {
        didSet { defaults.set(responseStyle, forKey: "responseStyle") }
    }

    // MARK: - Notifications

    var useSystemNotifications: Bool {
        didSet { defaults.set(useSystemNotifications, forKey: "useSystemNotifications") }
    }
    var useTelegramNotifications: Bool {
        didSet { defaults.set(useTelegramNotifications, forKey: "useTelegramNotifications") }
    }
    var useDiscordNotifications: Bool {
        didSet { defaults.set(useDiscordNotifications, forKey: "useDiscordNotifications") }
    }
    var wakeWordEnabled: Bool {
        didSet { defaults.set(wakeWordEnabled, forKey: "wakeWordEnabled") }
    }
    var quietHoursEnabled: Bool {
        didSet { defaults.set(quietHoursEnabled, forKey: "quietHoursEnabled") }
    }
    var quietHoursStart: Int {
        didSet { defaults.set(quietHoursStart, forKey: "quietHoursStart") }
    }
    var quietHoursEnd: Int {
        didSet { defaults.set(quietHoursEnd, forKey: "quietHoursEnd") }
    }
    var notifySound: Bool {
        didSet { defaults.set(notifySound, forKey: "notifySound") }
    }
    var notifyOnCompletion: Bool {
        didSet { defaults.set(notifyOnCompletion, forKey: "notifyOnCompletion") }
    }
    var notifyOnError: Bool {
        didSet { defaults.set(notifyOnError, forKey: "notifyOnError") }
    }
    var notifyOnScheduledTask: Bool {
        didSet { defaults.set(notifyOnScheduledTask, forKey: "notifyOnScheduledTask") }
    }

    // MARK: - Browsing

    var headlessBrowsing: Bool {
        didSet { defaults.set(headlessBrowsing, forKey: "headlessBrowsing") }
    }

    // MARK: - Privacy

    var saveConversations: Bool {
        didSet { defaults.set(saveConversations, forKey: "saveConversations") }
    }
    var conversationRetentionDays: Int {
        didSet { defaults.set(conversationRetentionDays, forKey: "conversationRetentionDays") }
    }

    // MARK: - Init (load from UserDefaults)

    private init() {
        let d = UserDefaults.standard

        // Profile
        userName = d.string(forKey: "userName") ?? ""
        userBio = d.string(forKey: "userBio") ?? ""
        userEmail = d.string(forKey: "userEmail") ?? ""
        userPhone = d.string(forKey: "userPhone") ?? ""
        userAddress = d.string(forKey: "userAddress") ?? ""
        userCity = d.string(forKey: "userCity") ?? ""
        userPostalCode = d.string(forKey: "userPostalCode") ?? ""
        userCountry = d.string(forKey: "userCountry") ?? ""
        assistantName = d.string(forKey: "assistantName") ?? "Dockwright"

        // General
        appearance = d.string(forKey: "appearance") ?? "system"
        showMenuBarExtra = d.object(forKey: "showMenuBarExtra") as? Bool ?? true
        alwaysOnTop = d.bool(forKey: "alwaysOnTop")
        sidebarDefaultOpen = d.object(forKey: "sidebarDefaultOpen") as? Bool ?? true
        sendWithReturn = d.object(forKey: "sendWithReturn") as? Bool ?? true
        streamResponses = d.object(forKey: "streamResponses") as? Bool ?? true
        showTokenCost = d.object(forKey: "showTokenCost") as? Bool ?? true
        confirmDeletions = d.object(forKey: "confirmDeletions") as? Bool ?? true
        chatFontSize = d.object(forKey: "chatFontSize") as? Double ?? 14.0

        // Model
        selectedModel = d.string(forKey: "selectedModel") ?? "claude-opus-4-6"

        // Advanced LLM
        temperature = d.object(forKey: "temperature") as? Double ?? 0.7
        maxTokens = d.object(forKey: "maxTokens") as? Int ?? 8192
        customSystemPrompt = d.string(forKey: "customSystemPrompt") ?? ""
        responseStyle = d.string(forKey: "responseStyle") ?? "balanced"

        // Notifications
        useSystemNotifications = d.object(forKey: "useSystemNotifications") as? Bool ?? true
        useTelegramNotifications = d.object(forKey: "useTelegramNotifications") as? Bool ?? true
        useDiscordNotifications = d.object(forKey: "useDiscordNotifications") as? Bool ?? false
        wakeWordEnabled = d.object(forKey: "wakeWordEnabled") as? Bool ?? true
        quietHoursEnabled = d.bool(forKey: "quietHoursEnabled")
        quietHoursStart = d.object(forKey: "quietHoursStart") as? Int ?? 22
        quietHoursEnd = d.object(forKey: "quietHoursEnd") as? Int ?? 8
        notifySound = d.object(forKey: "notifySound") as? Bool ?? true
        notifyOnCompletion = d.object(forKey: "notifyOnCompletion") as? Bool ?? true
        notifyOnError = d.object(forKey: "notifyOnError") as? Bool ?? true
        notifyOnScheduledTask = d.object(forKey: "notifyOnScheduledTask") as? Bool ?? true

        // Browsing
        headlessBrowsing = d.object(forKey: "headlessBrowsing") as? Bool ?? true

        // Privacy
        saveConversations = d.object(forKey: "saveConversations") as? Bool ?? true
        conversationRetentionDays = d.object(forKey: "conversationRetentionDays") as? Int ?? 90
    }

    // MARK: - Quiet Hours Check

    /// Returns true if quiet hours are active right now.
    var isQuietHoursActive: Bool {
        guard quietHoursEnabled else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        if quietHoursStart < quietHoursEnd {
            // e.g. 22:00 to 08:00 doesn't wrap → this branch is 09:00-17:00 style
            return hour >= quietHoursStart && hour < quietHoursEnd
        } else {
            // Wraps midnight: e.g. 22:00 to 08:00
            return hour >= quietHoursStart || hour < quietHoursEnd
        }
    }

    // MARK: - Provider Auth Helpers

    /// Check whether the given provider has a usable credential (OAuth or API key).
    func isProviderConfigured(_ provider: LLMProvider, authManager: AuthManager) -> Bool {
        switch provider {
        case .ollama:
            return true
        case .anthropic:
            return !authManager.anthropicApiKey.isEmpty
        case .openai:
            return !authManager.openaiApiKey.isEmpty
        case .google, .xai, .mistral, .deepseek, .kimi:
            return KeychainHelper.exists(key: provider.keychainKey)
        }
    }

    /// Check whether the currently selected model's provider is configured.
    func isCurrentProviderConfigured(authManager: AuthManager) -> Bool {
        let provider = LLMModels.provider(for: selectedModel)
        return isProviderConfigured(provider, authManager: authManager)
    }

    /// Returns true if ANY LLM provider that requires a real credential is configured.
    /// Gates onboarding — once any provider is configured, the user is past Welcome.
    /// Ollama counts if the user explicitly selected an Ollama model (not just as a silent fallback).
    func hasAnyConfiguredProvider(authManager: AuthManager) -> Bool {
        // If user explicitly chose Ollama, they're past onboarding
        if LLMModels.provider(for: selectedModel) == .ollama {
            return true
        }
        let keyedProviders: [LLMProvider] = [.anthropic, .openai, .google, .xai, .mistral, .deepseek, .kimi]
        return keyedProviders.contains { isProviderConfigured($0, authManager: authManager) }
    }

    /// If the currently selected model's provider is unavailable, switch to a fallback.
    func syncModelToAvailableProvider(authManager: AuthManager) {
        guard !isCurrentProviderConfigured(authManager: authManager) else { return }
        if let fallback = fallbackModel(authManager: authManager) {
            selectedModel = fallback
        }
    }

    /// Returns the first configured keyed provider's default model, or nil.
    /// Ollama is never returned as a fallback — it must be explicitly selected by the user.
    /// Returning nil means "no keyed provider available" → keep current model, show Welcome.
    func fallbackModel(authManager: AuthManager) -> String? {
        let keyedProviders: [LLMProvider] = [.anthropic, .openai, .google, .xai, .mistral, .deepseek, .kimi]
        for provider in keyedProviders {
            if isProviderConfigured(provider, authManager: authManager) {
                return LLMModels.allModels.first { LLMModels.provider(for: $0.id) == provider }?.id
            }
        }
        return nil
    }

    // MARK: - Response Style Prompt Fragment

    /// Returns a prompt fragment for the selected response style.
    var responseStylePrompt: String {
        switch responseStyle {
        case "brief":
            return "\nRespond as concisely as possible. Use short sentences. Avoid filler words. Bullet points over paragraphs."
        case "detailed":
            return "\nProvide thorough, detailed explanations. Include context, examples, and reasoning. Be comprehensive."
        case "technical":
            return "\nUse precise technical language. Include specifics like version numbers, exact commands, and code samples. Assume technical expertise."
        default: // "balanced"
            return ""
        }
    }

    // MARK: - Reset to Defaults

    /// Resets all preferences to their default values — both the in-memory singleton AND UserDefaults.
    /// API keys and OAuth tokens are NOT affected.
    func resetToDefaults() {
        // General
        appearance = "system"
        showMenuBarExtra = true
        alwaysOnTop = false
        sidebarDefaultOpen = true
        sendWithReturn = true
        streamResponses = true
        showTokenCost = true
        confirmDeletions = true
        chatFontSize = 14.0

        // Model — reset to project default
        selectedModel = "claude-opus-4-6"

        // Advanced LLM
        temperature = 0.7
        maxTokens = 8192
        customSystemPrompt = ""
        responseStyle = "balanced"

        // Notifications
        useSystemNotifications = true
        useTelegramNotifications = true
        useDiscordNotifications = true
        quietHoursEnabled = false
        quietHoursStart = 22
        quietHoursEnd = 8
        notifySound = true
        notifyOnCompletion = true
        notifyOnError = true
        notifyOnScheduledTask = true

        // Browsing
        headlessBrowsing = true

        // Privacy
        saveConversations = true
        conversationRetentionDays = 90

        // Also clean stale UserDefaults keys that aren't backed by properties
        let extraKeys = ["requireApprovalForRisky", "sendAnalytics", "debugLogging",
                         "showRawJSON", "cacheResponses", "cacheDurationHours",
                         "autonomyLevel", "heartbeatInterval", "agentTokenBudget"]
        for key in extraKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
