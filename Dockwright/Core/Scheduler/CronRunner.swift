import Foundation
import os

/// Timer loop that checks every 30 seconds for due jobs and executes them.
/// Runs on a background thread. Delivers via DeliveryChannel.
final class CronRunner: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "CronRunner")
    private let store: CronStore
    private let channel: NotificationChannel
    private let checkInterval: TimeInterval = 30
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.Aatje.Dockwright.CronRunner", qos: .utility)
    private var lastCheckMinute: Int = -1
    private(set) var isRunning = false

    init(store: CronStore, channel: NotificationChannel) {
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
            await channel.requestPermission()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: checkInterval)
        timer.setEventHandler { [weak self] in
            self?.checkJobs()
        }
        timer.resume()
        self.timer = timer
        logger.info("CronRunner started (interval: \(Int(self.checkInterval))s)")
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
        // Wrap entire check in do/catch to never crash the timer loop
        do {
            _checkJobsUnsafe()
        } catch {
            logger.error("CronRunner check failed: \(error.localizedDescription)")
        }
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
        switch job.action {
        case .notification(let title, let body):
            Task {
                do {
                    try await channel.send(title: title, body: body)
                    logger.info("Notification delivered for job: \(job.name)")
                } catch {
                    logger.error("Failed to deliver notification for \(job.name): \(error.localizedDescription)")
                }
            }

        case .message(let text):
            // Deliver as notification for now
            Task {
                do {
                    try await channel.send(title: "Dockwright", body: text)
                } catch {
                    logger.error("Failed to deliver message for \(job.name): \(error.localizedDescription)")
                }
            }

        case .tool(let name, let arguments):
            // Execute via ToolRegistry
            Task {
                let tool = ToolRegistry.shared.get(name: name)
                if let tool {
                    let args: [String: Any] = Dictionary(uniqueKeysWithValues: arguments.map { ($0.key, $0.value as Any) })
                    do {
                        let result = try await tool.execute(arguments: args)
                        logger.info("Tool \(name) executed for job \(job.name): \(result.output.prefix(100))")
                        // Send result as notification
                        try await channel.send(
                            title: "Dockwright: \(job.name)",
                            body: result.isError ? "Error: \(result.output)" : result.output
                        )
                    } catch {
                        logger.error("Tool execution failed for \(job.name): \(error.localizedDescription)")
                    }
                } else {
                    logger.error("Tool '\(name)' not found for job \(job.name)")
                }
            }
        }
    }
}
