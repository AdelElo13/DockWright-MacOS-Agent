import Foundation
import os

// MARK: - Cron Expression

/// Full 5-field cron expression parser.
/// Format: minute hour day-of-month month day-of-week
/// Supports: *, specific values, ranges (1-5), steps (*/5), lists (1,3,5), range+step (1-30/5)
nonisolated struct CronExpression: Sendable {
    let raw: String
    let minute: Set<Int>   // 0-59
    let hour: Set<Int>     // 0-23
    let dom: Set<Int>      // 1-31
    let month: Set<Int>    // 1-12
    let dow: Set<Int>      // 0-6 (0=Sunday)

    init(_ expression: String) throws {
        self.raw = expression.trimmingCharacters(in: .whitespaces)
        let parts = raw.split(separator: " ").map(String.init)
        guard parts.count == 5 else {
            throw CronError.invalidFieldCount(parts.count)
        }
        self.minute = try Self.parseField(parts[0], min: 0, max: 59)
        self.hour   = try Self.parseField(parts[1], min: 0, max: 23)
        self.dom    = try Self.parseField(parts[2], min: 1, max: 31)
        self.month  = try Self.parseField(parts[3], min: 1, max: 12)
        self.dow    = try Self.parseField(parts[4], min: 0, max: 6)
    }

    /// Check if a Date matches this cron expression.
    func matches(_ date: Date) -> Bool {
        let cal = Calendar.current
        let comps = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let min = comps.minute, let hr = comps.hour,
              let day = comps.day, let mon = comps.month,
              let wd = comps.weekday else { return false }

        // Calendar.weekday: 1=Sunday, 2=Monday, ..., 7=Saturday
        // Cron: 0=Sunday, 1=Monday, ..., 6=Saturday
        let cronDow = wd - 1

        return minute.contains(min)
            && hour.contains(hr)
            && dom.contains(day)
            && month.contains(mon)
            && dow.contains(cronDow)
    }

    /// Calculate the next occurrence of this cron expression after the given date.
    /// Searches up to 366 days forward.
    func nextOccurrence(after date: Date) -> Date? {
        let cal = Calendar.current
        // Start from the next full minute
        guard var candidate = cal.date(bySetting: .second, value: 0, of: date) else { return nil }
        candidate = cal.date(byAdding: .minute, value: 1, to: candidate) ?? candidate

        // Search up to 366 * 24 * 60 minutes (one year)
        let maxIterations = 366 * 24 * 60
        for _ in 0..<maxIterations {
            if matches(candidate) {
                return candidate
            }
            guard let next = cal.date(byAdding: .minute, value: 1, to: candidate) else { return nil }
            candidate = next
        }
        return nil
    }

    // MARK: - Field Parsing

    /// Parse a single cron field into a set of valid integers.
    /// Supports: *, N, N-M, */N, N-M/N, N,M,O
    private static func parseField(_ field: String, min: Int, max: Int) throws -> Set<Int> {
        var result = Set<Int>()

        for part in field.split(separator: ",").map(String.init) {
            let trimmed = part.trimmingCharacters(in: .whitespaces)

            if trimmed == "*" {
                // Wildcard — all values
                result.formUnion(min...max)

            } else if trimmed.contains("/") {
                // Step: */N or N/N or N-M/N
                let pieces = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
                guard pieces.count == 2, let step = Int(pieces[1]), step > 0 else {
                    throw CronError.invalidStep(trimmed)
                }
                let start: Int
                if pieces[0] == "*" {
                    start = min
                } else if pieces[0].contains("-") {
                    let rangeParts = pieces[0].split(separator: "-").map(String.init)
                    guard rangeParts.count == 2, let lo = Int(rangeParts[0]) else {
                        throw CronError.invalidRange(trimmed)
                    }
                    start = lo
                } else {
                    guard let s = Int(pieces[0]) else {
                        throw CronError.invalidValue(trimmed)
                    }
                    start = s
                }
                for val in stride(from: start, through: max, by: step) {
                    if val >= min && val <= max {
                        result.insert(val)
                    }
                }

            } else if trimmed.contains("-") {
                // Range: N-M
                let rangeParts = trimmed.split(separator: "-").map(String.init)
                guard rangeParts.count == 2,
                      let lo = Int(rangeParts[0]),
                      let hi = Int(rangeParts[1]),
                      lo >= min, hi <= max, lo <= hi else {
                    throw CronError.invalidRange(trimmed)
                }
                result.formUnion(lo...hi)

            } else {
                // Single value
                guard let val = Int(trimmed) else {
                    throw CronError.invalidValue(trimmed)
                }
                guard val >= min && val <= max else {
                    throw CronError.outOfRange(val, min: min, max: max)
                }
                result.insert(val)
            }
        }

        return result
    }
}

// MARK: - Cron Engine

