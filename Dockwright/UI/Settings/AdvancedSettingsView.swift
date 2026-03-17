import SwiftUI
import UniformTypeIdentifiers

/// Advanced model parameters, system prompt, debug, and developer settings.
/// All bindings read/write through AppPreferences (single source of truth).
struct AdvancedSettingsView: View {
    private var prefs: AppPreferences { AppPreferences.shared }

    @State private var cacheCleared = false

    var body: some View {
        ScrollView {
            Form {
                Section("Model Parameters") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Text(String(format: "%.2f", prefs.temperature))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { prefs.temperature },
                            set: { prefs.temperature = $0 }
                        ), in: 0...2, step: 0.05)
                        Text("Lower = more focused, higher = more creative")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Picker("Max tokens", selection: Binding(
                        get: { prefs.maxTokens },
                        set: { prefs.maxTokens = $0 }
                    )) {
                        Text("2,048").tag(2048)
                        Text("4,096").tag(4096)
                        Text("8,192").tag(8192)
                        Text("16,384").tag(16384)
                        Text("32,768").tag(32768)
                        Text("65,536").tag(65536)
                        Text("128,000").tag(128000)
                    }
                }

                Section("Response Style") {
                    Picker("Default style", selection: Binding(
                        get: { prefs.responseStyle },
                        set: { prefs.responseStyle = $0 }
                    )) {
                        Text("Brief").tag("brief")
                        Text("Balanced").tag("balanced")
                        Text("Detailed").tag("detailed")
                        Text("Technical").tag("technical")
                    }
                    .pickerStyle(.segmented)

                    Text("Controls the verbosity and tone of AI responses")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Section("Custom System Prompt") {
                    TextEditor(text: Binding(
                        get: { prefs.customSystemPrompt },
                        set: { prefs.customSystemPrompt = $0 }
                    ))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80)

                    Text("Appended to the default system prompt. Use this to personalize Dockwright's behavior.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Section("Web Search & Browsing") {
                    Toggle("Headless browsing (no visible browser)", isOn: Binding(
                        get: { prefs.headlessBrowsing },
                        set: { prefs.headlessBrowsing = $0 }
                    ))

                    Text("When ON, web searches and page fetches use headless Chrome or APIs. When OFF, opens a visible browser window.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    HStack {
                        Text("Brave Search API")
                        Spacer()
                        if KeychainHelper.exists(key: "brave_search_api_key") {
                            Text("Configured")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Text("Not set — add in API Keys tab")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Model Cache") {
                    Text("Model registry responses are cached for 24 hours to reduce API calls.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    HStack {
                        Button("Clear Model Cache") {
                            UserDefaults.standard.removeObject(forKey: "ModelRegistry.cachedModels")
                            UserDefaults.standard.removeObject(forKey: "ModelRegistry.cacheTimestamp")
                            cacheCleared = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { cacheCleared = false }
                        }
                        if cacheCleared {
                            Text("Cleared!")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }

                Section("Diagnostics") {
                    Button("Export Logs") {
                        exportLogs()
                    }

                    Button("Copy System Info to Clipboard") {
                        copySystemInfo()
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "dockwright-logs-\(formattedDate()).txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let logText = """
            Dockwright Debug Log Export
            Date: \(Date())
            Model: \(prefs.selectedModel)
            Temperature: \(prefs.temperature)
            Max Tokens: \(prefs.maxTokens)
            OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
            """
            try? logText.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func copySystemInfo() {
        let info = """
        Dockwright v1.0
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Model: \(prefs.selectedModel)
        Memory: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB
        Processors: \(ProcessInfo.processInfo.processorCount)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
    }

    private func formattedDate() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        return fmt.string(from: Date())
    }
}
