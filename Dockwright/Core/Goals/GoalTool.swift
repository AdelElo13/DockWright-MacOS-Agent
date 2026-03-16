import Foundation
import os

/// LLM tool for managing goals, milestones, and daily actions.
/// This is the core of the brain-dump workflow: users describe what they want to
/// achieve, and the AI breaks it down into actionable steps.
struct GoalTool: Tool, @unchecked Sendable {
    nonisolated let name = "goals"
    nonisolated let description = """
        Manage personal goals, milestones, and daily actions. Actions:
        - add_goal: Create a new goal. Params: title, description, category (health/career/learning/personal/financial), target_date (optional, ISO-8601).
        - list_goals: List all active goals with progress. No required params.
        - add_milestone: Add a milestone to a goal. Params: goal_id, title.
        - complete_milestone: Mark a milestone done. Params: goal_id, milestone_id.
        - complete_goal: Mark a goal done. Params: goal_id.
        - daily_actions: Get today's pending action items. No required params.
        - add_daily_action: Add a daily action for a goal. Params: goal_id, task, priority (1-5).
        - complete_action: Mark a daily action done. Params: action_id.
        - brain_dump: Accept free-form text and parse into goals/actions. Params: text.
        - progress_report: Summary of all goals with completion percentages. No required params.
        """

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "The action to perform",
            "enum": [
                "add_goal", "list_goals", "add_milestone", "complete_milestone",
                "complete_goal", "daily_actions", "add_daily_action", "complete_action",
                "brain_dump", "progress_report"
            ]
        ] as [String: Any],
        "title": [
            "type": "string",
            "description": "Title for a goal or milestone",
            "optional": true
        ] as [String: Any],
        "description": [
            "type": "string",
            "description": "Description for a new goal",
            "optional": true
        ] as [String: Any],
        "category": [
            "type": "string",
            "description": "Goal category: health, career, learning, personal, financial",
            "optional": true
        ] as [String: Any],
        "target_date": [
            "type": "string",
            "description": "Target completion date in ISO-8601 format (e.g. 2025-12-31)",
            "optional": true
        ] as [String: Any],
        "goal_id": [
            "type": "string",
            "description": "ID of the goal to operate on",
            "optional": true
        ] as [String: Any],
        "milestone_id": [
            "type": "string",
            "description": "ID of the milestone to complete",
            "optional": true
        ] as [String: Any],
        "action_id": [
            "type": "string",
            "description": "ID of the daily action to complete",
            "optional": true
        ] as [String: Any],
        "task": [
            "type": "string",
            "description": "Task description for a daily action",
            "optional": true
        ] as [String: Any],
        "priority": [
            "type": "integer",
            "description": "Priority level 1-5 (5 = highest) for daily actions",
            "optional": true
        ] as [String: Any],
        "text": [
            "type": "string",
            "description": "Free-form text for brain_dump",
            "optional": true
        ] as [String: Any]
    ]

    private let store: GoalStore

    init(store: GoalStore) {
        self.store = store
    }

    nonisolated func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Error: 'action' parameter is required.", isError: true)
        }

        switch action {
        case "add_goal":
            return addGoal(arguments)
        case "list_goals":
            return listGoals()
        case "add_milestone":
            return addMilestone(arguments)
        case "complete_milestone":
            return completeMilestone(arguments)
        case "complete_goal":
            return completeGoal(arguments)
        case "daily_actions":
            return getDailyActions()
        case "add_daily_action":
            return addDailyAction(arguments)
        case "complete_action":
            return completeAction(arguments)
        case "brain_dump":
            return brainDump(arguments)
        case "progress_report":
            return progressReport()
        default:
            return ToolResult("Unknown action '\(action)'. See tool description for valid actions.", isError: true)
        }
    }

    // MARK: - Action Implementations

    private func addGoal(_ args: [String: Any]) -> ToolResult {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return ToolResult("Error: 'title' is required for add_goal.", isError: true)
        }
        let description = args["description"] as? String ?? ""
        let category = args["category"] as? String ?? "personal"

        var targetDate: Date?
        if let dateStr = args["target_date"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            targetDate = formatter.date(from: dateStr)
            if targetDate == nil {
                // Try with dashes-only format
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                df.locale = Locale(identifier: "en_US_POSIX")
                targetDate = df.date(from: dateStr)
            }
        }

        do {
            let goal = try store.addGoal(title: title, description: description, category: category, targetDate: targetDate)
            var output = "Created goal: \(goal.title) [\(goal.id)]\n"
            output += "Category: \(goal.category)\n"
            if let target = goal.targetDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                output += "Target: \(formatter.string(from: target))\n"
            }
            if !description.isEmpty {
                output += "Description: \(description)\n"
            }
            return ToolResult(output)
        } catch {
            return ToolResult("Error creating goal: \(error.localizedDescription)", isError: true)
        }
    }

    private func listGoals() -> ToolResult {
        let goals = store.listGoals(activeOnly: true)
        if goals.isEmpty {
            return ToolResult("No active goals. Use 'add_goal' to create one, or 'brain_dump' to brain-dump your aspirations.")
        }

        var output = "Active Goals (\(goals.count)):\n\n"
        for goal in goals {
            output += "[\(goal.category.uppercased())] \(goal.title) (\(goal.id))\n"
            output += "  Progress: \(goal.completionPercentage)%"
            if let target = goal.targetDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                output += " | Target: \(formatter.string(from: target))"
            }
            output += "\n"
            if !goal.description.isEmpty {
                output += "  \(goal.description)\n"
            }
            if !goal.milestones.isEmpty {
                for ms in goal.milestones {
                    let check = ms.isCompleted ? "[x]" : "[ ]"
                    output += "    \(check) \(ms.title) (\(ms.id))\n"
                }
            }
            output += "\n"
        }
        return ToolResult(output)
    }

    private func addMilestone(_ args: [String: Any]) -> ToolResult {
        guard let goalId = args["goal_id"] as? String else {
            return ToolResult("Error: 'goal_id' is required for add_milestone.", isError: true)
        }
        guard let title = args["title"] as? String, !title.isEmpty else {
            return ToolResult("Error: 'title' is required for add_milestone.", isError: true)
        }

        do {
            guard let milestone = try store.addMilestone(goalId: goalId, title: title) else {
                return ToolResult("Error: goal '\(goalId)' not found.", isError: true)
            }
            return ToolResult("Added milestone: \(milestone.title) [\(milestone.id)] to goal \(goalId)")
        } catch {
            return ToolResult("Error adding milestone: \(error.localizedDescription)", isError: true)
        }
    }

    private func completeMilestone(_ args: [String: Any]) -> ToolResult {
        guard let goalId = args["goal_id"] as? String else {
            return ToolResult("Error: 'goal_id' is required for complete_milestone.", isError: true)
        }
        guard let milestoneId = args["milestone_id"] as? String else {
            return ToolResult("Error: 'milestone_id' is required for complete_milestone.", isError: true)
        }

        do {
            guard let ms = try store.completeMilestone(goalId: goalId, milestoneId: milestoneId) else {
                return ToolResult("Error: goal '\(goalId)' or milestone '\(milestoneId)' not found.", isError: true)
            }
            let goal = store.getGoal(id: goalId)
            var output = "Completed milestone: \(ms.title)\n"
            if let goal {
                output += "Goal progress: \(goal.completionPercentage)%"
            }
            return ToolResult(output)
        } catch {
            return ToolResult("Error completing milestone: \(error.localizedDescription)", isError: true)
        }
    }

    private func completeGoal(_ args: [String: Any]) -> ToolResult {
        guard let goalId = args["goal_id"] as? String else {
            return ToolResult("Error: 'goal_id' is required for complete_goal.", isError: true)
        }

        do {
            guard let goal = try store.completeGoal(id: goalId) else {
                return ToolResult("Error: goal '\(goalId)' not found.", isError: true)
            }
            return ToolResult("Goal completed: \(goal.title). Congratulations!")
        } catch {
            return ToolResult("Error completing goal: \(error.localizedDescription)", isError: true)
        }
    }

    private func getDailyActions() -> ToolResult {
        let pending = store.todaysPendingActions()
        if pending.isEmpty {
            let all = store.todaysActions()
            if all.isEmpty {
                return ToolResult("No daily actions for today. Use 'add_daily_action' to add tasks, or 'brain_dump' to generate them from your goals.")
            } else {
                return ToolResult("All \(all.count) action(s) for today are completed. Great job!")
            }
        }

        var output = "Today's Pending Actions (\(pending.count)):\n\n"
        for action in pending {
            let goalName = store.getGoal(id: action.goalId)?.title ?? "Unknown goal"
            output += "P\(action.priority): \(action.task) [\(action.id)]\n"
            output += "  Goal: \(goalName)\n\n"
        }
        return ToolResult(output)
    }

    private func addDailyAction(_ args: [String: Any]) -> ToolResult {
        guard let goalId = args["goal_id"] as? String else {
            return ToolResult("Error: 'goal_id' is required for add_daily_action.", isError: true)
        }
        guard let task = args["task"] as? String, !task.isEmpty else {
            return ToolResult("Error: 'task' is required for add_daily_action.", isError: true)
        }

        // Verify goal exists
        guard store.getGoal(id: goalId) != nil else {
            return ToolResult("Error: goal '\(goalId)' not found.", isError: true)
        }

        let priority: Int
        if let p = args["priority"] as? Int {
            priority = p
        } else if let p = args["priority"] as? Double {
            priority = Int(p)
        } else {
            priority = 3
        }

        do {
            let action = try store.addDailyAction(goalId: goalId, task: task, priority: priority)
            return ToolResult("Added daily action: \(action.task) [P\(action.priority)] (\(action.id))")
        } catch {
            return ToolResult("Error adding daily action: \(error.localizedDescription)", isError: true)
        }
    }

    private func completeAction(_ args: [String: Any]) -> ToolResult {
        guard let actionId = args["action_id"] as? String else {
            return ToolResult("Error: 'action_id' is required for complete_action.", isError: true)
        }

        do {
            guard let action = try store.completeAction(id: actionId) else {
                return ToolResult("Error: action '\(actionId)' not found.", isError: true)
            }
            let pending = store.todaysPendingActions()
            var output = "Completed: \(action.task)\n"
            if pending.isEmpty {
                output += "All actions for today are done! Great work."
            } else {
                output += "\(pending.count) action(s) remaining today."
            }
            return ToolResult(output)
        } catch {
            return ToolResult("Error completing action: \(error.localizedDescription)", isError: true)
        }
    }

    private func brainDump(_ args: [String: Any]) -> ToolResult {
        guard let text = args["text"] as? String, !text.isEmpty else {
            return ToolResult("Error: 'text' is required for brain_dump. Just dump everything on your mind!", isError: true)
        }

        // Parse the free-form text into goals and actions.
        // Split by sentences/lines, group related items, create goals.
        let lines = text
            .components(separatedBy: CharacterSet.newlines)
            .flatMap { $0.components(separatedBy: ". ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var createdGoals: [Goal] = []
        var createdActions: [DailyAction] = []

        for line in lines {
            let lower = line.lowercased()

            // Infer category from keywords
            let category: String
            if lower.contains("exercise") || lower.contains("health") || lower.contains("gym") ||
               lower.contains("diet") || lower.contains("sleep") || lower.contains("run") ||
               lower.contains("weight") || lower.contains("workout") || lower.contains("meditat") {
                category = "health"
            } else if lower.contains("job") || lower.contains("career") || lower.contains("work") ||
                      lower.contains("promotion") || lower.contains("resume") || lower.contains("interview") ||
                      lower.contains("project") || lower.contains("business") {
                category = "career"
            } else if lower.contains("learn") || lower.contains("study") || lower.contains("read") ||
                      lower.contains("course") || lower.contains("book") || lower.contains("skill") ||
                      lower.contains("language") || lower.contains("practice") {
                category = "learning"
            } else if lower.contains("save") || lower.contains("money") || lower.contains("invest") ||
                      lower.contains("budget") || lower.contains("financial") || lower.contains("debt") ||
                      lower.contains("income") || lower.contains("retire") {
                category = "financial"
            } else {
                category = "personal"
            }

            // Determine if this is an actionable task (short, verb-like) or a goal (aspirational)
            let isActionable = line.count < 80 && (
                lower.hasPrefix("do ") || lower.hasPrefix("go ") || lower.hasPrefix("buy ") ||
                lower.hasPrefix("call ") || lower.hasPrefix("email ") || lower.hasPrefix("finish ") ||
                lower.hasPrefix("start ") || lower.hasPrefix("check ") || lower.hasPrefix("review ") ||
                lower.hasPrefix("send ") || lower.hasPrefix("write ") || lower.hasPrefix("make ") ||
                lower.hasPrefix("set up ") || lower.hasPrefix("schedule ")
            )

            if isActionable {
                // If we have a recent goal in the same category, attach it
                if let matchingGoal = createdGoals.last(where: { $0.category == category }) {
                    do {
                        let action = try store.addDailyAction(goalId: matchingGoal.id, task: line, priority: 3)
                        createdActions.append(action)
                    } catch {
                        // Silently skip failed action creation
                    }
                } else {
                    // Create a generic goal and attach the action
                    do {
                        let goal = try store.addGoal(title: line.capitalized, description: "From brain dump", category: category)
                        createdGoals.append(goal)
                    } catch {
                        // Silently skip
                    }
                }
            } else {
                // Create as a goal
                do {
                    let goal = try store.addGoal(title: line, description: "From brain dump", category: category)
                    createdGoals.append(goal)
                } catch {
                    // Silently skip
                }
            }
        }

        if createdGoals.isEmpty && createdActions.isEmpty {
            return ToolResult("Could not parse any goals or actions from the text. Try listing specific goals or tasks, one per line.")
        }

        var output = "Brain dump processed!\n\n"
        if !createdGoals.isEmpty {
            output += "Created \(createdGoals.count) goal(s):\n"
            for g in createdGoals {
                output += "  [\(g.category.uppercased())] \(g.title) (\(g.id))\n"
            }
        }
        if !createdActions.isEmpty {
            output += "\nCreated \(createdActions.count) action(s):\n"
            for a in createdActions {
                output += "  P\(a.priority): \(a.task) (\(a.id))\n"
            }
        }
        output += "\nTip: Use 'add_milestone' to break goals into steps, and 'add_daily_action' to create today's tasks."
        return ToolResult(output)
    }

    private func progressReport() -> ToolResult {
        let report = store.progressReport()
        return ToolResult(report)
    }
}
