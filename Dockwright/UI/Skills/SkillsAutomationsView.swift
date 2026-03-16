import SwiftUI

/// Comprehensive dashboard for skills, goals, automations, and heartbeat status.
struct SkillsAutomationsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var appState: AppState

    // MARK: - Local State

    @State private var skills: [SkillLoader.Skill] = []
    @State private var goals: [Goal] = []
    @State private var todaysActions: [DailyAction] = []
    @State private var cronJobs: [CronJob] = []

    // Add Goal form
    @State private var showAddGoal = false
    @State private var newGoalTitle = ""
    @State private var newGoalDescription = ""
    @State private var newGoalCategory = "personal"
    @State private var newGoalHasTarget = false
    @State private var newGoalTargetDate = Date()

    private let goalCategories = ["health", "career", "learning", "personal", "financial"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            ScrollView {
                VStack(spacing: DockwrightTheme.Spacing.xl) {
                    skillsSection
                    goalsSection
                    automationsSection
                    heartbeatSection
                }
                .padding(.horizontal, DockwrightTheme.Spacing.lg)
                .padding(.vertical, DockwrightTheme.Spacing.md)
            }
        }
        .frame(minWidth: 520, minHeight: 500)
        .background(DockwrightTheme.Surface.canvas)
        .onAppear { refreshAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Skills & Automations")
                    .font(DockwrightTheme.Typography.title)
                    .foregroundStyle(.white)
                Text("\(skills.count) skills, \(goals.count) goals, \(cronJobs.count) jobs")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DockwrightTheme.Spacing.lg)
        .padding(.vertical, DockwrightTheme.Spacing.md)
    }

    // MARK: - 1. Active Skills

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: DockwrightTheme.Spacing.sm) {
            sectionHeader("Active Skills", count: skills.count)

            if skills.isEmpty {
                emptyCard("No skills loaded", subtitle: "Create a skill to teach Dockwright new capabilities.")
            } else {
                ForEach(Array(skills.enumerated()), id: \.offset) { _, skill in
                    skillRow(skill)
                }
            }

            Button {
                dismiss()
                Task {
                    await appState.sendMessage("Create a new skill for me")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("Create New Skill")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(DockwrightTheme.primary.opacity(0.8))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func skillRow(_ skill: SkillLoader.Skill) -> some View {
        HStack(spacing: DockwrightTheme.Spacing.sm) {
            Image(systemName: skill.source == "builtin" ? "star.fill" : "doc.text.fill")
                .font(.system(size: 14))
                .foregroundStyle(skill.source == "builtin" ? DockwrightTheme.caution : DockwrightTheme.primary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(skill.description)
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Spacer()

            if !skill.requires.isEmpty {
                Text(skill.requires.joined(separator: ", "))
                    .font(DockwrightTheme.Typography.captionMono)
                    .foregroundStyle(.quaternary)
            }

            if skill.source != "builtin" {
                Button {
                    deleteSkill(skill)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DockwrightTheme.Spacing.md)
        .padding(.vertical, DockwrightTheme.Spacing.sm)
        .background(DockwrightTheme.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md))
    }

    // MARK: - 2. Goals

    private var goalsSection: some View {
        VStack(alignment: .leading, spacing: DockwrightTheme.Spacing.sm) {
            sectionHeader("Goals", count: goals.count)

            if goals.isEmpty {
                emptyCard("No active goals", subtitle: "Add a goal to start tracking your progress.")
            } else {
                ForEach(goals) { goal in
                    goalRow(goal)
                }
            }

            // Today's actions
            if !todaysActions.isEmpty {
                HStack {
                    Text("Today's Actions")
                        .font(DockwrightTheme.Typography.sectionHeader)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    let done = todaysActions.filter(\.isCompleted).count
                    Text("\(done)/\(todaysActions.count)")
                        .font(DockwrightTheme.Typography.captionMono)
                        .foregroundStyle(.quaternary)
                }
                .padding(.top, DockwrightTheme.Spacing.xs)

                ForEach(Array(todaysActions.enumerated()), id: \.element.id) { _, action in
                    actionRow(action)
                }
            }

            // Add Goal button / inline form
            if showAddGoal {
                addGoalForm
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAddGoal = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Goal")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(DockwrightTheme.accent.opacity(0.8))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func goalRow(_ goal: Goal) -> some View {
        VStack(alignment: .leading, spacing: DockwrightTheme.Spacing.xs) {
            HStack(spacing: DockwrightTheme.Spacing.sm) {
                Text(goal.category.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(categoryColor(goal.category))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(categoryColor(goal.category).opacity(0.15))
                    .clipShape(Capsule())

                Text(goal.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                if let target = goal.targetDate {
                    Text(target, style: .date)
                        .font(DockwrightTheme.Typography.captionMono)
                        .foregroundStyle(.tertiary)
                }

                Text("\(goal.completionPercentage)%")
                    .font(DockwrightTheme.Typography.captionMono)
                    .foregroundStyle(.secondary)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(categoryColor(goal.category))
                        .frame(width: geo.size.width * CGFloat(goal.completionPercentage) / 100.0, height: 4)
                }
            }
            .frame(height: 4)

            // Milestones summary
            if !goal.milestones.isEmpty {
                let done = goal.milestones.filter(\.isCompleted).count
                Text("\(done)/\(goal.milestones.count) milestones completed")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, DockwrightTheme.Spacing.md)
        .padding(.vertical, DockwrightTheme.Spacing.sm)
        .background(DockwrightTheme.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md))
    }

    private func actionRow(_ action: DailyAction) -> some View {
        HStack(spacing: DockwrightTheme.Spacing.sm) {
            Button {
                markActionDone(action)
            } label: {
                Image(systemName: action.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(action.isCompleted ? DockwrightTheme.success : Color.gray)
            }
            .buttonStyle(.plain)

            Text(action.task)
                .font(.system(size: 13))
                .foregroundStyle(action.isCompleted ? Color.gray : Color.white)
                .strikethrough(action.isCompleted)
                .lineLimit(2)

            Spacer()

            Text("P\(action.priority)")
                .font(DockwrightTheme.Typography.captionMono)
                .foregroundStyle(action.priority >= 4 ? DockwrightTheme.caution : Color.gray.opacity(0.5))
        }
        .padding(.horizontal, DockwrightTheme.Spacing.md)
        .padding(.vertical, DockwrightTheme.Spacing.xs)
        .background(DockwrightTheme.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.sm))
    }

    private var addGoalForm: some View {
        VStack(alignment: .leading, spacing: DockwrightTheme.Spacing.sm) {
            Text("New Goal")
                .font(DockwrightTheme.Typography.heading)
                .foregroundStyle(.white)

            TextField("Title", text: $newGoalTitle)
                .textFieldStyle(.roundedBorder)

            TextField("Description", text: $newGoalDescription)
                .textFieldStyle(.roundedBorder)

            Picker("Category", selection: $newGoalCategory) {
                ForEach(goalCategories, id: \.self) { cat in
                    Text(cat.capitalized).tag(cat)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Set target date", isOn: $newGoalHasTarget)
                .font(DockwrightTheme.Typography.body)
                .foregroundStyle(.white)

            if newGoalHasTarget {
                DatePicker("Target", selection: $newGoalTargetDate, displayedComponents: .date)
                    .font(DockwrightTheme.Typography.body)
                    .foregroundStyle(.white)
            }

            HStack {
                Button("Cancel") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        resetGoalForm()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Add Goal") {
                    addGoal()
                }
                .buttonStyle(.borderedProminent)
                .tint(DockwrightTheme.accent)
                .disabled(newGoalTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DockwrightTheme.Spacing.md)
        .background(DockwrightTheme.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - 3. Automations

    private var automationsSection: some View {
        VStack(alignment: .leading, spacing: DockwrightTheme.Spacing.sm) {
            sectionHeader("Automations", count: cronJobs.count)

            if cronJobs.isEmpty {
                emptyCard("No automations", subtitle: "Ask Dockwright to schedule recurring tasks or reminders.")
            } else {
                ForEach(cronJobs) { job in
                    cronJobRow(job)
                }
            }
        }
    }

    private func cronJobRow(_ job: CronJob) -> some View {
        HStack(spacing: DockwrightTheme.Spacing.sm) {
            // Status dot
            Circle()
                .fill(job.enabled ? DockwrightTheme.success : Color.gray.opacity(0.5))
                .frame(width: 8, height: 8)

            // Icon
            Image(systemName: job.isOneShot ? "bell.fill" : "arrow.clockwise")
                .font(.system(size: 14))
                .foregroundStyle(job.isOneShot ? DockwrightTheme.caution : DockwrightTheme.primary)
                .frame(width: 20)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(job.schedule.count > 25 ? String(job.schedule.prefix(25)) + "..." : job.schedule)
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

            // Times
            VStack(alignment: .trailing, spacing: 2) {
                if let lastRun = job.lastRun {
                    HStack(spacing: 4) {
                        Text("last")
                            .font(.system(size: 10))
                            .foregroundStyle(.quaternary)
                        Text(lastRun, style: .relative)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 4) {
                    Text("next")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                    Text(job.nextRunFormatted)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Enable/disable toggle
            Toggle("", isOn: Binding(
                get: { job.enabled },
                set: { newValue in
                    toggleJobEnabled(job, enabled: newValue)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.horizontal, DockwrightTheme.Spacing.md)
        .padding(.vertical, DockwrightTheme.Spacing.sm)
        .background(DockwrightTheme.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md))
    }

    // MARK: - 4. Heartbeat Status

    private var heartbeatSection: some View {
        VStack(alignment: .leading, spacing: DockwrightTheme.Spacing.sm) {
            HStack {
                Text("Heartbeat")
                    .font(DockwrightTheme.Typography.sectionHeader)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack(spacing: DockwrightTheme.Spacing.md) {
                // Status indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.heartbeat.isRunning ? DockwrightTheme.success : DockwrightTheme.error)
                        .frame(width: 8, height: 8)
                    Text(appState.heartbeat.isRunning ? "Running" : "Stopped")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }

                Spacer()

                // Interval info
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Check interval: 30 min")
                        .font(DockwrightTheme.Typography.captionMono)
                        .foregroundStyle(.tertiary)
                    Text("Active hours: 07:00 - 23:00")
                        .font(DockwrightTheme.Typography.captionMono)
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, DockwrightTheme.Spacing.md)
            .padding(.vertical, DockwrightTheme.Spacing.sm)
            .background(DockwrightTheme.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md))
        }
    }

    // MARK: - Shared Components

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
    }

    private func emptyCard(_ title: String, subtitle: String) -> some View {
        VStack(spacing: DockwrightTheme.Spacing.xs) {
            Text(title)
                .font(DockwrightTheme.Typography.body)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(DockwrightTheme.Typography.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DockwrightTheme.Spacing.lg)
        .background(DockwrightTheme.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md))
    }

    // MARK: - Actions

    private func refreshAll() {
        skills = appState.skillLoader.allSkills
        goals = appState.goalStore.listGoals(activeOnly: true)
        todaysActions = appState.goalStore.todaysActions()
        cronJobs = appState.cronStore.listAll()
    }

    private func deleteSkill(_ skill: SkillLoader.Skill) {
        guard skill.source != "builtin" else { return }
        let url = URL(fileURLWithPath: skill.source)
        try? FileManager.default.removeItem(at: url)
        appState.skillLoader.reload()
        skills = appState.skillLoader.allSkills
    }

    private func markActionDone(_ action: DailyAction) {
        guard !action.isCompleted else { return }
        _ = try? appState.goalStore.completeAction(id: action.id)
        todaysActions = appState.goalStore.todaysActions()
    }

    private func toggleJobEnabled(_ job: CronJob, enabled: Bool) {
        var updated = job
        updated.enabled = enabled
        appState.cronStore.update(updated)
        cronJobs = appState.cronStore.listAll()
    }

    private func addGoal() {
        let title = newGoalTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let desc = newGoalDescription.trimmingCharacters(in: .whitespaces)
        let target: Date? = newGoalHasTarget ? newGoalTargetDate : nil

        _ = try? appState.goalStore.addGoal(
            title: title,
            description: desc,
            category: newGoalCategory,
            targetDate: target
        )

        resetGoalForm()
        goals = appState.goalStore.listGoals(activeOnly: true)
    }

    private func resetGoalForm() {
        showAddGoal = false
        newGoalTitle = ""
        newGoalDescription = ""
        newGoalCategory = "personal"
        newGoalHasTarget = false
        newGoalTargetDate = Date()
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "health": return DockwrightTheme.success
        case "career": return DockwrightTheme.primary
        case "learning": return DockwrightTheme.info
        case "financial": return DockwrightTheme.caution
        case "personal": return DockwrightTheme.secondary
        default: return DockwrightTheme.secondary
        }
    }
}
