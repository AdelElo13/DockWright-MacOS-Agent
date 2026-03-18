import SwiftUI

/// Fully interactive scheduler dashboard — create, edit, delete cron jobs and reminders.
struct SchedulerView: View {
    let store: CronStore
    var appState: AppState?
    @State private var jobs: [CronJob] = []
    @State private var editingJob: CronJob?
    @State private var isCreatingNew = false

    var body: some View {
        ZStack {
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

            // Job editor — in ZStack (not .overlay{}) to avoid blocking scroll
            if isCreatingNew || editingJob != nil {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        isCreatingNew = false
                        editingJob = nil
                    }

                JobEditorView(
                    job: editingJob,
                    onSave: { job in
                        if editingJob != nil {
                            store.update(job)
                        } else {
                            store.add(job)
                        }
                        editingJob = nil
                        isCreatingNew = false
                        refreshJobs()
                        appState?.cronJobCount = store.listAll().count
                    },
                    onCancel: {
                        editingJob = nil
                        isCreatingNew = false
                    }
                )
                .frame(width: 460)
                .background(DockwrightTheme.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.lg))
                .shadow(color: .black.opacity(0.5), radius: 20)
            }
        }
        // Removed implicit .animation() — blocks ScrollView scroll events on macOS
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cron Jobs")
                    .font(DockwrightTheme.Typography.title)
                    .foregroundStyle(.white)
                Text("\(jobs.count) job\(jobs.count == 1 ? "" : "s")")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                appState?.showScheduler = false
                Task {
                    await appState?.sendMessage("Help me set up a scheduled automation or recurring reminder")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                    Text("Ask Dockwright")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                editingJob = nil
                isCreatingNew = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("New Job")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(DockwrightTheme.primary.opacity(0.8))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                appState?.showScheduler = false
            } label: {
                Text("Done")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, DockwrightTheme.Spacing.lg)
                    .padding(.vertical, 6)
                    .background(DockwrightTheme.primary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DockwrightTheme.Spacing.lg)
        .padding(.vertical, DockwrightTheme.Spacing.md)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DockwrightTheme.Spacing.lg) {
            Spacer()
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No cron jobs yet")
                .font(DockwrightTheme.Typography.body)
                .foregroundStyle(.secondary)
            Text("Use the buttons above to create a job or ask Dockwright")
                .font(DockwrightTheme.Typography.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Job List

    private var jobList: some View {
        ScrollView {
            LazyVStack(spacing: DockwrightTheme.Spacing.sm) {
                ForEach(jobs) { job in
                    jobRow(job)
                }
            }
            .padding(.horizontal, DockwrightTheme.Spacing.lg)
            .padding(.vertical, DockwrightTheme.Spacing.sm)
        }
    }

    private func jobRow(_ job: CronJob) -> some View {
        HStack(spacing: DockwrightTheme.Spacing.sm) {
            // Enable/disable toggle
            Toggle("", isOn: Binding(
                get: { job.enabled },
                set: { newVal in
                    var updated = job
                    updated.enabled = newVal
                    store.update(updated)
                    refreshJobs()
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(job.enabled ? .white : .secondary)
                    .lineLimit(1)

                Text(Self.friendlySchedule(job.schedule))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Text(job.action.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
            }

            Spacer()

            // Next run
            if job.enabled {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("next")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                    Text(job.nextRunFormatted)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Edit
            Button {
                editingJob = job
                isCreatingNew = false
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)

            // Delete
            Button {
                _ = store.remove(job.id)
                refreshJobs()
                appState?.cronJobCount = store.listAll().count
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
        .opacity(job.enabled ? 1.0 : 0.6)
    }

    // MARK: - Helpers

    private func refreshJobs() {
        jobs = store.listAll()
    }

    /// Convert cron expressions and ISO dates to human-readable format
    static func friendlySchedule(_ schedule: String) -> String {
        // Check if it looks like an ISO 8601 date
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: schedule) {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            return fmt.string(from: date)
        }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFrac.date(from: schedule) {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            return fmt.string(from: date)
        }

        // Parse cron expression to friendly text
        let parts = schedule.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return schedule }
        let minP = parts[0], hourP = parts[1], dayP = parts[2], monP = parts[3], dowP = parts[4]
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

        // Format time string if we have specific hour+minute
        func timeStr() -> String {
            let h = Int(hourP) ?? 0
            let m = Int(minP) ?? 0
            return String(format: "%d:%02d", h, m)
        }

        if minP == "*" && hourP == "*" { return "Every minute" }
        if minP.hasPrefix("*/") && hourP == "*" { return "Every \(minP.dropFirst(2)) min" }
        if hourP == "*" && dayP == "*" { return "Every hour" }
        if hourP.hasPrefix("*/") { return "Every \(hourP.dropFirst(2)) hours" }
        if dayP == "*" && monP == "*" && dowP != "*" {
            let d = Int(dowP) ?? 0
            return "Every \(weekdays[d % 7]) at \(timeStr())"
        }
        if dayP.hasPrefix("*/") { return "Every \(dayP.dropFirst(2)) days at \(timeStr())" }
        if monP.hasPrefix("*/") { return "Every \(monP.dropFirst(2)) months" }
        if dayP == "1" && monP == "*" { return "Monthly at \(timeStr())" }
        if dayP == "*" && monP == "*" && dowP == "*" { return "Daily at \(timeStr())" }

        return schedule
    }
}

// MARK: - Job Editor — Simple visual form, no cron syntax visible

struct JobEditorView: View {
    let job: CronJob?
    let onSave: (CronJob) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var action: String = ""
    @State private var enabled: Bool = true

    // Schedule building blocks — no cron syntax shown to user
    enum RepeatMode: String, CaseIterable {
        case minutes = "Minutes"
        case hours = "Hours"
        case days = "Days"
        case weeks = "Weeks"
        case months = "Months"
    }

    @State private var repeatMode: RepeatMode = .days
    @State private var repeatInterval: Int = 1
    @State private var timeOfDay: Date = {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 9
        comps.minute = 0
        return Calendar.current.date(from: comps) ?? Date()
    }()
    @State private var dayOfWeek: Int = 2 // Monday

    private let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(job == nil ? "New Job" : "Edit Job")
                    .font(DockwrightTheme.Typography.title)
                    .foregroundStyle(.white)
                Spacer()
                Button { onCancel() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DockwrightTheme.Spacing.lg)
            .padding(.top, DockwrightTheme.Spacing.lg)
            .padding(.bottom, DockwrightTheme.Spacing.md)

            Divider().opacity(0.2)

            ScrollView {
                VStack(alignment: .leading, spacing: DockwrightTheme.Spacing.lg) {
                    // 1. Name
                    fieldGroup("Name") {
                        TextField("e.g. Morning briefing, Check email", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .padding(10)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // 2. Repeat — visual picker
                    fieldGroup("Repeat every") {
                        HStack(spacing: 12) {
                            // Number stepper
                            HStack(spacing: 0) {
                                Button {
                                    if repeatInterval > 1 { repeatInterval -= 1 }
                                } label: {
                                    Image(systemName: "minus")
                                        .font(.system(size: 12, weight: .bold))
                                        .frame(width: 32, height: 32)
                                        .foregroundStyle(.white)
                                        .background(Color.white.opacity(0.1))
                                }
                                .buttonStyle(.plain)

                                Text("\(repeatInterval)")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 40, height: 32)
                                    .background(Color.white.opacity(0.05))

                                Button {
                                    if repeatInterval < 365 { repeatInterval += 1 }
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 12, weight: .bold))
                                        .frame(width: 32, height: 32)
                                        .foregroundStyle(.white)
                                        .background(Color.white.opacity(0.1))
                                }
                                .buttonStyle(.plain)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            // Unit picker as segmented chips
                            HStack(spacing: 4) {
                                ForEach(RepeatMode.allCases, id: \.self) { mode in
                                    Button {
                                        repeatMode = mode
                                    } label: {
                                        Text(repeatInterval == 1 ? singularLabel(mode) : mode.rawValue)
                                            .font(.system(size: 12, weight: repeatMode == mode ? .semibold : .regular))
                                            .foregroundStyle(repeatMode == mode ? .white : .secondary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(repeatMode == mode ? DockwrightTheme.primary.opacity(0.8) : Color.white.opacity(0.05))
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Summary
                        Text(scheduleSummary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }

                    // 3. Day of week (only for weeks mode)
                    if repeatMode == .weeks {
                        fieldGroup("On") {
                            HStack(spacing: 4) {
                                ForEach(0..<7, id: \.self) { day in
                                    Button {
                                        dayOfWeek = day + 1
                                    } label: {
                                        Text(String(weekdays[day].prefix(3)))
                                            .font(.system(size: 12, weight: dayOfWeek == day + 1 ? .semibold : .regular))
                                            .foregroundStyle(dayOfWeek == day + 1 ? .white : .secondary)
                                            .frame(width: 42, height: 30)
                                            .background(dayOfWeek == day + 1 ? DockwrightTheme.primary.opacity(0.8) : Color.white.opacity(0.05))
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // 4. Time of day (for hours, days, weeks, months)
                    if repeatMode != .minutes {
                        fieldGroup("At") {
                            DatePicker("", selection: $timeOfDay, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .datePickerStyle(.field)
                        }
                    }

                    // 5. Action
                    fieldGroup("What should happen?") {
                        TextEditor(text: $action)
                            .font(.system(size: 14))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 80, maxHeight: 160)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .topLeading) {
                                if action.isEmpty {
                                    Text("e.g. Send me a daily summary, Check disk space, Remind me to stretch...")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.quaternary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 12)
                                        .allowsHitTesting(false)
                                }
                            }
                        Text("Dockwright will execute this for you")
                            .font(.system(size: 11))
                            .foregroundStyle(.quaternary)
                    }

                    // Enabled toggle
                    Toggle("Enabled", isOn: $enabled)
                        .toggleStyle(.switch)
                        .foregroundStyle(.white)
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, DockwrightTheme.Spacing.lg)
                .padding(.vertical, DockwrightTheme.Spacing.md)
            }

            Divider().opacity(0.2)

            // Footer buttons
            HStack {
                Button { onCancel() } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    saveJob()
                } label: {
                    Text(job == nil ? "Create Job" : "Save Changes")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(canSave ? DockwrightTheme.primary : DockwrightTheme.primary.opacity(0.3))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
            .padding(.horizontal, DockwrightTheme.Spacing.lg)
            .padding(.vertical, DockwrightTheme.Spacing.md)
        }
        .onAppear { loadFromJob() }
    }

    // MARK: - Helpers

    private var canSave: Bool {
        !name.isEmpty && !action.isEmpty
    }

    private func singularLabel(_ mode: RepeatMode) -> String {
        switch mode {
        case .minutes: return "Minute"
        case .hours: return "Hour"
        case .days: return "Day"
        case .weeks: return "Week"
        case .months: return "Month"
        }
    }

    private var scheduleSummary: String {
        let hour = Calendar.current.component(.hour, from: timeOfDay)
        let minute = Calendar.current.component(.minute, from: timeOfDay)
        let timeStr = String(format: "%d:%02d", hour, minute)

        switch repeatMode {
        case .minutes:
            return repeatInterval == 1 ? "Every minute" : "Every \(repeatInterval) minutes"
        case .hours:
            return repeatInterval == 1 ? "Every hour at :\(String(format: "%02d", minute))" : "Every \(repeatInterval) hours"
        case .days:
            return repeatInterval == 1 ? "Every day at \(timeStr)" : "Every \(repeatInterval) days at \(timeStr)"
        case .weeks:
            let dayName = weekdays[(dayOfWeek - 1) % 7]
            return repeatInterval == 1 ? "Every \(dayName) at \(timeStr)" : "Every \(repeatInterval) weeks on \(dayName) at \(timeStr)"
        case .months:
            return repeatInterval == 1 ? "Every month at \(timeStr)" : "Every \(repeatInterval) months at \(timeStr)"
        }
    }

    /// Build a cron expression from the visual picker state
    private var cronExpression: String {
        let hour = Calendar.current.component(.hour, from: timeOfDay)
        let minute = Calendar.current.component(.minute, from: timeOfDay)

        switch repeatMode {
        case .minutes:
            return repeatInterval == 1 ? "* * * * *" : "*/\(repeatInterval) * * * *"
        case .hours:
            return repeatInterval == 1 ? "\(minute) * * * *" : "\(minute) */\(repeatInterval) * * *"
        case .days:
            return repeatInterval == 1 ? "\(minute) \(hour) * * *" : "\(minute) \(hour) */\(repeatInterval) * *"
        case .weeks:
            let dow = (dayOfWeek - 1) % 7 // 0=Sun, 1=Mon, etc.
            return "\(minute) \(hour) * * \(dow)"
        case .months:
            return "\(minute) \(hour) 1 */\(repeatInterval) *"
        }
    }

    private func loadFromJob() {
        guard let job else { return }
        name = job.name
        enabled = job.enabled

        // Parse action
        switch job.action {
        case .notification(_, let body):
            action = body
        case .message(let text):
            action = text
        case .tool(let tName, let args):
            let argsStr = args.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            action = argsStr.isEmpty ? tName : "\(tName): \(argsStr)"
        }

        // Parse cron expression back into visual state
        parseCronToVisual(job.schedule)
    }

    private func parseCronToVisual(_ cron: String) {
        let parts = cron.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return }

        let minPart = parts[0]
        let hourPart = parts[1]
        let dayPart = parts[2]
        let monPart = parts[3]
        let dowPart = parts[4]

        // Set time from parsed hour/minute
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        if let h = Int(hourPart) { comps.hour = h } else { comps.hour = 9 }
        if let m = Int(minPart) { comps.minute = m } else { comps.minute = 0 }
        if let date = Calendar.current.date(from: comps) { timeOfDay = date }

        // Every N minutes: */N * * * *
        if minPart.hasPrefix("*/") && hourPart == "*" {
            repeatMode = .minutes
            repeatInterval = Int(minPart.dropFirst(2)) ?? 5
            return
        }
        // Every minute: * * * * *
        if minPart == "*" && hourPart == "*" {
            repeatMode = .minutes
            repeatInterval = 1
            return
        }
        // Every N hours: M */N * * *
        if hourPart.hasPrefix("*/") {
            repeatMode = .hours
            repeatInterval = Int(hourPart.dropFirst(2)) ?? 1
            return
        }
        // Hourly: M * * * *
        if hourPart == "*" && dayPart == "*" {
            repeatMode = .hours
            repeatInterval = 1
            return
        }
        // Weekly: M H * * DOW
        if dayPart == "*" && monPart == "*" && dowPart != "*" {
            repeatMode = .weeks
            repeatInterval = 1
            dayOfWeek = (Int(dowPart) ?? 0) + 1
            return
        }
        // Every N days: M H */N * *
        if dayPart.hasPrefix("*/") {
            repeatMode = .days
            repeatInterval = Int(dayPart.dropFirst(2)) ?? 1
            return
        }
        // Monthly: M H 1 */N *
        if monPart.hasPrefix("*/") {
            repeatMode = .months
            repeatInterval = Int(monPart.dropFirst(2)) ?? 1
            return
        }
        // Monthly: M H 1 * *
        if dayPart == "1" && monPart == "*" {
            repeatMode = .months
            repeatInterval = 1
            return
        }
        // Daily (default): M H * * *
        repeatMode = .days
        repeatInterval = 1
    }

    private func saveJob() {
        let cronAction: CronAction = .notification(title: name, body: action)
        let cron = cronExpression

        var nextRun: Date? = nil
        if let expr = try? CronExpression(cron) {
            nextRun = expr.nextOccurrence(after: Date())
        }

        let newJob = CronJob(
            id: job?.id ?? UUID().uuidString.prefix(8).lowercased().description,
            name: name,
            schedule: cron,
            isOneShot: false,
            action: cronAction,
            enabled: enabled,
            lastRun: job?.lastRun,
            nextRun: nextRun,
            runCount: job?.runCount ?? 0,
            createdAt: job?.createdAt ?? Date()
        )
        onSave(newJob)
    }

    private func fieldGroup<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
            content()
        }
    }
}
