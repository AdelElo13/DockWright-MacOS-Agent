import SwiftUI
import ServiceManagement

/// General app settings: launch behavior, appearance, data.
struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showDockIcon = !UserDefaults.standard.bool(forKey: "hideDockIcon")
    @State private var alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")
    @State private var showMenuBarExtra = UserDefaults.standard.bool(forKey: "showMenuBarExtra")
    @State private var theme = UserDefaults.standard.string(forKey: "appearance") ?? "system"
    @State private var fontSize = UserDefaults.standard.object(forKey: "chatFontSize") as? Double ?? 14.0
    @State private var sidebarDefault = UserDefaults.standard.object(forKey: "sidebarDefaultOpen") as? Bool ?? true
    @State private var sendWithReturn = UserDefaults.standard.object(forKey: "sendWithReturn") as? Bool ?? true
    @State private var streamResponses = UserDefaults.standard.object(forKey: "streamResponses") as? Bool ?? true
    @State private var showTokenCost = UserDefaults.standard.object(forKey: "showTokenCost") as? Bool ?? true
    @State private var confirmDeletions = UserDefaults.standard.object(forKey: "confirmDeletions") as? Bool ?? true
    @State private var conversationCount = 0

    var body: some View {
        Form {
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

                Toggle("Show in menu bar", isOn: $showMenuBarExtra)
                    .onChange(of: showMenuBarExtra) { _, v in
                        UserDefaults.standard.set(v, forKey: "showMenuBarExtra")
                    }

                Toggle("Float window on top", isOn: $alwaysOnTop)
                    .onChange(of: alwaysOnTop) { _, v in
                        UserDefaults.standard.set(v, forKey: "alwaysOnTop")
                    }
            }

            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    Text("System").tag("system")
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .onChange(of: theme) { _, v in
                    UserDefaults.standard.set(v, forKey: "appearance")
                }

                VStack(alignment: .leading) {
                    Text("Chat font size: \(Int(fontSize))pt")
                        .font(.caption)
                    Slider(value: $fontSize, in: 11...20, step: 1)
                        .onChange(of: fontSize) { _, v in
                            UserDefaults.standard.set(v, forKey: "chatFontSize")
                        }
                }
            }

            Section("Behavior") {
                Toggle("Show sidebar on launch", isOn: $sidebarDefault)
                    .onChange(of: sidebarDefault) { _, v in
                        UserDefaults.standard.set(v, forKey: "sidebarDefaultOpen")
                    }

                Toggle("Send message with Return", isOn: $sendWithReturn)
                    .onChange(of: sendWithReturn) { _, v in
                        UserDefaults.standard.set(v, forKey: "sendWithReturn")
                    }

                Toggle("Stream responses", isOn: $streamResponses)
                    .onChange(of: streamResponses) { _, v in
                        UserDefaults.standard.set(v, forKey: "streamResponses")
                    }

                Toggle("Show token cost in toolbar", isOn: $showTokenCost)
                    .onChange(of: showTokenCost) { _, v in
                        UserDefaults.standard.set(v, forKey: "showTokenCost")
                    }

                Toggle("Confirm before deleting conversations", isOn: $confirmDeletions)
                    .onChange(of: confirmDeletions) { _, v in
                        UserDefaults.standard.set(v, forKey: "confirmDeletions")
                    }
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
