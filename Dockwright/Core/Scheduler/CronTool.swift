import Foundation
import os

/// LLM tool for scheduling: create_reminder, create_cron, list_jobs, delete_job.
struct CronTool: Tool, @unchecked Sendable {
    let name = "scheduler"
    let description = """
        Schedule reminders and recurring cron jobs. Actions:
        - create_reminder: Set a one-time reminder. Params: message (string), delay (string like "2 minutes", "1 hour", "30 seconds").
        - create_cron: Create a recurring job. Params: name (string), schedule (cron expression or natural language like "every 5 minutes", "daily at 9am"), action_type ("notification", "tool", or "message"), action_body (string: notification body, tool name, or message text), action_args (optional JSON object for tool arguments).
        - list_jobs: List all scheduled jobs and reminders. No params needed.
        - delete_job: Delete a job by ID. Params: id (string).
        """

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "The action to perform: create_reminder, create_cron, list_jobs, or delete_job",
            "enum": ["create_reminder", "create_cron", "list_jobs", "delete_job"]
        ] as [String: Any],
        "message": [
            "type": "string",
            "description": "Reminder message (for create_reminder)",
            "optional": true
        ] as [String: Any],
        "delay": [
            "type": "string",
            "description": "How long until the reminder fires, e.g. '2 minutes', '1 hour', '30 seconds' (for create_reminder)",
            "optional": true
        ] as [String: Any],
        "name": [
            "type": "string",
            "description": "Job name (for create_cron)",
            "optional": true
        ] as [String: Any],
        "schedule": [
            "type": "string",
            "description": "Cron expression or natural language schedule (for create_cron)",
            "optional": true
        ] as [String: Any],
        "action_type": [
            "type": "string",
            "description": "Action type: notification, tool, or message (for create_cron)",
            "optional": true
        ] as [String: Any],
        "action_body": [
            "type": "string",
            "description": "Action body: notification text, tool name, or message (for create_cron)",
            "optional": true
        ] as [String: Any],
        "action_args": [
            "type": "object",
            "description": "Optional arguments for tool action (for create_cron)",
            "optional": true
        ] as [String: Any],
        "id": [
            "type": "string",
            "description": "Job ID to delete (for delete_job)",
            "optional": true
        ] as [String: Any]
    ]

    private let store: CronStore
    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "CronTool")

    init(store: CronStore) {
        self.store = store
    }

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing required parameter: action", isError: true)
        }

        switch action {
        case "create_reminder":
            return createReminder(arguments)
        case "create_cron":
            return createCron(arguments)
        case "list_jobs":
            return listJobs()
        case "delete_job":
            return deleteJob(arguments)
        default:
            return ToolResult("Unknown action: \(action). Use: create_reminder, create_cron, list_jobs, or delete_job.", isError: true)
        }
    }

    // MARK: - Actions

    private func createReminder(_ args: [String: Any]) -> ToolResult {
        guard let message = args["message"] as? String, !message.isEmpty else {
            return ToolResult("Missing required parameter: message", isError: true)
        }
        guard let delay = args["delay"] as? String, !delay.isEmpty else {
            return ToolResult("Missing required parameter: delay", isError: true)
        }

        guard let job = ReminderService.setReminder(message: message, delay: delay, store: store) else {
            return ToolResult("Could not parse delay '\(delay)'. Use formats like: '2 minutes', '1 hour', '30 seconds'.", isError: true)
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium

        return ToolResult("Reminder set: \"\(message)\" will fire \(job.nextRunFormatted) (at \(formatter.string(from: job.nextRun ?? Date()))). Job ID: \(job.id)")
    }

    private func createCron(_ args: [String: Any]) -> ToolResult {
        guard let jobName = args["name"] as? String, !jobName.isEmpty else {
            return ToolResult("Missing required parameter: name", isError: true)
        }
        guard let scheduleInput = args["schedule"] as? String, !scheduleInput.isEmpty else {
            return ToolResult("Missing required parameter: schedule", isError: true)
        }
        let actionType = args["action_type"] as? String ?? "notification"
        let actionBody = args["action_body"] as? String ?? jobName

        // Resolve schedule: try natural language first, then treat as raw cron
        let cronExpr: String
        if let natural = CronEngine.naturalLanguageToCron(scheduleInput) {
            cronExpr = natural
        } else {
            cronExpr = scheduleInput
        }

        // Validate
        switch CronEngine.validate(cronExpr) {
        case .failure(let error):
            return ToolResult("Invalid cron expression '\(cronExpr)': \(error.localizedDescription)", isError: true)
        case .success(let expr):
            // Build action
            let cronAction: CronAction
            switch actionType {
            case "tool":
                var toolArgs: [String: String] = [:]
                if let argsDict = args["action_args"] as? [String: Any] {
                    for (k, v) in argsDict {
                        toolArgs[k] = "\(v)"
                    }
                }
                cronAction = .tool(name: actionBody, arguments: toolArgs)
            case "message":
                cronAction = .message(text: actionBody)
            default:
                cronAction = .notification(title: "Dockwright: \(jobName)", body: actionBody)
            }

            let nextRun = expr.nextOccurrence(after: Date())

            let job = CronJob(
                name: jobName,
                schedule: cronExpr,
                isOneShot: false,
                action: cronAction,
                nextRun: nextRun
            )
            store.add(job)

            let nextStr = nextRun.map { date in
                let f = DateFormatter()
                f.dateStyle = .medium
                f.timeStyle = .short
                return f.string(from: date)
            } ?? "unknown"

            return ToolResult("Cron job created: \"\(jobName)\" with schedule '\(cronExpr)'. Next run: \(nextStr). Job ID: \(job.id)")
        }
    }

    private func listJobs() -> ToolResult {
        let jobs = store.listAll()
        if jobs.isEmpty {
            return ToolResult("No scheduled jobs or reminders.")
        }

        var lines: [String] = ["Scheduled jobs (\(jobs.count)):"]
        for job in jobs {
            let type = job.isOneShot ? "Reminder" : "Cron"
            let status = job.enabled ? "enabled" : "disabled"
            let next = job.nextRunFormatted
            lines.append("  [\(type)] \(job.name) | id: \(job.id) | schedule: \(job.schedule) | \(status) | runs: \(job.runCount) | next: \(next)")
        }
        return ToolResult(lines.joined(separator: "\n"))
    }

    private func deleteJob(_ args: [String: Any]) -> ToolResult {
        guard let jobId = args["id"] as? String, !jobId.isEmpty else {
            return ToolResult("Missing required parameter: id", isError: true)
        }

        if let job = store.get(jobId) {
            _ = store.remove(jobId)
            return ToolResult("Deleted job: \"\(job.name)\" (\(jobId))")
        } else {
            return ToolResult("No job found with ID: \(jobId)", isError: true)
        }
    }
}
