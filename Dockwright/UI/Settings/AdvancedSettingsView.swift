import SwiftUI
import UniformTypeIdentifiers

/// Advanced model parameters, system prompt, debug, and developer settings.
struct AdvancedSettingsView: View {
    @State private var temperature: Double = UserDefaults.standard.object(forKey: "temperature") as? Double ?? 0.7
    @State private var maxTokens: Int = UserDefaults.standard.object(forKey: "maxTokens") as? Int ?? 8192
    @State private var topP: Double = UserDefaults.standard.object(forKey: "topP") as? Double ?? 1.0
    @State private var customSystemPrompt = UserDefaults.standard.string(forKey: "customSystemPrompt") ?? ""
    @State private var debugLogging = UserDefaults.standard.bool(forKey: "debugLogging")
    @State private var showRawJSON = UserDefaults.standard.bool(forKey: "showRawJSON")
    @State private var cacheResponses = UserDefaults.standard.object(forKey: "cacheResponses") as? Bool ?? true
    @State private var cacheDurationHours = UserDefaults.standard.object(forKey: "cacheDurationHours") as? Int ?? 24
    @State private var responseStyle = UserDefaults.standard.string(forKey: "responseStyle") ?? "balanced"

    var body: some View {
        ScrollView {
            Form {
                Section("Model Parameters") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Text(String(format: "%.2f", temperature))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $temperature, in: 0...2, step: 0.05)
                            .onChange(of: temperature) { _, v in
                                UserDefaults.standard.set(v, forKey: "temperature")
                            }
                        Text("Lower = more focused, higher = more creative")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Top-P")
                            Spacer()
                            Text(String(format: "%.2f", topP))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $topP, in: 0...1, step: 0.05)
                            .onChange(of: topP) { _, v in
                                UserDefaults.standard.set(v, forKey: "topP")
                            }
                    }

                    Picker("Max tokens", selection: $maxTokens) {
                        Text("2,048").tag(2048)
                        Text("4,096").tag(4096)
                        Text("8,192").tag(8192)
                        Text("16,384").tag(16384)
                        Text("32,768").tag(32768)
                        Text("65,536").tag(65536)
                        Text("128,000").tag(128000)
                    }
                    .onChange(of: maxTokens) { _, v in
                        UserDefaults.standard.set(v, forKey: "maxTokens")
                    }
                }

                Section("Response Style") {
                    Picker("Default style", selection: $responseStyle) {
                        Text("Brief").tag("brief")
                        Text("Balanced").tag("balanced")
                        Text("Detailed").tag("detailed")
                        Text("Technical").tag("technical")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: responseStyle) { _, v in
                        UserDefaults.standard.set(v, forKey: "responseStyle")
                    }

                    Text("Controls the verbosity and tone of AI responses")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Section("Custom System Prompt") {
                    TextEditor(text: $customSystemPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 80)
                        .onChange(of: customSystemPrompt) { _, v in
                            UserDefaults.standard.set(v, forKey: "customSystemPrompt")
                        }

                    Text("Appended to the default system prompt. Use this to personalize Dockwright's behavior.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Section("Caching") {
                    Toggle("Cache model registry responses", isOn: $cacheResponses)
                        .onChange(of: cacheResponses) { _, v in
                            UserDefaults.standard.set(v, forKey: "cacheResponses")
                        }

                    if cacheResponses {
                        Picker("Cache duration", selection: $cacheDurationHours) {
                            Text("1 hour").tag(1)
                            Text("6 hours").tag(6)
                            Text("12 hours").tag(12)
                            Text("24 hours").tag(24)
                            Text("48 hours").tag(48)
                        }
                        .onChange(of: cacheDurationHours) { _, v in
                            UserDefaults.standard.set(v, forKey: "cacheDurationHours")
                        }
                    }

                    Button("Clear Model Cache") {
                        UserDefaults.standard.removeObject(forKey: "modelRegistry.cache")
                        UserDefaults.standard.removeObject(forKey: "modelRegistry.cacheTimestamp")
                    }
                }

                Section("Debug") {
                    Toggle("Enable debug logging", isOn: $debugLogging)
                        .onChange(of: debugLogging) { _, v in
                            UserDefaults.standard.set(v, forKey: "debugLogging")
                        }

                    Toggle("Show raw JSON in responses", isOn: $showRawJSON)
                        .onChange(of: showRawJSON) { _, v in
                            UserDefaults.standard.set(v, forKey: "showRawJSON")
                        }

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
            Model: \(UserDefaults.standard.string(forKey: "selectedModel") ?? "unknown")
            Temperature: \(temperature)
            Max Tokens: \(maxTokens)
            OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
            """
            try? logText.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func copySystemInfo() {
        let info = """
        Dockwright v1.0
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Model: \(UserDefaults.standard.string(forKey: "selectedModel") ?? "unknown")
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
