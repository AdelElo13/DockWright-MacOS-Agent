import Foundation
import os

/// Timer loop that checks every 30 seconds for due jobs and executes them.
/// Runs on a background thread. Delivers via DeliveryChannel.
final class CronRunner: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "CronRunner")
    private let store: CronStore
    private let channel: MultiChannel
    private let checkInterval: TimeInterval = 30
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.Aatje.Dockwright.CronRunner", qos: .utility)
    private var lastCheckMinute: Int = -1
    private(set) var isRunning = false

    /// Callback to send action text to the LLM for execution.
    /// When set, cron jobs send their action to Dockwright instead of just showing a notification.
    var onExecuteAction: ((_ jobName: String, _ actionText: String) -> Void)?

    init(store: CronStore, channel: MultiChannel) {
        self.store = store
        self.channel = channel
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Request notification permission on start
        Task {
            await channel.requestPermissions()
        }

        // Catch-up: check for jobs that were missed while app was closed
        catchUpMissedJobs()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: checkInterval)
        timer.setEventHandler { [weak self] in
            self?.checkJobs()
        }
        timer.resume()
        self.timer = timer
        logger.info("CronRunner started (interval: \(Int(self.checkInterval))s)")
    }

    /// On startup, check for missed jobs (lastRun + interval < now).
    /// One-shot jobs are executed immediately. Recurring jobs are logged.
    private func catchUpMissedJobs() {
        let now = Date()
        let jobs = store.listAll()

        for var job in jobs where job.enabled {
            if job.isOneShot {
                // One-shot: fire immediately if fire date has passed
                guard let fireDate = job.nextRun, now >= fireDate else { continue }
                logger.info("Catch-up: executing missed one-shot job: \(job.name) (was due: \(fireDate))")
                executeJob(job)
                _ = store.remove(job.id)
            } else {
                // Recurring: log if missed, update nextRun
                guard let lastRun = job.lastRun else { continue }
                do {
                    let expr = try CronExpression(job.schedule)
                    if let expectedNext = expr.nextOccurrence(after: lastRun),
                       now > expectedNext {
                        let missedMinutes = Int(now.timeIntervalSince(expectedNext) / 60)
                        logger.warning("Catch-up: recurring job '\(job.name)' missed by ~\(missedMinutes) min (expected: \(expectedNext))")

                        // Update nextRun to the next future occurrence
                        job.nextRun = expr.nextOccurrence(after: now)
                        store.update(job)
                    }
                } catch {
                    logger.error("Catch-up: invalid cron expression for \(job.name): \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
        logger.info("CronRunner stopped.")
    }

    /// Summary of active jobs for system prompt injection.
    func activeJobsSummary() -> String {
        let jobs = store.enabledJobs()
        if jobs.isEmpty { return "None" }
        return jobs.map { job in
            let type = job.isOneShot ? "Reminder" : "Cron"
            let next = job.nextRunFormatted
            return "- [\(type)] \(job.name) | \(job.schedule) | next: \(next)"
        }.joined(separator: "\n")
    }

    // MARK: - Check Loop

    private func checkJobs() {
        _checkJobsUnsafe()
    }

    private func _checkJobsUnsafe() {
        let now = Date()
        let cal = Calendar.current
        let currentMinute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)

        let jobs = store.listAll()

        for var job in jobs where job.enabled {
            if job.isOneShot {
                // One-shot: fire when nextRun has passed
                guard let fireDate = job.nextRun, now >= fireDate else { continue }
                logger.info("One-shot job triggered: \(job.name) (\(job.id))")
                executeJob(job)

                // Remove one-shot jobs after execution
                _ = store.remove(job.id)
            } else {
                // Recurring: only check once per minute to avoid duplicate triggers
                guard currentMinute != lastCheckMinute else { continue }

                do {
                    let expr = try CronExpression(job.schedule)
                    if expr.matches(now) {
                        logger.info("Cron job triggered: \(job.name) (\(job.id))")
                        executeJob(job)

                        // Update job state
                        job.lastRun = now
                        job.runCount += 1
                        job.nextRun = expr.nextOccurrence(after: now)
                        store.update(job)
                    }
                } catch {
                    logger.error("Invalid cron expression for job \(job.name): \(error.localizedDescription)")
                }
            }
        }

        lastCheckMinute = currentMinute
    }

    private func executeJob(_ job: CronJob) {
        // Extract the action text
        let actionText: String
        switch job.action {
        case .notification(_, let body):
            actionText = body
        case .message(let text):
            actionText = text
        case .tool(let name, let arguments):
            let argsStr = arguments.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            actionText = argsStr.isEmpty ? "Run the \(name) tool" : "Run the \(name) tool with \(argsStr)"
        }

        // If we have an LLM callback, send the action to Dockwright for execution
        if let handler = onExecuteAction, !actionText.isEmpty {
            logger.info("Sending cron job '\(job.name)' to Dockwright: \(actionText.prefix(80))")

            // Also send a notification so user knows a job fired
            Task {
                await channel.broadcast(
                    title: "Dockwright: \(job.name)",
                    body: "Running scheduled task...",
                    category: .scheduledTask
                )
            }

            handler(job.name, "[Scheduled job: \(job.name)] \(actionText)")
        } else {
            // Fallback: just send a notification
            Task {
                await channel.broadcast(
                    title: "Dockwright: \(job.name)",
                    body: actionText.isEmpty ? job.name : actionText,
                    category: .scheduledTask
                )
                logger.info("Notification delivered for job: \(job.name)")
            }
        }
    }
}
