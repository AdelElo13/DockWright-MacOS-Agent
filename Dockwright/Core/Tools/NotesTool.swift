import Foundation

/// LLM tool for interacting with Apple Notes via AppleScript.
/// Actions: create_note, list_notes, search_notes, read_note.
final class NotesTool: @unchecked Sendable {
    nonisolated init() {}

    /// Execute an AppleScript and return its output.
    private func runAppleScript(_ source: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw NotesToolError.scriptFailed(errStr)
        }

        return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

extension NotesTool: Tool {
    nonisolated var name: String { "notes" }

    nonisolated var description: String {
        "Manage Apple Notes: create, list, search, or read notes."
    }

    nonisolated var parametersSchema: [String: Any] {
        [
            "action": [
                "type": "string",
                "description": "One of: create_note, list_notes, search_notes, read_note",
            ] as [String: Any],
            "title": [
                "type": "string",
                "description": "Note title (for create_note)",
                "optional": true,
            ] as [String: Any],
            "body": [
                "type": "string",
                "description": "Note body/content (for create_note)",
                "optional": true,
            ] as [String: Any],
            "folder": [
                "type": "string",
                "description": "Notes folder name (default: Notes)",
                "optional": true,
            ] as [String: Any],
            "query": [
                "type": "string",
                "description": "Search query (for search_notes)",
                "optional": true,
            ] as [String: Any],
            "note_name": [
                "type": "string",
                "description": "Exact note name to read (for read_note)",
                "optional": true,
            ] as [String: Any],
        ]
    }

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing 'action' parameter. Use: create_note, list_notes, search_notes, read_note", isError: true)
        }

        switch action {
        case "create_note":
            return await createNote(arguments)
        case "list_notes":
            return await listNotes(arguments)
        case "search_notes":
            return await searchNotes(arguments)
        case "read_note":
            return await readNote(arguments)
        default:
            return ToolResult("Unknown action: \(action). Use: create_note, list_notes, search_notes, read_note", isError: true)
        }
    }

    // MARK: - Actions

    private func createNote(_ args: [String: Any]) async -> ToolResult {
        let title = (args["title"] as? String) ?? "Untitled"
        let body = (args["body"] as? String) ?? ""
        let folder = (args["folder"] as? String) ?? "Notes"

        // Escape special characters for AppleScript
        let escapedTitle = title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedFolder = folder.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Notes"
            try
                set targetFolder to folder "\(escapedFolder)" of default account
            on error
                set targetFolder to default account
            end try
            set newNote to make new note at targetFolder with properties {name:"\(escapedTitle)", body:"\(escapedBody)"}
            return name of newNote
        end tell
        """

        do {
            let result = try await runAppleScript(script)
            return ToolResult("Created note: \(result.isEmpty ? title : result) in folder: \(folder)")
        } catch {
            return ToolResult("Failed to create note: \(error.localizedDescription)", isError: true)
        }
    }

    private func listNotes(_ args: [String: Any]) async -> ToolResult {
        let folder = args["folder"] as? String
        let escapedFolder = folder?.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        if let ef = escapedFolder {
            script = """
            tell application "Notes"
                try
                    set noteNames to {}
                    set targetFolder to folder "\(ef)" of default account
                    repeat with n in notes of targetFolder
                        set noteDate to modification date of n
                        set end of noteNames to (name of n) & " | " & (noteDate as string)
                    end repeat
                    return noteNames as text
                on error errMsg
                    return "Error: " & errMsg
                end try
            end tell
            """
        } else {
            script = """
            tell application "Notes"
                set noteNames to {}
                repeat with n in notes of default account
                    set noteDate to modification date of n
                    set end of noteNames to (name of n) & " | " & (noteDate as string)
                end repeat
                return noteNames as text
            end tell
            """
        }

        do {
            let result = try await runAppleScript(script)
            if result.isEmpty {
                return ToolResult("No notes found.")
            }
            let lines = result.components(separatedBy: ", ")
            var output = "Notes (\(lines.count)):\n"
            for (idx, line) in lines.prefix(50).enumerated() {
                output += "\(idx + 1). \(line)\n"
            }
            if lines.count > 50 {
                output += "... and \(lines.count - 50) more\n"
            }
            return ToolResult(output)
        } catch {
            return ToolResult("Failed to list notes: \(error.localizedDescription)", isError: true)
        }
    }

    private func searchNotes(_ args: [String: Any]) async -> ToolResult {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return ToolResult("Missing 'query' for search_notes", isError: true)
        }

        let escapedQuery = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Notes"
            set matchingNotes to {}
            set searchQuery to "\(escapedQuery)"
            repeat with n in notes of default account
                set noteName to name of n
                set noteBody to plaintext of n
                if noteName contains searchQuery or noteBody contains searchQuery then
                    set end of matchingNotes to noteName & " | " & (modification date of n as string)
                end if
                if (count of matchingNotes) >= 20 then exit repeat
            end repeat
            return matchingNotes as text
        end tell
        """

        do {
            let result = try await runAppleScript(script)
            if result.isEmpty {
                return ToolResult("No notes found matching '\(query)'.")
            }
            let lines = result.components(separatedBy: ", ")
            var output = "Notes matching '\(query)' (\(lines.count)):\n"
            for (idx, line) in lines.enumerated() {
                output += "\(idx + 1). \(line)\n"
            }
            return ToolResult(output)
        } catch {
            return ToolResult("Failed to search notes: \(error.localizedDescription)", isError: true)
        }
    }

    private func readNote(_ args: [String: Any]) async -> ToolResult {
        guard let noteName = args["note_name"] as? String, !noteName.isEmpty else {
            return ToolResult("Missing 'note_name' for read_note", isError: true)
        }

        let escapedName = noteName.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Notes"
            repeat with n in notes of default account
                if name of n is "\(escapedName)" then
                    set noteTitle to name of n
                    set noteContent to plaintext of n
                    set noteDate to modification date of n
                    return noteTitle & "\\n---\\n" & noteContent & "\\n---\\nModified: " & (noteDate as string)
                end if
            end repeat
            return "Note not found: \(escapedName)"
        end tell
        """

        do {
            let result = try await runAppleScript(script)
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to read note: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Errors

private enum NotesToolError: Error, LocalizedError {
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): return "AppleScript error: \(msg)"
        }
    }
}
