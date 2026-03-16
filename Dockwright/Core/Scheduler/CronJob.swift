import Foundation

// MARK: - Cron Action

/// What a cron job does when triggered.
enum CronAction: Codable, Sendable, Equatable {
    case notification(title: String, body: String)
    case tool(name: String, arguments: [String: String])
    case message(text: String)

    /// Human-readable summary for display.
    var summary: String {
        switch self {
        case .notification(let title, let body):
            return "Notification: \(title) — \(body)"
        case .tool(let name, let arguments):
            return "Tool: \(name)(\(arguments.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")))"
        case .message(let text):
            return "Message: \(text)"
        }
    }
}

// MARK: - Cron Job

/// A single scheduled job — either recurring (cron expression) or one-shot (reminder).
struct CronJob: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var schedule: String          // 5-field cron expression OR ISO 8601 datetime for one-shots
    var isOneShot: Bool           // true = reminder (delete after firing), false = recurring
    var action: CronAction
    var enabled: Bool
    var lastRun: Date?
    var nextRun: Date?
    var runCount: Int
    var createdAt: Date

    init(
        id: String = UUID().uuidString.prefix(8).lowercased().description,
        name: String,
        schedule: String,
        isOneShot: Bool,
        action: CronAction,
        enabled: Bool = true,
        lastRun: Date? = nil,
        nextRun: Date? = nil,
        runCount: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.schedule = schedule
        self.isOneShot = isOneShot
        self.action = action
        self.enabled = enabled
        self.lastRun = lastRun
        self.nextRun = nextRun
        self.runCount = runCount
        self.createdAt = createdAt
    }

    /// Whether this job is a reminder (one-shot with future fire date).
    var isReminder: Bool { isOneShot }

    /// Formatted next-run string for UI.
    var nextRunFormatted: String {
        guard let next = nextRun else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: next, relativeTo: Date())
    }
}
