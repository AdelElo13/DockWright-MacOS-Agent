import Foundation
import AppKit

/// System control tool: launch apps, open URLs, get system info, toggle dark mode, set volume.
struct SystemTool: Tool, Sendable {
    let name = "system"
    let description = """
        Control macOS system features. Actions:
        - open_app: Open an application by name (e.g. "Safari", "Xcode")
        - open_url: Open a URL in the default browser
        - running_apps: List currently running applications
        - system_info: Get macOS version, RAM, disk space, battery, CPU info
        - toggle_dark_mode: Toggle between light and dark mode
        - set_volume: Set system volume (0-100)
        - get_volume: Get current system volume
        """

    let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "Action to perform",
            "enum": ["open_app", "open_url", "running_apps", "system_info", "toggle_dark_mode", "set_volume", "get_volume"]
        ] as [String: Any],
        "target": [
            "type": "string",
            "description": "App name (for open_app) or URL string (for open_url)",
            "optional": true
        ] as [String: Any],
        "value": [
            "type": "number",
            "description": "Volume level 0-100 (for set_volume)",
            "optional": true
        ] as [String: Any]
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing required parameter: action", isError: true)
        }

        switch action {
        case "open_app":
            guard let target = arguments["target"] as? String else {
                return ToolResult("Missing parameter: target (app name)", isError: true)
            }
            return await openApp(name: target)

        case "open_url":
            guard let target = arguments["target"] as? String else {
                return ToolResult("Missing parameter: target (URL)", isError: true)
            }
            return openURL(target)

        case "running_apps":
            return runningApps()

        case "system_info":
            return await systemInfo()

        case "toggle_dark_mode":
            return await toggleDarkMode()

        case "set_volume":
            let volume: Int
            if let v = arguments["value"] as? Int {
                volume = v
            } else if let v = arguments["value"] as? Double {
                volume = Int(v)
            } else {
                return ToolResult("Missing parameter: value (0-100)", isError: true)
            }
            return await setVolume(volume)

        case "get_volume":
            return await getVolume()

        default:
            return ToolResult("Unknown action: \(action)", isError: true)
        }
    }

    // MARK: - Open App

    private func openApp(name: String) async -> ToolResult {
        let workspace = NSWorkspace.shared
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        // Try to find the app by name
        let searchPaths = [
            "/Applications/\(name).app",
            "/System/Applications/\(name).app",
            "/Applications/Utilities/\(name).app",
            "/System/Applications/Utilities/\(name).app",
            NSHomeDirectory() + "/Applications/\(name).app",
        ]

        for path in searchPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try await workspace.openApplication(at: url, configuration: config)
                    return ToolResult("Opened \(name)")
                } catch {
                    return ToolResult("Failed to open \(name): \(error.localizedDescription)", isError: true)
                }
            }
        }

        // Try using NSWorkspace to find by bundle ID-like match using mdfind
        let result = await shellCommand("mdfind 'kMDItemKind == \"Application\"' | grep -i '\(name)' | head -3")
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        if let firstMatch = lines.first {
            let url = URL(fileURLWithPath: firstMatch)
            do {
                try await workspace.openApplication(at: url, configuration: config)
                return ToolResult("Opened \(firstMatch)")
            } catch {
                return ToolResult("Failed to open \(name): \(error.localizedDescription)", isError: true)
            }
        }

        return ToolResult("Application '\(name)' not found. Check the name and try again.", isError: true)
    }

    // MARK: - Open URL

    private func openURL(_ urlString: String) -> ToolResult {
        var finalURL = urlString
        if !finalURL.hasPrefix("http://") && !finalURL.hasPrefix("https://") {
            finalURL = "https://" + finalURL
        }

        guard let url = URL(string: finalURL) else {
            return ToolResult("Invalid URL: \(urlString)", isError: true)
        }

        NSWorkspace.shared.open(url)
        return ToolResult("Opened \(finalURL) in default browser")
    }

    // MARK: - Running Apps

    private func runningApps() -> ToolResult {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> String? in
                guard let name = app.localizedName else { return nil }
                let pid = app.processIdentifier
                let active = app.isActive ? " [active]" : ""
                return "  \(name) (PID: \(pid))\(active)"
            }

        return ToolResult("Running applications (\(apps.count)):\n" + apps.joined(separator: "\n"))
    }

    // MARK: - System Info

    private func systemInfo() async -> ToolResult {
        var info: [String] = []

        // macOS version
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        info.append("macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")

        // Machine name
        info.append("Host: \(ProcessInfo.processInfo.hostName)")

        // CPU
        info.append("CPUs: \(ProcessInfo.processInfo.processorCount) cores (active: \(ProcessInfo.processInfo.activeProcessorCount))")

        // RAM
        let physMem = ProcessInfo.processInfo.physicalMemory
        info.append("RAM: \(physMem / 1_073_741_824) GB")

        // Disk space
        let diskInfo = await shellCommand("df -h / | tail -1 | awk '{print \"Disk: \" $3 \" used / \" $4 \" free (\" $5 \" used)\"}'")
        if !diskInfo.isEmpty {
            info.append(diskInfo.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Battery
        let batteryInfo = await shellCommand("pmset -g batt | grep -o '[0-9]*%.*'")
        if !batteryInfo.isEmpty {
            info.append("Battery: \(batteryInfo.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Uptime
        let uptime = ProcessInfo.processInfo.systemUptime
        let hours = Int(uptime) / 3600
        let minutes = (Int(uptime) % 3600) / 60
        info.append("Uptime: \(hours)h \(minutes)m")

        // Dark mode
        let appearance = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        info.append("Dark mode: \(appearance == .darkAqua ? "on" : "off")")

        return ToolResult(info.joined(separator: "\n"))
    }

    // MARK: - Dark Mode

    private func toggleDarkMode() async -> ToolResult {
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to not dark mode
                return dark mode as text
            end tell
        end tell
        """
        let result = await runAppleScript(script)
        if result.contains("true") {
            return ToolResult("Dark mode enabled")
        } else if result.contains("false") {
            return ToolResult("Dark mode disabled")
        }
        return ToolResult("Toggle dark mode: \(result)")
    }

    // MARK: - Volume

    private func setVolume(_ level: Int) async -> ToolResult {
        let clamped = min(100, max(0, level))
        let script = "set volume output volume \(clamped)"
        _ = await runAppleScript(script)
        return ToolResult("Volume set to \(clamped)%")
    }

    private func getVolume() async -> ToolResult {
        let script = "output volume of (get volume settings)"
        let result = await runAppleScript(script)
        return ToolResult("Current volume: \(result.trimmingCharacters(in: .whitespacesAndNewlines))%")
    }

    // MARK: - Helpers

    private func shellCommand(_ command: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    private func runAppleScript(_ source: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: "Failed to create AppleScript")
                    return
                }
                let result = script.executeAndReturnError(&error)
                if let error {
                    continuation.resume(returning: "AppleScript error: \(error)")
                } else {
                    continuation.resume(returning: result.stringValue ?? "OK")
                }
            }
        }
    }
}
