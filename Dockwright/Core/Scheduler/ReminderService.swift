import Foundation
import os

/// Parse relative/absolute time strings and create one-shot reminder jobs.
nonisolated enum ReminderService {
    private static let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "ReminderService")

    /// Create a reminder that fires after a delay string like "2 minutes", "1 hour", "30 seconds".
    /// Returns the created CronJob.
    static func setReminder(message: String, delay: String, store: CronStore) -> CronJob? {
        guard let seconds = parseDelay(delay) else {
            logger.error("Could not parse delay: '\(delay)'")
            return nil
        }

        let fireDate = Date().addingTimeInterval(seconds)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let job = CronJob(
            name: message,
            schedule: isoFormatter.string(from: fireDate),
            isOneShot: true,
            action: .notification(title: "Reminder", body: message),
            nextRun: fireDate
        )

        store.add(job)
        logger.info("Reminder set: '\(message)' in \(Int(seconds))s (fires at \(fireDate))")
        return job
    }

    /// Create a reminder that fires at a specific Date.
    static func setReminder(message: String, at fireDate: Date, store: CronStore) -> CronJob {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let job = CronJob(
            name: message,
            schedule: isoFormatter.string(from: fireDate),
            isOneShot: true,
            action: .notification(title: "Reminder", body: message),
            nextRun: fireDate
        )

        store.add(job)
        logger.info("Reminder set: '\(message)' at \(fireDate)")
        return job
    }

    // MARK: - Delay Parsing

    /// Parse a human-readable delay like "2 minutes", "1 hour", "30 seconds", "1.5 hours".
    /// Returns seconds, or nil if unparseable.
    static func parseDelay(_ text: String) -> TimeInterval? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Try regex: number + unit
        let pattern = #"^(\d+(?:\.\d+)?)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(lowered.startIndex..., in: lowered)
        guard let match = regex.firstMatch(in: lowered, options: [], range: range) else {
            // Try bare number (assume minutes)
            if let num = Double(lowered) {
                return num * 60
            }
            return nil
        }

        guard let numRange = Range(match.range(at: 1), in: lowered),
              let unitRange = Range(match.range(at: 2), in: lowered),
              let number = Double(String(lowered[numRange])) else {
            return nil
        }

        let unit = String(lowered[unitRange])
        switch unit {
        case "s", "sec", "secs", "second", "seconds":
            return number
        case "m", "min", "mins", "minute", "minutes":
            return number * 60
        case "h", "hr", "hrs", "hour", "hours":
            return number * 3600
        case "d", "day", "days":
            return number * 86400
        default:
            return nil
        }
    }

    /// Parse an absolute time string like "15:30", "3pm", "tomorrow 9am".
    /// Returns a Date, or nil if unparseable.
    static func parseAbsoluteTime(_ text: String) -> Date? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let cal = Calendar.current
        var baseDate = Date()

        var timePart = lowered
        if lowered.hasPrefix("tomorrow") {
            guard let tomorrow = cal.date(byAdding: .day, value: 1, to: baseDate) else { return nil }
            baseDate = tomorrow
            timePart = String(lowered.dropFirst("tomorrow".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            // Remove optional "at"
            if timePart.hasPrefix("at ") {
                timePart = String(timePart.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        } else if lowered.hasPrefix("at ") {
            timePart = String(lowered.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }

        guard let parsed = CronEngine.parseTime(timePart) else { return nil }

        var components = cal.dateComponents([.year, .month, .day], from: baseDate)
        components.hour = parsed.hour
        components.minute = parsed.minute
        components.second = 0

        guard let result = cal.date(from: components) else { return nil }

        // If the time is in the past today, schedule for tomorrow
        if result <= Date() && !lowered.hasPrefix("tomorrow") {
            return cal.date(byAdding: .day, value: 1, to: result)
        }

        return result
    }
}
