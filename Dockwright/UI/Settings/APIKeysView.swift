import SwiftUI

/// API key entry for each LLM provider.
struct APIKeysView: View {
    @State private var anthropicKey = ""
    @State private var openaiKey = ""
    @State private var geminiKey = ""
    @State private var saveStatus = ""

    // Check which keys exist
    @State private var hasAnthropic = false
    @State private var hasOpenAI = false
    @State private var hasGemini = false

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Anthropic (Claude)")
                            .font(DockwrightTheme.Typography.bodyMedium)
                        Text("Required for chat. Get your key at console.anthropic.com")
                            .font(DockwrightTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusDot(hasAnthropic)
                }

                SecureField("sk-ant-...", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenAI (GPT)")
                            .font(DockwrightTheme.Typography.bodyMedium)
                        Text("Optional. For GPT model support.")
                            .font(DockwrightTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusDot(hasOpenAI)
                }

                SecureField("sk-...", text: $openaiKey)
                    .textFieldStyle(.roundedBorder)
            }

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
