import SwiftUI

/// API key entry for each LLM provider with OAuth connect/disconnect.
struct APIKeysView: View {
    @State private var anthropicKey = ""
    @State private var openaiKey = ""
    @State private var geminiKey = ""
    @State private var claudeCode = ""
    @State private var saveStatus = ""
    @State private var authManager = AuthManager()

    // Check which keys exist
    @State private var hasAnthropic = false
    @State private var hasOpenAI = false
    @State private var hasGemini = false

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
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Google (Gemini)")
                            .font(DockwrightTheme.Typography.bodyMedium)
                        Text("Optional. For Gemini model support.")
                            .font(DockwrightTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusDot(hasGemini)
                }

                SecureField("AIza...", text: $geminiKey)
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
        .onAppear { refreshStatus() }
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

        refreshStatus()
        saveStatus = "Saved!"

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saveStatus = ""
        }
    }

    private func refreshStatus() {
        hasAnthropic = KeychainHelper.exists(key: "anthropic_api_key")
        hasOpenAI = KeychainHelper.exists(key: "openai_api_key")
        hasGemini = KeychainHelper.exists(key: "gemini_api_key")
    }
}
