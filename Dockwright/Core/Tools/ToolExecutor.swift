import Foundation
import os

/// Executes tools by name, with per-tool timeouts.
nonisolated final class ToolExecutor: @unchecked Sendable {
    private let registry: ToolRegistry

    /// Callback to ask user for approval before running risky tools.
    /// Returns true if approved, false if denied.
    var onApprovalNeeded: ((_ toolName: String, _ description: String) async -> Bool)?

    /// Tools that are considered risky and require approval
    private let riskyTools: Set<String> = ["shell", "browser_action"]

    nonisolated init(registry: ToolRegistry = .shared) {
        self.registry = registry
    }

    /// Execute a tool by name with JSON arguments.
    /// - Parameters:
    ///   - name: Tool name from the LLM's tool_use block
    ///   - arguments: Parsed JSON arguments dictionary
    /// - Returns: ToolResult with output text
    func executeTool(name: String, arguments: [String: Any]) async -> ToolResult {
        guard let tool = registry.get(name: name) else {
            return ToolResult("Unknown tool: \(name)", isError: true)
        }

        // Check if approval is required for risky tools
        let requireApproval = UserDefaults.standard.object(forKey: "requireApprovalForRisky") as? Bool ?? true
        if requireApproval && riskyTools.contains(name) {
            let description: String
            if name == "shell", let cmd = arguments["command"] as? String {
                description = "Run shell command: \(cmd)"
            } else {
                description = "Execute \(name) tool"
            }

            if let approvalHandler = onApprovalNeeded {
                let approved = await approvalHandler(name, description)
                if !approved {
                    return ToolResult("Tool '\(name)' was denied by user", isError: true)
                }
            }
        }

        let timeout: UInt64 = name == "shell" ? 120_000_000_000 : 30_000_000_000

        do {
            return try await withThrowingTaskGroup(of: ToolResult.self) { group in
                // Tool execution
                group.addTask {
                    try await tool.execute(arguments: arguments)
                }

                // Timeout
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout)
                    throw ToolExecutionError.timeout(name)
                }

                guard let result = try await group.next() else {
                    return ToolResult("Tool '\(name)' returned no result", isError: true)
                }
                group.cancelAll()
                return result
            }
        } catch is CancellationError {
            return ToolResult("Tool '\(name)' was cancelled", isError: true)
        } catch let error as ToolExecutionError {
            return ToolResult(error.localizedDescription, isError: true)
        } catch {
            return ToolResult("Tool '\(name)' failed: \(error.localizedDescription)", isError: true)
        }
    }

    /// Parse JSON string arguments into a dictionary.
    func parseArguments(_ jsonString: String) -> [String: Any] {
        guard !jsonString.isEmpty else { return [:] }
        guard let data = jsonString.data(using: .utf8) else {
            AppLog.tools.warning("Tool arguments not valid UTF-8: \(jsonString.prefix(100))")
            return [:]
        }
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AppLog.tools.warning("Tool arguments not a JSON object: \(jsonString.prefix(100))")
                return [:]
            }
            return dict
        } catch {
            AppLog.tools.warning("Tool arguments JSON parse failed: \(error.localizedDescription)")
            return [:]
        }
    }
}

enum ToolExecutionError: LocalizedError {
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let name): return "Tool '\(name)' timed out"
        }
    }
}
