import SwiftUI

/// Dashboard showing all scheduled cron jobs and reminders.
struct SchedulerView: View {
    let store: CronStore
    var onClose: (() -> Void)?
    @State private var jobs: [CronJob] = []
    @State private var showAddReminder = false
    @State private var reminderMessage = ""
    @State private var reminderDelay = "5 minutes"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            if jobs.isEmpty {
                emptyState
            } else {
                jobList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DockwrightTheme.Surface.canvas)
        .onAppear { refreshJobs() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scheduler")
                    .font(DockwrightTheme.Typography.title)
                    .foregroundStyle(.white)
                Text("\(jobs.count) job\(jobs.count == 1 ? "" : "s")")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showAddReminder.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("Quick Reminder")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(DockwrightTheme.primary.opacity(0.8))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            if let onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Scheduler")
            }
        }
        .padding(.horizontal, DockwrightTheme.Spacing.lg)
        .padding(.vertical, DockwrightTheme.Spacing.md)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DockwrightTheme.Spacing.md) {
            Spacer()
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No scheduled jobs")
                .font(DockwrightTheme.Typography.body)
                .foregroundStyle(.secondary)
            Text("Ask Dockwright to set a reminder or create a cron job.")
                .font(DockwrightTheme.Typography.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Job List

    private var jobList: some View {
        ScrollView {
            LazyVStack(spacing: DockwrightTheme.Spacing.sm) {
                // Reminders section
                let reminders = jobs.filter(\.isOneShot)
                if !reminders.isEmpty {
                    sectionHeader("Reminders", count: reminders.count)
                    ForEach(reminders) { job in
                        jobRow(job)
                    }
                }

                // Cron jobs section
                let crons = jobs.filter { !$0.isOneShot }
                if !crons.isEmpty {
                    sectionHeader("Recurring Jobs", count: crons.count)
                    ForEach(crons) { job in
                        jobRow(job)
                    }
                }
            }
            .padding(.horizontal, DockwrightTheme.Spacing.lg)
            .padding(.vertical, DockwrightTheme.Spacing.sm)
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(DockwrightTheme.Typography.sectionHeader)
                .foregroundStyle(.tertiary)
            Spacer()
            Text("\(count)")
                .font(DockwrightTheme.Typography.captionMono)
                .foregroundStyle(.quaternary)
        }
        .padding(.top, DockwrightTheme.Spacing.sm)
    }

    private func jobRow(_ job: CronJob) -> some View {
        HStack(spacing: DockwrightTheme.Spacing.sm) {
            // Icon
            Image(systemName: job.isOneShot ? "bell.fill" : "arrow.clockwise")
                .font(.system(size: 14))
                .foregroundStyle(job.isOneShot ? DockwrightTheme.caution : DockwrightTheme.primary)
                .frame(width: 24)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(job.schedule.count > 20 ? String(job.schedule.prefix(20)) + "..." : job.schedule)
                        .font(DockwrightTheme.Typography.captionMono)
                        .foregroundStyle(.tertiary)

                    if !job.isOneShot {
                        Text("runs: \(job.runCount)")
                            .font(DockwrightTheme.Typography.captionMono)
                            .foregroundStyle(.quaternary)
                    }
                }
            }

            Spacer()

            // Next run
            VStack(alignment: .trailing, spacing: 2) {
                Text("next")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                Text(job.nextRunFormatted)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Delete
            Button {
                _ = store.remove(job.id)
                refreshJobs()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DockwrightTheme.Spacing.md)
        .padding(.vertical, DockwrightTheme.Spacing.sm)
        .background(DockwrightTheme.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md))
    }

    // MARK: - Add Reminder Sheet

    @ViewBuilder
    private var addReminderSheet: some View {
        VStack(spacing: DockwrightTheme.Spacing.md) {
            Text("Quick Reminder")
                .font(DockwrightTheme.Typography.title)

            TextField("What to remember", text: $reminderMessage)
                .textFieldStyle(.roundedBorder)

            TextField("In how long? (e.g. 5 minutes)", text: $reminderDelay)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    showAddReminder = false
                }
                Spacer()
                Button("Set Reminder") {
                    if !reminderMessage.isEmpty {
                        _ = ReminderService.setReminder(
                            message: reminderMessage,
                            delay: reminderDelay,
                            store: store
                        )
                        reminderMessage = ""
                        reminderDelay = "5 minutes"
                        showAddReminder = false
                        refreshJobs()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(DockwrightTheme.Spacing.lg)
        .frame(width: 350)
    }

    // MARK: - Helpers

    private func refreshJobs() {
        jobs = store.listAll()
    }
}
