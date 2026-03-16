import Foundation

/// LLM tool for interacting with Notes.app via AppleScript.
/// Actions: list, read, create, search, delete, list_folders.
nonisolated struct NotesTool: Tool, @unchecked Sendable {
    let name = "notes"
    let description = "Manage Notes: list notes, read a note, create new notes, search by content, delete notes, or list folders."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: list, read, create, search, delete, list_folders",
        ] as [String: Any],
        "title": [
            "type": "string",
            "description": "Note title (for read, create, delete)",
            "optional": true,
        ] as [String: Any],
        "body": [
            "type": "string",
            "description": "Note body content (for create)",
            "optional": true,
        ] as [String: Any],
        "folder": [
            "type": "string",
            "description": "Folder name (for list, create)",
            "optional": true,
        ] as [String: Any],
        "query": [
            "type": "string",
            "description": "Search query (for search)",
            "optional": true,
        ] as [String: Any],
    ]

    nonisolated init() {}

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult(
                "Missing 'action' parameter. Use: list, read, create, search, delete, list_folders",
                isError: true
            )
        }

        switch action {
        case "list":
            return await listNotes(arguments)
        case "read":
            return await readNote(arguments)
        case "create":
            return await createNote(arguments)
        case "search":
            return await searchNotes(arguments)
        case "delete":
            return await deleteNote(arguments)
        case "list_folders":
            return await listFolders()
        default:
            return ToolResult(
                "Unknown action: \(action). Use: list, read, create, search, delete, list_folders",
                isError: true
            )
        }
    }

    // MARK: - AppleScript Execution

    private func runAppleScript(_ script: String) async -> (output: String, success: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus != 0 {
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let errOutput = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                return (errOutput, false)
            }

            return (output, true)
        } catch {

            return (error.localizedDescription, false)
        }
    }

    private func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Actions

    private func listNotes(_ args: [String: Any]) async -> ToolResult {
        let folder = args["folder"] as? String

        let script: String
        if let folder = folder {
            let escaped = escapeForAppleScript(folder)
            script = """
                tell application "Notes"
                    set noteList to ""
                    set theFolder to folder "\(escaped)"
                    repeat with n in notes of theFolder
                        set noteList to noteList & name of n & linefeed
                    end repeat
                    return noteList
                end tell
                """
        } else {
            script = """
                tell application "Notes"
                    set noteList to ""
                    repeat with n in notes
                        set noteList to noteList & name of n & linefeed
                    end repeat
                    return noteList
                end tell
                """
        }

        let result = await runAppleScript(script)
        if !result.success {
            return ToolResult("Failed to list notes: \(result.output)", isError: true)
        }

        if result.output.isEmpty {
            let label = folder != nil ? "in folder '\(folder!)'" : ""
            return ToolResult("No notes found \(label).")
        }

        let notes = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }
        var output = "Notes (\(notes.count)):\n\n"
        for (idx, note) in notes.prefix(50).enumerated() {
            output += "\(idx + 1). \(note)\n"
        }
        if notes.count > 50 {
            output += "\n... and \(notes.count - 50) more notes."
        }

        return ToolResult(output)
    }

    private func readNote(_ args: [String: Any]) async -> ToolResult {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return ToolResult("Missing 'title' for read", isError: true)
        }

        let escaped = escapeForAppleScript(title)
        let script = """
            tell application "Notes"
                set matchedNotes to notes whose name is "\(escaped)"
                if (count of matchedNotes) is 0 then
                    return "NOT_FOUND"
                end if
                set n to item 1 of matchedNotes
                set noteBody to plaintext of n
                return noteBody
            end tell
            """

        let result = await runAppleScript(script)
        if !result.success {
            return ToolResult("Failed to read note: \(result.output)", isError: true)
        }

        if result.output == "NOT_FOUND" {
            return ToolResult("No note found with title '\(title)'.")
        }

        var output = "Note: \(title)\n"
        output += String(repeating: "-", count: min(title.count + 6, 60)) + "\n"
        output += result.output

        return ToolResult(output)
    }

    private func createNote(_ args: [String: Any]) async -> ToolResult {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return ToolResult("Missing 'title' for create", isError: true)
        }

        let body = (args["body"] as? String) ?? ""
        let folder = args["folder"] as? String

        let escapedTitle = escapeForAppleScript(title)
        let escapedBody = escapeForAppleScript(body)
        let htmlBody = "<h1>\(escapedTitle)</h1><br>\(escapedBody.replacingOccurrences(of: "\n", with: "<br>"))"

        let script: String
        if let folder = folder {
            let escapedFolder = escapeForAppleScript(folder)
            script = """
                tell application "Notes"
                    set theFolder to folder "\(escapedFolder)"
                    make new note at theFolder with properties {body:"\(htmlBody)"}
                    return "OK"
                end tell
                """
        } else {
            script = """
                tell application "Notes"
                    make new note with properties {body:"\(htmlBody)"}
                    return "OK"
                end tell
                """
        }

        let result = await runAppleScript(script)
        if !result.success {
            return ToolResult("Failed to create note: \(result.output)", isError: true)
        }

        var output = "Created note: \(title)\n"
        if let folder = folder {
            output += "Folder: \(folder)\n"
        }
        if !body.isEmpty {
            let preview = body.count > 100 ? String(body.prefix(100)) + "..." : body
            output += "Content: \(preview)\n"
        }

        return ToolResult(output)
    }

    private func searchNotes(_ args: [String: Any]) async -> ToolResult {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return ToolResult("Missing 'query' for search", isError: true)
        }

        let escaped = escapeForAppleScript(query)
        let script = """
            tell application "Notes"
                set noteList to ""
                repeat with n in notes
                    set noteName to name of n
                    set noteContent to plaintext of n
                    if noteContent contains "\(escaped)" or noteName contains "\(escaped)" then
                        set noteList to noteList & noteName & linefeed
                    end if
                end repeat
                return noteList
            end tell
            """

        let result = await runAppleScript(script)
        if !result.success {
            return ToolResult("Failed to search notes: \(result.output)", isError: true)
        }

        if result.output.isEmpty {
            return ToolResult("No notes found matching '\(query)'.")
        }

        let notes = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }
        var output = "Found \(notes.count) note(s) matching '\(query)':\n\n"
        for (idx, note) in notes.prefix(30).enumerated() {
            output += "\(idx + 1). \(note)\n"
        }
        if notes.count > 30 {
            output += "\n... and \(notes.count - 30) more results."
        }

        return ToolResult(output)
    }

    private func deleteNote(_ args: [String: Any]) async -> ToolResult {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return ToolResult("Missing 'title' for delete", isError: true)
        }

        let escaped = escapeForAppleScript(title)
        let script = """
            tell application "Notes"
                set matchedNotes to notes whose name is "\(escaped)"
                if (count of matchedNotes) is 0 then
                    return "NOT_FOUND"
                end if
                delete item 1 of matchedNotes
                return "OK"
            end tell
            """

        let result = await runAppleScript(script)
        if !result.success {
            return ToolResult("Failed to delete note: \(result.output)", isError: true)
        }

        if result.output == "NOT_FOUND" {
            return ToolResult("No note found with title '\(title)'.", isError: true)
        }

        return ToolResult("Deleted note: \(title)")
    }

    private func listFolders() async -> ToolResult {
        let script = """
            tell application "Notes"
                set folderList to ""
                repeat with f in folders
                    set folderList to folderList & name of f & " (" & (count of notes of f) & " notes)" & linefeed
                end repeat
                return folderList
            end tell
            """

        let result = await runAppleScript(script)
        if !result.success {
            return ToolResult("Failed to list folders: \(result.output)", isError: true)
        }

        if result.output.isEmpty {
            return ToolResult("No folders found.")
        }

        let folders = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }
        var output = "Note folders (\(folders.count)):\n\n"
        for (idx, folder) in folders.enumerated() {
            output += "\(idx + 1). \(folder)\n"
        }

        return ToolResult(output)
    }
}
