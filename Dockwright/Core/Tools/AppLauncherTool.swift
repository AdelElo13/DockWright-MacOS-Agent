import Foundation
import AppKit
import os

nonisolated private let appLauncherLogger = Logger(subsystem: "com.dockwright", category: "AppLauncherTool")

/// LLM tool for launching, quitting, and managing macOS applications.
/// Actions: open, quit, force_quit, list_running, list_installed, activate, hide.
nonisolated struct AppLauncherTool: Tool, @unchecked Sendable {
    let name = "app_launcher"
    let description = "Launch, quit, and manage macOS applications: open apps, quit or force quit, list running/installed apps, activate (bring to front), or hide."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: open, quit, force_quit, list_running, list_installed, activate, hide",
        ] as [String: Any],
        "app_name": [
            "type": "string",
            "description": "Application name (e.g. 'Safari', 'Visual Studio Code')",
            "optional": true,
        ] as [String: Any],
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult(
                "Missing 'action' parameter. Use: open, quit, force_quit, list_running, list_installed, activate, hide",
                isError: true
            )
        }

        switch action {
        case "open":
            return await openApp(arguments)
        case "quit":
            return await quitApp(arguments)
        case "force_quit":
            return await forceQuitApp(arguments)
        case "list_running":
            return await listRunning()
        case "list_installed":
            return listInstalled()
        case "activate":
            return await activateApp(arguments)
        case "hide":
            return await hideApp(arguments)
        default:
            return ToolResult(
                "Unknown action: \(action). Use: open, quit, force_quit, list_running, list_installed, activate, hide",
                isError: true
            )
        }
    }

    // MARK: - AppleScript Runner

    private func runAppleScript(_ source: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
            appLauncherLogger.error("AppleScript failed: \(errStr)")
            throw AppLauncherToolError.scriptFailed(errStr)
        }

        return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Actions

    private func openApp(_ args: [String: Any]) async -> ToolResult {
        guard let appName = args["app_name"] as? String, !appName.isEmpty else {
            return ToolResult("Missing 'app_name' for open", isError: true)
        }

        let escaped = escapeForAppleScript(appName)
        let script = """
        tell application "\(escaped)" to activate
        return "Launched: \(escaped)"
        """

        do {
            let result = try await runAppleScript(script)
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to open \(appName): \(error.localizedDescription)", isError: true)
        }
    }

    private func quitApp(_ args: [String: Any]) async -> ToolResult {
        guard let appName = args["app_name"] as? String, !appName.isEmpty else {
            return ToolResult("Missing 'app_name' for quit", isError: true)
        }

        let escaped = escapeForAppleScript(appName)
        let script = """
        tell application "\(escaped)" to quit
        return "Quit: \(escaped)"
        """

        do {
            let result = try await runAppleScript(script)
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to quit \(appName): \(error.localizedDescription)", isError: true)
        }
    }

    private func forceQuitApp(_ args: [String: Any]) async -> ToolResult {
        guard let appName = args["app_name"] as? String, !appName.isEmpty else {
            return ToolResult("Missing 'app_name' for force_quit", isError: true)
        }

        let escaped = escapeForAppleScript(appName)
        let script = """
        tell application "System Events"
            set targetProcs to every process whose name contains "\(escaped)"
            if (count of targetProcs) = 0 then
                return "No running process found matching: \(escaped)"
            end if
            repeat with proc in targetProcs
                set procName to name of proc
                do shell script "killall -9 " & quoted form of procName
            end repeat
            return "Force quit: \(escaped)"
        end tell
        """

        do {
            let result = try await runAppleScript(script)
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to force quit \(appName): \(error.localizedDescription)", isError: true)
        }
    }

    private func listRunning() async -> ToolResult {
        let apps: [String] = await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app -> String? in
                    guard let name = app.localizedName else { return nil }
                    let pid = app.processIdentifier
                    let active = app.isActive ? " [active]" : ""
                    let hidden = app.isHidden ? " [hidden]" : ""
                    return "  \(name) (PID: \(pid))\(active)\(hidden)"
                }
                .sorted()
        }

        if apps.isEmpty {
            return ToolResult("No running applications found.")
        }

        return ToolResult("Running applications (\(apps.count)):\n\n\(apps.joined(separator: "\n"))")
    }

    private func listInstalled() -> ToolResult {
        let fm = FileManager.default
        let applicationsPath = "/Applications"

        do {
            let contents = try fm.contentsOfDirectory(atPath: applicationsPath)
            let apps = contents
                .filter { $0.hasSuffix(".app") }
                .map { ($0 as NSString).deletingPathExtension }
                .sorted()

            if apps.isEmpty {
                return ToolResult("No applications found in /Applications.")
            }

            return ToolResult("Installed applications (\(apps.count)):\n\n\(apps.joined(separator: "\n"))")
        } catch {
            return ToolResult("Failed to list installed apps: \(error.localizedDescription)", isError: true)
        }
    }

    private func activateApp(_ args: [String: Any]) async -> ToolResult {
        guard let appName = args["app_name"] as? String, !appName.isEmpty else {
            return ToolResult("Missing 'app_name' for activate", isError: true)
        }

        let escaped = escapeForAppleScript(appName)
        let script = """
        tell application "\(escaped)" to activate
        return "Activated: \(escaped)"
        """

        do {
            let result = try await runAppleScript(script)
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to activate \(appName): \(error.localizedDescription)", isError: true)
        }
    }

    private func hideApp(_ args: [String: Any]) async -> ToolResult {
        guard let appName = args["app_name"] as? String, !appName.isEmpty else {
            return ToolResult("Missing 'app_name' for hide", isError: true)
        }

        let escaped = escapeForAppleScript(appName)
        let script = """
        tell application "System Events"
            set visible of process "\(escaped)" to false
        end tell
        return "Hidden: \(escaped)"
        """

        do {
            let result = try await runAppleScript(script)
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to hide \(appName): \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Errors

private enum AppLauncherToolError: Error, LocalizedError {
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): return "App launcher error: \(msg)"
        }
    }
}
