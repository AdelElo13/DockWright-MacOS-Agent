import SwiftUI

/// Notification channel preferences and quiet hours.
struct NotificationSettingsView: View {
    @State private var notifyOnCompletion = UserDefaults.standard.object(forKey: "notifyOnCompletion") as? Bool ?? true
    @State private var notifyOnError = UserDefaults.standard.object(forKey: "notifyOnError") as? Bool ?? true
    @State private var notifyOnScheduledTask = UserDefaults.standard.object(forKey: "notifyOnScheduledTask") as? Bool ?? true
    @State private var notifySound = UserDefaults.standard.object(forKey: "notifySound") as? Bool ?? true

    // Quiet hours
    @State private var quietHoursEnabled = UserDefaults.standard.bool(forKey: "quietHoursEnabled")
    @State private var quietHoursStart = UserDefaults.standard.object(forKey: "quietHoursStart") as? Int ?? 22
    @State private var quietHoursEnd = UserDefaults.standard.object(forKey: "quietHoursEnd") as? Int ?? 8

    // Channel preferences
    @State private var useSystemNotifications = UserDefaults.standard.object(forKey: "useSystemNotifications") as? Bool ?? true
    @State private var useTelegram = UserDefaults.standard.object(forKey: "useTelegramNotifications") as? Bool ?? true
    @State private var useDiscord = UserDefaults.standard.object(forKey: "useDiscordNotifications") as? Bool ?? true

    // Channel status
    @State private var hasTelegram = false
    @State private var hasDiscord = false

    var body: some View {
        Form {
            Section("Notify Me When") {
                Toggle("Task completes", isOn: $notifyOnCompletion)
                    .onChange(of: notifyOnCompletion) { _, v in
                        UserDefaults.standard.set(v, forKey: "notifyOnCompletion")
                    }

                Toggle("Error occurs", isOn: $notifyOnError)
                    .onChange(of: notifyOnError) { _, v in
                        UserDefaults.standard.set(v, forKey: "notifyOnError")
                    }

                Toggle("Scheduled task runs", isOn: $notifyOnScheduledTask)
                    .onChange(of: notifyOnScheduledTask) { _, v in
                        UserDefaults.standard.set(v, forKey: "notifyOnScheduledTask")
                    }

                Toggle("Play notification sound", isOn: $notifySound)
                    .onChange(of: notifySound) { _, v in
                        UserDefaults.standard.set(v, forKey: "notifySound")
                    }
            }

            Section("Delivery Channels") {
                channelToggle("macOS Notification Center",
                              icon: "bell.badge.fill",
                              isOn: $useSystemNotifications,
                              key: "useSystemNotifications",
                              configured: true)

                channelToggle("Telegram",
                              icon: "paperplane.fill",
                              isOn: $useTelegram,
                              key: "useTelegramNotifications",
                              configured: hasTelegram)

                channelToggle("Discord",
                              icon: "bubble.left.and.bubble.right.fill",
                              isOn: $useDiscord,
                              key: "useDiscordNotifications",
                              configured: hasDiscord)

                if !hasTelegram && !hasDiscord {
                    Text("Configure Telegram or Discord in the API Keys tab to enable remote notifications.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Quiet Hours") {
                Toggle("Enable quiet hours", isOn: $quietHoursEnabled)
                    .onChange(of: quietHoursEnabled) { _, v in
                        UserDefaults.standard.set(v, forKey: "quietHoursEnabled")
                    }

                if quietHoursEnabled {
                    HStack {
                        Picker("From", selection: $quietHoursStart) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d:00", h)).tag(h)
                            }
                        }
                        .onChange(of: quietHoursStart) { _, v in
                            UserDefaults.standard.set(v, forKey: "quietHoursStart")
                        }

                        Text("to")

                        Picker("", selection: $quietHoursEnd) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d:00", h)).tag(h)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: quietHoursEnd) { _, v in
                            UserDefaults.standard.set(v, forKey: "quietHoursEnd")
                        }
                    }

                    Text("Notifications will be silenced during quiet hours. Critical errors will still alert.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { checkChannelStatus() }
    }

    private func channelToggle(_ label: String, icon: String, isOn: Binding<Bool>, key: String, configured: Bool) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(configured ? .blue : .gray)
                .frame(width: 24)

            Toggle(label, isOn: isOn)
                .onChange(of: isOn.wrappedValue) { _, v in
                    UserDefaults.standard.set(v, forKey: key)
                }
                .disabled(!configured)

            if !configured {
                Text("Not configured")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func checkChannelStatus() {
        hasTelegram = KeychainHelper.exists(key: "telegram_bot_token") &&
            !(UserDefaults.standard.string(forKey: "telegram_chat_id") ?? "").isEmpty
        hasDiscord = !(UserDefaults.standard.string(forKey: "discord_webhook_url") ?? "").isEmpty
    }
}
