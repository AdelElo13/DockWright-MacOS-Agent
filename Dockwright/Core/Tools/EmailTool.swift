import Foundation
import os

private let logger = Logger(subsystem: "com.dockwright", category: "EmailTool")

/// LLM tool for interacting with Mail.app via AppleScript.
/// Actions: read_inbox, read_email, draft_reply, send_email, search_email, unread_count.
nonisolated struct EmailTool: Tool, @unchecked Sendable {
    let name = "email"
    let description = "Interact with Mail.app: read inbox, read/send/draft/search emails, and check unread count."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: read_inbox, read_email, draft_reply, send_email, search_email, unread_count",
        ] as [String: Any],
        "count": [
            "type": "integer",
            "description": "Number of emails to retrieve (for read_inbox, default 10)",
            "optional": true,
        ] as [String: Any],
        "index": [
            "type": "integer",
            "description": "Email index to read (1-based, for read_email)",
            "optional": true,
        ] as [String: Any],
        "subject": [
            "type": "string",
            "description": "Subject to search for (for read_email, search_email)",
            "optional": true,
        ] as [String: Any],
        "to": [
            "type": "string",
            "description": "Recipient email address (for send_email, draft_reply)",
            "optional": true,
        ] as [String: Any],
        "body": [
            "type": "string",
            "description": "Email body text (for send_email, draft_reply)",
            "optional": true,
        ] as [String: Any],
        "email_subject": [
            "type": "string",
            "description": "Email subject line (for send_email)",
            "optional": true,
        ] as [String: Any],
        "query": [
            "type": "string",
            "description": "Search query (for search_email)",
            "optional": true,
        ] as [String: Any],
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult(
                "Missing 'action' parameter. Use: read_inbox, read_email, draft_reply, send_email, search_email, unread_count",
                isError: true
            )
        }

        switch action {
        case "read_inbox":
            return await readInbox(arguments)
        case "read_email":
            return await readEmail(arguments)
        case "draft_reply":
            return await draftReply(arguments)
        case "send_email":
            return await sendEmail(arguments)
        case "search_email":
            return await searchEmail(arguments)
        case "unread_count":
            return await unreadCount()
        default:
            return ToolResult(
                "Unknown action: \(action). Use: read_inbox, read_email, draft_reply, send_email, search_email, unread_count",
                isError: true
            )
        }
    }

    // MARK: - AppleScript Runner

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
            logger.error("AppleScript failed: \(errStr)")
            throw EmailToolError.scriptFailed(errStr)
        }

        return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Actions

    private func readInbox(_ args: [String: Any]) async -> ToolResult {
        let count = (args["count"] as? Int) ?? 10
        let safeCount = max(1, min(count, 50))

        let script = """
        tell application "Mail"
            set output to ""
            set msgList to messages of inbox
            set msgCount to count of msgList
            if msgCount < \(safeCount) then
                set fetchCount to msgCount
            else
                set fetchCount to \(safeCount)
            end if
            repeat with i from 1 to fetchCount
                set msg to item i of msgList
                set msgSender to sender of msg
                set msgSubject to subject of msg
                set msgDate to date received of msg
                set msgRead to read status of msg
                set msgPreview to ""
                try
                    set msgContent to content of msg
                    if (count of msgContent) > 150 then
                        set msgPreview to text 1 thru 150 of msgContent
                    else
                        set msgPreview to msgContent
                    end if
                end try
                set readFlag to "unread"
                if msgRead then set readFlag to "read"
                set output to output & i & ". [" & readFlag & "] From: " & msgSender & "\\nSubject: " & msgSubject & "\\nDate: " & (msgDate as string) & "\\nPreview: " & msgPreview & "\\n---\\n"
            end repeat
            return output
        end tell
        """

        do {
            let result = try await runAppleScript(script)
            if result.isEmpty {
                return ToolResult("Inbox is empty.")
            }
            return ToolResult("Inbox (\(safeCount) most recent):\n\n\(result)")
        } catch {
            return ToolResult("Failed to read inbox: \(error.localizedDescription)", isError: true)
        }
    }

    private func readEmail(_ args: [String: Any]) async -> ToolResult {
        if let index = args["index"] as? Int {
            let script = """
            tell application "Mail"
                set msgList to messages of inbox
                set msgCount to count of msgList
                if \(index) > msgCount or \(index) < 1 then
                    return "Error: Index \(index) out of range. Inbox has " & msgCount & " messages."
                end if
                set msg to item \(index) of msgList
                set msgSender to sender of msg
                set msgSubject to subject of msg
                set msgDate to date received of msg
                set msgTo to ""
                try
                    set recipientList to to recipients of msg
                    repeat with r in recipientList
                        set msgTo to msgTo & (address of r) & ", "
                    end repeat
                end try
                set msgBody to content of msg
                return "From: " & msgSender & "\\nTo: " & msgTo & "\\nSubject: " & msgSubject & "\\nDate: " & (msgDate as string) & "\\n\\n" & msgBody
            end tell
            """

            do {
                let result = try await runAppleScript(script)
                return ToolResult(result)
            } catch {
                return ToolResult("Failed to read email at index \(index): \(error.localizedDescription)", isError: true)
            }
        } else if let subject = args["subject"] as? String, !subject.isEmpty {
            let escaped = escapeForAppleScript(subject)
            let script = """
            tell application "Mail"
                set output to ""
                set found to false
                repeat with msg in messages of inbox
                    if subject of msg contains "\(escaped)" then
                        set msgSender to sender of msg
                        set msgSubject to subject of msg
                        set msgDate to date received of msg
                        set msgTo to ""
                        try
                            set recipientList to to recipients of msg
                            repeat with r in recipientList
                                set msgTo to msgTo & (address of r) & ", "
                            end repeat
                        end try
                        set msgBody to content of msg
                        set output to "From: " & msgSender & "\\nTo: " & msgTo & "\\nSubject: " & msgSubject & "\\nDate: " & (msgDate as string) & "\\n\\n" & msgBody
                        set found to true
                        exit repeat
                    end if
                end repeat
                if not found then
                    return "No email found with subject containing: \(escaped)"
                end if
                return output
            end tell
            """

            do {
                let result = try await runAppleScript(script)
                return ToolResult(result)
            } catch {
                return ToolResult("Failed to search email by subject: \(error.localizedDescription)", isError: true)
            }
        } else {
            return ToolResult("Missing 'index' (integer) or 'subject' (string) for read_email", isError: true)
        }
    }

    private func draftReply(_ args: [String: Any]) async -> ToolResult {
        let body = (args["body"] as? String) ?? ""
        let escapedBody = escapeForAppleScript(body)

        // Find the email to reply to
        var targetScript: String
        if let index = args["index"] as? Int {
            targetScript = "set msg to item \(index) of messages of inbox"
        } else if let subject = args["subject"] as? String, !subject.isEmpty {
            let escaped = escapeForAppleScript(subject)
            targetScript = """
            set msg to missing value
            repeat with m in messages of inbox
                if subject of m contains "\(escaped)" then
                    set msg to m
                    exit repeat
                end if
            end repeat
            if msg is missing value then
                return "Error: No email found with subject containing: \(escaped)"
            end if
            """
        } else {
            return ToolResult("Missing 'index' or 'subject' to identify the email to reply to", isError: true)
        }

        let script = """
        tell application "Mail"
            \(targetScript)
            set replyMsg to reply msg with opening window
            set content of replyMsg to "\(escapedBody)"
            return "Draft reply created for: " & subject of msg
        end tell
        """

        do {
            let result = try await runAppleScript(script)
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to draft reply: \(error.localizedDescription)", isError: true)
        }
    }

    private func sendEmail(_ args: [String: Any]) async -> ToolResult {
        guard let to = args["to"] as? String, !to.isEmpty else {
            return ToolResult("Missing 'to' (recipient email address) for send_email", isError: true)
        }
        guard let subject = args["email_subject"] as? String, !subject.isEmpty else {
            return ToolResult("Missing 'email_subject' for send_email", isError: true)
        }
        let body = (args["body"] as? String) ?? ""

        let escapedTo = escapeForAppleScript(to)
        let escapedSubject = escapeForAppleScript(subject)
        let escapedBody = escapeForAppleScript(body)

        let script = """
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:"\(escapedSubject)", content:"\(escapedBody)", visible:true}
            tell newMsg
                make new to recipient at end of to recipients with properties {address:"\(escapedTo)"}
            end tell
            send newMsg
            return "Email sent to \(escapedTo) with subject: \(escapedSubject)"
        end tell
        """

        do {
            let result = try await runAppleScript(script)
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to send email: \(error.localizedDescription)", isError: true)
        }
    }

    private func searchEmail(_ args: [String: Any]) async -> ToolResult {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return ToolResult("Missing 'query' for search_email", isError: true)
        }

        let escaped = escapeForAppleScript(query)

        let script = """
        tell application "Mail"
            set output to ""
            set matchCount to 0
            repeat with msg in messages of inbox
                set msgSubject to subject of msg
                set msgSender to sender of msg
                set msgContent to ""
                try
                    set msgContent to content of msg
                end try
                if msgSubject contains "\(escaped)" or msgSender contains "\(escaped)" or msgContent contains "\(escaped)" then
                    set matchCount to matchCount + 1
                    set msgDate to date received of msg
                    set msgRead to read status of msg
                    set readFlag to "unread"
                    if msgRead then set readFlag to "read"
                    set output to output & matchCount & ". [" & readFlag & "] From: " & msgSender & "\\nSubject: " & msgSubject & "\\nDate: " & (msgDate as string) & "\\n---\\n"
                    if matchCount >= 20 then exit repeat
                end if
            end repeat
            if matchCount = 0 then
                return "No emails found matching: \(escaped)"
            end if
            return "Found " & matchCount & " matching emails:\\n\\n" & output
        end tell
        """

        do {
            let result = try await runAppleScript(script)
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to search emails: \(error.localizedDescription)", isError: true)
        }
    }

    private func unreadCount() async -> ToolResult {
        let script = """
        tell application "Mail"
            set totalUnread to 0
            set output to ""
            repeat with acct in accounts
                set acctName to name of acct
                repeat with mbox in mailboxes of acct
                    set boxUnread to unread count of mbox
                    if boxUnread > 0 then
                        set totalUnread to totalUnread + boxUnread
                        set output to output & acctName & "/" & name of mbox & ": " & boxUnread & "\\n"
                    end if
                end repeat
            end repeat
            return "Total unread: " & totalUnread & "\\n\\n" & output
        end tell
        """

        do {
            let result = try await runAppleScript(script)
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to get unread count: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Errors

private enum EmailToolError: Error, LocalizedError {
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): return "Mail AppleScript error: \(msg)"
        }
    }
}
