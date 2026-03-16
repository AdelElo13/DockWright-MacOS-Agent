import EventKit
import Foundation

/// LLM tool for interacting with Reminders via EventKit.
/// Actions: list, create, complete, delete, lists, overdue.
nonisolated struct RemindersTool: Tool, @unchecked Sendable {
    let name = "reminders"
    let description = "Manage Reminders: list reminders, create new ones, mark complete, delete, show lists, or find overdue reminders."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: list, create, complete, delete, lists, overdue",
        ] as [String: Any],
        "title": [
            "type": "string",
            "description": "Reminder title (for create, complete, delete)",
            "optional": true,
        ] as [String: Any],
        "due": [
            "type": "string",
            "description": "Due date in ISO 8601 format, e.g. 2025-12-31T09:00:00 (for create)",
            "optional": true,
        ] as [String: Any],
        "list": [
            "type": "string",
            "description": "Reminder list name (for list, create)",
            "optional": true,
        ] as [String: Any],
        "reminder_id": [
            "type": "string",
            "description": "Reminder identifier (for complete, delete)",
            "optional": true,
        ] as [String: Any],
    ]

    private let eventStore = EKEventStore()

    nonisolated init() {}

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult(
                "Missing 'action' parameter. Use: list, create, complete, delete, lists, overdue",
                isError: true
            )
        }

        do {
            try await ensureAccess()
        } catch {
            return ToolResult(
                "Reminders access denied. Please grant permission in System Settings > Privacy & Security > Reminders.",
                isError: true
            )
        }

        switch action {
        case "list":
            return await listReminders(arguments)
        case "create":
            return createReminder(arguments)
        case "complete":
            return await completeReminder(arguments)
        case "delete":
            return await deleteReminder(arguments)
        case "lists":
            return showLists()
        case "overdue":
            return await overdueReminders()
        default:
            return ToolResult(
                "Unknown action: \(action). Use: list, create, complete, delete, lists, overdue",
                isError: true
            )
        }
    }

    // MARK: - Access

    private func ensureAccess() async throws {
        let granted = try await eventStore.requestFullAccessToReminders()
        guard granted else {
            throw RemindersToolError.accessDenied
        }
    }

    // MARK: - Date Parsing

    private func parseDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }

        if let date = ISO8601DateFormatter().date(from: string) { return date }

        let simple = DateFormatter()
        simple.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        simple.locale = Locale(identifier: "en_US_POSIX")
        if let date = simple.date(from: string) { return date }

        simple.dateFormat = "yyyy-MM-dd"
        if let date = simple.date(from: string) { return date }

        return nil
    }

    // MARK: - Formatting

    private func formatReminder(_ reminder: EKReminder, index: Int) -> String {
        let status = reminder.isCompleted ? "[x]" : "[ ]"
        var line = "\(index). \(status) \(reminder.title ?? "Untitled")"

        if let dueDate = reminder.dueDateComponents,
           let date = Calendar.current.date(from: dueDate) {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            line += " — due \(fmt.string(from: date))"
        }

        if let calendar = reminder.calendar {
            line += " (\(calendar.title))"
        }

        if let notes = reminder.notes, !notes.isEmpty {
            let preview = notes.count > 80 ? String(notes.prefix(80)) + "..." : notes
            line += "\n   Notes: \(preview)"
        }

        line += "\n   ID: \(reminder.calendarItemIdentifier)"

        return line
    }

    // MARK: - Helpers

    private func fetchReminders(in calendar: EKCalendar? = nil) async -> [EKReminder] {
        let calendars: [EKCalendar]? = calendar != nil ? [calendar!] : nil
        let predicate = eventStore.predicateForReminders(in: calendars)

        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private func findCalendar(named name: String) -> EKCalendar? {
        eventStore.calendars(for: .reminder).first {
            $0.title.lowercased() == name.lowercased()
        }
    }

    // MARK: - Actions

    private func listReminders(_ args: [String: Any]) async -> ToolResult {
        let listName = args["list"] as? String

        var calendar: EKCalendar?
        if let listName = listName {
            guard let found = findCalendar(named: listName) else {
                return ToolResult("No reminder list found named '\(listName)'.", isError: true)
            }
            calendar = found
        }

        let reminders = await fetchReminders(in: calendar)
        let incomplete = reminders.filter { !$0.isCompleted }

        if incomplete.isEmpty {
            let label = listName != nil ? " in '\(listName!)'" : ""
            return ToolResult("No incomplete reminders\(label).")
        }

        let label = listName != nil ? "Reminders in '\(listName!)'" : "All reminders"
        var output = "\(label) — \(incomplete.count) incomplete:\n\n"

        let capped = Array(incomplete.prefix(50))
        for (idx, reminder) in capped.enumerated() {
            output += formatReminder(reminder, index: idx + 1) + "\n"
        }
        if incomplete.count > 50 {
            output += "\n... and \(incomplete.count - 50) more reminders."
        }

        return ToolResult(output)
    }

    private func createReminder(_ args: [String: Any]) -> ToolResult {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return ToolResult("Missing 'title' for create", isError: true)
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title

        if let dueStr = args["due"] as? String, let dueDate = parseDate(dueStr) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }

        if let listName = args["list"] as? String,
           let calendar = findCalendar(named: listName) {
            reminder.calendar = calendar
        } else {
            reminder.calendar = eventStore.defaultCalendarForNewReminders()
        }

        do {
            try eventStore.save(reminder, commit: true)

            var output = "Created reminder: \(title)\n"
            output += "List: \(reminder.calendar?.title ?? "Default")\n"
            if let dueStr = args["due"] as? String, let dueDate = parseDate(dueStr) {
                let fmt = DateFormatter()
                fmt.dateStyle = .medium
                fmt.timeStyle = .short
                output += "Due: \(fmt.string(from: dueDate))\n"
            }
            output += "ID: \(reminder.calendarItemIdentifier)"
            return ToolResult(output)
        } catch {
            return ToolResult("Failed to create reminder: \(error.localizedDescription)", isError: true)
        }
    }

    private func completeReminder(_ args: [String: Any]) async -> ToolResult {
        if let reminderID = args["reminder_id"] as? String, !reminderID.isEmpty {
            guard let item = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder else {
                return ToolResult("No reminder found with ID: \(reminderID)", isError: true)
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

        if let title = args["title"] as? String, !title.isEmpty {
            let reminders = await fetchReminders()
            let titleLower = title.lowercased()

            guard let reminder = reminders.first(where: {
                !$0.isCompleted && ($0.title?.lowercased() ?? "").contains(titleLower)
            }) else {
                return ToolResult("No incomplete reminder found matching '\(title)'.", isError: true)
            }

            reminder.isCompleted = true
            reminder.completionDate = Date()

            do {
                try eventStore.save(reminder, commit: true)
                return ToolResult("Completed reminder: \(reminder.title ?? title)")
            } catch {
                return ToolResult("Failed to complete reminder: \(error.localizedDescription)", isError: true)
            }
        }

        return ToolResult("Missing 'reminder_id' or 'title' for complete", isError: true)
    }

    private func deleteReminder(_ args: [String: Any]) async -> ToolResult {
        if let reminderID = args["reminder_id"] as? String, !reminderID.isEmpty {
            guard let item = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder else {
                return ToolResult("No reminder found with ID: \(reminderID)", isError: true)
            }

            let reminderTitle = item.title ?? reminderID
            do {
                try eventStore.remove(item, commit: true)
                return ToolResult("Deleted reminder: \(reminderTitle)")
            } catch {
                return ToolResult("Failed to delete reminder: \(error.localizedDescription)", isError: true)
            }
        }

        if let title = args["title"] as? String, !title.isEmpty {
            let reminders = await fetchReminders()
            let titleLower = title.lowercased()

            guard let reminder = reminders.first(where: {
                ($0.title?.lowercased() ?? "").contains(titleLower)
            }) else {
                return ToolResult("No reminder found matching '\(title)'.", isError: true)
            }

            let reminderTitle = reminder.title ?? title
            do {
                try eventStore.remove(reminder, commit: true)
                return ToolResult("Deleted reminder: \(reminderTitle)")
            } catch {
                return ToolResult("Failed to delete reminder: \(error.localizedDescription)", isError: true)
            }
        }

        return ToolResult("Missing 'reminder_id' or 'title' for delete", isError: true)
    }

    private func showLists() -> ToolResult {
        let calendars = eventStore.calendars(for: .reminder)

        if calendars.isEmpty {
            return ToolResult("No reminder lists found.")
        }

        var output = "Reminder lists (\(calendars.count)):\n\n"
        for (idx, calendar) in calendars.enumerated() {
            var line = "\(idx + 1). \(calendar.title)"
            if calendar == eventStore.defaultCalendarForNewReminders() {
                line += " (default)"
            }
            output += line + "\n"
        }

        return ToolResult(output)
    }

    private func overdueReminders() async -> ToolResult {
        let reminders = await fetchReminders()
        let now = Date()

        let overdue = reminders.filter { reminder in
            guard !reminder.isCompleted,
                  let dueComponents = reminder.dueDateComponents,
                  let dueDate = Calendar.current.date(from: dueComponents) else {
                return false
            }
            return dueDate < now
        }
        .sorted { r1, r2 in
            let d1 = Calendar.current.date(from: r1.dueDateComponents!) ?? Date.distantPast
            let d2 = Calendar.current.date(from: r2.dueDateComponents!) ?? Date.distantPast
            return d1 < d2
        }

        if overdue.isEmpty {
            return ToolResult("No overdue reminders.")
        }

        var output = "Overdue reminders (\(overdue.count)):\n\n"
        for (idx, reminder) in overdue.prefix(50).enumerated() {
            output += formatReminder(reminder, index: idx + 1) + "\n"
        }
        if overdue.count > 50 {
            output += "\n... and \(overdue.count - 50) more overdue reminders."
        }

        return ToolResult(output)
    }
}

// MARK: - Errors

private enum RemindersToolError: Error, LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Access to Reminders denied"
        }
    }
}
