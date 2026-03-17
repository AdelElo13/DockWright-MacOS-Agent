import SwiftUI
import AppKit

/// Opens SettingsView in its own NSWindow so it has proper event handling
/// (no overlay scrim intercepting clicks).
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func open(appState: AppState) {
        // If already open, just bring to front
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView(appState: appState)
            .frame(width: 780, height: 600)
            .background(DockwrightTheme.Surface.canvas)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )

        let hostingView = NSHostingView(rootView: settingsView)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.contentView = hostingView
        w.center()
        w.isReleasedWhenClosed = false
        w.title = "Dockwright Settings"
        w.backgroundColor = NSColor(DockwrightTheme.Surface.canvas)
        w.makeKeyAndOrderFront(nil)

        // Reset showSettings when window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { [weak appState] _ in
            appState?.showSettings = false
        }

        self.window = w
    }
}
