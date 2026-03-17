import Foundation
import os

/// Autonomous agent mode: multi-step task planning and execution.
/// Breaks user goals into steps, executes them sequentially with self-correction.
/// Reports progress to UI and can be cancelled at any point.
final class AgentExecutor: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "agent")
    private let lock = NSLock()

    // MARK: - Agent State

    enum AgentState: Sendable, Equatable {
        case idle
        case planning
        case executing(step: Int, total: Int, description: String)
        case retrying(step: Int, attempt: Int)
        case completed(summary: String)
        case failed(error: String)
        case cancelled
    }

    struct AgentPlan: Sendable {
        let goal: String
        let steps: [AgentStep]
    }

    struct AgentStep: Sendable {
        let index: Int
        let description: String
        let toolName: String?
        let toolArguments: [String: String]
    }

    struct StepResult: Sendable {
        let step: AgentStep
        let output: String
        let isError: Bool
        let retryCount: Int
    }

    // Config — read from UserDefaults (wired to Agent Settings UI)
    var maxSteps: Int {
        let v = UserDefaults.standard.object(forKey: "agentMaxSteps") as? Int ?? 10
        return max(1, min(v, 50))
    }
    var maxRetriesPerStep: Int {
        let autoRetry = UserDefaults.standard.object(forKey: "agentAutoRetry") as? Bool ?? true
        return autoRetry ? 2 : 0
    }

    // State
    private var _state: AgentState = .idle
    private var currentTask: Task<Void, Never>?

    var state: AgentState {
        lock.withLock { _state }
    }

    // Callbacks (set by AppState)
    var onStateChange: (@Sendable (AgentState) -> Void)?
    var onStepOutput: (@Sendable (StepResult) -> Void)?

    // MARK: - Plan Parsing

    /// Parse an LLM-generated plan from text. The LLM should return a numbered list.
    /// Format expected:
    /// 1. [tool:shell] description of what to do | {"command": "..."}
    /// 2. [tool:file] read a file | {"action": "read", "path": "..."}
    /// 3. description without tool (LLM reasoning step)
    func parsePlan(goal: String, planText: String) -> AgentPlan {
        var steps: [AgentStep] = []
        let lines = planText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for (idx, line) in lines.enumerated() {
            if idx >= maxSteps { break }

            // Strip leading number: "1. ", "2. ", etc.
            var cleaned = line
            if let range = cleaned.range(of: #"^\d+[\.\)]\s*"#, options: .regularExpression) {
                cleaned = String(cleaned[range.upperBound...])
            }

            // Parse [tool:name] prefix
            var toolName: String?
            var toolArgs: [String: String] = [:]

            if let toolRange = cleaned.range(of: #"\[tool:(\w+)\]\s*"#, options: .regularExpression) {
                let match = cleaned[toolRange]
                if let nameRange = match.range(of: #"\w+"#, options: .regularExpression, range: match.index(after: match.startIndex)..<match.endIndex) {
                    let extracted = String(match[nameRange])
                    if extracted != "tool" {
                        toolName = extracted
                    }
                }
                cleaned = String(cleaned[toolRange.upperBound...])
            }

            // Parse | {"key": "value"} suffix for tool arguments
            if let pipeRange = cleaned.range(of: " | {", options: .backwards) {
                let jsonPart = String(cleaned[pipeRange.upperBound...])
                let jsonStr = "{" + jsonPart
                if let data = jsonStr.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for (k, v) in dict {
                        toolArgs[k] = "\(v)"
                    }
                }
                cleaned = String(cleaned[..<pipeRange.lowerBound])
            }

            steps.append(AgentStep(
                index: idx + 1,
                description: cleaned.trimmingCharacters(in: .whitespaces),
                toolName: toolName,
                toolArguments: toolArgs
            ))
        }

        return AgentPlan(goal: goal, steps: steps)
    }

    // MARK: - Execution

    /// Execute a plan step-by-step. Can be called from AppState's agent mode.
    /// Returns collected results from all steps.
    func executePlan(
        plan: AgentPlan,
        toolExecutor: ToolExecutor,
        onProgress: @escaping @Sendable (AgentState) -> Void
    ) async -> [StepResult] {
        var results: [StepResult] = []

        updateState(.planning)
        onProgress(.planning)

        for step in plan.steps {
            if Task.isCancelled {
                updateState(.cancelled)
                onProgress(.cancelled)
                break
            }

            let stepState: AgentState = .executing(
                step: step.index,
                total: plan.steps.count,
                description: step.description
            )
            updateState(stepState)
            onProgress(stepState)

            // Execute step with retry
            var retryCount = 0
            var stepResult: StepResult?

            while retryCount <= maxRetriesPerStep {
                if Task.isCancelled { break }

                if retryCount > 0 {
                    let retryState: AgentState = .retrying(step: step.index, attempt: retryCount)
                    updateState(retryState)
                    onProgress(retryState)
                    logger.info("Retrying step \(step.index) (attempt \(retryCount + 1))")
                }

                let result: ToolResult
                if let toolName = step.toolName {
                    // Execute tool
                    var args = step.toolArguments.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }

                    // If previous step had output and this step has no args, pass previous output as context
                    if args.isEmpty, let prevResult = results.last {
                        args["context"] = prevResult.output
                    }

                    result = await toolExecutor.executeTool(name: toolName, arguments: args)
                } else {
                    // Reasoning step — no tool to execute
                    result = ToolResult("Reasoning: \(step.description)")
                }

                stepResult = StepResult(
                    step: step,
                    output: result.output,
                    isError: result.isError,
                    retryCount: retryCount
                )

                if !result.isError {
                    break // Success
                }

                retryCount += 1
                if retryCount > maxRetriesPerStep {
                    logger.warning("Step \(step.index) failed after \(self.maxRetriesPerStep) retries")
                }
            }

            if let sr = stepResult {
                results.append(sr)
                onStepOutput?(sr)
            }
        }

        if !Task.isCancelled {
            let summary = "Completed \(results.count)/\(plan.steps.count) steps for: \(plan.goal)"
            let finalState: AgentState = .completed(summary: summary)
            updateState(finalState)
            onProgress(finalState)
        }

        return results
    }

    // MARK: - Cancel

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        updateState(.cancelled)
    }

    // MARK: - State

    private func updateState(_ newState: AgentState) {
        lock.withLock { _state = newState }
        onStateChange?(newState)
    }

    /// Format agent plan and results as text for LLM context.
    static func formatResults(_ results: [StepResult]) -> String {
        var text = "Agent execution results:\n"
        for r in results {
            let status = r.isError ? "FAILED" : "OK"
            text += "Step \(r.step.index) [\(status)]: \(r.step.description)\n"
            if !r.output.isEmpty {
                let preview = String(r.output.prefix(500))
                text += "  Output: \(preview)\n"
            }
            if r.retryCount > 0 {
                text += "  (retried \(r.retryCount) time(s))\n"
            }
        }
        return text
    }
}
