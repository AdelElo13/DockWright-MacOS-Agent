import SwiftUI

/// Notification channel preferences and quiet hours.
/// All toggles read/write through AppPreferences — the runtime routing layer
/// (MultiChannel) reads these same preferences when deciding where to deliver.
struct NotificationSettingsView: View {
    private var prefs: AppPreferences { AppPreferences.shared }

    @State private var hasTelegram = false
    @State private var hasWhatsApp = false
    @State private var hasDiscord = false

    var body: some View {
        Form {
            Section("Notify Me When") {
                Toggle("Task completes", isOn: Binding(
                    get: { prefs.notifyOnCompletion },
                    set: { prefs.notifyOnCompletion = $0 }
                ))

                Toggle("Error occurs", isOn: Binding(
                    get: { prefs.notifyOnError },
                    set: { prefs.notifyOnError = $0 }
                ))

                Toggle("Scheduled task runs", isOn: Binding(
                    get: { prefs.notifyOnScheduledTask },
                    set: { prefs.notifyOnScheduledTask = $0 }
                ))

                Toggle("Play notification sound", isOn: Binding(
                    get: { prefs.notifySound },
                    set: { prefs.notifySound = $0 }
                ))
            }

            Section("Delivery Channels") {
                channelToggle("macOS Notification Center",
                              icon: "bell.badge.fill",
                              isOn: Binding(
                                get: { prefs.useSystemNotifications },
                                set: { prefs.useSystemNotifications = $0 }
                              ),
                              configured: true)

                channelToggle("Telegram",
                              icon: "paperplane.fill",
                              isOn: Binding(
                                get: { prefs.useTelegramNotifications },
                                set: { prefs.useTelegramNotifications = $0 }
                              ),
                              configured: hasTelegram)

                channelToggle("WhatsApp",
                              icon: "phone.fill",
                              isOn: Binding(
                                get: { UserDefaults.standard.bool(forKey: "useWhatsAppNotifications") },
                                set: { UserDefaults.standard.set($0, forKey: "useWhatsAppNotifications") }
                              ),
                              configured: hasWhatsApp)

                channelToggle("Discord",
                              icon: "bubble.left.and.bubble.right.fill",
                              isOn: Binding(
                                get: { prefs.useDiscordNotifications },
                                set: { prefs.useDiscordNotifications = $0 }
                              ),
                              configured: hasDiscord)

                if !hasTelegram && !hasWhatsApp && !hasDiscord {
                    Text("Configure Telegram, WhatsApp, or Discord in the Integrations tab to enable remote notifications.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Quiet Hours") {
                Toggle("Enable quiet hours", isOn: Binding(
                    get: { prefs.quietHoursEnabled },
                    set: { prefs.quietHoursEnabled = $0 }
                ))

                if prefs.quietHoursEnabled {
                    HStack {
                        Picker("From", selection: Binding(
                            get: { prefs.quietHoursStart },
                            set: { prefs.quietHoursStart = $0 }
                        )) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d:00", h)).tag(h)
                            }
                        }

                        Text("to")

                        Picker("", selection: Binding(
                            get: { prefs.quietHoursEnd },
                            set: { prefs.quietHoursEnd = $0 }
                        )) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d:00", h)).tag(h)
                            }
                        }
                        .labelsHidden()
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

    private func channelToggle(_ label: String, icon: String, isOn: Binding<Bool>, configured: Bool) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(configured ? .blue : .gray)
                .frame(width: 24)

            Toggle(label, isOn: isOn)
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
        hasWhatsApp = KeychainHelper.exists(key: "whatsapp_access_token") &&
            !(UserDefaults.standard.string(forKey: "whatsapp_phone_number_id") ?? "").isEmpty
        hasDiscord = !(UserDefaults.standard.string(forKey: "discord_webhook_url") ?? "").isEmpty
    }
}
