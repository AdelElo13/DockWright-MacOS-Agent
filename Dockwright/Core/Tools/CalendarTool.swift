import Foundation
import EventKit
import os

nonisolated private let logger = Logger(subsystem: "com.dockwright", category: "CalendarTool")

/// LLM tool for interacting with Calendar via EventKit.
/// Actions: today, upcoming, create_event, search_events, delete_event.
nonisolated struct CalendarTool: Tool, @unchecked Sendable {
    let name = "calendar"
    let description = "Manage Calendar events: view today's events, upcoming events, create, search, or delete events."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: today, upcoming, create_event, search_events, delete_event",
        ] as [String: Any],
        "days": [
            "type": "integer",
            "description": "Number of days to look ahead (for upcoming, default 7)",
            "optional": true,
        ] as [String: Any],
        "title": [
            "type": "string",
            "description": "Event title (for create_event, delete_event)",
            "optional": true,
        ] as [String: Any],
        "start": [
            "type": "string",
            "description": "Start date/time in ISO 8601 format, e.g. 2025-12-31T09:00:00 (for create_event)",
            "optional": true,
        ] as [String: Any],
        "end": [
            "type": "string",
            "description": "End date/time in ISO 8601 format (for create_event)",
            "optional": true,
        ] as [String: Any],
        "calendar": [
            "type": "string",
            "description": "Calendar name (for create_event, default: default calendar)",
            "optional": true,
        ] as [String: Any],
        "notes": [
            "type": "string",
            "description": "Event notes (for create_event)",
            "optional": true,
        ] as [String: Any],
        "location": [
            "type": "string",
            "description": "Event location (for create_event)",
            "optional": true,
        ] as [String: Any],
        "query": [
            "type": "string",
            "description": "Search query (for search_events)",
            "optional": true,
        ] as [String: Any],
        "event_id": [
            "type": "string",
            "description": "Event identifier (for delete_event)",
            "optional": true,
        ] as [String: Any],
    ]

    private let eventStore = EKEventStore()

    nonisolated init() {}

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult(
                "Missing 'action' parameter. Use: today, upcoming, create_event, search_events, delete_event",
                isError: true
            )
        }

        do {
            try await ensureAccess()
        } catch {
            return ToolResult(
                "Calendar access denied. Please grant permission in System Settings > Privacy & Security > Calendars.",
                isError: true
            )
        }

        switch action {
        case "today":
            return getEvents(daysAhead: 0)
        case "upcoming":
            let days = (arguments["days"] as? Int) ?? 7
            return getEvents(daysAhead: max(1, min(days, 90)))
        case "create_event":
            return createEvent(arguments)
        case "search_events":
            return searchEvents(arguments)
        case "delete_event":
            return deleteEvent(arguments)
        default:
            return ToolResult(
                "Unknown action: \(action). Use: today, upcoming, create_event, search_events, delete_event",
                isError: true
            )
        }
    }

    // MARK: - Access

    private func ensureAccess() async throws {
        let granted = try await eventStore.requestFullAccessToEvents()
        guard granted else {
            throw CalendarToolError.accessDenied
        }
    }

    // MARK: - Date Parsing

    private func parseDate(_ string: String) -> Date? {
        // Try ISO 8601 with fractional seconds
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }

        // Try ISO 8601 standard
        if let date = ISO8601DateFormatter().date(from: string) { return date }

        // Try simple format: yyyy-MM-ddTHH:mm:ss
        let simple = DateFormatter()
        simple.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        simple.locale = Locale(identifier: "en_US_POSIX")
        if let date = simple.date(from: string) { return date }

        // Try date-only: yyyy-MM-dd
        simple.dateFormat = "yyyy-MM-dd"
        if let date = simple.date(from: string) { return date }

        return nil
    }

    // MARK: - Event Formatting

    private func formatEvent(_ event: EKEvent, index: Int) -> String {
        let timeFmt = DateFormatter()
        timeFmt.dateStyle = .short
        timeFmt.timeStyle = .short

        var line = "\(index). "

        if event.isAllDay {
            let dayFmt = DateFormatter()
            dayFmt.dateStyle = .short
            dayFmt.timeStyle = .none
            line += "[All Day \(dayFmt.string(from: event.startDate))] "
        } else {
            line += "[\(timeFmt.string(from: event.startDate)) - \(timeFmt.string(from: event.endDate))] "
        }

        line += event.title ?? "Untitled"

        if let location = event.location, !location.isEmpty {
            line += " @ \(location)"
        }

        if let calendarTitle = event.calendar?.title {
            line += " (\(calendarTitle))"
        }

        if let notes = event.notes, !notes.isEmpty {
            let preview = notes.count > 100 ? String(notes.prefix(100)) + "..." : notes
            line += "\n   Notes: \(preview)"
        }

        line += "\n   ID: \(event.eventIdentifier ?? "unknown")"

        return line
    }

    // MARK: - Actions

    private func getEvents(daysAhead: Int) -> ToolResult {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())

        let startDate = startOfToday
        let endDate: Date
        if daysAhead == 0 {
            endDate = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        } else {
            endDate = calendar.date(byAdding: .day, value: daysAhead, to: startOfToday)!
        }

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let events = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        if events.isEmpty {
            let label = daysAhead == 0 ? "today" : "the next \(daysAhead) days"
            return ToolResult("No events found for \(label).")
        }

        let label = daysAhead == 0 ? "Today" : "Next \(daysAhead) days"
        var output = "\(label) — \(events.count) event(s):\n\n"

        var currentDay = ""
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "EEEE, MMM d, yyyy"

        for (idx, event) in events.enumerated() {
            let dayString = dayFmt.string(from: event.startDate)
            if dayString != currentDay {
                currentDay = dayString
                if idx > 0 { output += "\n" }
                output += "--- \(dayString) ---\n"
            }
            output += formatEvent(event, index: idx + 1) + "\n"
        }

        return ToolResult(output)
    }

    private func createEvent(_ args: [String: Any]) -> ToolResult {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return ToolResult("Missing 'title' for create_event", isError: true)
        }

        guard let startStr = args["start"] as? String, let startDate = parseDate(startStr) else {
            return ToolResult("Missing or invalid 'start' date for create_event. Use ISO 8601 format, e.g. 2025-12-31T09:00:00", isError: true)
        }

        let endDate: Date
        if let endStr = args["end"] as? String, let parsed = parseDate(endStr) {
            endDate = parsed
        } else {
            // Default to 1 hour duration
            endDate = startDate.addingTimeInterval(3600)
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate

        if let notes = args["notes"] as? String {
            event.notes = notes
        }

        if let location = args["location"] as? String {
            event.location = location
        }

        // Set calendar
        if let calendarName = args["calendar"] as? String,
           let cal = eventStore.calendars(for: .event).first(where: { $0.title.lowercased() == calendarName.lowercased() }) {
            event.calendar = cal
        } else {
            event.calendar = eventStore.defaultCalendarForNewEvents
        }

        do {
            try eventStore.save(event, span: .thisEvent)

            let timeFmt = DateFormatter()
            timeFmt.dateStyle = .medium
            timeFmt.timeStyle = .short

            var output = "Created event: \(title)\n"
            output += "When: \(timeFmt.string(from: startDate)) - \(timeFmt.string(from: endDate))\n"
            output += "Calendar: \(event.calendar?.title ?? "Default")\n"
            if let location = event.location, !location.isEmpty {
                output += "Location: \(location)\n"
            }
            output += "ID: \(event.eventIdentifier ?? "unknown")"
            return ToolResult(output)
        } catch {
            logger.error("Failed to create event: \(error.localizedDescription)")
            return ToolResult("Failed to create event: \(error.localizedDescription)", isError: true)
        }
    }

    private func searchEvents(_ args: [String: Any]) -> ToolResult {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return ToolResult("Missing 'query' for search_events", isError: true)
        }

        let calendar = Calendar.current
        let startDate = calendar.date(byAdding: .month, value: -3, to: Date())!
        let endDate = calendar.date(byAdding: .month, value: 3, to: Date())!

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let allEvents = eventStore.events(matching: predicate)

        let queryLower = query.lowercased()
        let matched = allEvents.filter { event in
            let titleMatch = event.title?.lowercased().contains(queryLower) ?? false
            let locationMatch = event.location?.lowercased().contains(queryLower) ?? false
            let notesMatch = event.notes?.lowercased().contains(queryLower) ?? false
            return titleMatch || locationMatch || notesMatch
        }
        .sorted { $0.startDate < $1.startDate }

        if matched.isEmpty {
            return ToolResult("No events found matching '\(query)' (searched 3 months past and future).")
        }

        let capped = Array(matched.prefix(30))
        var output = "Found \(matched.count) event(s) matching '\(query)':\n\n"
        for (idx, event) in capped.enumerated() {
            output += formatEvent(event, index: idx + 1) + "\n"
        }
        if matched.count > 30 {
            output += "\n... and \(matched.count - 30) more results."
        }

        return ToolResult(output)
    }

    private func deleteEvent(_ args: [String: Any]) -> ToolResult {
        // Try by event ID first
        if let eventID = args["event_id"] as? String, !eventID.isEmpty {
            guard let event = eventStore.event(withIdentifier: eventID) else {
                return ToolResult("No event found with ID: \(eventID)", isError: true)
            }

            let title = event.title ?? eventID
            do {
                try eventStore.remove(event, span: .thisEvent)
                return ToolResult("Deleted event: \(title)")
            } catch {
                return ToolResult("Failed to delete event: \(error.localizedDescription)", isError: true)
            }
        }

        // Try by title
        if let title = args["title"] as? String, !title.isEmpty {
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .month, value: -1, to: Date())!
            let endDate = calendar.date(byAdding: .month, value: 3, to: Date())!

            let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
            let allEvents = eventStore.events(matching: predicate)

            let titleLower = title.lowercased()
            guard let event = allEvents.first(where: { ($0.title?.lowercased() ?? "") == titleLower }) else {
                // Try partial match
                guard let event = allEvents.first(where: { ($0.title?.lowercased() ?? "").contains(titleLower) }) else {
                    return ToolResult("No event found with title: \(title)", isError: true)
                }

                let eventTitle = event.title ?? title
                do {
                    try eventStore.remove(event, span: .thisEvent)
                    return ToolResult("Deleted event: \(eventTitle)")
                } catch {
                    return ToolResult("Failed to delete event: \(error.localizedDescription)", isError: true)
                }
            }

            let eventTitle = event.title ?? title
            do {
                try eventStore.remove(event, span: .thisEvent)
                return ToolResult("Deleted event: \(eventTitle)")
            } catch {
                return ToolResult("Failed to delete event: \(error.localizedDescription)", isError: true)
            }
        }

        return ToolResult("Missing 'event_id' or 'title' for delete_event", isError: true)
    }
}

// MARK: - Errors

private enum CalendarToolError: Error, LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Access to Calendar denied"
        }
    }
}
