import Foundation
import os

nonisolated private let decompLog = Logger(subsystem: "com.Aatje.Dockwright", category: "DecomposeTask")

/// LLM tool that breaks complex tasks into ordered sub-tasks.
/// Returns a structured plan the agent can execute step by step.
nonisolated struct DecomposeTaskTool: Tool, @unchecked Sendable {
    let name = "decompose_task"
    let description = """
    Break a complex task into ordered sub-tasks with dependencies. \
    Use this when you receive a multi-step request that needs planning before execution. \
    Returns a structured plan you can follow step by step.
    """

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "task": [
            "type": "string",
            "description": "The complex task to decompose into sub-tasks",
        ] as [String: Any],
        "steps": [
            "type": "array",
            "description": "Array of step objects, each with: title (string), description (string), tool (optional string — tool name to use), depends_on (optional array of step indices that must complete first)",
        ] as [String: Any],
        "context": [
            "type": "string",
            "description": "Additional context about the task (e.g. current app, file paths, constraints)",
            "optional": true,
        ] as [String: Any],
    ]

    let requiredParams: [String] = ["task", "steps"]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let task = arguments["task"] as? String, !task.isEmpty else {
            return ToolResult("Missing 'task' — describe what needs to be done.", isError: true)
        }

        guard let stepsRaw = arguments["steps"] as? [[String: Any]], !stepsRaw.isEmpty else {
            return ToolResult("Missing 'steps' — provide an array of step objects.", isError: true)
        }

        var plan: [[String: Any]] = []
        var lines: [String] = ["📋 Task Plan: \(task)", ""]

        for (i, stepDict) in stepsRaw.enumerated() {
            let title = stepDict["title"] as? String ?? "Step \(i + 1)"
            let desc = stepDict["description"] as? String ?? ""
            let tool = stepDict["tool"] as? String
            let dependsOn = stepDict["depends_on"] as? [Int] ?? []

            var step: [String: Any] = [
                "index": i,
                "title": title,
                "description": desc,
                "status": "pending",
            ]
            if let tool = tool { step["tool"] = tool }
            if !dependsOn.isEmpty { step["depends_on"] = dependsOn }
            plan.append(step)

            // Format for display
            var line = "  \(i + 1). \(title)"
            if !desc.isEmpty { line += " — \(desc)" }
            if let tool = tool { line += " [tool: \(tool)]" }
            if !dependsOn.isEmpty {
                let deps = dependsOn.map { "step \($0 + 1)" }.joined(separator: ", ")
                line += " (after: \(deps))"
            }
            lines.append(line)
        }

        lines.append("")
        lines.append("Total: \(plan.count) steps")

        if let context = arguments["context"] as? String, !context.isEmpty {
            lines.append("Context: \(context)")
        }

        decompLog.info("Decomposed task into \(plan.count) steps: \(task.prefix(80))")

        return ToolResult(lines.joined(separator: "\n"))
    }
}
