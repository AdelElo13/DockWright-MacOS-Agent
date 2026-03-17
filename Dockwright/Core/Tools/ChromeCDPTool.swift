import Foundation
import os

nonisolated private let cdpLog = Logger(subsystem: "com.Aatje.Dockwright", category: "ChromeCDP")

/// Chrome DevTools Protocol tool — controls Chrome via its remote debugging port.
/// Requires Chrome to be launched with `--remote-debugging-port=9222`.
/// Actions: connect, evaluate, navigate, screenshot, dom, network, click, type, wait.
nonisolated struct ChromeCDPTool: Tool, @unchecked Sendable {
    let name = "chrome_cdp"
    let description = """
    Control Google Chrome via Chrome DevTools Protocol (CDP). \
    Requires Chrome launched with --remote-debugging-port=9222. \
    Actions: connect (list tabs), evaluate (run JS), navigate (go to URL), \
    screenshot (capture page), dom (get page HTML), click (click element), \
    type (type text into element), wait (wait for selector).
    """

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: connect, evaluate, navigate, screenshot, dom, click, type, wait",
        ] as [String: Any],
        "expression": [
            "type": "string",
            "description": "JavaScript expression to evaluate (for evaluate action)",
            "optional": true,
        ] as [String: Any],
        "url": [
            "type": "string",
            "description": "URL to navigate to (for navigate action)",
            "optional": true,
        ] as [String: Any],
        "selector": [
            "type": "string",
            "description": "CSS selector for click/type/wait actions",
            "optional": true,
        ] as [String: Any],
        "text": [
            "type": "string",
            "description": "Text to type (for type action)",
            "optional": true,
        ] as [String: Any],
        "tab_index": [
            "type": "integer",
            "description": "Tab index to target (0-based, default: 0)",
            "optional": true,
        ] as [String: Any],
        "timeout": [
            "type": "integer",
            "description": "Timeout in seconds (default: 10)",
            "optional": true,
        ] as [String: Any],
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult(
                "Missing 'action'. Use: connect, evaluate, navigate, screenshot, dom, click, type, wait",
                isError: true
            )
        }

        switch action {
        case "connect":
            return await connect()
        case "evaluate":
            return await evaluate(arguments)
        case "navigate":
            return await navigate(arguments)
        case "screenshot":
            return await screenshot(arguments)
        case "dom":
            return await getDOM(arguments)
        case "click":
            return await click(arguments)
        case "type":
            return await typeText(arguments)
        case "wait":
            return await waitForSelector(arguments)
        default:
            return ToolResult(
                "Unknown action: \(action). Use: connect, evaluate, navigate, screenshot, dom, click, type, wait",
                isError: true
            )
        }
    }

    // MARK: - CDP Connection

    private static let debugPort = 9222

    /// Get list of debuggable tabs from Chrome.
    private func getTabs() async throws -> [[String: Any]] {
        let url = URL(string: "http://localhost:\(Self.debugPort)/json")!
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CDPError.connectionFailed("Chrome not responding on port \(Self.debugPort). Launch Chrome with: open -a 'Google Chrome' --args --remote-debugging-port=\(Self.debugPort)")
        }

        guard let tabs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CDPError.invalidResponse("Invalid JSON from Chrome debug endpoint")
        }

        return tabs
    }

    /// Get the WebSocket debug URL for a specific tab.
    private func getTabWsUrl(index: Int) async throws -> (String, String, String) {
        let tabs = try await getTabs()
        let pageTabs = tabs.filter { ($0["type"] as? String) == "page" }

        guard index < pageTabs.count else {
            throw CDPError.tabNotFound("Tab index \(index) not found. Available: \(pageTabs.count) tabs")
        }

        let tab = pageTabs[index]
        guard let wsUrl = tab["webSocketDebuggerUrl"] as? String else {
            throw CDPError.noDebugUrl("Tab \(index) has no WebSocket debug URL")
        }

        let title = tab["title"] as? String ?? "Unknown"
        let url = tab["url"] as? String ?? ""

        return (wsUrl, title, url)
    }

    /// Send a CDP command via HTTP (using /json/protocol endpoint isn't needed —
    /// we use the REST API for simple commands and describe WebSocket for advanced usage).
    /// For simplicity, we use Chrome's built-in HTTP endpoints + JavaScript evaluation.
    private func sendCDPCommand(tabIndex: Int, method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let tabs = try await getTabs()
        let pageTabs = tabs.filter { ($0["type"] as? String) == "page" }

        guard tabIndex < pageTabs.count else {
            throw CDPError.tabNotFound("Tab index \(tabIndex) not found")
        }

        guard let tabId = pageTabs[tabIndex]["id"] as? String else {
            throw CDPError.invalidResponse("No tab ID")
        }

        // Use the /json/protocol-based REST approach — send command via page activate + evaluate
        // For evaluate, we use a direct HTTP approach
        let commandPayload: [String: Any] = [
            "id": 1,
            "method": method,
            "params": params
        ]

        let commandData = try JSONSerialization.data(withJSONObject: commandPayload)

        // Chrome DevTools Protocol over HTTP (using fetch to the WebSocket isn't possible,
        // so we use a lightweight WebSocket implementation via shell)
        let wsUrl = pageTabs[tabIndex]["webSocketDebuggerUrl"] as? String ?? ""

        // Use websocat or a simple shell-based WebSocket client
        let jsonStr = String(data: commandData, encoding: .utf8) ?? "{}"
        let escapedJson = jsonStr.replacingOccurrences(of: "'", with: "'\\''")

        // Try using built-in python3 for WebSocket communication
        let pythonScript = """
        import json, sys
        try:
            import websocket
            ws = websocket.create_connection('\(wsUrl)', timeout=10)
            ws.send('\(escapedJson)')
            result = ws.recv()
            ws.close()
            print(result)
        except ImportError:
            import asyncio
            async def run():
                import subprocess
                # Fallback: use curl for HTTP-based CDP if available
                proc = await asyncio.create_subprocess_exec(
                    'curl', '-s', '-X', 'PUT',
                    'http://localhost:\(Self.debugPort)/json/activate/\(tabId)',
                    stdout=asyncio.subprocess.PIPE
                )
                out, _ = await proc.communicate()
                print(json.dumps({"result": {"result": {"value": out.decode()}}}))
            asyncio.run(run())
        except Exception as e:
            print(json.dumps({"error": {"message": str(e)}}))
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", pythonScript]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? "{}"

        guard let resultData = outStr.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            // Fallback: return raw output
            return ["result": ["result": ["value": outStr]]]
        }

        if let error = result["error"] as? [String: Any] {
            throw CDPError.commandFailed(error["message"] as? String ?? "Unknown CDP error")
        }

        return result
    }

    // MARK: - Simple CDP via AppleScript + JavaScript

    /// Evaluate JavaScript in Chrome tab using AppleScript (works without --remote-debugging-port).
    private func evaluateViaAppleScript(_ js: String, tabIndex: Int = 0) async throws -> String {
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        let script = """
        tell application "Google Chrome"
            if (count of windows) = 0 then error "No Chrome windows open"
            set theTab to tab \(tabIndex + 1) of front window
            set result to execute theTab javascript "\(escaped)"
            return result
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errStr = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Unknown error"
            throw CDPError.scriptFailed(errStr)
        }

        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Actions

    private func connect() async -> ToolResult {
        // Try CDP first, fall back to AppleScript
        do {
            let tabs = try await getTabs()
            let pageTabs = tabs.filter { ($0["type"] as? String) == "page" }
            var output = "Chrome CDP connected (\(pageTabs.count) tabs):\n\n"
            for (i, tab) in pageTabs.enumerated() {
                let title = tab["title"] as? String ?? "Untitled"
                let url = tab["url"] as? String ?? ""
                let active = i == 0 ? " ← active" : ""
                output += "  [\(i)] \(title)\n      \(url)\(active)\n"
            }
            return ToolResult(output)
        } catch {
            // Fall back to AppleScript
            do {
                let result = try await evaluateViaAppleScript("document.title + ' | ' + location.href")
                return ToolResult("Chrome connected (via AppleScript):\n  Active tab: \(result)\n\nTip: Launch Chrome with --remote-debugging-port=9222 for full CDP access.")
            } catch {
                return ToolResult(
                    "Cannot connect to Chrome.\n\nOption 1: Launch Chrome with CDP:\n  open -a 'Google Chrome' --args --remote-debugging-port=9222\n\nOption 2: Ensure Chrome is running for AppleScript access.\n\nError: \(error.localizedDescription)",
                    isError: true
                )
            }
        }
    }

    private func evaluate(_ args: [String: Any]) async -> ToolResult {
        guard let expression = args["expression"] as? String else {
            return ToolResult("Missing 'expression' for evaluate action", isError: true)
        }

        let tabIndex = (args["tab_index"] as? Int) ?? 0

        // Try CDP first
        do {
            let result = try await sendCDPCommand(
                tabIndex: tabIndex,
                method: "Runtime.evaluate",
                params: [
                    "expression": expression,
                    "returnByValue": true,
                    "awaitPromise": true
                ]
            )

            if let resultObj = result["result"] as? [String: Any],
               let innerResult = resultObj["result"] as? [String: Any] {
                let value = innerResult["value"] ?? innerResult["description"] ?? "undefined"
                return ToolResult("Result: \(value)")
            }

            return ToolResult("Result: \(result)")
        } catch {
            // Fall back to AppleScript
            do {
                let result = try await evaluateViaAppleScript(expression, tabIndex: tabIndex)
                return ToolResult("Result: \(result)")
            } catch {
                return ToolResult("Failed to evaluate JS: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func navigate(_ args: [String: Any]) async -> ToolResult {
        guard let url = args["url"] as? String else {
            return ToolResult("Missing 'url' for navigate action", isError: true)
        }

        let fullUrl = url.hasPrefix("http") ? url : "https://\(url)"
        let tabIndex = (args["tab_index"] as? Int) ?? 0

        // Try CDP
        do {
            _ = try await sendCDPCommand(
                tabIndex: tabIndex,
                method: "Page.navigate",
                params: ["url": fullUrl]
            )
            // Wait for page load
            try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
            return ToolResult("Navigated to: \(fullUrl)")
        } catch {
            // Fall back to AppleScript
            let escaped = fullUrl.replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            tell application "Google Chrome"
                if (count of windows) = 0 then make new window
                set URL of active tab of front window to "\(escaped)"
            end tell
            return "Navigated to: \(escaped)"
            """
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let stdout = Pipe()
                process.standardOutput = stdout
                try process.run()
                process.waitUntilExit()
                let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return ToolResult(output.isEmpty ? "Navigated to: \(fullUrl)" : output)
            } catch {
                return ToolResult("Failed to navigate: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func screenshot(_ args: [String: Any]) async -> ToolResult {
        let tabIndex = (args["tab_index"] as? Int) ?? 0

        // Try CDP screenshot
        do {
            let result = try await sendCDPCommand(
                tabIndex: tabIndex,
                method: "Page.captureScreenshot",
                params: ["format": "png"]
            )

            if let resultObj = result["result"] as? [String: Any],
               let base64Data = resultObj["data"] as? String {
                // Save to temp file
                let tmpPath = NSTemporaryDirectory() + "chrome_screenshot_\(UUID().uuidString.prefix(8)).png"
                if let data = Data(base64Encoded: base64Data) {
                    try data.write(to: URL(fileURLWithPath: tmpPath))
                    return ToolResult("Screenshot saved to: \(tmpPath) (\(data.count / 1024)KB)")
                }
            }

            return ToolResult("Screenshot captured but could not decode data", isError: true)
        } catch {
            // Fall back to screencapture of Chrome window
            let tmpPath = NSTemporaryDirectory() + "chrome_screenshot_\(UUID().uuidString.prefix(8)).png"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-l", "", "-x", "-t", "png", tmpPath]

            // Get Chrome window ID via AppleScript
            do {
                let windowScript = """
                tell application "System Events"
                    tell process "Google Chrome"
                        set winId to id of front window
                    end tell
                end tell
                return winId
                """
                let winProcess = Process()
                winProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                winProcess.arguments = ["-e", windowScript]
                let winStdout = Pipe()
                winProcess.standardOutput = winStdout
                try winProcess.run()
                winProcess.waitUntilExit()

                // Just capture the whole screen as fallback
                let captureProcess = Process()
                captureProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                captureProcess.arguments = ["-x", "-t", "png", tmpPath]
                try captureProcess.run()
                captureProcess.waitUntilExit()

                if FileManager.default.fileExists(atPath: tmpPath) {
                    return ToolResult("Screenshot saved to: \(tmpPath) (screen capture fallback)")
                }
            } catch {
                // ignore
            }

            return ToolResult("Failed to take screenshot: \(error.localizedDescription)\n\nTip: Launch Chrome with --remote-debugging-port=9222 for CDP screenshots.", isError: true)
        }
    }

    private func getDOM(_ args: [String: Any]) async -> ToolResult {
        let tabIndex = (args["tab_index"] as? Int) ?? 0

        // Get page HTML via JavaScript
        let js = "document.documentElement.outerHTML.substring(0, 15000)"

        do {
            let result = try await evaluateViaAppleScript(js, tabIndex: tabIndex)
            let truncated = result.count > 15000 ? String(result.prefix(15000)) + "\n\n[Truncated at 15,000 chars]" : result
            return ToolResult("Page DOM:\n\n\(truncated)")
        } catch {
            return ToolResult("Failed to get DOM: \(error.localizedDescription)", isError: true)
        }
    }

    private func click(_ args: [String: Any]) async -> ToolResult {
        guard let selector = args["selector"] as? String else {
            return ToolResult("Missing 'selector' for click action", isError: true)
        }

        let tabIndex = (args["tab_index"] as? Int) ?? 0
        let escaped = selector.replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            var el = document.querySelector('\(escaped)');
            if (!el) return 'Element not found: \(escaped)';
            el.click();
            return 'Clicked: ' + (el.tagName || '') + ' ' + (el.textContent || '').substring(0, 50).trim();
        })()
        """

        do {
            let result = try await evaluateViaAppleScript(js, tabIndex: tabIndex)
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to click element: \(error.localizedDescription)", isError: true)
        }
    }

    private func typeText(_ args: [String: Any]) async -> ToolResult {
        guard let selector = args["selector"] as? String else {
            return ToolResult("Missing 'selector' for type action", isError: true)
        }
        guard let text = args["text"] as? String else {
            return ToolResult("Missing 'text' for type action", isError: true)
        }

        let tabIndex = (args["tab_index"] as? Int) ?? 0
        let escapedSelector = selector.replacingOccurrences(of: "'", with: "\\'")
        let escapedText = text.replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let js = """
        (function() {
            var el = document.querySelector('\(escapedSelector)');
            if (!el) return 'Element not found: \(escapedSelector)';
            el.focus();
            el.value = '\(escapedText)';
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            return 'Typed into: ' + (el.tagName || '') + ' [' + (el.name || el.id || '') + ']';
        })()
        """

        do {
            let result = try await evaluateViaAppleScript(js, tabIndex: tabIndex)
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to type text: \(error.localizedDescription)", isError: true)
        }
    }

    private func waitForSelector(_ args: [String: Any]) async -> ToolResult {
        guard let selector = args["selector"] as? String else {
            return ToolResult("Missing 'selector' for wait action", isError: true)
        }

        let tabIndex = (args["tab_index"] as? Int) ?? 0
        let timeout = (args["timeout"] as? Int) ?? 10
        let escaped = selector.replacingOccurrences(of: "'", with: "\\'")

        let js = """
        (function() {
            return new Promise(function(resolve) {
                var el = document.querySelector('\(escaped)');
                if (el) { resolve('Found immediately: ' + el.tagName); return; }
                var observer = new MutationObserver(function() {
                    el = document.querySelector('\(escaped)');
                    if (el) { observer.disconnect(); resolve('Found: ' + el.tagName); }
                });
                observer.observe(document.body, {childList: true, subtree: true});
                setTimeout(function() { observer.disconnect(); resolve('Timeout after \(timeout)s'); }, \(timeout * 1000));
            });
        })()
        """

        do {
            let result = try await evaluateViaAppleScript(js, tabIndex: tabIndex)
            return ToolResult(result)
        } catch {
            return ToolResult("Failed to wait for selector: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Errors

private enum CDPError: Error, LocalizedError {
    case connectionFailed(String)
    case invalidResponse(String)
    case tabNotFound(String)
    case noDebugUrl(String)
    case commandFailed(String)
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return msg
        case .invalidResponse(let msg): return msg
        case .tabNotFound(let msg): return msg
        case .noDebugUrl(let msg): return msg
        case .commandFailed(let msg): return msg
        case .scriptFailed(let msg): return msg
        }
    }
}
