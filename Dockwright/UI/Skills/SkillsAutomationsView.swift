import SwiftUI

/// Skills dashboard — shows active skills + community skill store.
struct SkillsAutomationsView: View {
    @Bindable var appState: AppState

    @State private var skills: [SkillLoader.Skill] = []
    @State private var communitySkills: [SkillLoader.Skill] = []
    @State private var selectedTab = 0  // 0 = My Skills, 1 = Skill Store
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)

            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("My Skills").tag(0)
                Text("Skill Store").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DockwrightTheme.Spacing.lg)
            .padding(.vertical, DockwrightTheme.Spacing.sm)

            if selectedTab == 1 {
                // Search bar for store
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField("Search skills...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, DockwrightTheme.Spacing.lg)
                .padding(.bottom, DockwrightTheme.Spacing.xs)
            }

            ScrollView {
                VStack(spacing: DockwrightTheme.Spacing.sm) {
                    if selectedTab == 0 {
                        mySkillsContent
                    } else {
                        skillStoreContent
                    }
                }
                .padding(.horizontal, DockwrightTheme.Spacing.lg)
                .padding(.vertical, DockwrightTheme.Spacing.md)
            }
        }
        .frame(minWidth: 520, minHeight: 400)
        .background(DockwrightTheme.Surface.canvas)
        .onAppear { refreshSkills() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Skills")
                    .font(DockwrightTheme.Typography.title)
                    .foregroundStyle(.white)
                Text(selectedTab == 0
                     ? "\(skills.count) active"
                     : "\(communitySkills.count) available")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                appState.showSkillsAutomations = false
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

    // MARK: - My Skills Tab

    private var mySkillsContent: some View {
        Group {
            if skills.isEmpty {
                emptyCard("No skills active", subtitle: "Activate skills from the Skill Store or create your own.")
            } else {
                ForEach(Array(skills.enumerated()), id: \.offset) { _, skill in
                    activeSkillRow(skill)
                }
            }

            Button {
                appState.showSkillsAutomations = false
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

    // MARK: - Skill Store Tab

    private var filteredCommunitySkills: [SkillLoader.Skill] {
        if searchText.isEmpty { return communitySkills }
        let q = searchText.lowercased()
        return communitySkills.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    private var skillStoreContent: some View {
        Group {
            if filteredCommunitySkills.isEmpty {
                emptyCard("No skills found", subtitle: searchText.isEmpty
                          ? "All community skills are already activated!"
                          : "No skills match your search.")
            } else {
                ForEach(Array(filteredCommunitySkills.enumerated()), id: \.offset) { _, skill in
                    communitySkillRow(skill)
                }
            }
        }
    }

    // MARK: - Active Skill Row

    private func activeSkillRow(_ skill: SkillLoader.Skill) -> some View {
        Button {
            appState.showSkillsAutomations = false
            let prompt: String
            if skill.source == "builtin" {
                prompt = "I want to use your \(skill.name) capability. \(skill.description). What do you need from me to get started?"
            } else {
                prompt = "Activate my custom skill \"\(skill.name)\" — read it with read_skill first, then follow its instructions"
            }
            Task {
                await appState.sendMessage(prompt)
            }
        } label: {
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

                if skill.source != "builtin" {
                    Button {
                        deactivateSkill(skill)
                    } label: {
                        Text("Remove")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DockwrightTheme.Spacing.md)
            .padding(.vertical, DockwrightTheme.Spacing.sm)
            .background(DockwrightTheme.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Community Skill Row

    private func communitySkillRow(_ skill: SkillLoader.Skill) -> some View {
        HStack(spacing: DockwrightTheme.Spacing.sm) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(DockwrightTheme.success)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if skill.stars > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                            Text("\(skill.stars)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                Text(skill.description)
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                if !skill.author.isEmpty {
                    Text("by @\(skill.author)")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                }
            }

            Spacer()

            Button {
                activateSkill(skill)
            } label: {
                Text("Activate")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(DockwrightTheme.success.opacity(0.8))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DockwrightTheme.Spacing.md)
        .padding(.vertical, DockwrightTheme.Spacing.sm)
        .background(DockwrightTheme.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md))
    }

    // MARK: - Actions

    private func activateSkill(_ skill: SkillLoader.Skill) {
        if appState.skillLoader.activateCommunitySkill(named: skill.name) {
            refreshSkills()
        }
    }

    private func deactivateSkill(_ skill: SkillLoader.Skill) {
        if appState.skillLoader.deactivateSkill(named: skill.name) {
            refreshSkills()
        }
    }

    private func refreshSkills() {
        skills = appState.skillLoader.allSkills
        communitySkills = appState.skillLoader.availableCommunitySkills
    }

    // MARK: - Helpers

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
}
