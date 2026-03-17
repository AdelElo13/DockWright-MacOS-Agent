import SwiftUI
import ServiceManagement

/// General app settings — all bindings read/write through AppPreferences (single source of truth).
struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showDockIcon = !UserDefaults.standard.bool(forKey: "hideDockIcon")
    @State private var conversationCount = 0
    @AppStorage("appearance") private var appearanceSetting: String = "system"
    @State private var appLanguage = VoiceService.effectiveLanguage

    private var prefs: AppPreferences { AppPreferences.shared }

    var body: some View {
        Form {
            Section("Language") {
                Picker("App language", selection: $appLanguage) {
                    ForEach(VoiceService.supportedSTTLanguages, id: \.id) { lang in
                        Text(lang.label).tag(lang.id)
                    }
                }
                .onChange(of: appLanguage) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "voice.sttLanguage")
                    VoiceService.shared.sttLanguage = newValue
                }

                Text("Controls the language for AI responses, voice recognition, and text-to-speech.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !newValue
                        }
                    }

                Toggle("Show in menu bar", isOn: Binding(
                    get: { prefs.showMenuBarExtra },
                    set: { prefs.showMenuBarExtra = $0 }
                ))

                Toggle("Float window on top", isOn: Binding(
                    get: { prefs.alwaysOnTop },
                    set: { prefs.alwaysOnTop = $0 }
                ))
            }

            Section("Appearance") {
                Picker("Theme", selection: $appearanceSetting) {
                    Text("System").tag("system")
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .onChange(of: appearanceSetting) { _, newVal in
                    prefs.appearance = newVal
                }

                VStack(alignment: .leading) {
                    Text("Chat font size: \(Int(prefs.chatFontSize))pt")
                        .font(.caption)
                    Slider(value: Binding(
                        get: { prefs.chatFontSize },
                        set: { prefs.chatFontSize = $0 }
                    ), in: 11...20, step: 1)
                }
            }

            Section("Behavior") {
                Toggle("Show sidebar on launch", isOn: Binding(
                    get: { prefs.sidebarDefaultOpen },
                    set: { prefs.sidebarDefaultOpen = $0 }
                ))

                Toggle("Send message with Return", isOn: Binding(
                    get: { prefs.sendWithReturn },
                    set: { prefs.sendWithReturn = $0 }
                ))

                Toggle("Stream responses", isOn: Binding(
                    get: { prefs.streamResponses },
                    set: { prefs.streamResponses = $0 }
                ))

                Toggle("Show token cost in toolbar", isOn: Binding(
                    get: { prefs.showTokenCost },
                    set: { prefs.showTokenCost = $0 }
                ))

                Toggle("Confirm before deleting conversations", isOn: Binding(
                    get: { prefs.confirmDeletions },
                    set: { prefs.confirmDeletions = $0 }
                ))
            }

            Section("Data") {
                HStack {
                    Text("Conversations stored")
                    Spacer()
                    Text("\(conversationCount)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Skills directory")
                    Spacer()
                    Text("~/.dockwright/skills/")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack {
                    Text("Goals file")
                    Spacer()
                    Text("~/.dockwright/goals.json")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Button("Open Data Folder in Finder") {
                    let path = NSString("~/.dockwright").expandingTildeInPath
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let store = ConversationStore()
            conversationCount = store.listAll().count
        }
    }
}
