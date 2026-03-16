import Foundation
import os

nonisolated private let finderLogger = Logger(subsystem: "com.dockwright", category: "FinderTool")

/// LLM tool for file system operations via Finder and FileManager.
/// Actions: list, move, copy, rename, trash, create_folder, compress, decompress, info, reveal, search.
nonisolated struct FinderTool: Tool, @unchecked Sendable {
    let name = "finder"
    let description = "Manage files and folders: list directory contents, move, copy, rename, trash, create folders, compress/decompress, get file info, reveal in Finder, and Spotlight search."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: list, move, copy, rename, trash, create_folder, compress, decompress, info, reveal, search",
        ] as [String: Any],
        "path": [
            "type": "string",
            "description": "File or directory path (required for most actions)",
            "optional": true,
        ] as [String: Any],
        "destination": [
            "type": "string",
            "description": "Destination path (for move, copy)",
            "optional": true,
        ] as [String: Any],
        "new_name": [
            "type": "string",
            "description": "New name (for rename)",
            "optional": true,
        ] as [String: Any],
        "query": [
            "type": "string",
            "description": "Search query (for search via Spotlight)",
            "optional": true,
        ] as [String: Any],
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult(
                "Missing 'action' parameter. Use: list, move, copy, rename, trash, create_folder, compress, decompress, info, reveal, search",
                isError: true
            )
        }

        switch action {
        case "list":
            return listDirectory(arguments)
        case "move":
            return moveItem(arguments)
        case "copy":
            return copyItem(arguments)
        case "rename":
            return renameItem(arguments)
        case "trash":
            return trashItem(arguments)
        case "create_folder":
            return createFolder(arguments)
        case "compress":
            return await compressItem(arguments)
        case "decompress":
            return await decompressItem(arguments)
        case "info":
            return fileInfo(arguments)
        case "reveal":
            return await revealInFinder(arguments)
        case "search":
            return await spotlightSearch(arguments)
        default:
            return ToolResult(
                "Unknown action: \(action). Use: list, move, copy, rename, trash, create_folder, compress, decompress, info, reveal, search",
                isError: true
            )
        }
    }

    // MARK: - Shell Runner

    private func runShell(_ command: String, arguments args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args

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
            finderLogger.error("Shell command failed: \(errStr)")
            throw FinderToolError.commandFailed(errStr)
        }

        return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Helpers

    private func expandPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Actions

    private func listDirectory(_ args: [String: Any]) -> ToolResult {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return ToolResult("Missing 'path' for list", isError: true)
        }

        let expanded = expandPath(path)
        let fm = FileManager.default

        guard fm.fileExists(atPath: expanded) else {
            return ToolResult("Path does not exist: \(expanded)", isError: true)
        }

        do {
            let contents = try fm.contentsOfDirectory(atPath: expanded)
            if contents.isEmpty {
                return ToolResult("Directory is empty: \(expanded)")
            }

            var lines: [String] = []
            for item in contents.sorted() {
                let itemPath = (expanded as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: itemPath, isDirectory: &isDir)

                let attrs = try? fm.attributesOfItem(atPath: itemPath)
                let size = (attrs?[.size] as? Int64) ?? 0
                let modified = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
                let typeStr = isDir.boolValue ? "DIR " : "FILE"

                lines.append("\(typeStr)  \(formatBytes(size).padding(toLength: 10, withPad: " ", startingAt: 0))  \(formatDate(modified))  \(item)")
            }

            return ToolResult("Contents of \(expanded):\n\n\(lines.joined(separator: "\n"))")
        } catch {
            return ToolResult("Failed to list directory: \(error.localizedDescription)", isError: true)
        }
    }

    private func moveItem(_ args: [String: Any]) -> ToolResult {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return ToolResult("Missing 'path' for move", isError: true)
        }
        guard let destination = args["destination"] as? String, !destination.isEmpty else {
            return ToolResult("Missing 'destination' for move", isError: true)
        }

        let src = expandPath(path)
        let dst = expandPath(destination)

        do {
            try FileManager.default.moveItem(atPath: src, toPath: dst)
            return ToolResult("Moved: \(src) → \(dst)")
        } catch {
            return ToolResult("Failed to move: \(error.localizedDescription)", isError: true)
        }
    }

    private func copyItem(_ args: [String: Any]) -> ToolResult {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return ToolResult("Missing 'path' for copy", isError: true)
        }
        guard let destination = args["destination"] as? String, !destination.isEmpty else {
            return ToolResult("Missing 'destination' for copy", isError: true)
        }

        let src = expandPath(path)
        let dst = expandPath(destination)

        do {
            try FileManager.default.copyItem(atPath: src, toPath: dst)
            return ToolResult("Copied: \(src) → \(dst)")
        } catch {
            return ToolResult("Failed to copy: \(error.localizedDescription)", isError: true)
        }
    }

    private func renameItem(_ args: [String: Any]) -> ToolResult {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return ToolResult("Missing 'path' for rename", isError: true)
        }
        guard let newName = args["new_name"] as? String, !newName.isEmpty else {
            return ToolResult("Missing 'new_name' for rename", isError: true)
        }

        let src = expandPath(path)
        let parentDir = (src as NSString).deletingLastPathComponent
        let dst = (parentDir as NSString).appendingPathComponent(newName)

        do {
            try FileManager.default.moveItem(atPath: src, toPath: dst)
            return ToolResult("Renamed: \(src) → \(dst)")
        } catch {
            return ToolResult("Failed to rename: \(error.localizedDescription)", isError: true)
        }
    }

    private func trashItem(_ args: [String: Any]) -> ToolResult {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return ToolResult("Missing 'path' for trash", isError: true)
        }

        let expanded = expandPath(path)
        let url = URL(fileURLWithPath: expanded)

        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            let trashPath = resultingURL?.path ?? "Trash"
            return ToolResult("Moved to Trash: \(expanded) → \(trashPath)")
        } catch {
            return ToolResult("Failed to trash: \(error.localizedDescription)", isError: true)
        }
    }

    private func createFolder(_ args: [String: Any]) -> ToolResult {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return ToolResult("Missing 'path' for create_folder", isError: true)
        }

        let expanded = expandPath(path)

        do {
            try FileManager.default.createDirectory(atPath: expanded, withIntermediateDirectories: true)
            return ToolResult("Created folder: \(expanded)")
        } catch {
            return ToolResult("Failed to create folder: \(error.localizedDescription)", isError: true)
        }
    }

    private func compressItem(_ args: [String: Any]) async -> ToolResult {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return ToolResult("Missing 'path' for compress", isError: true)
        }

        let expanded = expandPath(path)
        let _ = (expanded as NSString).deletingLastPathComponent
        let fileName = (expanded as NSString).lastPathComponent
        let zipPath = args["destination"] as? String ?? "\(expanded).zip"

        do {
            _ = try await runShell("/usr/bin/zip", arguments: ["-r", zipPath, fileName])
            // zip needs to run from the parent directory, use ditto instead
        } catch {
            // Fall through to ditto
        }

        do {
            _ = try await runShell("/usr/bin/ditto", arguments: ["-c", "-k", "--sequesterRsrc", expanded, zipPath])
            return ToolResult("Compressed: \(expanded) → \(zipPath)")
        } catch {
            return ToolResult("Failed to compress: \(error.localizedDescription)", isError: true)
        }
    }

    private func decompressItem(_ args: [String: Any]) async -> ToolResult {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return ToolResult("Missing 'path' for decompress", isError: true)
        }

        let expanded = expandPath(path)
        let destination = args["destination"] as? String ?? (expanded as NSString).deletingLastPathComponent

        do {
            _ = try await runShell("/usr/bin/ditto", arguments: ["-x", "-k", expanded, destination])
            return ToolResult("Decompressed: \(expanded) → \(destination)")
        } catch {
            return ToolResult("Failed to decompress: \(error.localizedDescription)", isError: true)
        }
    }

    private func fileInfo(_ args: [String: Any]) -> ToolResult {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return ToolResult("Missing 'path' for info", isError: true)
        }

        let expanded = expandPath(path)
        let fm = FileManager.default

        guard fm.fileExists(atPath: expanded) else {
            return ToolResult("Path does not exist: \(expanded)", isError: true)
        }

        do {
            let attrs = try fm.attributesOfItem(atPath: expanded)
            let size = (attrs[.size] as? Int64) ?? 0
            let type = (attrs[.type] as? FileAttributeType) ?? .typeRegular
            let created = (attrs[.creationDate] as? Date) ?? Date.distantPast
            let modified = (attrs[.modificationDate] as? Date) ?? Date.distantPast
            let permissions = (attrs[.posixPermissions] as? Int) ?? 0
            let owner = (attrs[.ownerAccountName] as? String) ?? "unknown"
            let group = (attrs[.groupOwnerAccountName] as? String) ?? "unknown"

            let typeStr: String
            switch type {
            case .typeDirectory: typeStr = "Directory"
            case .typeSymbolicLink: typeStr = "Symbolic Link"
            default: typeStr = "File"
            }

            let permStr = String(format: "%o", permissions)

            let info = """
            Path: \(expanded)
            Type: \(typeStr)
            Size: \(formatBytes(size)) (\(size) bytes)
            Created: \(formatDate(created))
            Modified: \(formatDate(modified))
            Permissions: \(permStr)
            Owner: \(owner)
            Group: \(group)
            """

            return ToolResult(info)
        } catch {
            return ToolResult("Failed to get file info: \(error.localizedDescription)", isError: true)
        }
    }

    private func revealInFinder(_ args: [String: Any]) async -> ToolResult {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return ToolResult("Missing 'path' for reveal", isError: true)
        }

        let expanded = expandPath(path)

        do {
            _ = try await runShell("/usr/bin/open", arguments: ["-R", expanded])
            return ToolResult("Revealed in Finder: \(expanded)")
        } catch {
            return ToolResult("Failed to reveal in Finder: \(error.localizedDescription)", isError: true)
        }
    }

    private func spotlightSearch(_ args: [String: Any]) async -> ToolResult {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return ToolResult("Missing 'query' for search", isError: true)
        }

        let searchPath = args["path"] as? String

        do {
            var shellArgs = [query]
            if let searchPath = searchPath, !searchPath.isEmpty {
                shellArgs.insert(contentsOf: ["-onlyin", expandPath(searchPath)], at: 0)
            }

            let result = try await runShell("/usr/bin/mdfind", arguments: shellArgs)
            if result.isEmpty {
                return ToolResult("No results found for: \(query)")
            }

            let lines = result.components(separatedBy: "\n")
            let limited = lines.prefix(50)
            var output = "Spotlight results for '\(query)' (\(lines.count) found):\n\n"
            output += limited.joined(separator: "\n")
            if lines.count > 50 {
                output += "\n\n[Showing first 50 of \(lines.count) results]"
            }

            return ToolResult(output)
        } catch {
            return ToolResult("Spotlight search failed: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Errors

private enum FinderToolError: Error, LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let msg): return "Finder tool error: \(msg)"
        }
    }
}
