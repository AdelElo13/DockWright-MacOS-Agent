import SwiftUI
import Carbon
import os

@main
struct DockwrightApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("appearance") private var appearanceSetting: String = "system"

    private var prefs: AppPreferences { AppPreferences.shared }

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.hasAPIKey {
                    mainView
                } else {
                    WelcomeView(authManager: appState.authManager) {
                        appState.loadConversations()
                    }
                }
            }
            .frame(minWidth: 700, minHeight: 500)
            .preferredColorScheme(resolvedColorScheme)
            .onAppear {
                applyAlwaysOnTop()
            }
            .onChange(of: prefs.alwaysOnTop) { _, _ in
                applyAlwaysOnTop()
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1000, height: 700)

        Settings {
            SettingsView(appState: appState)
        }

        // Menu bar icon — respect showMenuBarExtra preference
        MenuBarExtra("Dockwright", systemImage: "circle.hexagongrid.circle", isInserted: menuBarInserted) {
            menuBarContent
        }
    }

    // MARK: - Appearance

    private var resolvedColorScheme: ColorScheme? {
        switch appearanceSetting {
        case "dark": return .dark
        case "light": return .light
        default: return nil // system
        }
    }

    // MARK: - Always On Top

    private func applyAlwaysOnTop() {
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                window.level = prefs.alwaysOnTop ? .floating : .normal
            }
        }
    }

    // MARK: - Menu Bar

    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { prefs.showMenuBarExtra },
            set: { prefs.showMenuBarExtra = $0 }
        )
    }

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

            if prefs.showTokenCost {
                HStack {
                    Text("Cost:")
                        .foregroundStyle(.secondary)
                    Text(appState.tokenCounter.formattedCost())
                }
                .font(.caption)
            }

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
            appState.showGoals = false
        }
    }

    /// Whether any overlay panel is visible.
    private var hasOverlay: Bool {
        appState.showSettings || appState.showSkillsAutomations || appState.showScheduler || appState.showGoals
    }

    private var mainView: some View {
        ZStack {
            // Base content — use HStack instead of HSplitView to avoid macOS hit-testing bugs
            HStack(spacing: 0) {
                if appState.showSidebar {
                    SidebarView(appState: appState, showSettings: $appState.showSettings)
                        .frame(width: DockwrightTheme.Layout.sidebarWidth)
                    Divider()
                }

                ChatView(appState: appState)
                    .frame(minWidth: 400, maxWidth: .infinity)
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
                    HStack(spacing: 6) {
                        Spacer(minLength: 8)

                        // Provider warning if active model's provider is not configured
                        if !appState.isActiveProviderConfigured {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 11))
                                .help("No credential for \(LLMModels.provider(for: appState.selectedModel).rawValue). Go to Settings > API Keys.")
                        }

                        Button {
                            appState.agentMode.toggle()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "brain")
                                Text("Agent")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .fixedSize()
                            .foregroundStyle(
                                appState.agentMode ? DockwrightTheme.secondary : .secondary
                            )
                        }
                        .buttonStyle(.plain)

                        Menu {
                            ForEach(LLMModels.allModels, id: \.id) { model in
                                Button {
                                    appState.selectedModel = model.id
                                } label: {
                                    if model.id == appState.selectedModel {
                                        Label(model.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(model.displayName)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(LLMModels.allModels.first { $0.id == appState.selectedModel }?.displayName ?? appState.selectedModel)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9))
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        if prefs.showTokenCost {
                            Text(appState.tokenCounter.formattedCost())
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                        }
                    }
                    .padding(.trailing, 12)
                }
            }
            .onAppear {
                appState.loadConversations()
            }
        }
        .overlay {
            if hasOverlay {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { dismissAllOverlays() }

                if appState.showSettings {
                    SettingsView(appState: appState)
                        .frame(width: 780, height: 600)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.5), radius: 20)
                }

                if appState.showSkillsAutomations {
                    SkillsAutomationsView(appState: appState)
                        .frame(width: 780, height: 600)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.5), radius: 20)
                }

                if appState.showScheduler {
                    SchedulerView(store: appState.cronStore, appState: appState)
                        .frame(width: 780, height: 500)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.5), radius: 20)
                }

                if appState.showGoals {
                    GoalsView(appState: appState)
                        .frame(width: 780, height: 600)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.5), radius: 20)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hasOverlay)
        .alert("Approve Action?", isPresented: $appState.showToolApproval) {
            Button("Allow", role: .destructive) {
                appState.toolApprovalContinuation?.resume(returning: true)
                appState.toolApprovalContinuation = nil
            }
            Button("Deny", role: .cancel) {
                appState.toolApprovalContinuation?.resume(returning: false)
                appState.toolApprovalContinuation = nil
            }
        } message: {
            Text(appState.toolApprovalDescription)
        }
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
