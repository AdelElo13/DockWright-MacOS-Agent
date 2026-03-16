import SwiftUI

/// Privacy, permissions, and security settings.
/// Auto-requests undetermined permissions on appear and monitors for changes in real-time.
struct PrivacySettingsView: View {
    private var pm = PermissionsManager.shared
    @State private var requireApproval = UserDefaults.standard.object(forKey: "requireApprovalForRisky") as? Bool ?? true
    @State private var saveConversations = UserDefaults.standard.object(forKey: "saveConversations") as? Bool ?? true
    @State private var retentionDays = UserDefaults.standard.object(forKey: "conversationRetentionDays") as? Int ?? 90
    @State private var sendAnalytics = UserDefaults.standard.bool(forKey: "sendAnalytics")
    @State private var showClearConfirm = false
    @State private var showResetConfirm = false

    private let retentionOptions = [7, 14, 30, 60, 90, 180, 365]

    private let permissionRows: [(type: PermissionType, name: String, icon: String, description: String)] = [
        (.microphone, "Microphone", "mic.fill", "Voice input & dictation"),
        (.speechRecognition, "Speech Recognition", "waveform", "Voice-to-text transcription"),
        (.calendar, "Calendar", "calendar", "Read & create events"),
        (.reminders, "Reminders", "checklist", "Read & create reminders"),
        (.accessibility, "Accessibility", "hand.point.up.left.fill", "UI automation & browser reading"),
        (.notifications, "Notifications", "bell.fill", "Background alerts"),
        (.fullDiskAccess, "Full Disk Access", "externaldrive.fill", "File system access"),
    ]

    var body: some View {
        Form {
            Section("System Permissions") {
                ForEach(permissionRows, id: \.type) { row in
                    permissionRowView(row.type, name: row.name, icon: row.icon, description: row.description)
                }
            }

            Section("Execution Safety") {
                Toggle("Require approval for risky operations", isOn: $requireApproval)
                    .onChange(of: requireApproval) { _, v in
                        UserDefaults.standard.set(v, forKey: "requireApprovalForRisky")
                    }

                Text("When enabled, Dockwright will ask before running shell commands, modifying files, or sending messages.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Data & Privacy") {
                Toggle("Save conversation history", isOn: $saveConversations)
                    .onChange(of: saveConversations) { _, v in
                        UserDefaults.standard.set(v, forKey: "saveConversations")
                    }

                Picker("Auto-delete conversations after", selection: $retentionDays) {
                    ForEach(retentionOptions, id: \.self) { days in
                        Text("\(days) days").tag(days)
                    }
                    Text("Never").tag(0)
                }
                .onChange(of: retentionDays) { _, v in
                    UserDefaults.standard.set(v, forKey: "conversationRetentionDays")
                }

                Toggle("Send anonymous usage analytics", isOn: $sendAnalytics)
                    .onChange(of: sendAnalytics) { _, v in
                        UserDefaults.standard.set(v, forKey: "sendAnalytics")
                    }
            }

            Section("Danger Zone") {
                Button("Clear All Conversations") {
                    showClearConfirm = true
                }
                .foregroundStyle(.red)
                .alert("Clear All Conversations?", isPresented: $showClearConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear All", role: .destructive) {
                        clearAllConversations()
                    }
                } message: {
                    Text("This will permanently delete all conversation history. This cannot be undone.")
                }

                Button("Reset All Settings") {
                    showResetConfirm = true
                }
                .foregroundStyle(.red)
                .alert("Reset All Settings?", isPresented: $showResetConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Reset", role: .destructive) {
                        resetAllSettings()
                    }
                } message: {
                    Text("This will reset all preferences to defaults. API keys will not be affected.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            pm.startMonitoring()
            // Auto-request all undetermined permissions — triggers native dialogs
            pm.requestAllUndetermined()
        }
        .onDisappear {
            pm.stopMonitoring()
        }
    }

    private func permissionRowView(_ type: PermissionType, name: String, icon: String, description: String) -> some View {
        let state = pm.statuses[type] ?? .notDetermined

        return HStack {
            Image(systemName: icon)
                .foregroundStyle(stateColor(state))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            switch state {
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .denied:
                Button("Open Settings") {
                    Task { await pm.request(type) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .notDetermined:
                Button("Grant") {
                    Task { await pm.request(type) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func stateColor(_ state: PermissionState) -> Color {
        switch state {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        }
    }

    private func clearAllConversations() {
        let store = ConversationStore()
        for summary in store.listAll() {
            store.delete(id: summary.id)
        }
    }

    private func resetAllSettings() {
        let keysToReset = [
            "alwaysOnTop", "showMenuBarExtra", "appearance", "chatFontSize",
            "sidebarDefaultOpen", "sendWithReturn", "streamResponses", "showTokenCost",
            "confirmDeletions", "requireApprovalForRisky", "saveConversations",
            "conversationRetentionDays", "sendAnalytics", "temperature",
            "maxTokens", "customSystemPrompt", "debugLogging",
            "quietHoursEnabled", "quietHoursStart", "quietHoursEnd",
            "notifyOnCompletion", "notifyOnError", "autonomyLevel",
            "heartbeatInterval", "agentTokenBudget"
        ]
        for key in keysToReset {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
