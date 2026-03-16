import Foundation
import os

// MARK: - Models

nonisolated struct Goal: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var title: String
    var description: String
    var category: String
    var milestones: [Milestone]
    var isCompleted: Bool
    var createdAt: Date
    var targetDate: Date?

    init(title: String, description: String, category: String, targetDate: Date? = nil) {
        self.id = String(UUID().uuidString.prefix(8))
        self.title = title
        self.description = description
        self.category = Self.normalizeCategory(category)
        self.milestones = []
        self.isCompleted = false
        self.createdAt = Date()
        self.targetDate = targetDate
    }

    static func normalizeCategory(_ raw: String) -> String {
        let valid = ["health", "career", "learning", "personal", "financial"]
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        return valid.contains(lower) ? lower : "personal"
    }

    var completionPercentage: Int {
        guard !milestones.isEmpty else { return isCompleted ? 100 : 0 }
        let done = milestones.filter(\.isCompleted).count
        return Int((Double(done) / Double(milestones.count)) * 100)
    }
}

nonisolated struct Milestone: Codable, Sendable, Equatable {
    let id: String
    var title: String
    var isCompleted: Bool
    var completedAt: Date?

    init(title: String) {
        self.id = String(UUID().uuidString.prefix(8))
        self.title = title
        self.isCompleted = false
        self.completedAt = nil
    }
}

nonisolated struct DailyAction: Codable, Sendable, Equatable {
    let id: String
    var goalId: String
    var task: String
    var priority: Int
    var isCompleted: Bool
    var generatedAt: Date

    init(goalId: String, task: String, priority: Int) {
        self.id = String(UUID().uuidString.prefix(8))
        self.goalId = goalId
        self.task = task
        self.priority = max(1, min(5, priority))
        self.isCompleted = false
        self.generatedAt = Date()
    }
}

// MARK: - GoalStore

