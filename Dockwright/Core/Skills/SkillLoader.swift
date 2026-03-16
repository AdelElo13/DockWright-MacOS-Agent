import Foundation
import os

/// Loads SKILL.md files from ~/.dockwright/skills/ and parses them into
/// structured skill definitions that get injected into the system prompt.
///
/// Frontmatter format:
/// ```
/// ---
/// name: My Skill
/// description: What the skill does
/// requires: shell, file
/// ---
/// (markdown body with instructions)
/// ```
final class SkillLoader: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "Skills")
    private let queue = DispatchQueue(label: "com.Aatje.Dockwright.SkillLoader", qos: .utility)
    private var skills: [Skill] = []
    private let skillsDirectory: URL

    struct Skill: Sendable {
        let name: String
        let description: String
        let requires: [String]
        let body: String
        let source: String  // "builtin" or file path
    }

    init() {
        self.skillsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dockwright/skills", isDirectory: true)
        loadAll()
    }

    // MARK: - Public API

    /// All loaded skills (built-in + user).
    var allSkills: [Skill] {
        queue.sync { skills }
    }

    /// Reload skills from disk.
    func reload() {
        loadAll()
    }

    /// Generate a system prompt fragment describing available skills.
    func systemPromptFragment() -> String {
        let all = allSkills
        guard !all.isEmpty else { return "" }

        var prompt = "\nAvailable skills:\n"
        for skill in all {
            prompt += "- \(skill.name): \(skill.description)\n"
            if !skill.requires.isEmpty {
                prompt += "  Requires tools: \(skill.requires.joined(separator: ", "))\n"
            }
        }
        return prompt
    }

    /// Get the full body of a skill by name (for injection when the user invokes it).
    func skillBody(named name: String) -> String? {
        allSkills.first { $0.name.lowercased() == name.lowercased() }?.body
    }

    // MARK: - Loading

    private func loadAll() {
        queue.sync {
            skills = Self.builtInSkills()

            // Load user skills from disk
            let fm = FileManager.default
            try? fm.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)

            guard let files = try? fm.contentsOfDirectory(at: skillsDirectory,
                                                           includingPropertiesForKeys: nil,
                                                           options: .skipsHiddenFiles) else {
                logger.info("No user skills directory or empty: \(self.skillsDirectory.path)")
                return
            }

            let mdFiles = files.filter { $0.pathExtension.lowercased() == "md" }

            for file in mdFiles {
                guard let content = try? String(contentsOf: file, encoding: .utf8) else {
                    logger.warning("Couldn't read skill file: \(file.lastPathComponent)")
                    continue
                }
                if let skill = Self.parse(content: content, source: file.path) {
                    skills.append(skill)
                    logger.info("Loaded user skill: \(skill.name)")
                } else {
                    logger.warning("Failed to parse skill file: \(file.lastPathComponent)")
                }
            }

            logger.info("Loaded \(self.skills.count) skills (\(Self.builtInSkills().count) built-in, \(self.skills.count - Self.builtInSkills().count) user)")
        }
    }

    // MARK: - Parsing

    /// Parse a SKILL.md file with YAML-like frontmatter.
    static func parse(content: String, source: String) -> Skill? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else {
            // No frontmatter -- treat entire content as body with filename as name
            let name = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
            return Skill(name: name, description: "User skill", requires: [], body: trimmed, source: source)
        }

        // Split on frontmatter delimiters
        let parts = trimmed.components(separatedBy: "---")
        guard parts.count >= 3 else { return nil }

        let frontmatter = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let body = parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)

        var name = ""
        var description = ""
        var requires: [String] = []

        for line in frontmatter.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("name:") {
                name = String(trimmedLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if trimmedLine.hasPrefix("description:") {
                description = String(trimmedLine.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            } else if trimmedLine.hasPrefix("requires:") {
                let reqStr = String(trimmedLine.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                requires = reqStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }

        guard !name.isEmpty else { return nil }
        if description.isEmpty { description = name }

        return Skill(name: name, description: description, requires: requires, body: body, source: source)
    }

    // MARK: - Built-in Skills

    static func builtInSkills() -> [Skill] {
        [
            Skill(
                name: "Code Review",
                description: "Analyze code files for bugs, style issues, and improvements",
                requires: ["shell", "file"],
                body: """
                When reviewing code:
                1. Read the file(s) using the file tool
                2. Check for: bugs, security issues, performance problems, style violations
                3. Suggest specific improvements with code examples
                4. Rate severity: critical, warning, info
                5. Summarize findings in a table
                """,
                source: "builtin"
            ),
            Skill(
                name: "Git Workflow",
                description: "Help with git operations: commits, branches, PRs, conflict resolution",
                requires: ["shell"],
                body: """
                For git operations:
                1. Always check `git status` and `git diff` first
                2. Write clear, conventional commit messages (feat:, fix:, chore:, etc.)
                3. For conflicts: show both sides, suggest resolution
                4. For PRs: summarize changes, list affected files
                5. Never force-push to main/master without explicit user consent
                """,
                source: "builtin"
            ),
            Skill(
                name: "System Diagnostics",
                description: "Diagnose macOS system issues: performance, disk, network, processes",
                requires: ["shell", "system_info"],
                body: """
                For system diagnostics:
                1. Check CPU/memory with `top -l 1 -n 10`
                2. Check disk with `df -h` and `du -sh ~/Library/Caches/*`
                3. Check network with `networksetup -getinfo Wi-Fi`
                4. Check for stuck processes with `ps aux | sort -nrk 3 | head -5`
                5. Present findings clearly with recommended actions
                """,
                source: "builtin"
            ),
            Skill(
                name: "File Organizer",
                description: "Organize and clean up files in a directory",
                requires: ["shell", "file"],
                body: """
                When organizing files:
                1. List all files in the target directory
                2. Categorize by type: documents, images, code, archives, etc.
                3. Propose a folder structure
                4. Ask for confirmation before moving anything
                5. Create folders and move files using shell commands
                6. Report what was moved and the new structure
                """,
                source: "builtin"
            ),
        ]
    }
}
