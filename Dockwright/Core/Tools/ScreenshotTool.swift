import Foundation
import os

nonisolated private let screenshotLogger = Logger(subsystem: "com.dockwright", category: "ScreenshotTool")

/// LLM tool for capturing screenshots using the macOS screencapture command.
/// Actions: capture_screen, capture_window, capture_area, list_windows.
nonisolated struct ScreenshotTool: Tool, @unchecked Sendable {
    let name = "screenshot"
    let description = "Capture screenshots: full screen, frontmost window, interactive area selection, or list all windows."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: capture_screen, capture_window, capture_area, list_windows",
        ] as [String: Any],
        "display": [
            "type": "integer",
            "description": "Display number for capture_screen (default: main display)",
            "optional": true,
        ] as [String: Any],
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult(
                "Missing 'action' parameter. Use: capture_screen, capture_window, capture_area, list_windows",
                isError: true
            )
        }

        switch action {
        case "capture_screen":
            return await captureScreen()
        case "capture_window":
            return await captureWindow()
        case "capture_area":
            return await captureArea()
        case "list_windows":
            return await listWindows()
        default:
            return ToolResult(
                "Unknown action: \(action). Use: capture_screen, capture_window, capture_area, list_windows",
                isError: true
            )
        }
    }

    // MARK: - Helpers

    private func screenshotDirectory() -> URL {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let dir = desktop.appendingPathComponent("Dockwright Screenshots")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func generateFilename(prefix: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        return "\(prefix)_\(timestamp).png"
    }

    private func runProcess(_ executablePath: String, arguments: [String]) async throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }

    // MARK: - Actions

    private func captureScreen() async -> ToolResult {
        let dir = screenshotDirectory()
        let filename = generateFilename(prefix: "screen")
        let filePath = dir.appendingPathComponent(filename).path

        do {
            let result = try await runProcess("/usr/sbin/screencapture", arguments: ["-x", filePath])
            if result.status != 0 {
                return ToolResult("Screenshot failed: \(result.stderr)", isError: true)
            }

            if FileManager.default.fileExists(atPath: filePath) {
                return ToolResult("Full screen screenshot saved to: \(filePath)")
            } else {
                return ToolResult("Screenshot command completed but file was not created.", isError: true)
            }
        } catch {
            return ToolResult("Failed to run screencapture: \(error.localizedDescription)", isError: true)
        }
    }

    private func captureWindow() async -> ToolResult {
        let dir = screenshotDirectory()
        let filename = generateFilename(prefix: "window")
        let filePath = dir.appendingPathComponent(filename).path

        do {
            // -l flag with window ID would be ideal, but -w captures frontmost window
            let result = try await runProcess("/usr/sbin/screencapture", arguments: ["-x", "-w", filePath])
            if result.status != 0 {
                return ToolResult("Screenshot failed: \(result.stderr)", isError: true)
            }

            if FileManager.default.fileExists(atPath: filePath) {
                return ToolResult("Frontmost window screenshot saved to: \(filePath)")
            } else {
                return ToolResult("Screenshot command completed but file was not created. The user may have cancelled.", isError: true)
            }
        } catch {
            return ToolResult("Failed to run screencapture: \(error.localizedDescription)", isError: true)
        }
    }

    private func captureArea() async -> ToolResult {
        let dir = screenshotDirectory()
        let filename = generateFilename(prefix: "area")
        let filePath = dir.appendingPathComponent(filename).path

        do {
            let result = try await runProcess("/usr/sbin/screencapture", arguments: ["-x", "-i", filePath])
            if result.status != 0 {
                return ToolResult("Screenshot failed: \(result.stderr)", isError: true)
            }

            if FileManager.default.fileExists(atPath: filePath) {
                return ToolResult("Area screenshot saved to: \(filePath)")
            } else {
                return ToolResult("Screenshot command completed but file was not created. The user may have cancelled the selection.", isError: true)
            }
        } catch {
            return ToolResult("Failed to run screencapture: \(error.localizedDescription)", isError: true)
        }
    }

    private func listWindows() async -> ToolResult {
        let script = """
        tell application "System Events"
            set windowList to ""
            set allProcesses to application processes whose visible is true
            repeat with proc in allProcesses
                set procName to name of proc
                try
                    set wins to windows of proc
                    repeat with w in wins
                        set winTitle to name of w
                        set winPos to position of w
                        set winSize to size of w
                        set windowList to windowList & procName & " | " & winTitle & " | Position: " & (item 1 of winPos as string) & "," & (item 2 of winPos as string) & " | Size: " & (item 1 of winSize as string) & "x" & (item 2 of winSize as string) & "\\n"
                    end repeat
                end try
            end repeat
            return windowList
        end tell
        """

        do {
            let result = try await runProcess("/usr/bin/osascript", arguments: ["-e", script])
            if result.status != 0 {
                return ToolResult("Failed to list windows: \(result.stderr)", isError: true)
            }
            if result.stdout.isEmpty {
                return ToolResult("No visible windows found.")
            }
            return ToolResult("Visible windows:\n\nApp | Title | Position | Size\n\(result.stdout)")
        } catch {
            return ToolResult("Failed to list windows: \(error.localizedDescription)", isError: true)
        }
    }
}
