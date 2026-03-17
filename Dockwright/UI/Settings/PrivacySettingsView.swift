import SwiftUI

/// Privacy, permissions, and security settings.
/// Auto-requests undetermined permissions on appear and monitors for changes in real-time.
struct PrivacySettingsView: View {
    private var pm = PermissionsManager.shared
    private var prefs: AppPreferences { AppPreferences.shared }

    @State private var requireApproval = UserDefaults.standard.object(forKey: "requireApprovalForRisky") as? Bool ?? true
    @State private var showClearConfirm = false
    @State private var showResetConfirm = false

    /// Optional reference to AppState for clearing conversations end-to-end.
    /// Injected from parent; if nil, falls back to store-only clear.
    var appState: AppState?

    init(appState: AppState? = nil) {
        self.appState = appState
    }

    private let retentionOptions = [7, 14, 30, 60, 90, 180, 365]

    private let permissionRows: [(type: PermissionType, name: String, icon: String, description: String)] = [
        (.microphone, "Microphone", "mic.fill", "Voice input & dictation"),
        (.camera, "Camera", "camera.fill", "Take photos for AI analysis"),
        (.speechRecognition, "Speech Recognition", "waveform", "Voice-to-text transcription"),
        (.calendar, "Calendar", "calendar", "Read & create events"),
        (.reminders, "Reminders", "checklist", "Read & create reminders"),
        (.contacts, "Contacts", "person.crop.circle", "Search & display contacts"),
        (.accessibility, "Accessibility", "hand.point.up.left.fill", "UI automation & browser reading"),
        (.screenRecording, "Screen Recording", "rectangle.dashed.badge.record", "Screenshot & screen OCR"),
        (.notifications, "Notifications", "bell.fill", "Background alerts"),
        (.fullDiskAccess, "Full Disk Access", "externaldrive.fill", "File system access"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(permissionRows, id: \.type) { row in
                    permissionRowView(row.type, name: row.name, icon: row.icon, description: row.description)
                }
            } header: {
                HStack {
                    Text("System Permissions")
                    Spacer()
                    Button("Refresh All") {
                        pm.requestAllUndetermined()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            pm.refreshAll()
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            Section("Execution Safety") {
                Toggle("Require approval for risky operations", isOn: $requireApproval)
                    .onChange(of: requireApproval) { _, newVal in
                        UserDefaults.standard.set(newVal, forKey: "requireApprovalForRisky")
                    }

                Text("Asks for confirmation before running shell commands or browser actions.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Data & Privacy") {
                Toggle("Save conversation history", isOn: Binding(
                    get: { prefs.saveConversations },
                    set: { prefs.saveConversations = $0 }
                ))

                Picker("Auto-delete conversations after", selection: Binding(
                    get: { prefs.conversationRetentionDays },
                    set: { prefs.conversationRetentionDays = $0 }
                )) {
                    ForEach(retentionOptions, id: \.self) { days in
                        Text("\(days) days").tag(days)
                    }
                    Text("Never").tag(0)
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
            // Silently request all undetermined permissions — if already granted
            // in System Settings, the API call returns immediately without dialog
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
        if let appState {
            // Full end-to-end clear: store + in-memory + sidebar
            appState.clearAllConversations()
        } else {
            // Fallback: store-only clear
            let store = ConversationStore()
            for summary in store.listAll() {
                store.delete(id: summary.id)
            }
        }
    }

    private func resetAllSettings() {
        // Reset the live singleton (which also persists to UserDefaults via didSet)
        AppPreferences.shared.resetToDefaults()

        // After reset, the selected model may point to a provider that has no key.
        // Sync to an available provider so the user doesn't land on a broken model.
        if let authManager = appState?.authManager {
            AppPreferences.shared.syncModelToAvailableProvider(authManager: authManager)
        }

        // Reset local @State vars that mirror UserDefaults directly
        requireApproval = true
    }
}
