import SwiftUI

// MARK: - Settings Tab Enum

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case apiKeys = "API Keys"
    case models = "Models"
    case voice = "Voice"
    case agent = "Agent"
    case notifications = "Notifications"
    case privacy = "Privacy"
    case advanced = "Advanced"
    case about = "About"

    var id: SettingsTab { self }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .apiKeys: "key.fill"
        case .models: "cpu"
        case .voice: "mic.fill"
        case .agent: "brain"
        case .notifications: "bell.fill"
        case .privacy: "lock.shield.fill"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }
}

/// Sidebar-based settings panel (matches Jarvis style).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var appState: AppState?
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Settings")
                    .font(DockwrightTheme.Typography.heading)
                Spacer()
                Button {
                    if let appState { appState.showSettings = false } else { dismiss() }
                } label: {
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, DockwrightTheme.Spacing.lg)
                        .padding(.vertical, 6)
                        .background(DockwrightTheme.primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DockwrightTheme.Spacing.xl)
            .padding(.top, DockwrightTheme.Spacing.lg)
            .padding(.bottom, DockwrightTheme.Spacing.sm)

            Divider().opacity(0.15)

            // Sidebar + Content
            HStack(spacing: 0) {
                // Sidebar navigation
                List {
                    Section("General") {
                        settingsTabRow(.general)
                        settingsTabRow(.apiKeys)
                        settingsTabRow(.models)
                        settingsTabRow(.voice)
                    }
                    Section("Features") {
                        settingsTabRow(.agent)
                        settingsTabRow(.notifications)
                    }
                    Section("Security") {
                        settingsTabRow(.privacy)
                    }
                    Section("Other") {
                        settingsTabRow(.advanced)
                        settingsTabRow(.about)
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 180, maxWidth: 180)
                .layoutPriority(1)

                Divider().opacity(0.15)

                // Content area
                ScrollView {
                    Group {
                        switch selectedTab {
                        case .general: GeneralSettingsView()
                        case .apiKeys:
                            if let mgr = appState?.authManager {
                                APIKeysView(authManager: mgr)
                            } else {
                                Text("Settings unavailable — reopen from main window.")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        case .models: ModelSettingsView()
                        case .voice: VoiceSettingsView()
                        case .agent: AgentSettingsView()
                        case .notifications: NotificationSettingsView()
                        case .privacy: PrivacySettingsView(appState: appState)
                        case .advanced: AdvancedSettingsView()
                        case .about: aboutView
                        }
                    }
                    .padding(DockwrightTheme.Spacing.lg)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 780, height: 600)
        .background(DockwrightTheme.Surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DockwrightTheme.Radius.card)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }

    private func settingsTabRow(_ tab: SettingsTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Label(tab.rawValue, systemImage: tab.icon)
                .font(DockwrightTheme.Typography.body)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            selectedTab == tab
                ? Color.white.opacity(0.10)
                : Color.clear
        )
    }

    private var aboutView: some View {
        VStack(spacing: DockwrightTheme.Spacing.xl) {
            Spacer()

            ZStack {
                Circle()
                    .fill(DockwrightTheme.orbGradient)
                    .frame(width: 50, height: 50)
                    .blur(radius: 1)
            }

            Text("Dockwright")
                .font(DockwrightTheme.Typography.displayMedium)

            Text("macOS AI Assistant")
                .font(DockwrightTheme.Typography.body)
                .foregroundStyle(.secondary)

            Text("Version 1.0")
                .font(DockwrightTheme.Typography.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Model Settings

struct ModelSettingsView: View {
    private var prefs: AppPreferences { AppPreferences.shared }
    @State private var isRefreshing = false
    @State private var refreshStatus = ""
    @State private var modelsByProvider: [LLMProvider: [LLMModelInfo]] = [:]

    /// Provider display order.
    private let providerOrder: [LLMProvider] = [
        .anthropic, .openai, .google, .xai, .mistral, .deepseek, .kimi, .ollama
    ]

    var body: some View {
        ScrollView {
            Form {
                Section("Default Model") {
                    Picker("Model", selection: Binding(
                        get: { prefs.selectedModel },
                        set: { prefs.selectedModel = $0 }
                    )) {
                        ForEach(providerOrder, id: \.self) { provider in
                            let models = modelsByProvider[provider] ?? []
                            if !models.isEmpty {
                                ForEach(models) { model in
                                    Text("\(model.displayName) (\(provider.rawValue))")
                                        .tag(model.id)
                                }
                            }
                        }
                    }
                }

                Section("Model Registry") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Fetch available models from all configured providers")
                                .font(DockwrightTheme.Typography.caption)
                                .foregroundStyle(.secondary)

                            if !refreshStatus.isEmpty {
                                Text(refreshStatus)
                                    .font(DockwrightTheme.Typography.caption)
                                    .foregroundStyle(DockwrightTheme.success)
                            }
                        }

                        Spacer()

                        Button {
                            refreshAllModels()
                        } label: {
                            HStack(spacing: 4) {
                                if isRefreshing {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text("Refresh Models")
                            }
                        }
                        .disabled(isRefreshing)
                    }
                }

                // Per-provider model lists
                ForEach(providerOrder, id: \.self) { provider in
                    let models = modelsByProvider[provider] ?? []
                    let hasKey = providerHasKey(provider)

                    Section {
                        HStack {
                            Text(provider.rawValue)
                                .font(DockwrightTheme.Typography.bodyMedium)
                            Spacer()
                            if hasKey || provider == .ollama {
                                Text("\(models.count) models")
                                    .font(DockwrightTheme.Typography.caption)
                                    .foregroundStyle(.secondary)
                                if hasKey {
                                    Circle()
                                        .fill(DockwrightTheme.success)
                                        .frame(width: 6, height: 6)
                                }
                            } else {
                                Text("No API key")
                                    .font(DockwrightTheme.Typography.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        if !models.isEmpty {
                            ForEach(models) { model in
                                HStack {
                                    Circle()
                                        .fill(model.id == prefs.selectedModel ? DockwrightTheme.primary : DockwrightTheme.success.opacity(0.5))
                                        .frame(width: 6, height: 6)
                                    Text(model.displayName)
                                        .font(DockwrightTheme.Typography.body)
                                    Spacer()
                                    Text(model.id)
                                        .font(DockwrightTheme.Typography.captionMono)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { loadModels() }
    }

    private func loadModels() {
        var grouped: [LLMProvider: [LLMModelInfo]] = [:]
        for model in ModelRegistry.shared.allModels {
            grouped[model.provider, default: []].append(model)
        }
        modelsByProvider = grouped
    }

    private func refreshAllModels() {
        isRefreshing = true
        refreshStatus = ""
        Task {
            let count = await ModelRegistry.shared.refreshAll()
            isRefreshing = false
            refreshStatus = "Fetched \(count) models"
            loadModels()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                refreshStatus = ""
            }
        }
    }

    private func providerHasKey(_ provider: LLMProvider) -> Bool {
        if provider == .ollama { return true }
        if provider == .anthropic {
            return KeychainHelper.exists(key: "anthropic_api_key") ||
                   KeychainHelper.exists(key: "claude_oauth_token")
        }
        if provider == .openai {
            return KeychainHelper.exists(key: "openai_api_key") ||
                   KeychainHelper.exists(key: "openai_oauth_token")
        }
        return KeychainHelper.exists(key: provider.keychainKey)
    }
}

// MARK: - Voice Settings

struct VoiceSettingsView: View {
    @State private var voiceEnabled = UserDefaults.standard.object(forKey: "voiceEnabled") as? Bool ?? true
    @State private var sttLanguage = VoiceService.effectiveLanguage
    @State private var ttsRate: Float = UserDefaults.standard.object(forKey: "ttsRate") as? Float ?? 0.52
    @State private var silenceThreshold: Float = UserDefaults.standard.object(forKey: "voiceSilenceThreshold") as? Float ?? 0.013
    @State private var silenceDuration: Double = UserDefaults.standard.object(forKey: "voiceSilenceDuration") as? Double ?? 1.5

    var body: some View {
        Form {
            Section("Speech Recognition (STT)") {
                Toggle("Enable Voice Mode", isOn: $voiceEnabled)
                    .onChange(of: voiceEnabled) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "voiceEnabled")
                    }

                Picker("Voice language", selection: $sttLanguage) {
                    ForEach(VoiceService.supportedSTTLanguages, id: \.id) { lang in
                        Text(lang.label).tag(lang.id)
                    }
                }
                .onChange(of: sttLanguage) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "voice.sttLanguage")
                    VoiceService.shared.sttLanguage = newValue
                }

                Text("Also settable from General tab. Controls AI response language too.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Silence Detection") {
                VStack(alignment: .leading) {
                    Text("Silence threshold: \(String(format: "%.3f", silenceThreshold))")
                        .font(DockwrightTheme.Typography.caption)
                    Slider(value: $silenceThreshold, in: 0.005...0.05, step: 0.001)
                        .onChange(of: silenceThreshold) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "voiceSilenceThreshold")
                        }
                }

                VStack(alignment: .leading) {
                    Text("Silence duration: \(String(format: "%.1fs", silenceDuration))")
                        .font(DockwrightTheme.Typography.caption)
                    Slider(value: $silenceDuration, in: 0.5...5.0, step: 0.1)
                        .onChange(of: silenceDuration) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "voiceSilenceDuration")
                        }
                }
            }

            Section("Text-to-Speech (TTS)") {
                Picker("Provider", selection: Binding(
                    get: { TTSService.shared.provider },
                    set: { TTSService.shared.provider = $0 }
                )) {
                    ForEach(TTSService.TTSProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }

                if TTSService.shared.provider == .elevenLabs {
                    HStack {
                        Text("Voice")
                            .font(DockwrightTheme.Typography.body)
                        Spacer()
                        if TTSService.shared.isLoadingVoices {
                            ProgressView().controlSize(.small)
                        }
                        Picker("", selection: Binding(
                            get: { TTSService.shared.elevenLabsVoiceId },
                            set: { TTSService.shared.elevenLabsVoiceId = $0 }
                        )) {
                            if TTSService.shared.elevenLabsVoices.isEmpty {
                                Text("Loading...").tag(TTSService.shared.elevenLabsVoiceId)
                            }
                            ForEach(TTSService.shared.elevenLabsVoices, id: \.id) { voice in
                                Text(voice.label).tag(voice.id)
                            }
                        }
                        .frame(maxWidth: 200)
                    }
                    .onAppear { TTSService.shared.fetchElevenLabsVoices() }

                    if !KeychainHelper.exists(key: "elevenlabs_api_key") {
                        Text("Add ElevenLabs API key in API Keys tab")
                            .font(DockwrightTheme.Typography.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    // System TTS voice picker
                    let sysVoices = TTSService.systemVoices(for: sttLanguage)
                    if !sysVoices.isEmpty {
                        Picker("Voice", selection: Binding(
                            get: {
                                let current = TTSService.shared.systemVoiceId
                                // Auto-select best voice if none set
                                if current.isEmpty, let best = sysVoices.first {
                                    TTSService.shared.systemVoiceId = best.id
                                    return best.id
                                }
                                return current
                            },
                            set: { TTSService.shared.systemVoiceId = $0 }
                        )) {
                            ForEach(sysVoices, id: \.id) { voice in
                                Text(voice.label).tag(voice.id)
                            }
                        }
                    }

                    Button {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 11))
                            Text("Download more voices")
                                .font(DockwrightTheme.Typography.caption)
                        }
                        .foregroundStyle(DockwrightTheme.primary)
                    }
                    .buttonStyle(.plain)
                }

                // Test voice — works for both macOS TTS and ElevenLabs
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button {
                            if isPreviewing {
                                TTSService.shared.stopSpeaking()
                                isPreviewing = false
                            } else {
                                TTSService.shared.lastError = nil
                                isPreviewing = true
                                TTSService.shared.onSpeakingComplete = {
                                    isPreviewing = false
                                    TTSService.shared.onSpeakingComplete = nil
                                }
                                TTSService.shared.speak(text: previewPhrase)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: isPreviewing ? "stop.fill" : "play.fill")
                                    .font(.system(size: 10))
                                Text(isPreviewing ? "Stop" : "Test Voice")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(isPreviewing ? DockwrightTheme.error : DockwrightTheme.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                (isPreviewing ? DockwrightTheme.error : DockwrightTheme.primary)
                                    .opacity(0.12)
                            )
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Text(previewPhrase)
                            .font(DockwrightTheme.Typography.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    if let error = TTSService.shared.lastError {
                        Text(error)
                            .font(DockwrightTheme.Typography.caption)
                            .foregroundStyle(DockwrightTheme.error)
                            .lineLimit(2)
                    }
                }

                VStack(alignment: .leading) {
                    Text("Speech rate: \(String(format: "%.2f", ttsRate))")
                        .font(DockwrightTheme.Typography.caption)
                    Slider(value: $ttsRate, in: 0.3...0.7, step: 0.01)
                        .onChange(of: ttsRate) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "ttsRate")
                            TTSService.shared.rate = newValue
                        }
                }
            }
        }
        .formStyle(.grouped)
    }

    @State private var isPreviewing = false

    /// Sample phrase matching the selected STT language.
    private var previewPhrase: String {
        switch sttLanguage {
        case "nl-NL": return "Hallo, ik ben Dockwright. Hoe kan ik je helpen?"
        case "fr-FR": return "Bonjour, je suis Dockwright. Comment puis-je vous aider?"
        case "de-DE": return "Hallo, ich bin Dockwright. Wie kann ich Ihnen helfen?"
        case "es-ES": return "Hola, soy Dockwright. \u{00BF}En qu\u{00E9} puedo ayudarte?"
        case "it-IT": return "Ciao, sono Dockwright. Come posso aiutarti?"
        case "pt-BR": return "Ol\u{00E1}, eu sou Dockwright. Como posso te ajudar?"
        case "ja-JP": return "\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}\u{3001}Dockwright\u{3067}\u{3059}\u{3002}\u{304A}\u{624B}\u{4F1D}\u{3044}\u{3057}\u{307E}\u{3057}\u{3087}\u{3046}\u{304B}\u{FF1F}"
        case "zh-CN": return "\u{4F60}\u{597D}\u{FF0C}\u{6211}\u{662F}Dockwright\u{3002}\u{6709}\u{4EC0}\u{4E48}\u{53EF}\u{4EE5}\u{5E2E}\u{52A9}\u{4F60}\u{7684}\u{FF1F}"
        default: return "Hello, I'm Dockwright. How can I help you today?"
        }
    }
}
