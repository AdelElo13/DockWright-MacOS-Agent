import Foundation
import os

/// Runs multiple agent tasks concurrently, each with its own LLM conversation
/// context and tool execution loop. Reports per-task progress and supports
/// individual or bulk cancellation.
@Observable
final class ParallelAgentExecutor: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "parallel-agent")
    private let lock = NSLock()

    // MARK: - Types

    struct AgentTask: Identifiable, Sendable {
        let id: String
        var description: String
        var status: TaskStatus
        var result: String?
        var startedAt: Date
        var completedAt: Date?

        enum TaskStatus: Sendable, Equatable, CustomStringConvertible {
            case pending
            case running(step: Int, total: Int)
            case completed
            case failed(String)
            case cancelled

            nonisolated var description: String {
                switch self {
                case .pending:                return "pending"
                case .running(let s, let t):  return "running (\(s)/\(t))"
                case .completed:              return "completed"
                case .failed(let msg):        return "failed: \(msg)"
                case .cancelled:              return "cancelled"
                }
            }
        }
    }

    // MARK: - Configuration (wired to Agent Settings UI)

    private var maxStepsPerTask: Int {
        let v = UserDefaults.standard.object(forKey: "agentMaxSteps") as? Int ?? 10
        return max(1, min(v, 50))
    }
    private var maxRetriesPerStep: Int {
        let autoRetry = UserDefaults.standard.object(forKey: "agentAutoRetry") as? Bool ?? true
        return autoRetry ? 2 : 0
    }
    private var maxParallelTasks: Int {
        let v = UserDefaults.standard.object(forKey: "maxParallelTasks") as? Int ?? 3
        return max(1, min(v, 10))
    }

    // MARK: - Observable State

    var activeTasks: [AgentTask] = []

    var isRunning: Bool {
        activeTasks.contains {
            if case .running = $0.status { return true }
            return false
        }
    }

    // MARK: - Internal Task Handles

    /// Maps AgentTask.id -> Swift Task handle for individual cancellation.
    /// Guarded by `lock`; marked nonisolated(unsafe) to allow access from task groups.
    @ObservationIgnored nonisolated(unsafe) private var taskHandles: [String: Task<AgentTask, Never>] = [:]

    /// Top-level group task for cancelAll.
    /// Guarded by `lock`; marked nonisolated(unsafe) to allow access from task groups.
    @ObservationIgnored nonisolated(unsafe) private var groupTask: Task<[AgentTask], Never>?

    // MARK: - Execute Multiple Tasks

    /// Launch multiple tasks in parallel. Each task gets its own LLM conversation
    /// and runs an independent tool-calling loop until the LLM signals completion.
    ///
    /// - Parameters:
    ///   - descriptions: Goals for each parallel sub-agent.
    ///   - toolExecutor: Shared tool executor (thread-safe).
    ///   - llmService: Shared LLM client (thread-safe).
    ///   - apiKey: API key for the LLM provider.
    ///   - model: Model identifier (e.g. "claude-sonnet-4-6").
    /// - Returns: Final snapshot of all agent tasks with results.
    @discardableResult
    func executeTasks(
        _ descriptions: [String],
        toolExecutor: ToolExecutor,
        llmService: LLMService,
        apiKey: String,
        model: String
    ) async -> [AgentTask] {
        // Initialise all tasks as pending
        let tasks = descriptions.map { desc in
            AgentTask(
                id: UUID().uuidString.prefix(8).lowercased(),
                description: desc,
                status: .pending,
                result: nil,
                startedAt: Date(),
                completedAt: nil
            )
        }

        lock.withLock { taskHandles.removeAll() }
        updateActiveTasks(tasks)

        let toolDefs = ToolRegistry.shared.anthropicToolDefinitions()

        // Launch sub-agents in parallel, respecting maxParallelTasks limit.
        // Uses a sliding window: start N tasks, then add one as each finishes.
        let limit = maxParallelTasks
        let parentTask = Task<[AgentTask], Never> { [weak self] in
            guard let self else { return tasks }

            return await withTaskGroup(of: AgentTask.self) { group in
                var taskQueue = tasks[...]
                var launched = 0

                // Seed the group up to the concurrency limit
                while launched < limit, let task = taskQueue.popFirst() {
                    launched += 1
                    group.addTask { [weak self] in
                        guard let self else { return task }
                        let handle = Task<AgentTask, Never> {
                            await self.runSubAgent(
                                task: task,
                                toolExecutor: toolExecutor,
                                llmService: llmService,
                                apiKey: apiKey,
                                model: model,
                                toolDefinitions: toolDefs
                            )
                        }
                        self.lock.withLock { self.taskHandles[task.id] = handle }
                        return await handle.value
                    }
                }

                var results: [AgentTask] = []
                for await completed in group {
                    results.append(completed)
                    self.lock.withLock { _ = self.taskHandles.removeValue(forKey: completed.id) }

                    // Launch next task from the queue
                    if let task = taskQueue.popFirst() {
                        group.addTask { [weak self] in
                            guard let self else { return task }
                            let handle = Task<AgentTask, Never> {
                                await self.runSubAgent(
                                    task: task,
                                    toolExecutor: toolExecutor,
                                    llmService: llmService,
                                    apiKey: apiKey,
                                    model: model,
                                    toolDefinitions: toolDefs
                                )
                            }
                            self.lock.withLock { self.taskHandles[task.id] = handle }
                            return await handle.value
                        }
                    }
                }

                return results
            }
        }

        lock.withLock { groupTask = parentTask }

        let results = await parentTask.value

        lock.withLock {
            groupTask = nil
            taskHandles.removeAll()
        }
        updateActiveTasks(results)

        return results
    }

    // MARK: - Cancel

    /// Cancel a single task by its ID.
    func cancelTask(id: String) {
        lock.withLock {
            taskHandles[id]?.cancel()
            taskHandles.removeValue(forKey: id)
        }
        updateTaskStatus(id: id, status: .cancelled, completedAt: Date())
        logger.info("Cancelled task \(id)")
    }

    /// Cancel every running task.
    func cancelAll() {
        lock.withLock {
            groupTask?.cancel()
            groupTask = nil
            for (_, handle) in taskHandles { handle.cancel() }
            taskHandles.removeAll()
        }

        let now = Date()
        var snapshot = activeTasks
        for i in snapshot.indices {
            switch snapshot[i].status {
            case .pending, .running:
                snapshot[i].status = .cancelled
                snapshot[i].completedAt = now
            default:
                break
            }
        }
        updateActiveTasks(snapshot)
        logger.info("Cancelled all tasks")
    }

    // MARK: - Sub-Agent Loop

    /// Runs one sub-agent: sends the goal to the LLM, executes tool calls,
    /// feeds results back, and repeats until the LLM finishes or the step
    /// budget is exhausted.
    private func runSubAgent(
        task: AgentTask,
        toolExecutor: ToolExecutor,
        llmService: LLMService,
        apiKey: String,
        model: String,
        toolDefinitions: [[String: Any]]
    ) async -> AgentTask {
        var current = task
        current.status = .running(step: 0, total: maxStepsPerTask)
        current.startedAt = Date()
        updateTaskInPlace(current)

        let systemPrompt = """
        You are an autonomous agent executing a single task. \
        Use the provided tools to accomplish the goal. \
        When the task is complete, reply with a final summary (no tool calls). \
        Be concise and efficient.
        """

        var messages: [LLMMessage] = [
            .user("Goal: \(task.description)\n\nBegin working on this task now.")
        ]

        var stepCount = 0
        var lastContent: String?

        while stepCount < maxStepsPerTask {
            if Task.isCancelled {
                current.status = .cancelled
                current.completedAt = Date()
                updateTaskInPlace(current)
                return current
            }

            stepCount += 1
            current.status = .running(step: stepCount, total: maxStepsPerTask)
            updateTaskInPlace(current)

            logger.info("Task \(task.id) — step \(stepCount)/\(self.maxStepsPerTask)")

            // Call the LLM
            let response: LLMResponse
            do {
                response = try await llmService.streamChat(
                    messages: messages,
                    tools: toolDefinitions,
                    model: model,
                    apiKey: apiKey,
                    systemPrompt: systemPrompt,
                    onChunk: { _ in } // Sub-agents run silently
                )
            } catch {
                if Task.isCancelled {
                    current.status = .cancelled
                } else {
                    current.status = .failed("LLM error: \(error.localizedDescription)")
                    logger.error("Task \(task.id) LLM error: \(error.localizedDescription)")
                }
                current.completedAt = Date()
                updateTaskInPlace(current)
                return current
            }

            // Capture any text content
            if let content = response.content, !content.isEmpty {
                lastContent = content
            }

            // If there are tool calls, execute them and continue the loop
            guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                // No tool calls — the agent is done (or the model stopped)
                break
            }

            // Append the assistant's message (with tool calls) to the conversation
            messages.append(.assistant(response.content ?? "", toolCalls: response.toolCalls))

            // Execute each tool call and feed results back
            for call in toolCalls {
                if Task.isCancelled {
                    current.status = .cancelled
                    current.completedAt = Date()
                    updateTaskInPlace(current)
                    return current
                }

                let args = toolExecutor.parseArguments(call.function.arguments)
                let result = await executeWithRetry(
                    toolName: call.function.name,
                    arguments: args,
                    toolExecutor: toolExecutor
                )

                messages.append(.tool(callId: call.id, content: result.output))

                logger.info("Task \(task.id) tool \(call.function.name) → \(result.isError ? "ERROR" : "OK")")
            }
        }

        // Finalise
        if Task.isCancelled {
            current.status = .cancelled
        } else {
            current.status = .completed
            current.result = lastContent ?? "(task completed with no final summary)"
        }
        current.completedAt = Date()
        updateTaskInPlace(current)

        logger.info("Task \(task.id) finished — \(current.status)")
        return current
    }

    // MARK: - Tool Execution with Retry

    private func executeWithRetry(
        toolName: String,
        arguments: [String: Any],
        toolExecutor: ToolExecutor
    ) async -> ToolResult {
        var lastResult = ToolResult("", isError: true)

        for attempt in 0...maxRetriesPerStep {
            if Task.isCancelled {
                return ToolResult("Cancelled", isError: true)
            }

            lastResult = await toolExecutor.executeTool(name: toolName, arguments: arguments)

            if !lastResult.isError {
                return lastResult
            }

            if attempt < maxRetriesPerStep {
                logger.info("Retrying tool \(toolName) (attempt \(attempt + 2))")
                // Brief back-off before retry
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        return lastResult
    }

    // MARK: - State Updates

    /// Replace the entire activeTasks array (posts to MainActor).
    private func updateActiveTasks(_ tasks: [AgentTask]) {
        let sorted = tasks.sorted { $0.startedAt < $1.startedAt }
        Task { @MainActor [sorted] in
            self.activeTasks = sorted
        }
    }

    /// Update a single task's entry in the activeTasks array.
    private func updateTaskInPlace(_ task: AgentTask) {
        Task { @MainActor [task] in
            if let idx = self.activeTasks.firstIndex(where: { $0.id == task.id }) {
                self.activeTasks[idx] = task
            } else {
                self.activeTasks.append(task)
            }
        }
    }

    /// Update status and completion date for a single task.
    private func updateTaskStatus(id: String, status: AgentTask.TaskStatus, completedAt: Date?) {
        Task { @MainActor in
            if let idx = self.activeTasks.firstIndex(where: { $0.id == id }) {
                self.activeTasks[idx].status = status
                self.activeTasks[idx].completedAt = completedAt
            }
        }
    }

    // MARK: - Formatting

    /// Format results for display or LLM context injection.
    static func formatResults(_ tasks: [AgentTask]) -> String {
        var text = "Parallel execution results (\(tasks.count) tasks):\n"
        for task in tasks {
            let statusLabel: String
            switch task.status {
            case .pending:                statusLabel = "PENDING"
            case .running(let s, let t):  statusLabel = "RUNNING (\(s)/\(t))"
            case .completed:              statusLabel = "COMPLETED"
            case .failed(let msg):        statusLabel = "FAILED: \(msg)"
            case .cancelled:              statusLabel = "CANCELLED"
            }

            text += "\n[\(task.id)] \(statusLabel)\n"
            text += "  Goal: \(task.description)\n"
            if let result = task.result {
                let preview = String(result.prefix(500))
                text += "  Result: \(preview)\n"
            }
            if let duration = task.completedAt?.timeIntervalSince(task.startedAt) {
                text += "  Duration: \(String(format: "%.1fs", duration))\n"
            }
        }
        return text
    }
}
