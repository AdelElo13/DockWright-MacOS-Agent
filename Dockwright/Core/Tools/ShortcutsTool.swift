import Foundation
import os

nonisolated private let shortcutsLogger = Logger(subsystem: "com.dockwright", category: "ShortcutsTool")

/// LLM tool for running and managing Shortcuts.app shortcuts via the `shortcuts` CLI.
/// Actions: list, run, details.
nonisolated struct ShortcutsTool: Tool, @unchecked Sendable {
    let name = "shortcuts"
    let description = "Manage macOS Shortcuts: list all shortcuts, run a shortcut by name with optional input, or get shortcut details."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: list, run, details",
        ] as [String: Any],
        "shortcut_name": [
            "type": "string",
            "description": "Name of the shortcut (for run, details)",
            "optional": true,
        ] as [String: Any],
        "input": [
            "type": "string",
            "description": "Input text to pass to the shortcut (for run)",
            "optional": true,
        ] as [String: Any],
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult(
                "Missing 'action' parameter. Use: list, run, details",
                isError: true
            )
        }

        switch action {
        case "list":
            return await listShortcuts()
        case "run":
            return await runShortcut(arguments)
        case "details":
            return await shortcutDetails(arguments)
        default:
            return ToolResult(
                "Unknown action: \(action). Use: list, run, details",
                isError: true
            )
        }
    }

    // MARK: - Shell Runner

    private func runShell(_ executable: String, arguments args: [String], inputData: Data? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        if let inputData = inputData {
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(inputData)
            stdin.fileHandleForWriting.closeFile()
        } else {
            try process.run()
        }

        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
            shortcutsLogger.error("Shell command failed: \(errStr)")
            throw ShortcutsToolError.commandFailed(errStr)
        }

        return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Actions

    private func listShortcuts() async -> ToolResult {
        do {
            let result = try await runShell("/usr/bin/shortcuts", arguments: ["list"])

            if result.isEmpty {
                return ToolResult("No shortcuts found. Create shortcuts in the Shortcuts app.")
            }

            let shortcuts = result.components(separatedBy: "\n").filter { !$0.isEmpty }
            return ToolResult("Available shortcuts (\(shortcuts.count)):\n\n\(shortcuts.joined(separator: "\n"))")
        } catch {
            return ToolResult("Failed to list shortcuts: \(error.localizedDescription)", isError: true)
        }
    }

    private func runShortcut(_ args: [String: Any]) async -> ToolResult {
        guard let name = args["shortcut_name"] as? String, !name.isEmpty else {
            return ToolResult("Missing 'shortcut_name' for run", isError: true)
        }

        let inputText = args["input"] as? String

        do {
            var shellArgs = ["run", name]
            var inputData: Data?

            if let inputText = inputText, !inputText.isEmpty {
                shellArgs.append(contentsOf: ["--input-type", "text"])
                inputData = inputText.data(using: .utf8)
            }

            let result = try await runShell("/usr/bin/shortcuts", arguments: shellArgs, inputData: inputData)

            if result.isEmpty {
                return ToolResult("Shortcut '\(name)' executed successfully (no output).")
            }

            return ToolResult("Shortcut '\(name)' output:\n\n\(result)")
        } catch {
            return ToolResult("Failed to run shortcut '\(name)': \(error.localizedDescription)", isError: true)
        }
    }

    private func shortcutDetails(_ args: [String: Any]) async -> ToolResult {
        guard let name = args["shortcut_name"] as? String, !name.isEmpty else {
            return ToolResult("Missing 'shortcut_name' for details", isError: true)
        }

        do {
            // List shortcuts and check if it exists
            let listResult = try await runShell("/usr/bin/shortcuts", arguments: ["list"])
            let shortcuts = listResult.components(separatedBy: "\n").filter { !$0.isEmpty }

            let matchingShortcut = shortcuts.first { $0.trimmingCharacters(in: .whitespaces) == name }

            if matchingShortcut == nil {
                // Try case-insensitive match
                let lowerName = name.lowercased()
                let fuzzyMatch = shortcuts.first { $0.trimmingCharacters(in: .whitespaces).lowercased() == lowerName }

                if let fuzzyMatch = fuzzyMatch {
                    return ToolResult("Shortcut found (case-insensitive match): \(fuzzyMatch)\n\nNote: Use the exact name '\(fuzzyMatch.trimmingCharacters(in: .whitespaces))' to run it.")
                }

                // Suggest similar names
                let similar = shortcuts.filter { $0.lowercased().contains(lowerName) || lowerName.contains($0.lowercased()) }
                if !similar.isEmpty {
                    return ToolResult("Shortcut '\(name)' not found.\n\nDid you mean:\n\(similar.joined(separator: "\n"))")
                }

                return ToolResult("Shortcut '\(name)' not found. Use the 'list' action to see available shortcuts.", isError: true)
            }

            return ToolResult("Shortcut: \(name)\nStatus: Available\n\nUse the 'run' action with shortcut_name='\(name)' to execute it.")
        } catch {
            return ToolResult("Failed to get shortcut details: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Errors

private enum ShortcutsToolError: Error, LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let msg): return "Shortcuts tool error: \(msg)"
        }
    }
}
