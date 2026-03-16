import Foundation
import os

nonisolated private let logger = Logger(subsystem: "com.dockwright", category: "BrowserTool")

/// LLM tool for controlling Safari and Chrome via AppleScript.
/// Actions: current_tab, all_tabs, open_url, read_page, search_web, screenshot_page.
nonisolated struct BrowserTool: Tool, @unchecked Sendable {
    let name = "browser"
    let description = "Control Safari and Chrome: get current tab, list tabs, open URLs, read page content, and search the web."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: current_tab, all_tabs, open_url, read_page, search_web, screenshot_page",
        ] as [String: Any],
        "url": [
            "type": "string",
            "description": "URL to open (for open_url)",
            "optional": true,
        ] as [String: Any],
        "query": [
            "type": "string",
            "description": "Search query (for search_web)",
            "optional": true,
        ] as [String: Any],
        "browser": [
            "type": "string",
            "description": "Force a specific browser: safari or chrome (default: auto-detect frontmost)",
            "optional": true,
        ] as [String: Any],
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult(
                "Missing 'action' parameter. Use: current_tab, all_tabs, open_url, read_page, search_web, screenshot_page",
                isError: true
            )
        }

        switch action {
        case "current_tab":
            return await currentTab(arguments)
        case "all_tabs":
            return await allTabs(arguments)
        case "open_url":
            return await openURL(arguments)
        case "read_page":
            return await readPage(arguments)
        case "search_web":
            return await searchWeb(arguments)
        case "screenshot_page":
            return await screenshotPage(arguments)
        default:
            return ToolResult(
                "Unknown action: \(action). Use: current_tab, all_tabs, open_url, read_page, search_web, screenshot_page",
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
            throw BrowserToolError.scriptFailed(errStr)
        }

        return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Browser Detection

    private enum Browser: String {
        case safari = "Safari"
        case chrome = "Google Chrome"
    }

    private func detectBrowser(_ args: [String: Any]) async -> Browser {
        if let explicit = args["browser"] as? String {
            if explicit.lowercased().contains("chrome") { return .chrome }
            if explicit.lowercased().contains("safari") { return .safari }
        }

        // Check which browser is frontmost
        let script = """
        tell application "System Events"
            set frontApp to name of first application process whose frontmost is true
        end tell
        return frontApp
        """

        do {
            let result = try await runAppleScript(script)
            if result.contains("Chrome") { return .chrome }
            if result.contains("Safari") { return .safari }
        } catch {
            logger.warning("Could not detect frontmost browser: \(error.localizedDescription)")
        }

        // Check if Safari is running, then Chrome
        let checkScript = """
        tell application "System Events"
            set safariRunning to exists (processes where name is "Safari")
            set chromeRunning to exists (processes where name is "Google Chrome")
            if safariRunning then
                return "Safari"
            else if chromeRunning then
                return "Google Chrome"
            else
                return "Safari"
            end if
        end tell
        """

        do {
            let result = try await runAppleScript(checkScript)
            if result.contains("Chrome") { return .chrome }
        } catch {
            // Default to Safari
        }

        return .safari
    }

    // MARK: - Actions

    private func currentTab(_ args: [String: Any]) async -> ToolResult {
        let browser = await detectBrowser(args)

        let script: String
        switch browser {
        case .safari:
            script = """
            tell application "Safari"
                if (count of windows) = 0 then return "No Safari windows open."
                set currentTab to current tab of front window
                set tabURL to URL of currentTab
                set tabTitle to name of currentTab
                return "Title: " & tabTitle & "\\nURL: " & tabURL
            end tell
            """
        case .chrome:
            script = """
            tell application "Google Chrome"
                if (count of windows) = 0 then return "No Chrome windows open."
                set currentTab to active tab of front window
                set tabURL to URL of currentTab
                set tabTitle to title of currentTab
                return "Title: " & tabTitle & "\\nURL: " & tabURL
            end tell
            """
        }

        do {
            let result = try await runAppleScript(script)
            return ToolResult("[\(browser.rawValue)]\n\(result)")
        } catch {
            return ToolResult("Failed to get current tab from \(browser.rawValue): \(error.localizedDescription)", isError: true)
        }
    }

    private func allTabs(_ args: [String: Any]) async -> ToolResult {
        let browser = await detectBrowser(args)

        let script: String
        switch browser {
        case .safari:
            script = """
            tell application "Safari"
                set output to ""
                set winCount to count of windows
                if winCount = 0 then return "No Safari windows open."
                repeat with w from 1 to winCount
                    set output to output & "Window " & w & ":\\n"
                    set tabList to tabs of window w
                    repeat with t from 1 to (count of tabList)
                        set aTab to item t of tabList
                        set tabTitle to name of aTab
                        set tabURL to URL of aTab
                        set output to output & "  " & t & ". " & tabTitle & "\\n     " & tabURL & "\\n"
                    end repeat
                end repeat
                return output
            end tell
            """
        case .chrome:
            script = """
            tell application "Google Chrome"
                set output to ""
                set winCount to count of windows
                if winCount = 0 then return "No Chrome windows open."
                repeat with w from 1 to winCount
                    set output to output & "Window " & w & ":\\n"
                    set tabList to tabs of window w
                    repeat with t from 1 to (count of tabList)
                        set aTab to item t of tabList
                        set tabTitle to title of aTab
                        set tabURL to URL of aTab
                        set output to output & "  " & t & ". " & tabTitle & "\\n     " & tabURL & "\\n"
                    end repeat
                end repeat
                return output
            end tell
            """
        }

        do {
            let result = try await runAppleScript(script)
            return ToolResult("[\(browser.rawValue)] All tabs:\n\n\(result)")
        } catch {
            return ToolResult("Failed to list tabs from \(browser.rawValue): \(error.localizedDescription)", isError: true)
        }
    }

    private func openURL(_ args: [String: Any]) async -> ToolResult {
        guard let url = args["url"] as? String, !url.isEmpty else {
            return ToolResult("Missing 'url' for open_url", isError: true)
        }

        // Ensure URL has a scheme
        let fullURL: String
        if url.hasPrefix("http://") || url.hasPrefix("https://") {
            fullURL = url
        } else {
            fullURL = "https://\(url)"
        }

        let escaped = escapeForAppleScript(fullURL)

        // Use the system default browser via `open`
        let script = """
        do shell script "open \\"\(escaped)\\""
        return "Opened: \(escaped)"
        """

        do {
            let result = try await runAppleScript(script)
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to open URL: \(error.localizedDescription)", isError: true)
        }
    }

    private func readPage(_ args: [String: Any]) async -> ToolResult {
        let browser = await detectBrowser(args)

        let script: String
        switch browser {
        case .safari:
            script = """
            tell application "Safari"
                if (count of windows) = 0 then return "No Safari windows open."
                set currentTab to current tab of front window
                set tabURL to URL of currentTab
                set tabTitle to name of currentTab
                set pageText to do JavaScript "document.body.innerText" in currentTab
                if (count of pageText) > 10000 then
                    set pageText to text 1 thru 10000 of pageText
                    set pageText to pageText & "\\n\\n[Content truncated at 10,000 characters]"
                end if
                return "Title: " & tabTitle & "\\nURL: " & tabURL & "\\n\\n" & pageText
            end tell
            """
        case .chrome:
            script = """
            tell application "Google Chrome"
                if (count of windows) = 0 then return "No Chrome windows open."
                set currentTab to active tab of front window
                set tabURL to URL of currentTab
                set tabTitle to title of currentTab
                set pageText to execute currentTab javascript "document.body.innerText"
                if (count of pageText) > 10000 then
                    set pageText to text 1 thru 10000 of pageText
                    set pageText to pageText & "\\n\\n[Content truncated at 10,000 characters]"
                end if
                return "Title: " & tabTitle & "\\nURL: " & tabURL & "\\n\\n" & pageText
            end tell
            """
        }

        do {
            let result = try await runAppleScript(script)
            return ToolResult("[\(browser.rawValue)] Page content:\n\n\(result)")
        } catch {
            return ToolResult("Failed to read page from \(browser.rawValue): \(error.localizedDescription)\n\nNote: Safari requires 'Allow JavaScript from Apple Events' in Develop menu. Chrome requires no special setup.", isError: true)
        }
    }

    private func searchWeb(_ args: [String: Any]) async -> ToolResult {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return ToolResult("Missing 'query' for search_web", isError: true)
        }

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return ToolResult("Failed to encode search query", isError: true)
        }

        let searchURL = "https://www.google.com/search?q=\(encoded)"
        let escaped = escapeForAppleScript(searchURL)

        let script = """
        do shell script "open \\"\(escaped)\\""
        return "Opened Google search for: \(escapeForAppleScript(query))"
        """

        do {
            let result = try await runAppleScript(script)
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to open search: \(error.localizedDescription)", isError: true)
        }
    }

    private func screenshotPage(_ args: [String: Any]) async -> ToolResult {
        // Placeholder: return current page info since actual screenshot requires more infrastructure
        let browser = await detectBrowser(args)

        let script: String
        switch browser {
        case .safari:
            script = """
            tell application "Safari"
                if (count of windows) = 0 then return "No Safari windows open."
                set currentTab to current tab of front window
                set tabURL to URL of currentTab
                set tabTitle to name of currentTab
                tell application "System Events"
                    tell process "Safari"
                        set winPos to position of window 1
                        set winSize to size of window 1
                    end tell
                end tell
                return "Title: " & tabTitle & "\\nURL: " & tabURL & "\\nWindow position: " & (item 1 of winPos as string) & ", " & (item 2 of winPos as string) & "\\nWindow size: " & (item 1 of winSize as string) & "x" & (item 2 of winSize as string) & "\\n\\n[Screenshot capture not yet implemented — use the Vision tool or system screenshot instead]"
            end tell
            """
        case .chrome:
            script = """
            tell application "Google Chrome"
                if (count of windows) = 0 then return "No Chrome windows open."
                set currentTab to active tab of front window
                set tabURL to URL of currentTab
                set tabTitle to title of currentTab
                tell application "System Events"
                    tell process "Google Chrome"
                        set winPos to position of window 1
                        set winSize to size of window 1
                    end tell
                end tell
                return "Title: " & tabTitle & "\\nURL: " & tabURL & "\\nWindow position: " & (item 1 of winPos as string) & ", " & (item 2 of winPos as string) & "\\nWindow size: " & (item 1 of winSize as string) & "x" & (item 2 of winSize as string) & "\\n\\n[Screenshot capture not yet implemented — use the Vision tool or system screenshot instead]"
            end tell
            """
        }

        do {
            let result = try await runAppleScript(script)
            return ToolResult("[\(browser.rawValue)] Page info:\n\n\(result)")
        } catch {
            return ToolResult("Failed to get page info from \(browser.rawValue): \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Errors

private enum BrowserToolError: Error, LocalizedError {
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): return "Browser AppleScript error: \(msg)"
        }
    }
}
