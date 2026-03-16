import SwiftUI

/// Tab-based settings window.
struct SettingsView: View {
    var body: some View {
        TabView {
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

            aboutView
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 520, height: 420)
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
    @State private var selectedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? "claude-sonnet-4-20250514"
    @State private var ollamaModels: [String] = []
    @State private var isCheckingOllama = false

    var body: some View {
        Form {
            Section("Default Model") {
                Picker("Model", selection: $selectedModel) {
                    ForEach(LLMModels.allModels, id: \.id) { model in
                        Text("\(model.displayName) (\(model.provider.rawValue))")
                            .tag(model.id)
                    }

                    if !ollamaModels.isEmpty {
                        Divider()
                        ForEach(ollamaModels, id: \.self) { model in
                            Text("\(model) (Ollama)")
                                .tag(model)
                        }
                    }
                }
                .onChange(of: selectedModel) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "selectedModel")
                }
            }

            Section("Ollama (Local)") {
                HStack {
                    Text("Auto-detect local models from Ollama")
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Refresh") {
                        refreshOllama()
                    }
                    .disabled(isCheckingOllama)
                }

                if !ollamaModels.isEmpty {
                    ForEach(ollamaModels, id: \.self) { model in
                        HStack {
                            Circle()
                                .fill(DockwrightTheme.success)
                                .frame(width: 6, height: 6)
                            Text(model)
                                .font(DockwrightTheme.Typography.body)
                        }
                    }
                } else {
                    Text("No Ollama models detected. Make sure Ollama is running.")
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshOllama() }
    }

    private func refreshOllama() {
        isCheckingOllama = true
        Task {
            let models = await LLMService().fetchOllamaModels()
            ollamaModels = models
            isCheckingOllama = false
        }
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
