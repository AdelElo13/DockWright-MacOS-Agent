import SwiftUI

/// API key entry for each LLM provider with OAuth connect/disconnect.
struct APIKeysView: View {
    @State private var anthropicKey = ""
    @State private var openaiKey = ""
    @State private var geminiKey = ""
    @State private var xaiKey = ""
    @State private var mistralKey = ""
    @State private var deepseekKey = ""
    @State private var kimiKey = ""
    @State private var telegramToken = ""
    @State private var telegramChatId = UserDefaults.standard.string(forKey: "telegram_chat_id") ?? ""
    @State private var discordWebhook = UserDefaults.standard.string(forKey: "discord_webhook_url") ?? ""
    @State private var elevenLabsKey = ""
    @State private var claudeCode = ""
    @State private var saveStatus = ""
    @State private var authManager = AuthManager()

    // Check which keys exist
    @State private var hasAnthropic = false
    @State private var hasOpenAI = false
    @State private var hasGemini = false
    @State private var hasXAI = false
    @State private var hasMistral = false
    @State private var hasDeepSeek = false
    @State private var hasKimi = false
    @State private var hasTelegram = false
    @State private var hasDiscord = false
    @State private var hasElevenLabs = false

    var body: some View {
        ScrollView {
            Form {
                // Claude / Anthropic Section
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Anthropic (Claude)")
                                .font(DockwrightTheme.Typography.bodyMedium)
                            if authManager.isClaudeOAuth {
                                Text("Connected via OAuth")
                                    .font(DockwrightTheme.Typography.caption)
                                    .foregroundStyle(DockwrightTheme.success)
                            } else if hasAnthropic {
                                Text("API key configured")
                                    .font(DockwrightTheme.Typography.caption)
                                    .foregroundStyle(DockwrightTheme.success)
                            } else {
                                Text("Not connected")
                                    .font(DockwrightTheme.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        statusDot(authManager.isClaudeSignedIn || hasAnthropic)
                    }

                    // OAuth buttons
                    HStack(spacing: DockwrightTheme.Spacing.sm) {
                        if authManager.isClaudeSignedIn {
                            Button("Disconnect Claude") {
                                authManager.signOutClaude()
                                refreshStatus()
                            }
                            .foregroundStyle(DockwrightTheme.error)
                        } else {
                            Button("Sign in with Claude") {
                                authManager.signInWithClaude()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DockwrightTheme.primary)
                        }
                    }

                    // Claude OAuth code entry
                    if authManager.oauthCodePrompt {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Paste the authorization code:")
                                .font(DockwrightTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                TextField("Code...", text: $claudeCode)
                                    .textFieldStyle(.roundedBorder)
                                Button("Submit") {
                                    Task {
                                        await authManager.exchangeClaudeCode(claudeCode)
                                        claudeCode = ""
                                        refreshStatus()
                                    }
                                }
                                .disabled(claudeCode.isEmpty || authManager.isSigningIn)
                            }
                        }
                    }

                    // Manual key entry
                    SecureField("sk-ant-... (manual API key)", text: $anthropicKey)
                        .textFieldStyle(.roundedBorder)
                }

                // OpenAI Section
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OpenAI (GPT)")
                                .font(DockwrightTheme.Typography.bodyMedium)
                            if authManager.isOpenAIOAuth {
                                Text("Connected via OAuth")
                                    .font(DockwrightTheme.Typography.caption)
                                    .foregroundStyle(DockwrightTheme.success)
                            } else if hasOpenAI {
                                Text("API key configured")
                                    .font(DockwrightTheme.Typography.caption)
                                    .foregroundStyle(DockwrightTheme.success)
                            } else {
                                Text("Optional. For GPT model support.")
                                    .font(DockwrightTheme.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        statusDot(authManager.isOpenAISignedIn || hasOpenAI)
                    }

                    HStack(spacing: DockwrightTheme.Spacing.sm) {
                        if authManager.isOpenAISignedIn {
                            Button("Disconnect OpenAI") {
                                authManager.signOutOpenAI()
                                refreshStatus()
                            }
                            .foregroundStyle(DockwrightTheme.error)
                        } else {
                            Button("Sign in with OpenAI") {
                                authManager.signInWithOpenAI()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    SecureField("sk-... (manual API key)", text: $openaiKey)
                        .textFieldStyle(.roundedBorder)
                }

                // Gemini Section
                Section {
                    providerRow(name: "Google (Gemini)", hasKey: hasGemini, description: "For Gemini model support.")
                    SecureField("AIza...", text: $geminiKey)
                        .textFieldStyle(.roundedBorder)
                }

                // xAI / Grok Section
                Section {
                    providerRow(name: "xAI (Grok)", hasKey: hasXAI, description: "For Grok model support.")
                    SecureField("xai-...", text: $xaiKey)
                        .textFieldStyle(.roundedBorder)
                }

                // Mistral Section
                Section {
                    providerRow(name: "Mistral", hasKey: hasMistral, description: "For Mistral model support.")
                    SecureField("Mistral API key", text: $mistralKey)
                        .textFieldStyle(.roundedBorder)
                }

                // DeepSeek Section
                Section {
                    providerRow(name: "DeepSeek", hasKey: hasDeepSeek, description: "For DeepSeek model support.")
                    SecureField("sk-...", text: $deepseekKey)
                        .textFieldStyle(.roundedBorder)
                }

                // Kimi / Moonshot Section
                Section {
                    providerRow(name: "Kimi (Moonshot)", hasKey: hasKimi, description: "For Moonshot model support.")
                    SecureField("sk-...", text: $kimiKey)
                        .textFieldStyle(.roundedBorder)
                }

                // Telegram Section
                Section {
                    providerRow(name: "Telegram Bot", hasKey: hasTelegram, description: "For Telegram notifications.")
                    SecureField("Bot token (from @BotFather)", text: $telegramToken)
                        .textFieldStyle(.roundedBorder)
                    TextField("Chat ID", text: $telegramChatId)
                        .textFieldStyle(.roundedBorder)
                }

                // Discord Section
                Section {
                    providerRow(name: "Discord Webhook", hasKey: hasDiscord, description: "For Discord channel notifications.")
                    TextField("Webhook URL", text: $discordWebhook)
                        .textFieldStyle(.roundedBorder)
                }

                // ElevenLabs Section
                Section {
                    providerRow(name: "ElevenLabs", hasKey: hasElevenLabs, description: "High-quality AI text-to-speech voices.")
                    SecureField("API Key", text: $elevenLabsKey)
                        .textFieldStyle(.roundedBorder)
                }

                // Error display
                if let error = authManager.signInError {
                    Section {
                        Text(error)
                            .font(DockwrightTheme.Typography.caption)
                            .foregroundStyle(DockwrightTheme.error)
                    }
                }

                // Save button
                Section {
                    HStack {
                        Button("Save Keys") {
                            saveKeys()
                        }
                        .buttonStyle(.borderedProminent)

                        if !saveStatus.isEmpty {
                            Text(saveStatus)
                                .font(DockwrightTheme.Typography.caption)
                                .foregroundStyle(DockwrightTheme.success)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { refreshStatus() }
    }

    // MARK: - Helpers

    private func providerRow(name: String, hasKey: Bool, description: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(DockwrightTheme.Typography.bodyMedium)
                if hasKey {
                    Text("API key configured")
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(DockwrightTheme.success)
                } else {
                    Text("Optional. \(description)")
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            statusDot(hasKey)
        }
    }

    private func statusDot(_ exists: Bool) -> some View {
        Circle()
            .fill(exists ? DockwrightTheme.success : Color.gray.opacity(0.3))
            .frame(width: 8, height: 8)
    }

    private func saveKeys() {
        if !anthropicKey.isEmpty {
            KeychainHelper.save(key: "anthropic_api_key", value: anthropicKey)
            anthropicKey = ""
        }
        if !openaiKey.isEmpty {
            KeychainHelper.save(key: "openai_api_key", value: openaiKey)
            openaiKey = ""
        }
        if !geminiKey.isEmpty {
            KeychainHelper.save(key: "gemini_api_key", value: geminiKey)
            geminiKey = ""
        }
        if !xaiKey.isEmpty {
            KeychainHelper.save(key: "xai_api_key", value: xaiKey)
            xaiKey = ""
        }
        if !mistralKey.isEmpty {
            KeychainHelper.save(key: "mistral_api_key", value: mistralKey)
            mistralKey = ""
        }
        if !deepseekKey.isEmpty {
            KeychainHelper.save(key: "deepseek_api_key", value: deepseekKey)
            deepseekKey = ""
        }
        if !kimiKey.isEmpty {
            KeychainHelper.save(key: "kimi_api_key", value: kimiKey)
            kimiKey = ""
        }
        if !telegramToken.isEmpty {
            KeychainHelper.save(key: "telegram_bot_token", value: telegramToken)
            telegramToken = ""
        }
        if !telegramChatId.isEmpty {
            UserDefaults.standard.set(telegramChatId, forKey: "telegram_chat_id")
        }
        if !discordWebhook.isEmpty {
            UserDefaults.standard.set(discordWebhook, forKey: "discord_webhook_url")
        }
        if !elevenLabsKey.isEmpty {
            KeychainHelper.save(key: "elevenlabs_api_key", value: elevenLabsKey)
            elevenLabsKey = ""
        }

        refreshStatus()
        saveStatus = "Saved!"

        // Refresh model registry after saving new keys
        Task.detached {
            await ModelRegistry.shared.refreshAll()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saveStatus = ""
        }
    }

    private func refreshStatus() {
        hasAnthropic = KeychainHelper.exists(key: "anthropic_api_key")
        hasOpenAI = KeychainHelper.exists(key: "openai_api_key")
        hasGemini = KeychainHelper.exists(key: "gemini_api_key")
        hasXAI = KeychainHelper.exists(key: "xai_api_key")
        hasMistral = KeychainHelper.exists(key: "mistral_api_key")
        hasDeepSeek = KeychainHelper.exists(key: "deepseek_api_key")
        hasKimi = KeychainHelper.exists(key: "kimi_api_key")
        hasTelegram = KeychainHelper.exists(key: "telegram_bot_token")
        hasDiscord = !(UserDefaults.standard.string(forKey: "discord_webhook_url") ?? "").isEmpty
        hasElevenLabs = KeychainHelper.exists(key: "elevenlabs_api_key")
    }
}
