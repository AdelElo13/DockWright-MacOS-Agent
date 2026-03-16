import SwiftUI

/// Shown when no API key is configured.
/// Prompts user to enter their Anthropic API key.
struct WelcomeView: View {
    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var errorMessage = ""
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

            VStack(spacing: DockwrightTheme.Spacing.md) {
                Text("Enter your Anthropic API key to get started")
                    .font(DockwrightTheme.Typography.body)
                    .foregroundStyle(.secondary)

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
