import Foundation
import EventKit

/// LLM tool for interacting with Apple Reminders via EventKit.
/// Actions: create_reminder, complete_reminder, list_reminders, delete_reminder.
final class RemindersTool: @unchecked Sendable {
    private let eventStore = EKEventStore()
    private var authorized = false

    nonisolated init() {}

    private func ensureAccess() async throws {
        guard !authorized else { return }
        let granted = try await eventStore.requestFullAccessToReminders()
        guard granted else {
            throw ReminderError.accessDenied
        }
        authorized = true
    }
}

extension RemindersTool: Tool {
    nonisolated var name: String { "reminders" }

    nonisolated var description: String {
        "Manage Apple Reminders: create, complete, list, or delete reminders."
    }

    nonisolated var parametersSchema: [String: Any] {
        [
            "action": [
                "type": "string",
                "description": "One of: create_reminder, complete_reminder, list_reminders, delete_reminder",
            ] as [String: Any],
            "title": [
                "type": "string",
                "description": "Reminder title (for create_reminder)",
                "optional": true,
            ] as [String: Any],
            "due_date": [
                "type": "string",
                "description": "ISO 8601 due date, e.g. 2025-12-31T09:00:00 (for create_reminder)",
                "optional": true,
            ] as [String: Any],
            "list_name": [
                "type": "string",
                "description": "Reminders list name (default: default list)",
                "optional": true,
            ] as [String: Any],
            "reminder_id": [
                "type": "string",
                "description": "Reminder identifier (for complete/delete)",
                "optional": true,
            ] as [String: Any],
            "notes": [
                "type": "string",
                "description": "Notes for the reminder (for create_reminder)",
                "optional": true,
            ] as [String: Any],
        ]
    }

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing 'action' parameter. Use: create_reminder, complete_reminder, list_reminders, delete_reminder", isError: true)
        }

        do {
            try await ensureAccess()
        } catch {
            return ToolResult("Reminders access denied. Please grant permission in System Settings > Privacy & Security > Reminders.", isError: true)
        }

        switch action {
        case "create_reminder":
            return await createReminder(arguments)
        case "complete_reminder":
            return await completeReminder(arguments)
        case "list_reminders":
            return await listReminders(arguments)
        case "delete_reminder":
            return await deleteReminder(arguments)
        default:
            return ToolResult("Unknown action: \(action). Use: create_reminder, complete_reminder, list_reminders, delete_reminder", isError: true)
        }
    }

    // MARK: - Actions

    private func createReminder(_ args: [String: Any]) async -> ToolResult {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return ToolResult("Missing 'title' for create_reminder", isError: true)
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title

        if let notes = args["notes"] as? String {
            reminder.notes = notes
        }

        // Due date
        if let dueDateStr = args["due_date"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dueDateStr) ?? ISO8601DateFormatter().date(from: dueDateStr) {
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                reminder.dueDateComponents = components
                reminder.addAlarm(EKAlarm(absoluteDate: date))
            } else {
                // Try a simpler date format
                let simple = DateFormatter()
                simple.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                if let date = simple.date(from: dueDateStr) {
                    let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                    reminder.dueDateComponents = components
                    reminder.addAlarm(EKAlarm(absoluteDate: date))
                }
            }
        }

        // Calendar (list)
        if let listName = args["list_name"] as? String,
           let calendar = eventStore.calendars(for: .reminder).first(where: { $0.title.lowercased() == listName.lowercased() }) {
            reminder.calendar = calendar
        } else {
            reminder.calendar = eventStore.defaultCalendarForNewReminders()
        }

        do {
            try eventStore.save(reminder, commit: true)
            var result = "Created reminder: \(title)"
            if let due = reminder.dueDateComponents, let month = due.month, let day = due.day {
                result += " (due: \(due.year ?? 0)-\(month)-\(day))"
            }
            result += "\nID: \(reminder.calendarItemIdentifier)"
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to create reminder: \(error.localizedDescription)", isError: true)
        }
    }

    private func completeReminder(_ args: [String: Any]) async -> ToolResult {
        guard let reminderID = args["reminder_id"] as? String else {
            return ToolResult("Missing 'reminder_id' for complete_reminder", isError: true)
        }

        guard let item = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            return ToolResult("Reminder not found with ID: \(reminderID)", isError: true)
        }

        item.isCompleted = true
        item.completionDate = Date()

        do {
            try eventStore.save(item, commit: true)
            return ToolResult("Completed reminder: \(item.title ?? reminderID)")
        } catch {
            return ToolResult("Failed to complete reminder: \(error.localizedDescription)", isError: true)
        }
    }

    private func listReminders(_ args: [String: Any]) async -> ToolResult {
        let calendars: [EKCalendar]
        if let listName = args["list_name"] as? String {
            calendars = eventStore.calendars(for: .reminder).filter { $0.title.lowercased() == listName.lowercased() }
            if calendars.isEmpty {
                return ToolResult("No reminders list found named '\(listName)'. Available lists: \(eventStore.calendars(for: .reminder).map(\.title).joined(separator: ", "))", isError: true)
            }
        } else {
            calendars = eventStore.calendars(for: .reminder)
        }

        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )

        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                guard let reminders, !reminders.isEmpty else {
                    continuation.resume(returning: ToolResult("No incomplete reminders found."))
                    return
                }

                var output = "Incomplete reminders (\(reminders.count)):\n"
                for (idx, r) in reminders.prefix(50).enumerated() {
                    let due: String
                    if let comps = r.dueDateComponents,
                       let date = Calendar.current.date(from: comps) {
                        let fmt = DateFormatter()
                        fmt.dateStyle = .medium
                        fmt.timeStyle = .short
                        due = fmt.string(from: date)
                    } else {
                        due = "no due date"
                    }
                    let list = r.calendar?.title ?? "Unknown"
                    output += "\(idx + 1). [\(list)] \(r.title ?? "Untitled") | \(due) | ID: \(r.calendarItemIdentifier)\n"
                }
                if reminders.count > 50 {
                    output += "... and \(reminders.count - 50) more\n"
                }
                continuation.resume(returning: ToolResult(output))
            }
        }
    }

    private func deleteReminder(_ args: [String: Any]) async -> ToolResult {
        guard let reminderID = args["reminder_id"] as? String else {
            return ToolResult("Missing 'reminder_id' for delete_reminder", isError: true)
        }

        guard let item = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            return ToolResult("Reminder not found with ID: \(reminderID)", isError: true)
        }

        let title = item.title ?? reminderID
        do {
            try eventStore.remove(item, commit: true)
            return ToolResult("Deleted reminder: \(title)")
        } catch {
            return ToolResult("Failed to delete reminder: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Errors

private enum ReminderError: Error, LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Access to Reminders denied"
        }
    }
}
