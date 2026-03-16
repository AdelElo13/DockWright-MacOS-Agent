import Foundation
import os
import UserNotifications

/// Periodic heartbeat that checks for actionable notifications (reminders, system status, etc.)
/// Fires every 30 minutes during active hours (07:00-23:00). Deduplicates identical messages
/// within a 24-hour window.
final class HeartbeatRunner: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "Heartbeat")
    private let channel: NotificationChannel
    private let cronStore: CronStore
    private let queue = DispatchQueue(label: "com.Aatje.Dockwright.Heartbeat", qos: .utility)
    private var timer: DispatchSourceTimer?
    private(set) var isRunning = false

    /// Interval between heartbeat checks (30 minutes).
    private let checkInterval: TimeInterval = 1800

    /// Active hours: heartbeat is silent between 23:00 and 07:00.
    private let activeStartHour = 7
    private let activeEndHour = 23

    /// Deduplication window: don't send the same message within 24 hours.
    private let deduplicationWindow: TimeInterval = 86400
    private var sentMessages: [String: Date] = [:]
    private let sentLock = NSLock()

    init(channel: NotificationChannel, cronStore: CronStore) {
        self.channel = channel
        self.cronStore = cronStore
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + checkInterval, repeating: checkInterval)
        timer.setEventHandler { [weak self] in
            self?.heartbeat()
        }
        timer.resume()
        self.timer = timer
        logger.info("HeartbeatRunner started (interval: \(Int(self.checkInterval))s)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
        logger.info("HeartbeatRunner stopped.")
    }

    // MARK: - Heartbeat Logic

    private func heartbeat() {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)

        // Quiet hours check
        if hour < activeStartHour || hour >= activeEndHour {
            logger.debug("Heartbeat skipped: outside active hours (\(hour):00)")
            return
        }

        // Prune old dedup entries
        pruneSentMessages(now: now)

        // Check for things to notify about
        checkMissedJobs(now: now)
        checkUpcomingReminders(now: now)
        checkSystemHealth()
    }

    // MARK: - Checks

    /// Check for cron jobs that may have been missed (e.g., due to app being closed).
    private func checkMissedJobs(now: Date) {
        let jobs = cronStore.enabledJobs()
        var missedCount = 0

        for job in jobs where !job.isOneShot {
            guard let lastRun = job.lastRun else { continue }

            // If the job hasn't run in 2x its expected interval, it's "missed"
            if let expr = try? CronExpression(job.schedule),
               let expectedNext = expr.nextOccurrence(after: lastRun),
               now.timeIntervalSince(expectedNext) > 3600 {
                missedCount += 1
            }
        }

        if missedCount > 0 {
            sendDeduped(
                key: "missed_jobs_\(missedCount)",
                title: "Dockwright: Missed Jobs",
                body: "\(missedCount) scheduled job(s) may have been missed while the app was closed. Open Dockwright to review."
            )
        }
    }

    /// Notify about reminders coming up in the next hour.
    private func checkUpcomingReminders(now: Date) {
        let jobs = cronStore.enabledJobs()
        let oneHourAhead = now.addingTimeInterval(3600)

        for job in jobs where job.isOneShot {
            guard let fireDate = job.nextRun,
                  fireDate > now,
                  fireDate <= oneHourAhead else { continue }

            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            let relativeTime = formatter.localizedString(for: fireDate, relativeTo: now)

            sendDeduped(
                key: "upcoming_\(job.id)",
                title: "Upcoming: \(job.name)",
                body: "Due \(relativeTime)"
            )
        }
    }

    /// Basic system health checks.
    private func checkSystemHealth() {
        // Check disk space
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeSpace = attrs[.systemFreeSize] as? Int64 {
            let freeGB = Double(freeSpace) / 1_073_741_824
            if freeGB < 5.0 {
                sendDeduped(
                    key: "disk_low",
                    title: "Low Disk Space",
                    body: String(format: "Only %.1f GB free on your startup disk.", freeGB)
                )
            }
        }
    }

    // MARK: - Deduplication

    private func sendDeduped(key: String, title: String, body: String) {
        let shouldSend = sentLock.withLock { () -> Bool in
            if let lastSent = sentMessages[key],
               Date().timeIntervalSince(lastSent) < deduplicationWindow {
                return false
            }
            sentMessages[key] = Date()
            return true
        }

        guard shouldSend else {
            logger.debug("Heartbeat deduped: \(key)")
            return
        }

        Task {
            do {
                try await channel.send(title: title, body: body)
                logger.info("Heartbeat notification sent: \(title)")
            } catch {
                logger.error("Heartbeat notification failed: \(error.localizedDescription)")
            }
        }
    }

    private func pruneSentMessages(now: Date) {
        sentLock.withLock {
            sentMessages = sentMessages.filter { _, date in
                now.timeIntervalSince(date) < deduplicationWindow
            }
        }
    }
}
