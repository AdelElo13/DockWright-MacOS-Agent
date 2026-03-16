import Foundation
import AppKit
import os.log

/// Polls browser tabs via AppleScript for Safari, Chrome, Firefox, Edge, Arc, and Brave.
/// Feeds results into WorldModel every 15 seconds when a supported browser is frontmost.
nonisolated final class BrowserTabWatcher: @unchecked Sendable {
    static let shared = BrowserTabWatcher()

    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "browser-tabs")
    private let queue = DispatchQueue(label: "com.dockwright.browsertabwatcher")
    private var isRunning = false

    private let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser" // Arc
    ]

    private init() {}

    func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            logger.info("BrowserTabWatcher started")
            poll()
        }
    }

    func stop() {
        queue.async { [self] in
            isRunning = false
            logger.info("BrowserTabWatcher stopped")
        }
    }

    private func poll() {
        guard isRunning else { return }

        let frontApp = WorldModel.shared.frontmostAppBundleID

        if browserBundleIDs.contains(frontApp) {
            fetchTabs(for: frontApp)
        }

        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.poll()
        }
    }

    private func fetchTabs(for bundleID: String) {
        let script: String

        switch bundleID {
        case "com.apple.Safari":
            script = """
            tell application "Safari"
                set tabList to ""
                set activeIdx to -1
                repeat with w in windows
                    set tabIdx to 0
                    repeat with t in tabs of w
                        set tabList to tabList & name of t & "|||" & URL of t & linefeed
                        if t is current tab of w then set activeIdx to tabIdx
                        set tabIdx to tabIdx + 1
                    end repeat
                end repeat
                return (activeIdx as text) & linefeed & "---" & linefeed & tabList
            end tell
            """

        case "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser":
            let appName: String
            switch bundleID {
            case "com.microsoft.edgemac": appName = "Microsoft Edge"
            case "com.brave.Browser": appName = "Brave Browser"
            default: appName = "Google Chrome"
            }
            script = """
            tell application "\(appName)"
                set tabList to ""
                set activeIdx to -1
                repeat with w in windows
                    set tabIdx to 0
                    repeat with t in tabs of w
                        set tabList to tabList & title of t & "|||" & URL of t & linefeed
                        if t is active tab of w then set activeIdx to tabIdx
                        set tabIdx to tabIdx + 1
                    end repeat
                end repeat
                return (activeIdx as text) & linefeed & "---" & linefeed & tabList
            end tell
            """

        case "company.thebrowser.Browser":
            // Arc uses Chromium AppleScript model
            script = """
            tell application "Arc"
                set tabList to ""
                set activeIdx to -1
                repeat with w in windows
                    set tabIdx to 0
                    repeat with t in tabs of w
                        set tabList to tabList & title of t & "|||" & URL of t & linefeed
                        if t is active tab of w then set activeIdx to tabIdx
                        set tabIdx to tabIdx + 1
                    end repeat
                end repeat
                return (activeIdx as text) & linefeed & "---" & linefeed & tabList
            end tell
            """

        case "org.mozilla.firefox":
            // Firefox has limited AppleScript support — get window title only
            script = """
            tell application "System Events"
                tell process "Firefox"
                    set winTitle to name of front window
                end tell
            end tell
            return "0" & linefeed & "---" & linefeed & winTitle & "|||"
            """

        default:
            return
        }

        queue.async { [weak self] in
            guard let self else { return }

            var error: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else { return }
            let result = appleScript.executeAndReturnError(&error)

            if error != nil {
                self.logger.debug("AppleScript error for \(bundleID, privacy: .public)")
                return
            }

            guard let output = result.stringValue else { return }
            let parts = output.components(separatedBy: "\n---\n")
            guard parts.count == 2 else { return }

            let activeIdx = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            let tabLines = parts[1].components(separatedBy: "\n").filter { !$0.isEmpty }

            var tabs: [BrowserTab] = []
            for line in tabLines.prefix(30) {
                let components = line.components(separatedBy: "|||")
                if components.count >= 2 {
                    tabs.append(BrowserTab(
                        title: String(components[0].prefix(100)),
                        url: String(components[1].prefix(200))
                    ))
                }
            }

            WorldModel.shared.updateBrowserTabs(tabs, activeIndex: activeIdx)
            self.logger.debug("Updated \(tabs.count) browser tabs")
        }
    }
}

// MARK: - Data

nonisolated struct BrowserTab: Sendable {
    let title: String
    let url: String
}
