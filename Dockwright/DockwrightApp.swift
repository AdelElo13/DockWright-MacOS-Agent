import SwiftUI
import Carbon
import os

@main
struct DockwrightApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.hasAPIKey {
                    mainView
                } else {
                    WelcomeView {
                        appState.loadConversations()
                    }
                }
            }
            .frame(minWidth: 700, minHeight: 500)
            .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1000, height: 700)

        Settings {
            SettingsView()
        }

        // Menu bar icon
        MenuBarExtra("Dockwright", systemImage: "brain.head.profile") {
            menuBarContent
        }
    }

    // MARK: - Menu Bar

    private var menuBarContent: some View {
        VStack {
            Button("Show Dockwright") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title != "Item-0" && $0.canBecomeMain }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button("New Chat") {
                NSApp.activate(ignoringOtherApps: true)
                appState.newConversation()
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button(appState.voiceMode ? "Stop Voice" : "Start Voice") {
                Task {
                    await appState.toggleVoiceMode()
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Button(appState.agentMode ? "Disable Agent Mode" : "Enable Agent Mode") {
                appState.agentMode.toggle()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Divider()

            HStack {
                Text("Model:")
                    .foregroundStyle(.secondary)
                Text(appState.selectedModel.replacingOccurrences(of: "claude-", with: "").replacingOccurrences(of: "-20250514", with: ""))
            }
            .font(.caption)

            HStack {
                Text("Cost:")
                    .foregroundStyle(.secondary)
                Text(appState.tokenCounter.formattedCost())
            }
            .font(.caption)

            Divider()

            Button("Quit Dockwright") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }

    // MARK: - Main View

    /// Dismiss all overlay panels (settings, skills, scheduler).
    private func dismissAllOverlays() {
        withAnimation(.easeOut(duration: 0.2)) {
            appState.showSettings = false
            appState.showSkillsAutomations = false
            appState.showScheduler = false
        }
    }

    /// Whether any overlay panel is visible.
    private var hasOverlay: Bool {
        appState.showSettings || appState.showSkillsAutomations || appState.showScheduler
    }

    private var mainView: some View {
        ZStack {
            // Base content
            HSplitView {
                if appState.showSidebar {
                    SidebarView(appState: appState, showSettings: $appState.showSettings)
                        .frame(width: DockwrightTheme.Layout.sidebarWidth)
                }

                ChatView(appState: appState)
                    .frame(minWidth: 400)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appState.showSidebar.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Toggle sidebar")
                }

                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 8) {
                        Button {
                            appState.agentMode.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "brain")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Agent")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .fixedSize()
                            .foregroundStyle(
                                appState.agentMode ? DockwrightTheme.secondary : .secondary
                            )
                        }
                        .buttonStyle(.plain)

                        Picker("", selection: $appState.selectedModel) {
                            ForEach(LLMModels.allModels, id: \.id) { model in
                                Text(model.displayName)
                                    .tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()

                        Text(appState.tokenCounter.formattedCost())
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                    .padding(.trailing, 4)
                }
            }
            .onAppear {
                appState.loadConversations()
            }

            // Overlay panels — click the dimmed background to dismiss
            if hasOverlay {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { dismissAllOverlays() }
                    .transition(.opacity)

                if appState.showSettings {
                    SettingsView(onClose: { dismissAllOverlays() })
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }

                if appState.showSkillsAutomations {
                    SkillsAutomationsView(appState: appState)
                        .frame(minWidth: 560, minHeight: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.5), radius: 20)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }

                if appState.showScheduler {
                    SchedulerView(store: appState.cronStore, onClose: { dismissAllOverlays() })
                        .frame(minWidth: 500, minHeight: 400)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.5), radius: 20)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hasOverlay)
    }
}

// MARK: - App Delegate for Global Hotkey

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerGlobalHotkey()

        // Auto-request undetermined permissions at startup (like Jarvis)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            PermissionsManager.shared.healIfNeeded()
        }
    }

    /// Register Cmd+Shift+Space as a global hotkey to show/hide the app.
    private func registerGlobalHotkey() {
        // Define the hotkey: Cmd+Shift+Space
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x44574B59) // "DWKY"
        hotKeyID.id = 1

        // Register the hotkey
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let keyCode: UInt32 = 49 // Space bar

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            log.error("[Hotkey] Failed to register global hotkey: \(status)")
            return
        }

        // Install event handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            // Toggle app visibility
            DispatchQueue.main.async {
                if NSApp.isActive {
                    NSApp.hide(nil)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandler
        )

        log.info("[Hotkey] Registered Cmd+Shift+Space global hotkey")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
    }
}
