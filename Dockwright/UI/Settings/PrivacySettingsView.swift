import SwiftUI
import AVFoundation
import EventKit

/// Privacy, permissions, and security settings.
struct PrivacySettingsView: View {
    @State private var hasMicAccess = false
    @State private var hasCalendarAccess = false
    @State private var requireApproval = UserDefaults.standard.object(forKey: "requireApprovalForRisky") as? Bool ?? true
    @State private var saveConversations = UserDefaults.standard.object(forKey: "saveConversations") as? Bool ?? true
    @State private var retentionDays = UserDefaults.standard.object(forKey: "conversationRetentionDays") as? Int ?? 90
    @State private var sendAnalytics = UserDefaults.standard.bool(forKey: "sendAnalytics")
    @State private var showClearConfirm = false
    @State private var showResetConfirm = false

    private let retentionOptions = [7, 14, 30, 60, 90, 180, 365]

    var body: some View {
        Form {
            Section("System Permissions") {
                permissionRow("Microphone", granted: hasMicAccess, description: "Required for voice input")
                permissionRow("Calendar", granted: hasCalendarAccess, description: "Required for calendar tool")
                permissionRow("Accessibility", granted: nil, description: "Required for browser reading")

                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }
                .font(.caption)
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
        .onAppear { checkPermissions() }
    }

    private func permissionRow(_ name: String, granted: Bool?, description: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let granted {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(granted ? .green : .red)
            } else {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func checkPermissions() {
        hasMicAccess = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ekStatus = EKEventStore.authorizationStatus(for: .event)
        hasCalendarAccess = ekStatus == .fullAccess
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
