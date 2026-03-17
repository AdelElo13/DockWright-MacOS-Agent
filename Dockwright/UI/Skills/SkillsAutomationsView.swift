import SwiftUI

/// Skills dashboard — shows what Dockwright can do (built-in + user skills).
struct SkillsAutomationsView: View {
    @Bindable var appState: AppState

    @State private var skills: [SkillLoader.Skill] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            ScrollView {
                VStack(spacing: DockwrightTheme.Spacing.sm) {
                    if skills.isEmpty {
                        emptyCard("No skills loaded", subtitle: "Create a skill to teach Dockwright new capabilities.")
                    } else {
                        ForEach(Array(skills.enumerated()), id: \.offset) { _, skill in
                            skillRow(skill)
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
                .padding(.horizontal, DockwrightTheme.Spacing.lg)
                .padding(.vertical, DockwrightTheme.Spacing.md)
            }
        }
        .frame(minWidth: 520, minHeight: 400)
        .background(DockwrightTheme.Surface.canvas)
        .onAppear { skills = appState.skillLoader.allSkills }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Skills")
                    .font(DockwrightTheme.Typography.title)
                    .foregroundStyle(.white)
                Text("\(skills.count) skill\(skills.count == 1 ? "" : "s")")
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

    // MARK: - Skill Row

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
                .help("Delete skill")
            }
        }
        .padding(.horizontal, DockwrightTheme.Spacing.md)
        .padding(.vertical, DockwrightTheme.Spacing.sm)
        .background(DockwrightTheme.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md))
        .contentShape(Rectangle())
        .onTapGesture {
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
        }
    }

    // MARK: - Helpers

    private func deleteSkill(_ skill: SkillLoader.Skill) {
        guard skill.source != "builtin" else { return }
        let url = URL(fileURLWithPath: skill.source)
        try? FileManager.default.removeItem(at: url)
        appState.skillLoader.reload()
        skills = appState.skillLoader.allSkills
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
}
