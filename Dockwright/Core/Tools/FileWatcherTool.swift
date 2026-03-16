import Foundation
import os

/// File watcher tool: monitor directories for changes using DispatchSource.
/// Supports multiple concurrent watches. Notifies via callback when files change.
struct FileWatcherTool: Tool, @unchecked Sendable {
    let name = "file_watcher"
    let description = """
        Watch directories for file changes. Actions:
        - start_watch: Start watching a directory for changes. Params: path (directory to watch)
        - stop_watch: Stop watching a directory. Params: watch_id (from start_watch result)
        - list_watches: List all active file watches
        - check_changes: Check for recent changes in a watched directory. Params: watch_id
        """

    let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "Action: start_watch, stop_watch, list_watches, check_changes",
            "enum": ["start_watch", "stop_watch", "list_watches", "check_changes"]
        ] as [String: Any],
        "path": [
            "type": "string",
            "description": "Directory path to watch (for start_watch)",
            "optional": true
        ] as [String: Any],
        "watch_id": [
            "type": "string",
            "description": "Watch ID (for stop_watch, check_changes)",
            "optional": true
        ] as [String: Any]
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing required parameter: action", isError: true)
        }

        switch action {
        case "start_watch":
            guard let path = arguments["path"] as? String else {
                return ToolResult("Missing parameter: path", isError: true)
            }
            let expandedPath = (path as NSString).expandingTildeInPath
            return FileWatcherManager.shared.startWatch(path: expandedPath)

        case "stop_watch":
            guard let watchId = arguments["watch_id"] as? String else {
                return ToolResult("Missing parameter: watch_id", isError: true)
            }
            return FileWatcherManager.shared.stopWatch(id: watchId)

        case "list_watches":
            return FileWatcherManager.shared.listWatches()

        case "check_changes":
            guard let watchId = arguments["watch_id"] as? String else {
                return ToolResult("Missing parameter: watch_id", isError: true)
            }
            return FileWatcherManager.shared.checkChanges(id: watchId)

        default:
            return ToolResult("Unknown action: \(action)", isError: true)
        }
    }
}

// MARK: - File Watcher Manager (Singleton)

nonisolated final class FileWatcherManager: @unchecked Sendable {
    static let shared = FileWatcherManager()

    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "file-watcher")
    private let lock = NSLock()
    private var watches: [String: WatchEntry] = [:]
    private let maxWatches = 10

    private struct WatchEntry {
        let id: String
        let path: String
        let source: DispatchSourceFileSystemObject
        let fileDescriptor: Int32
        let startTime: Date
        var initialContents: Set<String>
        var changes: [FileChange]
    }

    struct FileChange: Sendable {
        let path: String
        let type: String // "added", "removed", "modified"
        let timestamp: Date
    }

    private init() {}

    func startWatch(path: String) -> ToolResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return ToolResult("Path is not a directory: \(path)", isError: true)
        }

        lock.lock()
        if watches.count >= maxWatches {
            lock.unlock()
            return ToolResult("Maximum \(maxWatches) concurrent watches reached. Stop an existing watch first.", isError: true)
        }
        lock.unlock()

        let watchId = "watch_\(UUID().uuidString.prefix(8).lowercased())"

        // Get initial directory contents
        let initialContents = Set((try? fm.contentsOfDirectory(atPath: path)) ?? [])

        // Open directory file descriptor
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            return ToolResult("Cannot open directory for watching: \(path)", isError: true)
        }

        // Create DispatchSource for file system events
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )

        var entry = WatchEntry(
            id: watchId,
            path: path,
            source: source,
            fileDescriptor: fd,
            startTime: Date(),
            initialContents: initialContents,
            changes: []
        )

        source.setEventHandler { [weak self] in
            self?.handleChange(watchId: watchId)
        }

        source.setCancelHandler {
            close(fd)
        }

        lock.lock()
        watches[watchId] = entry
        lock.unlock()

        source.resume()

        logger.info("Started watching: \(path, privacy: .public) as \(watchId, privacy: .public)")
        return ToolResult("Watch started. ID: \(watchId)\nPath: \(path)\nInitial files: \(initialContents.count)")
    }

    func stopWatch(id: String) -> ToolResult {
        lock.lock()
        guard let entry = watches.removeValue(forKey: id) else {
            lock.unlock()
            return ToolResult("No watch found with ID: \(id)", isError: true)
        }
        lock.unlock()

        entry.source.cancel()
        logger.info("Stopped watching: \(entry.path, privacy: .public)")
        return ToolResult("Stopped watch \(id) on \(entry.path)")
    }

    func listWatches() -> ToolResult {
        lock.lock()
        let current = watches
        lock.unlock()

        if current.isEmpty {
            return ToolResult("No active file watches.")
        }

        var lines: [String] = ["Active watches (\(current.count)):"]
        for (_, entry) in current.sorted(by: { $0.value.startTime < $1.value.startTime }) {
            let elapsed = Int(Date().timeIntervalSince(entry.startTime))
            lines.append("  [\(entry.id)] \(entry.path) (running \(elapsed)s, \(entry.changes.count) changes)")
        }
        return ToolResult(lines.joined(separator: "\n"))
    }

    func checkChanges(id: String) -> ToolResult {
        lock.lock()
        guard let entry = watches[id] else {
            lock.unlock()
            return ToolResult("No watch found with ID: \(id)", isError: true)
        }

        // Snapshot current directory
        let fm = FileManager.default
        let currentContents = Set((try? fm.contentsOfDirectory(atPath: entry.path)) ?? [])

        let added = currentContents.subtracting(entry.initialContents)
        let removed = entry.initialContents.subtracting(currentContents)
        let changeCount = entry.changes.count
        lock.unlock()

        var lines: [String] = ["Watch \(id) on \(entry.path):"]
        lines.append("FS events received: \(changeCount)")

        if !added.isEmpty {
            lines.append("New files (\(added.count)):")
            for f in added.sorted().prefix(50) {
                lines.append("  + \(f)")
            }
        }
        if !removed.isEmpty {
            lines.append("Removed files (\(removed.count)):")
            for f in removed.sorted().prefix(50) {
                lines.append("  - \(f)")
            }
        }
        if added.isEmpty && removed.isEmpty && changeCount == 0 {
            lines.append("No changes detected.")
        } else if added.isEmpty && removed.isEmpty {
            lines.append("File modifications detected (no new/removed files).")
        }

        return ToolResult(lines.joined(separator: "\n"))
    }

    private func handleChange(watchId: String) {
        lock.lock()
        guard var entry = watches[watchId] else {
            lock.unlock()
            return
        }
        entry.changes.append(FileChange(
            path: entry.path,
            type: "modified",
            timestamp: Date()
        ))
        watches[watchId] = entry
        lock.unlock()
    }
}
