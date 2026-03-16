import Foundation

/// Web search via DuckDuckGo HTML API.
struct WebSearchTool: Tool, Sendable {
    let name = "web_search"
    let description = "Search the web using DuckDuckGo. Returns top results with titles, URLs, and snippets."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "query": [
            "type": "string",
            "description": "The search query"
        ] as [String: Any]
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let query = arguments["query"] as? String else {
            return ToolResult("Missing required parameter: query", isError: true)
        }

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return ToolResult("Invalid search query", isError: true)
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await withRetry(maxAttempts: 2, delay: 1.0) {
                try await URLSession.shared.data(for: request)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                return ToolResult("Search request returned invalid response", isError: true)
            }

            switch httpResponse.statusCode {
            case 200:
                break // success
            case 429:
                return ToolResult("Search rate limited. Please try again in a moment.", isError: true)
            case 500...599:
                return ToolResult("Search engine server error (HTTP \(httpResponse.statusCode)). Try again later.", isError: true)
            default:
                return ToolResult("Search request failed with HTTP \(httpResponse.statusCode)", isError: true)
            }

            guard let html = String(data: data, encoding: .utf8) else {
                return ToolResult("Cannot decode search results (encoding issue)", isError: true)
            }

            let results = parseResults(html: html)
            if results.isEmpty {
                return ToolResult("No results found for: \(query)")
            }

            var output = "Search results for: \(query)\n\n"
            for (index, result) in results.prefix(5).enumerated() {
                output += "\(index + 1). \(result.title)\n"
                output += "   URL: \(result.url)\n"
                output += "   \(result.snippet)\n\n"
            }

            return ToolResult(output)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return ToolResult("No internet connection. Cannot perform web search.", isError: true)
            case .timedOut:
                return ToolResult("Search timed out. Check your internet connection.", isError: true)
            case .cannotFindHost, .dnsLookupFailed:
                return ToolResult("DNS lookup failed. Cannot reach search engine.", isError: true)
            default:
                return ToolResult("Search failed: \(error.localizedDescription)", isError: true)
            }
        } catch {
            return ToolResult("Search failed: \(error.localizedDescription)", isError: true)
        }
    }

    private struct SearchResult {
        let title: String
        let url: String
        let snippet: String
    }

    private func parseResults(html: String) -> [SearchResult] {
        var results: [SearchResult] = []

        // Parse DuckDuckGo HTML results
        // Results are in <a class="result__a" href="...">title</a>
        // Snippets in <a class="result__snippet" ...>text</a>

        // Extract result blocks
        let resultPattern = #"class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"class="result__snippet"[^>]*>(.*?)</a>"#

        let titleMatches = regexMatches(html, pattern: resultPattern)
        let snippetMatches = regexMatches(html, pattern: snippetPattern)

        for (index, titleMatch) in titleMatches.enumerated() {
            guard titleMatch.count >= 3 else { continue }

            let rawURL = titleMatch[1]
            let rawTitle = stripHTML(titleMatch[2])

            // DuckDuckGo wraps URLs in redirect — extract the actual URL
            let actualURL = extractURL(from: rawURL)
            let snippet = index < snippetMatches.count && snippetMatches[index].count >= 2
                ? stripHTML(snippetMatches[index][1])
                : ""

            if !actualURL.isEmpty && !rawTitle.isEmpty {
                results.append(SearchResult(title: rawTitle, url: actualURL, snippet: snippet))
            }
        }

        return results
    }

    private func regexMatches(_ string: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }

        let nsString = string as NSString
        let matches = regex.matches(in: string, range: NSRange(location: 0, length: nsString.length))

        return matches.map { match in
            (0..<match.numberOfRanges).map { i in
                let range = match.range(at: i)
                return range.location != NSNotFound ? nsString.substring(with: range) : ""
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

    private func extractURL(from ddgURL: String) -> String {
        // DuckDuckGo redirects look like //duckduckgo.com/l/?uddg=https%3A%2F%2F...&rut=...
        if let range = ddgURL.range(of: "uddg=") {
            let encoded = String(ddgURL[range.upperBound...])
                .components(separatedBy: "&").first ?? ""
            return encoded.removingPercentEncoding ?? encoded
        }
        // Direct URL
        if ddgURL.hasPrefix("http") { return ddgURL }
        if ddgURL.hasPrefix("//") { return "https:" + ddgURL }
        return ddgURL
    }
}
