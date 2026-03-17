import Foundation
import os

/// Remembers tool errors and provides fix hints to the LLM.
///
/// Key design: **never bans a tool**. Instead, it records the error pattern
/// and a suggested fix so the LLM can adjust its approach next time.
/// Example: shell "rm /tmp/foo" → "No such file" → hint: "Check file exists first with `test -f`"
nonisolated final class ErrorMemoryBank: @unchecked Sendable {
    static let shared = ErrorMemoryBank()

    private let queue = DispatchQueue(label: "com.dockwright.errormemory", attributes: .concurrent)
    private var entries: [ErrorEntry] = []
    private let maxEntries = 200
    private let storePath: String

    struct ErrorEntry: Codable, Sendable {
        let toolName: String
        let argSignature: String   // simplified key of what was attempted
        let errorSnippet: String   // first 200 chars of error output
        let hint: String           // generated fix suggestion
        let timestamp: Date
        var hitCount: Int          // how many times this pattern was seen
    }

    private init() {
        let base = NSHomeDirectory() + "/.dockwright"
        storePath = base + "/error_memory.json"
        load()
    }

    // MARK: - Record an error

    /// Record a tool failure. Automatically generates a fix hint from the error.
    func record(toolName: String, arguments: [String: Any], errorOutput: String) {
        let sig = argSignature(toolName: toolName, arguments: arguments)
        let snippet = String(errorOutput.prefix(200))
        let hint = generateHint(toolName: toolName, arguments: arguments, error: errorOutput)

        queue.async(flags: .barrier) { [self] in
            // Check if we already have this pattern
            if let idx = entries.firstIndex(where: { $0.toolName == toolName && $0.argSignature == sig }) {
                entries[idx].hitCount += 1
            } else {
                let entry = ErrorEntry(
                    toolName: toolName,
                    argSignature: sig,
                    errorSnippet: snippet,
                    hint: hint,
                    timestamp: Date(),
                    hitCount: 1
                )
                entries.append(entry)

                // Evict oldest if over limit
                if entries.count > maxEntries {
                    entries.removeFirst(entries.count - maxEntries)
                }
            }
            save()
        }
        log.info("[ErrorMemory] Recorded: \(toolName) → \(snippet.prefix(60))...")
    }

    // MARK: - Get hints for a tool call (pre-execution)

    /// Returns relevant error hints for a tool before the LLM calls it.
    /// Injected into system prompt so the LLM can avoid known pitfalls.
    func hintsForTool(_ toolName: String, arguments: [String: Any]) -> String? {
        var result: String?
        queue.sync {
            let sig = argSignature(toolName: toolName, arguments: arguments)

            // Exact match on signature
            let exact = entries.filter { $0.toolName == toolName && $0.argSignature == sig }
            if !exact.isEmpty {
                result = exact.map { "⚠️ Previously failed: \($0.errorSnippet.prefix(100))... → Fix: \($0.hint)" }
                    .joined(separator: "\n")
                return
            }

            // Fuzzy match: same tool, similar pattern
            let similar = entries.filter { $0.toolName == toolName && $0.hitCount >= 2 }
                .prefix(3)
            if !similar.isEmpty {
                result = similar.map { "💡 Known issue with \($0.toolName): \($0.hint)" }
                    .joined(separator: "\n")
            }
        }
        return result
    }

    /// Returns a summary of recent errors for system prompt injection.
    /// Only includes high-frequency errors (seen 2+ times).
    func systemPromptFragment() -> String {
        var fragment = ""
        queue.sync {
            let recent = entries
                .filter { $0.hitCount >= 2 }
                .suffix(5)

            if !recent.isEmpty {
                fragment = "\nTOOL ERROR MEMORY (avoid repeating these mistakes):\n"
                for entry in recent {
                    fragment += "- \(entry.toolName): \(entry.hint)\n"
                }
            }
        }
        return fragment
    }

    // MARK: - Hint generation (rule-based, no LLM needed)

    private func generateHint(toolName: String, arguments: [String: Any], error: String) -> String {
        let errorLower = error.lowercased()

        // Shell-specific patterns
        if toolName == "shell" {
            let cmd = (arguments["command"] as? String) ?? ""

            if errorLower.contains("no such file or directory") {
                let path = extractPath(from: error)
                return "Path '\(path)' doesn't exist. Check with `test -f \(path)` or `ls` first."
            }
            if errorLower.contains("permission denied") {
                return "Permission denied. The command may need different permissions or the file is protected."
            }
            if errorLower.contains("command not found") {
                let cmdName = cmd.split(separator: " ").first.map(String.init) ?? cmd
                return "'\(cmdName)' is not installed. Check with `which \(cmdName)` or install it first."
            }
            if errorLower.contains("operation not permitted") {
                return "macOS blocked this operation. May need Full Disk Access or specific entitlement."
            }
            if errorLower.contains("timed out") || errorLower.contains("timeout") {
                return "Command timed out. Use a shorter timeout, run async, or break into smaller steps."
            }
            if errorLower.contains("syntax error") {
                return "Shell syntax error. Check quoting, escaping, and bracket matching."
            }
            if errorLower.contains("disk full") || errorLower.contains("no space left") {
                return "Disk is full. Free up space before retrying."
            }
            if errorLower.contains("connection refused") || errorLower.contains("could not resolve host") {
                return "Network error. Check if the service is running or the URL is correct."
            }
        }

        // File tool patterns
        if toolName == "file" {
            if errorLower.contains("no such file") || errorLower.contains("doesn't exist") {
                return "File doesn't exist. Use 'exists' action to check first, or 'list' to find the correct path."
            }
            if errorLower.contains("is a directory") {
                return "Target is a directory, not a file. Use 'list' action for directories."
            }
            if errorLower.contains("too large") || errorLower.contains("exceeds") {
                return "File is too large to read. Try reading a smaller portion or use shell with `head`/`tail`."
            }
        }

        // Web search patterns
        if toolName == "web_search" {
            if errorLower.contains("rate limit") || errorLower.contains("429") {
                return "Search rate limited. Wait a moment before searching again."
            }
        }

        // Calendar/Contacts/Reminders patterns
        if errorLower.contains("not authorized") || errorLower.contains("access denied") || errorLower.contains("denied") {
            return "Permission not granted for \(toolName). User needs to allow access in System Settings → Privacy."
        }

        // Generic fallback — still useful
        let briefError = String(error.prefix(80)).replacingOccurrences(of: "\n", with: " ")
        return "Failed with: \(briefError). Verify inputs and try a different approach."
    }

    // MARK: - Helpers

    /// Create a simplified signature from tool args for pattern matching.
    private func argSignature(toolName: String, arguments: [String: Any]) -> String {
        switch toolName {
        case "shell":
            // Normalize: strip variable parts, keep command structure
            let cmd = (arguments["command"] as? String) ?? ""
            let parts = cmd.split(separator: " ").prefix(3)
            return parts.joined(separator: " ")
        case "file":
            let action = (arguments["action"] as? String) ?? ""
            let path = (arguments["path"] as? String) ?? ""
            return "\(action):\(path)"
        default:
            let action = (arguments["action"] as? String) ?? ""
            return action.isEmpty ? toolName : "\(toolName):\(action)"
        }
    }

    /// Try to extract a file path from an error message.
    private func extractPath(from error: String) -> String {
        // Pattern: "No such file or directory: '/path/to/thing'" or similar
        if let range = error.range(of: #"['\"]?(/[^\s'\"]+)['\"]?"#, options: .regularExpression) {
            let match = String(error[range])
            return match.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        return "(unknown path)"
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            let dir = (storePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
        } catch {
            log.error("[ErrorMemory] Save failed: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: storePath)),
              let loaded = try? JSONDecoder().decode([ErrorEntry].self, from: data) else {
            return
        }
        entries = loaded
        log.info("[ErrorMemory] Loaded \(self.entries.count) error patterns")
    }
}