/// Stateless cron utility: parsing, matching, and natural-language presets.
nonisolated enum CronEngine {

    /// Parse a natural language schedule into a 5-field cron expression.
    /// Returns nil if the input is already a valid cron expression.
    static func naturalLanguageToCron(_ text: String) -> String? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Exact presets
        switch lowered {
        case "every minute":
            return "* * * * *"
        case "every hour":
            return "0 * * * *"
        case "every day", "daily":
            return "0 9 * * *"
        case "every week", "weekly":
            return "0 9 * * 1"
        default:
            break
        }

        // "every N minutes"
        if let match = lowered.range(of: #"every (\d+) minutes?"#, options: .regularExpression) {
            let numStr = lowered[match].split(separator: " ")[1]
            if let n = Int(numStr), n > 0, n <= 59 {
                return "*/\(n) * * * *"
            }
        }

        // "every N hours"
        if let match = lowered.range(of: #"every (\d+) hours?"#, options: .regularExpression) {
            let numStr = lowered[match].split(separator: " ")[1]
            if let n = Int(numStr), n > 0, n <= 23 {
                return "0 */\(n) * * *"
            }
        }

        // "daily at HH:MM" or "daily at Ham/Hpm"
        if let hourMin = parseTimeFromString(lowered, prefix: "daily at") {
            return "\(hourMin.minute) \(hourMin.hour) * * *"
        }
        if let hourMin = parseTimeFromString(lowered, prefix: "every day at") {
            return "\(hourMin.minute) \(hourMin.hour) * * *"
        }

        // "weekdays at HH:MM"
        if let hourMin = parseTimeFromString(lowered, prefix: "weekdays at") {
            return "\(hourMin.minute) \(hourMin.hour) * * 1-5"
        }

        // "every monday at HH:MM" etc.
        let dayMap = ["sunday": 0, "monday": 1, "tuesday": 2, "wednesday": 3,
                      "thursday": 4, "friday": 5, "saturday": 6]
        for (dayName, dayNum) in dayMap {
            if let hourMin = parseTimeFromString(lowered, prefix: "every \(dayName) at") {
                return "\(hourMin.minute) \(hourMin.hour) * * \(dayNum)"
            }
        }

        return nil
    }

    /// Try to parse "HH:MM" or "Ham/Hpm" from a string after a given prefix.
    private static func parseTimeFromString(_ text: String, prefix: String) -> (hour: Int, minute: Int)? {
        guard text.hasPrefix(prefix) else { return nil }
        let timePart = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return parseTime(timePart)
    }

    /// Parse a time string like "9:30", "9am", "15:00", "3pm".
    static func parseTime(_ text: String) -> (hour: Int, minute: Int)? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)

        // "HH:MM" format
        if t.contains(":") {
            let parts = t.replacingOccurrences(of: "am", with: "")
                         .replacingOccurrences(of: "pm", with: "")
                         .split(separator: ":").map(String.init)
            guard parts.count == 2, var hour = Int(parts[0]), let min = Int(parts[1]) else { return nil }
            if t.hasSuffix("pm") && hour < 12 { hour += 12 }
            if t.hasSuffix("am") && hour == 12 { hour = 0 }
            guard hour >= 0, hour <= 23, min >= 0, min <= 59 else { return nil }
            return (hour, min)
        }

        // "9am", "3pm" format
        let stripped = t.replacingOccurrences(of: "am", with: "")
                        .replacingOccurrences(of: "pm", with: "")
        guard var hour = Int(stripped) else { return nil }
        if t.hasSuffix("pm") && hour < 12 { hour += 12 }
        if t.hasSuffix("am") && hour == 12 { hour = 0 }
        guard hour >= 0, hour <= 23 else { return nil }
        return (hour, 0)
    }

    /// Validate a cron expression string.
    static func validate(_ expression: String) -> Result<CronExpression, CronError> {
        do {
            let expr = try CronExpression(expression)
            return .success(expr)
        } catch let error as CronError {
            return .failure(error)
        } catch {
            return .failure(.invalidValue(expression))
        }
    }
}

// MARK: - Cron Error

nonisolated enum CronError: Error, LocalizedError, Sendable {
    case invalidFieldCount(Int)
    case invalidStep(String)
    case invalidRange(String)
    case invalidValue(String)
    case outOfRange(Int, min: Int, max: Int)

    var errorDescription: String? {
        switch self {
        case .invalidFieldCount(let count):
            return "Cron expression must have 5 fields, got \(count)"
        case .invalidStep(let field):
            return "Invalid step expression: \(field)"
        case .invalidRange(let field):
            return "Invalid range expression: \(field)"
        case .invalidValue(let field):
            return "Invalid value: \(field)"
        case .outOfRange(let val, let min, let max):
            return "Value \(val) out of range [\(min)-\(max)]"
        }
    }
}
