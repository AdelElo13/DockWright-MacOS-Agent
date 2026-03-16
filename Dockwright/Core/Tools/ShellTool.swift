import Foundation

/// Execute shell commands via /bin/zsh.
/// Captures stdout, stderr, and exit code.
struct ShellTool: Tool, Sendable {
    let name = "shell"
    let description = "Run a shell command on the user's Mac. Returns stdout, stderr, and exit code."

    let parametersSchema: [String: Any] = [
        "command": [
            "type": "string",
            "description": "The shell command to execute"
        ] as [String: Any],
        "working_directory": [
            "type": "string",
            "description": "Working directory for the command (default: user home)",
            "optional": true
        ] as [String: Any]
    ]

    // Commands that are too dangerous to run
    private static let blockedPatterns: [String] = [
        "rm -rf /",
        "rm -rf /*",
        "mkfs",
        ":(){ :|:& };:",
        "> /dev/sda",
        "dd if=/dev/zero of=/dev",
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let command = arguments["command"] as? String else {
            return ToolResult("Missing required parameter: command", isError: true)
        }

        // Security check
        let lowered = command.lowercased().trimmingCharacters(in: .whitespaces)
        for pattern in Self.blockedPatterns {
            if lowered.contains(pattern) {
                return ToolResult("Blocked dangerous command: \(pattern)", isError: true)
            }
        }
        if lowered.hasPrefix("sudo ") {
            return ToolResult("sudo commands are not allowed for safety", isError: true)
        }

        let workingDir = arguments["working_directory"] as? String
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        return await runProcess(command: command, workingDirectory: workingDir)
    }

    private func runProcess(command: String, workingDirectory: String) async -> ToolResult {
        // Validate working directory exists
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: workingDirectory, isDirectory: &isDir), isDir.boolValue else {
            return ToolResult("Working directory does not exist: \(workingDirectory)", isError: true)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

                // Inherit user's PATH
                var env = ProcessInfo.processInfo.environment
                if env["PATH"] == nil {
                    env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                }
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // Collect output in background to prevent pipe buffer deadlock
                var stdoutData = Data()
                var stderrData = Data()
                let maxOutputBytes = 512_000 // 512KB raw cap to prevent OOM

                let stdoutHandle = stdoutPipe.fileHandleForReading
                let stderrHandle = stderrPipe.fileHandleForReading

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ToolResult("Failed to run command: \(error.localizedDescription)", isError: true))
                    return
                }

                // Read pipes after process exits to avoid deadlock
                process.waitUntilExit()

                stdoutData = stdoutHandle.readDataToEndOfFile()
                stderrData = stderrHandle.readDataToEndOfFile()

                // Cap raw data size to prevent memory issues with binary output
                if stdoutData.count > maxOutputBytes {
                    stdoutData = stdoutData.prefix(maxOutputBytes)
                }
                if stderrData.count > maxOutputBytes {
                    stderrData = stderrData.prefix(maxOutputBytes)
                }

                let stdout = String(data: stdoutData, encoding: .utf8)
                    ?? String(data: stdoutData, encoding: .ascii)
                    ?? "[binary output, \(stdoutData.count) bytes]"
                let stderr = String(data: stderrData, encoding: .utf8)
                    ?? String(data: stderrData, encoding: .ascii)
                    ?? "[binary output, \(stderrData.count) bytes]"
                let exitCode = process.terminationStatus

                // Truncate output to prevent token explosion
                let maxOutput = 50_000
                let truncatedStdout = stdout.count > maxOutput ? String(stdout.prefix(maxOutput)) + "\n[truncated]" : stdout
                let truncatedStderr = stderr.count > maxOutput ? String(stderr.prefix(maxOutput)) + "\n[truncated]" : stderr

                var result = "Exit code: \(exitCode)"
                if !truncatedStdout.isEmpty {
                    result += "\n\nSTDOUT:\n\(truncatedStdout)"
                }
                if !truncatedStderr.isEmpty {
                    result += "\n\nSTDERR:\n\(truncatedStderr)"
                }

                continuation.resume(returning: ToolResult(result, isError: exitCode != 0))
            }
        }
    }
}