nonisolated final class GoalStore: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "GoalStore")
    private let queue = DispatchQueue(label: "com.Aatje.Dockwright.GoalStore", qos: .utility)
    private let baseDirectory: String
    private let goalsPath: String
    private let actionsPath: String

    private var goals: [Goal] = []
    private var dailyActions: [DailyAction] = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        self.baseDirectory = NSHomeDirectory() + "/.dockwright"
        self.goalsPath = baseDirectory + "/goals.json"
        self.actionsPath = baseDirectory + "/daily_actions.json"
        loadAll()
    }

    // MARK: - Persistence

    private func loadAll() {
        queue.sync {
            let fm = FileManager.default
            try? fm.createDirectory(atPath: baseDirectory, withIntermediateDirectories: true)

            if let data = fm.contents(atPath: goalsPath) {
                do {
                    goals = try decoder.decode([Goal].self, from: data)
                } catch {
                    logger.error("Failed to decode goals: \(error.localizedDescription)")
                    goals = []
                }
            }

            if let data = fm.contents(atPath: actionsPath) {
                do {
                    dailyActions = try decoder.decode([DailyAction].self, from: data)
                } catch {
                    logger.error("Failed to decode daily actions: \(error.localizedDescription)")
                    dailyActions = []
                }
            }
        }
    }

    private func saveGoals() throws {
        let data = try encoder.encode(goals)
        try atomicWrite(data: data, to: goalsPath)
    }

    private func saveActions() throws {
        let data = try encoder.encode(dailyActions)
        try atomicWrite(data: data, to: actionsPath)
    }

    private func atomicWrite(data: Data, to path: String) throws {
        let tmpPath = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
        try fm.moveItem(atPath: tmpPath, toPath: path)
    }

    // MARK: - Goal CRUD

    func addGoal(title: String, description: String, category: String, targetDate: Date? = nil) throws -> Goal {
        return try queue.sync {
            let goal = Goal(title: title, description: description, category: category, targetDate: targetDate)
            goals.append(goal)
            try saveGoals()
            logger.info("Added goal: \(goal.title) [\(goal.id)]")
            return goal
        }
    }

    func listGoals(activeOnly: Bool = true) -> [Goal] {
        queue.sync {
            activeOnly ? goals.filter { !$0.isCompleted } : goals
        }
    }

    func getGoal(id: String) -> Goal? {
        queue.sync {
            goals.first { $0.id == id }
        }
    }

    func completeGoal(id: String) throws -> Goal? {
        return try queue.sync {
            guard let index = goals.firstIndex(where: { $0.id == id }) else { return nil }
            goals[index].isCompleted = true
            try saveGoals()
            logger.info("Completed goal: \(self.goals[index].title)")
            return goals[index]
        }
    }

    func deleteGoal(id: String) throws -> Bool {
        return try queue.sync {
            guard let index = goals.firstIndex(where: { $0.id == id }) else { return false }
            let title = goals[index].title
            goals.remove(at: index)
            try saveGoals()
            logger.info("Deleted goal: \(title)")
            return true
        }
    }

    // MARK: - Milestone CRUD

    func addMilestone(goalId: String, title: String) throws -> Milestone? {
        return try queue.sync {
            guard let index = goals.firstIndex(where: { $0.id == goalId }) else { return nil }
            let milestone = Milestone(title: title)
            goals[index].milestones.append(milestone)
            try saveGoals()
            logger.info("Added milestone '\(title)' to goal \(goalId)")
            return milestone
        }
    }

    func completeMilestone(goalId: String, milestoneId: String) throws -> Milestone? {
        return try queue.sync {
            guard let goalIdx = goals.firstIndex(where: { $0.id == goalId }),
                  let msIdx = goals[goalIdx].milestones.firstIndex(where: { $0.id == milestoneId }) else {
                return nil
            }
            goals[goalIdx].milestones[msIdx].isCompleted = true
            goals[goalIdx].milestones[msIdx].completedAt = Date()
            try saveGoals()
            logger.info("Completed milestone: \(self.goals[goalIdx].milestones[msIdx].title)")
            return goals[goalIdx].milestones[msIdx]
        }
    }

    // MARK: - Daily Actions

    func addDailyAction(goalId: String, task: String, priority: Int) throws -> DailyAction {
        return try queue.sync {
            let action = DailyAction(goalId: goalId, task: task, priority: priority)
            dailyActions.append(action)
            try saveActions()
            logger.info("Added daily action: \(task) [priority \(priority)]")
            return action
        }
    }

    func todaysPendingActions() -> [DailyAction] {
        queue.sync {
            let calendar = Calendar.current
            return dailyActions
                .filter { !$0.isCompleted && calendar.isDateInToday($0.generatedAt) }
                .sorted { $0.priority > $1.priority }
        }
    }

    func todaysActions() -> [DailyAction] {
        queue.sync {
            let calendar = Calendar.current
            return dailyActions
                .filter { calendar.isDateInToday($0.generatedAt) }
                .sorted { $0.priority > $1.priority }
        }
    }

    func completeAction(id: String) throws -> DailyAction? {
        return try queue.sync {
            guard let index = dailyActions.firstIndex(where: { $0.id == id }) else { return nil }
            dailyActions[index].isCompleted = true
            try saveActions()
            logger.info("Completed action: \(self.dailyActions[index].task)")
            return dailyActions[index]
        }
    }

    // MARK: - Reporting

    func progressReport() -> String {
        queue.sync {
            let active = goals.filter { !$0.isCompleted }
            let completed = goals.filter { $0.isCompleted }

            var report = "Goal Progress Report\n"
            report += "====================\n\n"
            report += "Active goals: \(active.count) | Completed: \(completed.count)\n\n"

            for goal in active {
                report += "[\(goal.category.uppercased())] \(goal.title) (\(goal.id))\n"
                report += "  Progress: \(goal.completionPercentage)%"
                if let target = goal.targetDate {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    report += " | Target: \(formatter.string(from: target))"
                }
                report += "\n"
                if !goal.milestones.isEmpty {
                    for ms in goal.milestones {
                        let check = ms.isCompleted ? "[x]" : "[ ]"
                        report += "    \(check) \(ms.title)\n"
                    }
                }
                report += "\n"
            }

            let calendar = Calendar.current
            let todaysActions = dailyActions.filter { calendar.isDateInToday($0.generatedAt) }
            let doneToday = todaysActions.filter(\.isCompleted).count

            if !todaysActions.isEmpty {
                report += "Today's Actions: \(doneToday)/\(todaysActions.count) completed\n"
                for action in todaysActions.sorted(by: { $0.priority > $1.priority }) {
                    let check = action.isCompleted ? "[x]" : "[ ]"
                    let goalName = goals.first { $0.id == action.goalId }?.title ?? "Unknown"
                    report += "  \(check) P\(action.priority): \(action.task) (\(goalName))\n"
                }
            }

            return report
        }
    }
}
