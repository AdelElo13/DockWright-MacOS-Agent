import SwiftUI

/// Shown when no API key is configured.
/// Prompts user to enter their Anthropic API key or sign in with OAuth.
struct WelcomeView: View {
    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var errorMessage = ""
    @State private var claudeCode = ""
    @State private var authManager = AuthManager()
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: DockwrightTheme.Spacing.xxxl) {
            Spacer()

            // Logo
            ZStack {
                Circle()
                    .fill(DockwrightTheme.orbGradient)
                    .frame(width: 80, height: 80)
                    .blur(radius: 1)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.3), .clear],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 40
                        )
                    )
                    .frame(width: 64, height: 64)
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
                Text("Sign in to get started")
                    .font(DockwrightTheme.Typography.body)
                    .foregroundStyle(.secondary)

                Button {
                    authManager.signInWithClaude()
                } label: {
                    HStack(spacing: DockwrightTheme.Spacing.sm) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 14))
                        Text("Sign in with Claude")
                            .font(DockwrightTheme.Typography.bodyLargeMedium)
                    }
                    .frame(width: 240, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(DockwrightTheme.primary)
                .disabled(authManager.isSigningIn)

                Button {
                    authManager.signInWithOpenAI()
                } label: {
                    HStack(spacing: DockwrightTheme.Spacing.sm) {
                        if authManager.isSigningIn {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 14))
                        Text("Sign in with OpenAI")
                            .font(DockwrightTheme.Typography.bodyLargeMedium)
                    }
                    .frame(width: 240, height: 36)
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
                Text("or enter an API key")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.quaternary)
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            }
            .frame(maxWidth: 400)

            // Manual API key entry
            VStack(spacing: DockwrightTheme.Spacing.md) {
                SecureField("sk-ant-api03-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 400)

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
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)

                if let keyURL = URL(string: "https://console.anthropic.com/settings/keys") {
                    Link("Get an API key at console.anthropic.com",
                         destination: keyURL)
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(DockwrightTheme.info)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DockwrightTheme.Surface.canvas)
        .onChange(of: authManager.isOpenAISignedIn) { _, signedIn in
            if signedIn { onComplete() }
        }
        .onChange(of: authManager.isClaudeSignedIn) { _, signedIn in
            if signedIn { onComplete() }
        }
    }

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard trimmed.hasPrefix("sk-") else {
            errorMessage = "API key should start with 'sk-'"
            return
        }

        isSaving = true
        errorMessage = ""

        KeychainHelper.save(key: "anthropic_api_key", value: trimmed)
        apiKey = ""
        isSaving = false
        onComplete()
    }
}
