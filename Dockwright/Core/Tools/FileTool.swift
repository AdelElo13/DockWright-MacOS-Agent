import Foundation

/// File operations: read, write, list, search, exists.
struct FileTool: Tool, Sendable {
    let name = "file"
    let description = "Read, write, list, search, or check existence of files on the user's Mac."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "Action to perform: read, write, list, search, exists",
            "enum": ["read", "write", "list", "search", "exists"]
        ] as [String: Any],
        "path": [
            "type": "string",
            "description": "File or directory path"
        ] as [String: Any],
        "content": [
            "type": "string",
            "description": "Content to write (only for write action)",
            "optional": true
        ] as [String: Any],
        "pattern": [
            "type": "string",
            "description": "Glob pattern for search (e.g. '*.swift')",
            "optional": true
        ] as [String: Any]
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing required parameter: action", isError: true)
        }
        guard let path = arguments["path"] as? String else {
            return ToolResult("Missing required parameter: path", isError: true)
        }

        let expandedPath = (path as NSString).expandingTildeInPath
        let fm = FileManager.default

        switch action {
        case "read":
            return readFile(at: expandedPath)

        case "write":
            guard let content = arguments["content"] as? String else {
                return ToolResult("Missing required parameter: content for write action", isError: true)
            }
            return writeFile(at: expandedPath, content: content)

        case "list":
            return listDirectory(at: expandedPath)

        case "search":
            let pattern = arguments["pattern"] as? String ?? "*"
            return searchFiles(in: expandedPath, pattern: pattern)

        case "exists":
            let exists = fm.fileExists(atPath: expandedPath)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: expandedPath, isDirectory: &isDir)
            if exists {
                return ToolResult("Exists: \(isDir.boolValue ? "directory" : "file")")
            }
            return ToolResult("Does not exist")

        default:
            return ToolResult("Unknown action: \(action). Use: read, write, list, search, exists", isError: true)
        }
    }

    private func readFile(at path: String) -> ToolResult {
        let fm = FileManager.default

        // Resolve symlinks to get the real path
        let resolvedPath = (path as NSString).resolvingSymlinksInPath

        guard fm.fileExists(atPath: resolvedPath) else {
            return ToolResult("File not found: \(path)", isError: true)
        }

        // Check if it's a directory
        var isDir: ObjCBool = false
        fm.fileExists(atPath: resolvedPath, isDirectory: &isDir)
        if isDir.boolValue {
            return ToolResult("Path is a directory, not a file. Use 'list' action instead.", isError: true)
        }

        do {
            let attrs = try fm.attributesOfItem(atPath: resolvedPath)
            guard let size = attrs[.size] as? UInt64 else {
                return ToolResult("Cannot read file attributes", isError: true)
            }

            let maxSize: UInt64 = 1_000_000 // 1MB
            if size > maxSize {
                return ToolResult("File too large (\(size) bytes, max \(maxSize)). Use shell tool with head/tail instead.", isError: true)
            }

            guard fm.isReadableFile(atPath: resolvedPath) else {
                return ToolResult("Permission denied: cannot read \(path)", isError: true)
            }

            guard let data = fm.contents(atPath: resolvedPath),
                  let content = String(data: data, encoding: .utf8) else {
                return ToolResult("Cannot read file (binary or encoding issue)", isError: true)
            }

            return ToolResult(content)
        } catch {
            return ToolResult("Cannot read file attributes: \(error.localizedDescription)", isError: true)
        }
    }

    private func writeFile(at path: String, content: String) -> ToolResult {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return ToolResult("Written \(content.count) characters to \(path)")
        } catch {
            return ToolResult("Write failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func listDirectory(at path: String) -> ToolResult {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else {
            return ToolResult("Cannot list directory: \(path)", isError: true)
        }

        let sorted = items.sorted()
        var lines: [String] = []
        for item in sorted.prefix(200) {
            let fullPath = (path as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            let suffix = isDir.boolValue ? "/" : ""
            lines.append("\(item)\(suffix)")
        }
        if sorted.count > 200 {
            lines.append("... and \(sorted.count - 200) more items")
        }

        return ToolResult(lines.joined(separator: "\n"))
    }

    private func searchFiles(in path: String, pattern: String) -> ToolResult {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else {
            return ToolResult("Cannot search in: \(path)", isError: true)
        }

        var matches: [String] = []
        let maxResults = 100

        while let file = enumerator.nextObject() as? String {
            if matches.count >= maxResults { break }

            let filename = (file as NSString).lastPathComponent
            if matchesGlob(filename, pattern: pattern) {
                matches.append(file)
            }
        }

        if matches.isEmpty {
            return ToolResult("No files matching '\(pattern)' found in \(path)")
        }

        var result = "Found \(matches.count) match(es):\n"
        result += matches.joined(separator: "\n")
        if matches.count == maxResults {
            result += "\n[limited to \(maxResults) results]"
        }
        return ToolResult(result)
    }

    /// Simple glob matching supporting * and ?
    private func matchesGlob(_ string: String, pattern: String) -> Bool {
        let regexPattern = "^" + NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"

        return string.range(of: regexPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
