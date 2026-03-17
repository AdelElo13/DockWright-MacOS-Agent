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
    @State private var whatsappToken = ""
    @State private var whatsappPhoneId = UserDefaults.standard.string(forKey: "whatsapp_phone_number_id") ?? ""
    @State private var whatsappVerifyToken = UserDefaults.standard.string(forKey: "whatsapp_verify_token") ?? "dockwright_wa_verify"
    @State private var whatsappAllowed = UserDefaults.standard.string(forKey: "whatsapp_allowed_numbers") ?? ""
    @State private var elevenLabsKey = ""
    @State private var braveSearchKey = ""
    @State private var claudeCode = ""
    @State private var saveStatus = ""
    @State private var debounceTask: Task<Void, Never>?
    var authManager: AuthManager

    // Check which keys exist
    @State private var hasAnthropic = false
    @State private var hasOpenAI = false
    @State private var hasGemini = false
    @State private var hasXAI = false
    @State private var hasMistral = false
    @State private var hasDeepSeek = false
    @State private var hasKimi = false
    @State private var hasTelegram = false
    @State private var hasWhatsApp = false
    @State private var hasDiscord = false
    @State private var hasElevenLabs = false
    @State private var hasBraveSearch = false

    var body: some View {
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
                                AppPreferences.shared.syncModelToAvailableProvider(authManager: authManager)
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
                                        AppPreferences.shared.syncModelToAvailableProvider(authManager: authManager)
                                    }
                                }
                                .disabled(claudeCode.isEmpty || authManager.isSigningIn)
                            }
                        }
                    }

                    // Manual key entry
                    SecureField("sk-ant-... (manual API key)", text: $anthropicKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { autoSave(key: "anthropic_api_key", value: &anthropicKey) }
                        .onChange(of: anthropicKey) { _, v in debounceSave(key: "anthropic_api_key", value: v) }
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
                                AppPreferences.shared.syncModelToAvailableProvider(authManager: authManager)
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
                        .onSubmit { autoSave(key: "openai_api_key", value: &openaiKey) }
                        .onChange(of: openaiKey) { _, v in debounceSave(key: "openai_api_key", value: v) }
                }

                // Gemini Section
                Section {
                    providerRow(name: "Google (Gemini)", hasKey: hasGemini, description: "For Gemini model support.")
                    SecureField("AIza...", text: $geminiKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { autoSave(key: "gemini_api_key", value: &geminiKey) }
                        .onChange(of: geminiKey) { _, v in debounceSave(key: "gemini_api_key", value: v) }
                }

                // xAI / Grok Section
                Section {
                    providerRow(name: "xAI (Grok)", hasKey: hasXAI, description: "For Grok model support.")
                    SecureField("xai-...", text: $xaiKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { autoSave(key: "xai_api_key", value: &xaiKey) }
                        .onChange(of: xaiKey) { _, v in debounceSave(key: "xai_api_key", value: v) }
                }

                // Mistral Section
                Section {
                    providerRow(name: "Mistral", hasKey: hasMistral, description: "For Mistral model support.")
                    SecureField("Mistral API key", text: $mistralKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { autoSave(key: "mistral_api_key", value: &mistralKey) }
                        .onChange(of: mistralKey) { _, v in debounceSave(key: "mistral_api_key", value: v) }
                }

                // DeepSeek Section
                Section {
                    providerRow(name: "DeepSeek", hasKey: hasDeepSeek, description: "For DeepSeek model support.")
                    SecureField("sk-...", text: $deepseekKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { autoSave(key: "deepseek_api_key", value: &deepseekKey) }
                        .onChange(of: deepseekKey) { _, v in debounceSave(key: "deepseek_api_key", value: v) }
                }

                // Kimi / Moonshot Section
                Section {
                    providerRow(name: "Kimi (Moonshot)", hasKey: hasKimi, description: "For Moonshot model support.")
                    SecureField("sk-...", text: $kimiKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { autoSave(key: "kimi_api_key", value: &kimiKey) }
                        .onChange(of: kimiKey) { _, v in debounceSave(key: "kimi_api_key", value: v) }
                }

                // Telegram Section
                Section {
                    providerRow(name: "Telegram Bot", hasKey: hasTelegram, description: "Two-way bot: receive & reply to messages via Telegram.")
                    SecureField("Bot token (from @BotFather)", text: $telegramToken)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { autoSave(key: "telegram_bot_token", value: &telegramToken) }
                        .onChange(of: telegramToken) { _, v in debounceSave(key: "telegram_bot_token", value: v) }
                    TextField("Chat ID (leave empty for discovery mode)", text: $telegramChatId)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: telegramChatId) { _, v in
                            UserDefaults.standard.set(v, forKey: "telegram_chat_id")
                        }
                    Text("Leave Chat ID empty to auto-learn it from the first message.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // WhatsApp Section
                Section {
                    providerRow(name: "WhatsApp Business", hasKey: hasWhatsApp, description: "Two-way bot via Meta Cloud API.")
                    SecureField("Access token", text: $whatsappToken)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { autoSave(key: "whatsapp_token", value: &whatsappToken) }
                        .onChange(of: whatsappToken) { _, v in debounceSave(key: "whatsapp_token", value: v) }
                    TextField("Phone Number ID", text: $whatsappPhoneId)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: whatsappPhoneId) { _, v in
                            UserDefaults.standard.set(v, forKey: "whatsapp_phone_number_id")
                        }
                    TextField("Verify token", text: $whatsappVerifyToken)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: whatsappVerifyToken) { _, v in
                            UserDefaults.standard.set(v, forKey: "whatsapp_verify_token")
                        }
                    TextField("Allowed numbers (+31612345678,...)", text: $whatsappAllowed)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: whatsappAllowed) { _, v in
                            UserDefaults.standard.set(v, forKey: "whatsapp_allowed_numbers")
                        }
                    Text("Webhook URL: http://your-ip:9879/webhook")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Discord Section
                Section {
                    providerRow(name: "Discord Webhook", hasKey: hasDiscord, description: "For Discord channel notifications.")
                    TextField("Webhook URL", text: $discordWebhook)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: discordWebhook) { _, v in
                            UserDefaults.standard.set(v, forKey: "discord_webhook_url")
                            hasDiscord = !v.isEmpty
                        }
                }

                // ElevenLabs Section
                Section {
                    providerRow(name: "ElevenLabs", hasKey: hasElevenLabs, description: "High-quality AI text-to-speech voices.")
                    SecureField("API Key", text: $elevenLabsKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { autoSave(key: "elevenlabs_api_key", value: &elevenLabsKey) }
                        .onChange(of: elevenLabsKey) { _, v in debounceSave(key: "elevenlabs_api_key", value: v) }
                }

                // Brave Search Section
                Section {
                    providerRow(name: "Brave Search", hasKey: hasBraveSearch, description: "Web search API (free tier: 2000 queries/mo).")
                    SecureField("BSA...", text: $braveSearchKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { autoSave(key: "brave_search_api_key", value: &braveSearchKey) }
                        .onChange(of: braveSearchKey) { _, v in debounceSave(key: "brave_search_api_key", value: v) }
                    if !hasBraveSearch {
                        Link("Get free API key →", destination: URL(string: "https://brave.com/search/api/")!)
                            .font(DockwrightTheme.Typography.caption)
                    }
                }

                // Error display
                if let error = authManager.signInError {
                    Section {
                        Text(error)
                            .font(DockwrightTheme.Typography.caption)
                            .foregroundStyle(DockwrightTheme.error)
                    }
                }

                // Auto-save status
                if !saveStatus.isEmpty {
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(DockwrightTheme.success)
                            Text(saveStatus)
                                .font(DockwrightTheme.Typography.caption)
                                .foregroundStyle(DockwrightTheme.success)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        .onAppear { refreshStatus() }
        .onChange(of: authManager.isClaudeSignedIn) { _, signedIn in
            if signedIn {
                refreshStatus()
                AppPreferences.shared.syncModelToAvailableProvider(authManager: authManager)
            }
        }
        .onChange(of: authManager.isOpenAISignedIn) { _, signedIn in
            if signedIn {
                refreshStatus()
                AppPreferences.shared.syncModelToAvailableProvider(authManager: authManager)
            }
        }
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

    /// Instant save on Enter/submit.
    private func autoSave(key: String, value: inout String) {
        guard !value.isEmpty else { return }
        authManager.saveKey(key, value: value)
        value = ""
        didSave()
    }

    /// Debounced save — waits 1.5s after last keystroke, then saves.
    /// Requires minimum 10 characters to avoid persisting partial keys mid-typing.
    private func debounceSave(key: String, value: String) {
        debounceTask?.cancel()
        guard !value.isEmpty, value.count >= 10 else { return }
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            authManager.saveKey(key, value: value)
            didSave()
        }
    }

    /// Common post-save actions.
    private func didSave() {
        refreshStatus()
        saveStatus = "Saved!"
        AppPreferences.shared.syncModelToAvailableProvider(authManager: authManager)
        Task.detached { await ModelRegistry.shared.refreshAll() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = "" }
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
        hasWhatsApp = KeychainHelper.exists(key: "whatsapp_token")
        hasDiscord = !(UserDefaults.standard.string(forKey: "discord_webhook_url") ?? "").isEmpty
        hasElevenLabs = KeychainHelper.exists(key: "elevenlabs_api_key")
        hasBraveSearch = KeychainHelper.exists(key: "brave_search_api_key")
    }
}
