import SwiftUI

/// Tab-based settings window.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 12)
                .padding(.trailing, 16)
            }

            TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            APIKeysView()
                .tabItem {
                    Label("API Keys", systemImage: "key.fill")
                }

            ModelSettingsView()
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }

            VoiceSettingsView()
                .tabItem {
                    Label("Voice", systemImage: "mic.fill")
                }

            AgentSettingsView()
                .tabItem {
                    Label("Agent", systemImage: "brain")
                }

            NotificationSettingsView()
                .tabItem {
                    Label("Notifications", systemImage: "bell.fill")
                }

            PrivacySettingsView()
                .tabItem {
                    Label("Privacy", systemImage: "lock.shield.fill")
                }

            AdvancedSettingsView()
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }

            aboutView
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
            .frame(width: 780, height: 560)
        }
        .frame(width: 780, height: 600)
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
    @State private var selectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? "claude-opus-4-6"
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
                    Picker("Model", selection: $selectedModel) {
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
                    .onChange(of: selectedModel) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "selectedModel")
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
                                        .fill(model.id == selectedModel ? DockwrightTheme.primary : DockwrightTheme.success.opacity(0.5))
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
    @State private var voiceEnabled = UserDefaults.standard.bool(forKey: "voiceEnabled")
    @State private var sttLanguage = UserDefaults.standard.string(forKey: "voice.sttLanguage") ?? "en-US"
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

                Picker("Language", selection: $sttLanguage) {
                    ForEach(VoiceService.supportedSTTLanguages, id: \.id) { lang in
                        Text(lang.label).tag(lang.id)
                    }
                }
                .onChange(of: sttLanguage) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "voice.sttLanguage")
                }
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
}
