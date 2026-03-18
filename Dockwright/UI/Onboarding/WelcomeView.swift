import SwiftUI

/// Shown when no API key is configured.
/// Prompts user to enter their Anthropic API key or sign in with OAuth.
struct WelcomeView: View {
    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var errorMessage = ""
    @State private var claudeCode = ""
    @State private var selectedProvider: LLMProvider = .anthropic
    var authManager: AuthManager
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: DockwrightTheme.Spacing.xxxl) {
            Spacer()

            // Logo
            if let img = NSImage(named: "AppIcon") {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(color: DockwrightTheme.primary.opacity(0.3), radius: 20, y: 4)
            }

            VStack(spacing: DockwrightTheme.Spacing.sm) {
                Text("Welcome to Dockwright")
                    .font(DockwrightTheme.Typography.displayLarge)
                    .foregroundStyle(.white)

                Text("Your macOS AI assistant")
                    .font(DockwrightTheme.Typography.bodyLarge)
                    .foregroundStyle(.secondary)
            }

            // OAuth Sign-in Buttons
            VStack(spacing: DockwrightTheme.Spacing.md) {
                Text("Sign in with your account — no API key needed")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.tertiary)

                Button {
                    authManager.signInWithClaude()
                } label: {
                    HStack(spacing: DockwrightTheme.Spacing.md) {
                        Image(systemName: "shield.checkered")
                            .font(.system(size: 16))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Continue with Anthropic")
                                .font(DockwrightTheme.Typography.bodyLargeMedium)
                            Text("Claude OAuth — recommended")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .frame(width: 280, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(DockwrightTheme.primary)
                .disabled(authManager.isSigningIn)

                Button {
                    authManager.signInWithOpenAI()
                } label: {
                    HStack(spacing: DockwrightTheme.Spacing.md) {
                        if authManager.isSigningIn {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "shield.checkered")
                                .font(.system(size: 16))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Continue with OpenAI")
                                .font(DockwrightTheme.Typography.bodyLargeMedium)
                            Text("GPT OAuth")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 280, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(authManager.isSigningIn)

                // Claude OAuth code entry (shown after browser redirect)
                if authManager.oauthCodePrompt {
                    VStack(spacing: DockwrightTheme.Spacing.sm) {
                        Text("Paste the authorization code from your browser:")
                            .font(DockwrightTheme.Typography.caption)
                            .foregroundStyle(.secondary)

                        TextField("Authorization code...", text: $claudeCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 400)

                        Button("Submit Code") {
                            Task {
                                await authManager.exchangeClaudeCode(claudeCode)
                                if authManager.isClaudeSignedIn {
                                    onComplete()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DockwrightTheme.accent)
                        .disabled(claudeCode.trimmingCharacters(in: .whitespaces).isEmpty || authManager.isSigningIn)
                    }
                }

                if let error = authManager.signInError {
                    Text(error)
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(DockwrightTheme.error)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }
            }

            // Divider
            HStack {
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                Text("or use an API key")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.quaternary)
                    .fixedSize()
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            }
            .frame(maxWidth: 320)

            // Manual API key entry — any provider
            VStack(spacing: DockwrightTheme.Spacing.md) {
                Picker("Provider", selection: $selectedProvider) {
                    Text("Anthropic (Claude)").tag(LLMProvider.anthropic)
                    Text("OpenAI (GPT)").tag(LLMProvider.openai)
                    Text("Google (Gemini)").tag(LLMProvider.google)
                    Text("xAI (Grok)").tag(LLMProvider.xai)
                    Text("Mistral").tag(LLMProvider.mistral)
                    Text("DeepSeek").tag(LLMProvider.deepseek)
                    Text("Kimi (Moonshot)").tag(LLMProvider.kimi)
                    Text("Ollama (Local)").tag(LLMProvider.ollama)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 400)

                if selectedProvider == .ollama {
                    Text("No API key needed — make sure Ollama is running on localhost:11434")
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 400)
                } else {
                    SecureField("Paste API key...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 400)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(DockwrightTheme.error)
                }

                Button {
                    saveKey()
                } label: {
                    HStack(spacing: DockwrightTheme.Spacing.sm) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Get Started")
                            .font(DockwrightTheme.Typography.bodyLargeMedium)
                    }
                    .frame(width: 160, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(DockwrightTheme.primary)
                .disabled(selectedProvider != .ollama && (apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isSaving))

                if let (label, urlStr) = providerKeyLink, let keyURL = URL(string: urlStr) {
                    Link(label, destination: keyURL)
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(DockwrightTheme.info)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DockwrightTheme.Surface.canvas)
        .onChange(of: authManager.isOpenAISignedIn) { _, signedIn in
            if signedIn {
                // Sync model to OpenAI since the user just signed in with it
                AppPreferences.shared.syncModelToAvailableProvider(authManager: authManager)
                onComplete()
            }
        }
        .onChange(of: authManager.isClaudeSignedIn) { _, signedIn in
            if signedIn {
                // Sync model to Claude since the user just signed in with it
                AppPreferences.shared.syncModelToAvailableProvider(authManager: authManager)
                onComplete()
            }
        }
    }

    /// Provider-aware link to get an API key.
    private var providerKeyLink: (String, String)? {
        switch selectedProvider {
        case .anthropic: return ("Get an API key at console.anthropic.com", "https://console.anthropic.com/settings/keys")
        case .openai:    return ("Get an API key at platform.openai.com", "https://platform.openai.com/api-keys")
        case .google:    return ("Get an API key at aistudio.google.com", "https://aistudio.google.com/app/apikey")
        case .xai:       return ("Get an API key at console.x.ai", "https://console.x.ai/")
        case .mistral:   return ("Get an API key at console.mistral.ai", "https://console.mistral.ai/api-keys")
        case .deepseek:  return ("Get an API key at platform.deepseek.com", "https://platform.deepseek.com/api_keys")
        case .kimi:      return ("Get an API key at platform.moonshot.cn", "https://platform.moonshot.cn/console/api-keys")
        case .ollama:    return ("Download Ollama at ollama.com", "https://ollama.com/download")
        }
    }

    private func saveKey() {
        isSaving = true
        errorMessage = ""

        if selectedProvider == .ollama {
            // No key needed — just select an Ollama model
            if let firstModel = LLMModels.allModels.first(where: { LLMModels.provider(for: $0.id) == .ollama }) {
                AppPreferences.shared.selectedModel = firstModel.id
            }
            isSaving = false
            onComplete()
            return
        }

        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isSaving = false
            return
        }

        // Save to the correct keychain key for the chosen provider (bumps keychainVersion)
        authManager.saveKey(selectedProvider.keychainKey, value: trimmed)

        // Auto-select a model from this provider so it's immediately usable
        if let firstModel = LLMModels.allModels.first(where: { LLMModels.provider(for: $0.id) == selectedProvider }) {
            AppPreferences.shared.selectedModel = firstModel.id
        }

        apiKey = ""
        isSaving = false
        onComplete()
    }
}
