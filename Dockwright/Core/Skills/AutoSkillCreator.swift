import Foundation
import os

/// LLM tool for creating, listing, updating, and deleting reusable AI skills.
/// Skills are stored as .md files in ~/.dockwright/skills/ and get loaded into
/// the system prompt so the AI can follow learned procedures.
struct AutoSkillCreatorTool: Tool, @unchecked Sendable {
    nonisolated let name = "skills"
    nonisolated let description = """
        Create, list, update, and delete reusable AI skills. Skills are saved as markdown files and loaded into the system prompt. Actions:
        - create_skill: Create a new skill. Params: name, description, instructions, parameters (optional, comma-separated "param: desc" pairs).
        - list_skills: List all available skills. No params required.
        - update_skill: Update an existing skill. Params: name, plus any of: description, instructions, parameters.
        - delete_skill: Delete a skill by name. Params: name.
        """

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "The action to perform: create_skill, list_skills, update_skill, or delete_skill",
            "enum": ["create_skill", "list_skills", "update_skill", "delete_skill"]
        ] as [String: Any],
        "name": [
            "type": "string",
            "description": "Name of the skill",
            "optional": true
        ] as [String: Any],
        "description": [
            "type": "string",
            "description": "What the skill does",
            "optional": true
        ] as [String: Any],
        "instructions": [
            "type": "string",
            "description": "Step-by-step instructions for the AI to follow when this skill is activated",
            "optional": true
        ] as [String: Any],
        "parameters": [
            "type": "string",
            "description": "Comma-separated list of 'param: description' pairs",
            "optional": true
        ] as [String: Any]
    ]

    private let skillsDirectory: URL
    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "AutoSkillCreator")
    private let skillLoader: SkillLoader?

    init(skillLoader: SkillLoader? = nil) {
        self.skillsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dockwright/skills", isDirectory: true)
        self.skillLoader = skillLoader
    }

    nonisolated func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Error: 'action' parameter is required.", isError: true)
        }

        switch action {
        case "create_skill":
            return createSkill(arguments)
        case "list_skills":
            return listSkills()
        case "update_skill":
            return updateSkill(arguments)
        case "delete_skill":
            return deleteSkill(arguments)
        default:
            return ToolResult("Unknown action '\(action)'. Use create_skill, list_skills, update_skill, or delete_skill.", isError: true)
        }
    }

    // MARK: - Actions

    private func createSkill(_ args: [String: Any]) -> ToolResult {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return ToolResult("Error: 'name' is required for create_skill.", isError: true)
        }
        guard let description = args["description"] as? String, !description.isEmpty else {
            return ToolResult("Error: 'description' is required for create_skill.", isError: true)
        }
        guard let instructions = args["instructions"] as? String, !instructions.isEmpty else {
            return ToolResult("Error: 'instructions' is required for create_skill.", isError: true)
        }

        let filename = sanitizeFilename(name)
        let fileURL = skillsDirectory.appendingPathComponent("\(filename).md")
        let fm = FileManager.default

        // Check if it already exists
        if fm.fileExists(atPath: fileURL.path) {
            return ToolResult("Error: skill '\(name)' already exists. Use 'update_skill' to modify it.", isError: true)
        }

        let content = buildSkillMarkdown(name: name, description: description, instructions: instructions, parameters: args["parameters"] as? String)

        do {
            try fm.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            skillLoader?.reload()
            logger.info("Created skill: \(name) at \(fileURL.path)")
            return ToolResult("Created skill '\(name)' at \(fileURL.path)\nThe skill is now available and will be loaded into future conversations.")
        } catch {
            return ToolResult("Error creating skill: \(error.localizedDescription)", isError: true)
        }
    }

    private func listSkills() -> ToolResult {
        let fm = FileManager.default
        try? fm.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)

        guard let files = try? fm.contentsOfDirectory(at: skillsDirectory,
                                                       includingPropertiesForKeys: [.creationDateKey],
                                                       options: .skipsHiddenFiles) else {
            return ToolResult("No skills directory found or it's empty.")
        }

        let mdFiles = files.filter { $0.pathExtension.lowercased() == "md" }

        if mdFiles.isEmpty {
            return ToolResult("No user-created skills found. Use 'create_skill' to create one.")
        }

        var output = "User Skills (\(mdFiles.count)):\n\n"
        for file in mdFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }

            let parsed = parseSkillFile(content: content)
            let skillName = parsed.name ?? file.deletingPathExtension().lastPathComponent
            let skillDesc = parsed.description ?? "No description"

            output += "- \(skillName): \(skillDesc)\n"
            output += "  File: \(file.lastPathComponent)\n"
        }

        return ToolResult(output)
    }

    private func updateSkill(_ args: [String: Any]) -> ToolResult {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return ToolResult("Error: 'name' is required for update_skill.", isError: true)
        }

        // Find the skill file
        guard let fileURL = findSkillFile(named: name) else {
            return ToolResult("Error: skill '\(name)' not found. Use 'list_skills' to see available skills.", isError: true)
        }

        guard let existingContent = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return ToolResult("Error: could not read skill file.", isError: true)
        }

        let existing = parseSkillFile(content: existingContent)
        let updatedName = name
        let updatedDesc = (args["description"] as? String) ?? existing.description ?? name
        let updatedInstructions = (args["instructions"] as? String) ?? existing.instructions ?? ""
        let updatedParams = (args["parameters"] as? String) ?? existing.parameters

        let content = buildSkillMarkdown(name: updatedName, description: updatedDesc, instructions: updatedInstructions, parameters: updatedParams)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            skillLoader?.reload()
            logger.info("Updated skill: \(name)")
            return ToolResult("Updated skill '\(name)'. Changes will take effect in future conversations.")
        } catch {
            return ToolResult("Error updating skill: \(error.localizedDescription)", isError: true)
        }
    }

    private func deleteSkill(_ args: [String: Any]) -> ToolResult {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return ToolResult("Error: 'name' is required for delete_skill.", isError: true)
        }

        guard let fileURL = findSkillFile(named: name) else {
            return ToolResult("Error: skill '\(name)' not found. Use 'list_skills' to see available skills.", isError: true)
        }

        do {
            try FileManager.default.removeItem(at: fileURL)
            skillLoader?.reload()
            logger.info("Deleted skill: \(name)")
            return ToolResult("Deleted skill '\(name)'.")
        } catch {
            return ToolResult("Error deleting skill: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Helpers

    private func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return name
            .lowercased()
            .components(separatedBy: .whitespaces)
            .joined(separator: "-")
            .unicodeScalars
            .filter { allowed.contains($0) }
            .map { String($0) }
            .joined()
    }

    private func buildSkillMarkdown(name: String, description: String, instructions: String, parameters: String?) -> String {
        var content = "# \(name)\n"
        content += "\(description)\n\n"
        content += "## Instructions\n"
        content += "\(instructions)\n"

        if let params = parameters, !params.isEmpty {
            content += "\n## Parameters\n"
            let pairs = params.components(separatedBy: ",")
            for pair in pairs {
                let trimmed = pair.trimmingCharacters(in: .whitespaces)
                if trimmed.contains(":") {
                    content += "- \(trimmed)\n"
                } else if !trimmed.isEmpty {
                    content += "- \(trimmed): (no description)\n"
                }
            }
        }

        return content
    }

    private func findSkillFile(named name: String) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: skillsDirectory,
                                                       includingPropertiesForKeys: nil,
                                                       options: .skipsHiddenFiles) else {
            return nil
        }

        let mdFiles = files.filter { $0.pathExtension.lowercased() == "md" }

        // First try exact filename match
        let sanitized = sanitizeFilename(name)
        if let exact = mdFiles.first(where: { $0.deletingPathExtension().lastPathComponent == sanitized }) {
            return exact
        }

        // Then try matching by parsed skill name (case-insensitive)
        for file in mdFiles {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let parsed = parseSkillFile(content: content)
            if let skillName = parsed.name, skillName.lowercased() == name.lowercased() {
                return file
            }
        }

        return nil
    }

    private struct ParsedSkill {
        var name: String?
        var description: String?
        var instructions: String?
        var parameters: String?
    }

    private func parseSkillFile(content: String) -> ParsedSkill {
        var result = ParsedSkill()
        let lines = content.components(separatedBy: .newlines)

        var currentSection: String?
        var sectionContent: [String] = []

        func flushSection() {
            let text = sectionContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            switch currentSection {
            case "instructions":
                result.instructions = text
            case "parameters":
                result.parameters = text
            default:
                break
            }
            sectionContent = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("## ") {
                result.name = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("## instructions") {
                flushSection()
                currentSection = "instructions"
            } else if trimmed.lowercased().hasPrefix("## parameters") {
                flushSection()
                currentSection = "parameters"
            } else if trimmed.hasPrefix("## ") {
                flushSection()
                currentSection = nil
            } else if currentSection != nil {
                sectionContent.append(line)
            } else if result.name != nil && result.description == nil && !trimmed.isEmpty {
                // First non-empty line after title is description
                result.description = trimmed
            }
        }

        flushSection()
        return result
    }
}
