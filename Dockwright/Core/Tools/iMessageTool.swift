import Foundation
import os

nonisolated private let logger = Logger(subsystem: "com.dockwright", category: "iMessageTool")

/// LLM tool for reading and sending iMessages via Messages.app database + AppleScript.
/// Actions: read_messages, send_message, list_chats, search_messages.
nonisolated struct iMessageTool: Tool, @unchecked Sendable {
    let name = "imessage"
    let description = "Read and send iMessages via Messages.app: read recent messages, send texts, list chats, search conversations."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: read_messages, send_message, list_chats, search_messages",
        ] as [String: Any],
        "contact": [
            "type": "string",
            "description": "Phone number or email address of the recipient (for send_message, read_messages)",
            "optional": true,
        ] as [String: Any],
        "message": [
            "type": "string",
            "description": "Message text to send (for send_message)",
            "optional": true,
        ] as [String: Any],
        "count": [
            "type": "integer",
            "description": "Number of messages/chats to retrieve (default 10)",
            "optional": true,
        ] as [String: Any],
        "query": [
            "type": "string",
            "description": "Search term (for search_messages)",
            "optional": true,
        ] as [String: Any],
    ]

    let requiredParams: [String] = ["action"]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing 'action' parameter. Must be one of: read_messages, send_message, list_chats, search_messages", isError: true)
        }

        switch action {
        case "read_messages":
            return await readMessages(arguments: arguments)
        case "send_message":
            return await sendMessage(arguments: arguments)
        case "list_chats":
            return await listChats(arguments: arguments)
        case "search_messages":
            return await searchMessages(arguments: arguments)
        default:
            return ToolResult("Unknown action '\(action)'. Use: read_messages, send_message, list_chats, search_messages", isError: true)
        }
    }

    // MARK: - Read Messages

    private func readMessages(arguments: [String: Any]) async -> ToolResult {
        let count = arguments["count"] as? Int ?? 10
        let contact = arguments["contact"] as? String

        let dbPath = NSHomeDirectory() + "/Library/Messages/chat.db"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return ToolResult("Cannot access Messages database. Grant Full Disk Access in System Settings > Privacy & Security.", isError: true)
        }

        var sql: String
        if let contact = contact, !contact.isEmpty {
            let escaped = contact.replacingOccurrences(of: "'", with: "''")
            sql = """
            SELECT m.text, m.is_from_me,
                   datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') as msg_date,
                   h.id as sender
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE (h.id LIKE '%\(escaped)%' OR c.chat_identifier LIKE '%\(escaped)%')
                  AND m.text IS NOT NULL
            ORDER BY m.date DESC LIMIT \(min(count, 50))
            """
        } else {
            sql = """
            SELECT m.text, m.is_from_me,
                   datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') as msg_date,
                   h.id as sender
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.text IS NOT NULL
            ORDER BY m.date DESC LIMIT \(min(count, 50))
            """
        }

        let rows = await querySQLite(dbPath: dbPath, sql: sql)
        guard let rows = rows.value else { return rows.error! }

        if rows.isEmpty {
            return ToolResult(contact != nil ? "No messages found for \(contact!)." : "No messages found.")
        }

        let header = contact != nil ? "Messages with \(contact!):\n\n" : "Recent messages:\n\n"
        var result = header
        for row in rows.reversed() {
            let text = row["text"] ?? ""
            let date = row["msg_date"] ?? ""
            let isFromMe = row["is_from_me"] == "1"
            let sender = isFromMe ? "You" : (row["sender"] ?? "Unknown")
            result += "[\(date)] \(sender): \(text)\n"
        }
        return ToolResult(result)
    }

    // MARK: - Send Message

    private func sendMessage(arguments: [String: Any]) async -> ToolResult {
        guard let contact = arguments["contact"] as? String, !contact.isEmpty else {
            return ToolResult("Missing 'contact' — provide a phone number or email address.", isError: true)
        }
        guard let message = arguments["message"] as? String, !message.isEmpty else {
            return ToolResult("Missing 'message' — what do you want to send?", isError: true)
        }

        let escapedMessage = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedContact = contact
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to participant "\(escapedContact)" of targetService
            send "\(escapedMessage)" to targetBuddy
        end tell
        """

        return await runAppleScript(script, successMessage: "Message sent to \(contact): \"\(message)\"")
    }

    // MARK: - List Chats

    private func listChats(arguments: [String: Any]) async -> ToolResult {
        let count = arguments["count"] as? Int ?? 15
        let dbPath = NSHomeDirectory() + "/Library/Messages/chat.db"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return ToolResult("Cannot access Messages database. Grant Full Disk Access in System Settings > Privacy & Security.", isError: true)
        }

        let sql = """
        SELECT c.chat_identifier, c.display_name,
            (SELECT m.text FROM message m
             JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
             WHERE cmj.chat_id = c.ROWID AND m.text IS NOT NULL
             ORDER BY m.date DESC LIMIT 1) as last_message,
            (SELECT datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') FROM message m
             JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
             WHERE cmj.chat_id = c.ROWID
             ORDER BY m.date DESC LIMIT 1) as last_date
        FROM chat c
        WHERE last_message IS NOT NULL
        ORDER BY last_date DESC LIMIT \(min(count, 30))
        """

        let rows = await querySQLite(dbPath: dbPath, sql: sql)
        guard let rows = rows.value else { return rows.error! }

        if rows.isEmpty { return ToolResult("No chats found.") }

        var result = "Recent chats:\n\n"
        for (i, row) in rows.enumerated() {
            let displayName = row["display_name"] ?? ""
            let name = displayName.isEmpty ? (row["chat_identifier"] ?? "Unknown") : displayName
            let lastMsg = row["last_message"] ?? ""
            let date = row["last_date"] ?? ""
            let preview = lastMsg.count > 60 ? String(lastMsg.prefix(60)) + "..." : lastMsg
            result += "\(i + 1). \(name) [\(date)]\n   \(preview)\n"
        }
        return ToolResult(result)
    }

    // MARK: - Search Messages

    private func searchMessages(arguments: [String: Any]) async -> ToolResult {
        guard let searchQuery = arguments["query"] as? String, !searchQuery.isEmpty else {
            return ToolResult("Missing 'query' — what do you want to search for?", isError: true)
        }
        let count = arguments["count"] as? Int ?? 10
        let dbPath = NSHomeDirectory() + "/Library/Messages/chat.db"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return ToolResult("Cannot access Messages database. Grant Full Disk Access in System Settings > Privacy & Security.", isError: true)
        }

        let escaped = searchQuery.replacingOccurrences(of: "'", with: "''")
        let sql = """
        SELECT m.text, m.is_from_me,
               datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime') as msg_date,
               h.id as sender
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.text LIKE '%\(escaped)%'
        ORDER BY m.date DESC LIMIT \(min(count, 30))
        """

        let rows = await querySQLite(dbPath: dbPath, sql: sql)
        guard let rows = rows.value else { return rows.error! }

        if rows.isEmpty { return ToolResult("No messages found matching '\(searchQuery)'.") }

        var result = "Messages matching '\(searchQuery)':\n\n"
        for row in rows {
            let text = row["text"] ?? ""
            let date = row["msg_date"] ?? ""
            let isFromMe = row["is_from_me"] == "1"
            let sender = isFromMe ? "You" : (row["sender"] ?? "Unknown")
            result += "[\(date)] \(sender): \(text)\n"
        }
        return ToolResult(result)
    }

    // MARK: - Helpers

    /// Result wrapper to avoid duplicating error handling
    private struct QueryResult {
        let value: [[String: String]]?
        let error: ToolResult?
    }

    private func querySQLite(dbPath: String, sql: String) async -> QueryResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-header", "-separator", "\t", dbPath, sql]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return QueryResult(value: nil, error: ToolResult("Failed to query Messages database: \(error.localizedDescription)", isError: true))
        }

        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
            if errStr.contains("authorization denied") || errStr.contains("not authorized") {
                return QueryResult(value: nil, error: ToolResult("Access denied. Grant Full Disk Access to Dockwright in System Settings > Privacy & Security > Full Disk Access.", isError: true))
            }
            return QueryResult(value: nil, error: ToolResult("SQLite error: \(errStr)", isError: true))
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? ""

        let lines = outStr.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count > 1 else {
            return QueryResult(value: [], error: nil)
        }

        let headers = lines[0].components(separatedBy: "\t")
        var rows: [[String: String]] = []
        for line in lines.dropFirst() {
            let values = line.components(separatedBy: "\t")
            var row: [String: String] = [:]
            for (i, header) in headers.enumerated() {
                row[header] = i < values.count ? values[i] : ""
            }
            rows.append(row)
        }

        return QueryResult(value: rows, error: nil)
    }

    private func runAppleScript(_ source: String, successMessage: String) async -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ToolResult("AppleScript execution failed: \(error.localizedDescription)", isError: true)
        }

        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
            logger.warning("iMessage AppleScript error: \(errStr)")
            return ToolResult("Failed: \(errStr)", isError: true)
        }

        return ToolResult(successMessage)
    }
}
