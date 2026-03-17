import Foundation
import os

private nonisolated let wsLog = Logger(subsystem: "com.Aatje.Dockwright", category: "WebSearch")

/// Web search with priority chain (always has a working path):
///   1. Brave Search API (if key configured) — clean JSON, no CAPTCHAs
///   2. Headless Chrome → DuckDuckGo lite — handles JS, fewer CAPTCHAs
///   3. DuckDuckGo HTML via URLSession — no deps but may CAPTCHA
///   4. Headless Chrome → Google — often CAPTCHA'd but worth trying
///   5. Visible browser fallback — always works, opens real browser
///
/// Direct URL fetches use headless Chrome (if available) or URLSession.
/// When headlessBrowsing is OFF in settings, search_web opens a visible browser tab instead.
struct WebSearchTool: Tool, Sendable {
    let name = "web_search"
    let description = "Search the web. Returns top results with titles, URLs, and snippets. Can also fetch/read a specific URL's content."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "query": [
            "type": "string",
            "description": "Search query OR a full URL to fetch directly"
        ] as [String: Any]
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return ToolResult("Missing required parameter: query", isError: true)
        }

        // If it looks like a URL, fetch the page content directly
        if query.hasPrefix("http://") || query.hasPrefix("https://") {
            return await fetchURL(query)
        }

        let headless = await MainActor.run { AppPreferences.shared.headlessBrowsing }

        // When headless is OFF — open visible browser and tell the user
        if !headless {
            return await openVisibleSearch(query)
        }

        // Priority 1: Brave Search API (if key configured — clean JSON, no CAPTCHAs)
        if let braveKey = KeychainHelper.read(key: "brave_search_api_key"), !braveKey.isEmpty {
            let result = await braveSearch(query: query, apiKey: braveKey)
            if !result.isError { return result }
            wsLog.warning("Brave Search failed, falling back: \(result.output)")
        }

        // Priority 2: Headless Chrome → DuckDuckGo lite (better than URLSession, handles JS)
        if chromeAvailable {
            let chromeResult = await headlessChromeSearch(query: query)
            if !chromeResult.isError { return chromeResult }
            wsLog.warning("Headless Chrome DDG failed, trying URLSession DDG")
        }

        // Priority 3: DuckDuckGo HTML via URLSession (may hit CAPTCHA)
        let ddgResult = await duckDuckGoSearch(query: query)
        if !ddgResult.isError { return ddgResult }

        // Priority 4: Headless Chrome → Google (often CAPTCHA'd but worth trying)
        if chromeAvailable {
            let googleResult = await headlessChromeGoogleSearch(query: query)
            if !googleResult.isError { return googleResult }
        }

        // Priority 5: Fall back to visible browser — always works
        wsLog.warning("All headless search methods failed for: \(query) — falling back to visible browser")
        return await openVisibleSearch(query)
    }

    // MARK: - Brave Search API

    private func braveSearch(query: String, apiKey: String) async -> ToolResult {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.search.brave.com/res/v1/web/search?q=\(encoded)&count=5") else {
            return ToolResult("Invalid search query", isError: true)
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                return ToolResult("Brave Search: invalid response", isError: true)
            }

            if http.statusCode == 422 || http.statusCode == 401 {
                return ToolResult("Brave Search: invalid API key", isError: true)
            }

            guard http.statusCode == 200 else {
                return ToolResult("Brave Search: HTTP \(http.statusCode)", isError: true)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let webResults = json["web"] as? [String: Any],
                  let results = webResults["results"] as? [[String: Any]] else {
                return ToolResult("Brave Search: could not parse results", isError: true)
            }

            if results.isEmpty {
                return ToolResult("No results found for: \(query)")
            }

            var output = "Search results for: \(query)\n\n"
            for (i, r) in results.prefix(5).enumerated() {
                let title = r["title"] as? String ?? "Untitled"
                let rURL = r["url"] as? String ?? ""
                let snippet = r["description"] as? String ?? ""
                output += "\(i + 1). \(title)\n"
                output += "   URL: \(rURL)\n"
                output += "   \(snippet)\n\n"
            }

            wsLog.info("Brave Search returned \(results.count) results for: \(query)")
            return ToolResult(output)

        } catch {
            return ToolResult("Brave Search error: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Fetch URL (headless Chrome or URLSession)

    private func fetchURL(_ urlString: String) async -> ToolResult {
        let headless = await MainActor.run { AppPreferences.shared.headlessBrowsing }

        if headless && chromeAvailable {
            // Use headless Chrome for better JS rendering
            return await headlessChromeFetch(urlString)
        }

        // Fallback: URLSession for plain HTML
        guard let url = URL(string: urlString) else {
            return ToolResult("Invalid URL: \(urlString)", isError: true)
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return ToolResult("HTTP \(code) fetching \(urlString)", isError: true)
            }
            guard let html = String(data: data, encoding: .utf8) else {
                return ToolResult("Cannot decode page content", isError: true)
            }
            let text = extractText(from: html)
            let truncated = String(text.prefix(15000))
            return ToolResult("Content from \(urlString):\n\n\(truncated)")
        } catch {
            return ToolResult("Failed to fetch \(urlString): \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Headless Chrome

    private var chromeAvailable: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    }

    private func headlessChromeFetch(_ urlString: String) async -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        process.arguments = ["--headless", "--disable-gpu", "--dump-dom", "--virtual-time-budget=5000", urlString]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()

            // 20-second timeout using async wait
            let timedOut = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                func safeResume(_ value: Bool) {
                    let already = resumed.withLock { v -> Bool in if v { return true }; v = true; return false }
                    guard !already else { return }
                    cont.resume(returning: value)
                }
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    safeResume(false)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                    safeResume(true)
                }
            }

            if timedOut {
                process.terminate()
                return ToolResult("Headless Chrome timed out fetching \(urlString)", isError: true)
            }

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
                return ToolResult("Headless Chrome returned empty content", isError: true)
            }

            let text = extractText(from: html)
            let truncated = String(text.prefix(15000))

            if text.count < 100 {
                return ToolResult("Page returned minimal content (\(text.count) chars)", isError: true)
            }

            return ToolResult("Content from \(urlString):\n\n\(truncated)")
        } catch {
            return ToolResult("Headless Chrome error: \(error.localizedDescription)", isError: true)
        }
    }

    private func headlessChromeSearch(query: String) async -> ToolResult {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return ToolResult("Failed to encode search query", isError: true)
        }

        let result = await headlessChromeFetch("https://lite.duckduckgo.com/lite/?q=\(encoded)")
        if result.isError { return result }

        return ToolResult("Search results for: \(query)\n\n\(result.output)")
    }

    private func headlessChromeGoogleSearch(query: String) async -> ToolResult {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return ToolResult("Failed to encode search query", isError: true)
        }

        let result = await headlessChromeFetch("https://www.google.com/search?q=\(encoded)")
        if result.isError { return result }

        return ToolResult("Search results for: \(query)\n\n\(result.output)")
    }

    // MARK: - Visible Browser Search

    private func openVisibleSearch(_ query: String) async -> ToolResult {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return ToolResult("Failed to encode search query", isError: true)
        }

        // If Brave key available, still use the API even in non-headless mode
        if let braveKey = KeychainHelper.read(key: "brave_search_api_key"), !braveKey.isEmpty {
            let result = await braveSearch(query: query, apiKey: braveKey)
            if !result.isError { return result }
        }

        // Open in default browser and tell the LLM what happened
        let searchURL = "https://www.google.com/search?q=\(encoded)"
        let script = """
        do shell script "open '\(searchURL.replacingOccurrences(of: "'", with: "'\\''"))'"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        process.waitUntilExit()

        return ToolResult("Opened Google search for \"\(query)\" in the user's browser. Headless browsing is disabled — use the browser tool's read_page action to get the results, or ask the user what they see.")
    }

    // MARK: - DuckDuckGo HTML Fallback

    private func duckDuckGoSearch(query: String) async -> ToolResult {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return ToolResult("Invalid search query", isError: true)
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return ToolResult("DuckDuckGo HTTP error", isError: true)
            }

            guard let html = String(data: data, encoding: .utf8) else {
                return ToolResult("Cannot decode response", isError: true)
            }

            // Detect CAPTCHA
            if html.contains("anomaly-modal") || html.contains("challenge-form") || html.contains("captcha") {
                wsLog.warning("DuckDuckGo returned CAPTCHA")
                return ToolResult("DuckDuckGo blocked with CAPTCHA", isError: true)
            }

            let results = parseDDGResults(html: html)
            if results.isEmpty {
                return ToolResult("DuckDuckGo: no results", isError: true)
            }

            var output = "Search results for: \(query)\n\n"
            for (i, r) in results.prefix(5).enumerated() {
                output += "\(i + 1). \(r.title)\n"
                output += "   URL: \(r.url)\n"
                output += "   \(r.snippet)\n\n"
            }
            return ToolResult(output)

        } catch {
            return ToolResult("DuckDuckGo error: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - HTML Parsing Helpers

    private struct SearchResult {
        let title: String
        let url: String
        let snippet: String
    }

    private func parseDDGResults(html: String) -> [SearchResult] {
        var results: [SearchResult] = []

        let titlePattern = #"class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"class="result__snippet"[^>]*>(.*?)</a>"#

        let titleMatches = regexMatches(html, pattern: titlePattern)
        let snippetMatches = regexMatches(html, pattern: snippetPattern)

        for (index, titleMatch) in titleMatches.enumerated() {
            guard titleMatch.count >= 3 else { continue }

            let rawURL = titleMatch[1]
            let rawTitle = stripHTML(titleMatch[2])
            let actualURL = extractDDGURL(from: rawURL)
            let snippet = index < snippetMatches.count && snippetMatches[index].count >= 2
                ? stripHTML(snippetMatches[index][1])
                : ""

            if !actualURL.isEmpty && !rawTitle.isEmpty {
                results.append(SearchResult(title: rawTitle, url: actualURL, snippet: snippet))
            }
        }

        return results
    }

    private func extractText(from html: String) -> String {
        // Remove script/style blocks first
        var text = html
        text = text.replacingOccurrences(of: #"<script[^>]*>[\s\S]*?</script>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<style[^>]*>[\s\S]*?</style>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = stripHTML(text)
        // Collapse whitespace
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func regexMatches(_ string: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = string as NSString
        return regex.matches(in: string, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { i in
                let range = match.range(at: i)
                return range.location != NSNotFound ? ns.substring(with: range) : ""
            }
        }
    }

    private func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractDDGURL(from ddgURL: String) -> String {
        if let range = ddgURL.range(of: "uddg=") {
            let encoded = String(ddgURL[range.upperBound...])
                .components(separatedBy: "&").first ?? ""
            return encoded.removingPercentEncoding ?? encoded
        }
        if ddgURL.hasPrefix("http") { return ddgURL }
        if ddgURL.hasPrefix("//") { return "https:" + ddgURL }
        return ddgURL
    }
}
