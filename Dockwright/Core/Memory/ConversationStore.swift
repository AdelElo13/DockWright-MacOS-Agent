import Foundation
import os

/// Persists conversations to ~/.dockwright/conversations/ as JSON files.
/// Thread-safe via serial DispatchQueue. Includes in-memory LRU cache.
final class ConversationStore: @unchecked Sendable {
    private let storageDir: URL
    private let indexFile: URL
    private let ioQueue = DispatchQueue(label: "com.dockwright.conversations.io")

    // LRU cache
    private var cache: [String: CachedConversation] = [:]
    private let maxCacheEntries = 5
    private var cachedIndex: [ConversationSummary]?

    private struct CachedConversation {
        let conversation: Conversation
        var accessTime: CFAbsoluteTime
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    nonisolated init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        storageDir = home.appendingPathComponent(".dockwright/conversations")
        indexFile = storageDir.appendingPathComponent("index.json")

        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        } catch {
            AppLog.storage.error("Failed to create conversations directory: \(error.localizedDescription)")
        }
    }

    // MARK: - Load Index

    func loadIndex() -> [ConversationSummary] {
        ioQueue.sync { _loadIndexUnsafe() }
    }

    private func _loadIndexUnsafe() -> [ConversationSummary] {
        if let cached = cachedIndex { return cached }
        guard FileManager.default.fileExists(atPath: indexFile.path) else { return [] }
        do {
            let data = try Data(contentsOf: indexFile)
            let summaries = try Self.decoder.decode([ConversationSummary].self, from: data)
            let sorted = summaries.sorted { $0.updatedAt > $1.updatedAt }
            cachedIndex = sorted
            return sorted
        } catch {
            AppLog.storage.error("Corrupt index.json detected: \(error.localizedDescription). Backing up and recreating.")
            // Backup corrupt file
            let backupURL = indexFile.deletingPathExtension().appendingPathExtension("corrupt.\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: indexFile, to: backupURL)
            return []
        }
    }

    private func _saveIndexUnsafe(_ summaries: [ConversationSummary]) {
        do {
            let sorted = summaries.sorted { $0.updatedAt > $1.updatedAt }
            let data = try Self.encoder.encode(sorted)
            try data.write(to: indexFile, options: .atomic)
            cachedIndex = sorted
        } catch {
            cachedIndex = nil
            AppLog.storage.error("Failed to save index: \(error.localizedDescription)")
        }
    }

    // MARK: - Load Conversation

    func load(id: String) -> Conversation? {
        // Validate id to prevent path traversal
        let safeId = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard safeId == id else { return nil }

        return ioQueue.sync {
            if let cached = cache[id] {
                cache[id]?.accessTime = CFAbsoluteTimeGetCurrent()
                return cached.conversation
            }

            let file = storageDir.appendingPathComponent("\(id).json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            do {
                let data = try Data(contentsOf: file)
                let conv = try Self.decoder.decode(Conversation.self, from: data)
                insertIntoCache(id: id, conversation: conv)
                return conv
            } catch {
                AppLog.storage.error("Corrupt conversation file \(id).json: \(error.localizedDescription). Backing up.")
                let backupURL = file.deletingPathExtension().appendingPathExtension("corrupt.\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: file, to: backupURL)
                return nil
            }
        }
    }

    // MARK: - Save Conversation

    func save(_ conversation: Conversation) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let file = storageDir.appendingPathComponent("\(conversation.id).json")
            do {
                let data = try Self.encoder.encode(conversation)
                try data.write(to: file, options: .atomic)
            } catch {
                AppLog.storage.error("Failed to save conversation \(conversation.id): \(error.localizedDescription)")
            }

            // Update index
            var summaries = _loadIndexUnsafe()
            let summary = ConversationSummary(from: conversation)
            if let idx = summaries.firstIndex(where: { $0.id == conversation.id }) {
                summaries[idx] = summary
            } else {
                summaries.insert(summary, at: 0)
            }
            _saveIndexUnsafe(summaries)

            insertIntoCache(id: conversation.id, conversation: conversation)
        }
    }

    // MARK: - Delete

    func delete(id: String) {
        let safeId = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard safeId == id else { return }

        ioQueue.sync {
            let file = storageDir.appendingPathComponent("\(id).json")
            try? FileManager.default.removeItem(at: file)

            var summaries = _loadIndexUnsafe()
            summaries.removeAll { $0.id == id }
            _saveIndexUnsafe(summaries)

            cache.removeValue(forKey: id)
        }
    }

    // MARK: - List All

    func listAll() -> [ConversationSummary] {
        loadIndex()
    }

    // MARK: - Search

    func search(query: String) -> [ConversationSummary] {
        let q = query.lowercased()
        return loadIndex().filter {
            $0.title.lowercased().contains(q) || $0.preview.lowercased().contains(q)
        }
    }

    // MARK: - LRU Cache

    private func insertIntoCache(id: String, conversation: Conversation) {
        cache[id] = CachedConversation(conversation: conversation, accessTime: CFAbsoluteTimeGetCurrent())
        if cache.count > maxCacheEntries {
            if let oldest = cache.min(by: { $0.value.accessTime < $1.value.accessTime }) {
                cache.removeValue(forKey: oldest.key)
            }
        }
    }
}
