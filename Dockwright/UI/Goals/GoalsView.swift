import SwiftUI

/// Goals dashboard — track personal goals, milestones, and daily actions.
struct GoalsView: View {
    @Bindable var appState: AppState

    @State private var goals: [Goal] = []
    @State private var todaysActions: [DailyAction] = []

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
                VStack(spacing: DockwrightTheme.Spacing.lg) {
                    goalsSection
                    if !todaysActions.isEmpty {
                        actionsSection
                    }
                }
                .padding(.horizontal, DockwrightTheme.Spacing.lg)
                .padding(.vertical, DockwrightTheme.Spacing.md)
            }
        }
        .frame(minWidth: 520, minHeight: 400)
        .background(DockwrightTheme.Surface.canvas)
        .onAppear { refreshAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Goals")
                    .font(DockwrightTheme.Typography.title)
                    .foregroundStyle(.white)
                Text("\(goals.count) goal\(goals.count == 1 ? "" : "s")")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                appState.showGoals = false
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

    // MARK: - Goals

    private var goalsSection: some View {
        VStack(alignment: .leading, spacing: DockwrightTheme.Spacing.sm) {
            if goals.isEmpty {
                VStack(spacing: DockwrightTheme.Spacing.xs) {
                    Text("No active goals")
                        .font(DockwrightTheme.Typography.body)
                        .foregroundStyle(.secondary)
                    Text("Add a goal to start tracking your progress.")
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DockwrightTheme.Spacing.lg)
                .background(DockwrightTheme.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md))
            } else {
                ForEach(goals) { goal in
                    goalRow(goal)
                }
            }

            // Add Goal button / inline form
            if showAddGoal {
                addGoalForm
            } else {
                HStack(spacing: DockwrightTheme.Spacing.sm) {
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

                    Button {
                        appState.showGoals = false
                        Task {
                            await appState.sendMessage("Help me set a new goal and break it down into milestones")
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
                }
            }
        }
    }

    private func goalRow(_ goal: Goal) -> some View {
        Button {
            appState.showGoals = false
            Task {
                await appState.sendMessage("Show me the status and details of my goal \"\(goal.title)\" and suggest next steps")
            }
        } label: {
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

                    Button {
                        deleteGoal(goal)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete goal")
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
        .buttonStyle(.plain)
    }

    // MARK: - Today's Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: DockwrightTheme.Spacing.sm) {
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

            ForEach(Array(todaysActions.enumerated()), id: \.element.id) { _, action in
                actionRow(action)
            }
        }
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

    // MARK: - Add Goal Form

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

    // MARK: - Actions

    private func refreshAll() {
        goals = appState.goalStore.listGoals(activeOnly: true)
        todaysActions = appState.goalStore.todaysActions()
    }

    private func deleteGoal(_ goal: Goal) {
        _ = try? appState.goalStore.deleteGoal(id: goal.id)
        goals = appState.goalStore.listGoals(activeOnly: true)
        todaysActions = appState.goalStore.todaysActions()
        appState.refreshBadgeCounts()
    }

    private func markActionDone(_ action: DailyAction) {
        guard !action.isCompleted else { return }
        _ = try? appState.goalStore.completeAction(id: action.id)
        todaysActions = appState.goalStore.todaysActions()
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
        appState.refreshBadgeCounts()
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
