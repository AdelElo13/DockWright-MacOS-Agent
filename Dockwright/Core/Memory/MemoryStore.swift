import Foundation
import os

/// SQLite + FTS5 memory store for facts and episodes.
/// Provides full-text search for the LLM to remember and recall information.
final class MemoryStore: @unchecked Sendable {
    private let db = SQLiteManager()
    private let dbPath: String

    nonisolated init() {
        let base = NSHomeDirectory() + "/.dockwright"
        dbPath = base + "/memory.db"
    }

    /// Initialize database and create tables if needed.
    func setup() throws {
        do {
            try db.open(path: dbPath)
        } catch {
            log.error("[Memory] Database open failed, attempting recovery: \(error.localizedDescription)")
            try db.recoverIfCorrupt(path: dbPath)
        }

        // Facts table — stores individual pieces of information
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS facts (
                id TEXT PRIMARY KEY,
                content TEXT NOT NULL,
                category TEXT NOT NULL DEFAULT 'general',
                created_at TEXT NOT NULL
            )
        """)

        // Episodes table — stores conversation summaries
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS episodes (
                id TEXT PRIMARY KEY,
                summary TEXT NOT NULL,
                timestamp TEXT NOT NULL
            )
        """)

        // FTS5 virtual table for full-text search on facts
        // Use IF NOT EXISTS pattern: attempt create, ignore error if exists
        do {
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(
                    content, category,
                    content_rowid='rowid',
                    tokenize='porter unicode61'
                )
            """)
        } catch {
            // FTS table may already exist — that's fine
            log.debug("[Memory] FTS table already exists or creation skipped: \(error.localizedDescription)")
        }

        // FTS5 for episodes
        do {
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS episodes_fts USING fts5(
                    summary,
                    content_rowid='rowid',
                    tokenize='porter unicode61'
                )
            """)
        } catch {
            log.debug("[Memory] Episodes FTS table already exists or creation skipped: \(error.localizedDescription)")
        }

        log.info("[Memory] Database initialized at \(self.dbPath)")
    }

    // MARK: - Facts

    /// Save a fact to memory.
    func saveFact(content: String, category: String = "general") throws {
        let id = UUID().uuidString
        let createdAt = ISO8601DateFormatter().string(from: Date())

        try db.execute(
            sql: "INSERT INTO facts (id, content, category, created_at) VALUES (?, ?, ?, ?)",
            params: [id, content, category, createdAt]
        )

        // Insert into FTS index
        try db.execute(
            sql: "INSERT INTO facts_fts (rowid, content, category) VALUES (last_insert_rowid(), ?, ?)",
            params: [content, category]
        )

        log.debug("[Memory] Saved fact: \(content.prefix(50))...")
    }

    /// Search facts using FTS5 full-text search.
    func searchFacts(query: String, limit: Int = 10) throws -> [FactResult] {
        // Use FTS5 MATCH for full-text search with ranking
        let rows = try db.query(
            sql: """
                SELECT f.id, f.content, f.category, f.created_at
                FROM facts f
                JOIN facts_fts fts ON f.rowid = fts.rowid
                WHERE facts_fts MATCH ?
                ORDER BY rank
                LIMIT ?
            """,
            params: [sanitizeFTSQuery(query), String(limit)]
        )

        return rows.map { row in
            FactResult(
                id: row["id"] ?? "",
                content: row["content"] ?? "",
                category: row["category"] ?? "general",
                createdAt: row["created_at"] ?? ""
            )
        }
    }

    /// List all facts, optionally filtered by category.
    func listFacts(category: String? = nil, limit: Int = 50) throws -> [FactResult] {
        let sql: String
        let params: [String]

        if let category = category {
            sql = "SELECT id, content, category, created_at FROM facts WHERE category = ? ORDER BY created_at DESC LIMIT ?"
            params = [category, String(limit)]
        } else {
            sql = "SELECT id, content, category, created_at FROM facts ORDER BY created_at DESC LIMIT ?"
            params = [String(limit)]
        }

        let rows = try db.query(sql: sql, params: params)
        return rows.map { row in
            FactResult(
                id: row["id"] ?? "",
                content: row["content"] ?? "",
                category: row["category"] ?? "general",
                createdAt: row["created_at"] ?? ""
            )
        }
    }

    /// Delete a fact by ID.
    func deleteFact(id: String) throws {
        try db.execute(sql: "DELETE FROM facts WHERE id = ?", params: [id])
    }

    // MARK: - Episodes

    /// Save a conversation episode/summary.
    func saveEpisode(summary: String) throws {
        let id = UUID().uuidString
        let timestamp = ISO8601DateFormatter().string(from: Date())

        try db.execute(
            sql: "INSERT INTO episodes (id, summary, timestamp) VALUES (?, ?, ?)",
            params: [id, summary, timestamp]
        )

        try db.execute(
            sql: "INSERT INTO episodes_fts (rowid, summary) VALUES (last_insert_rowid(), ?)",
            params: [summary]
        )
    }

    /// Search episodes using FTS5.
    func searchEpisodes(query: String, limit: Int = 10) throws -> [EpisodeResult] {
        let rows = try db.query(
            sql: """
                SELECT e.id, e.summary, e.timestamp
                FROM episodes e
                JOIN episodes_fts efts ON e.rowid = efts.rowid
                WHERE episodes_fts MATCH ?
                ORDER BY rank
                LIMIT ?
            """,
            params: [sanitizeFTSQuery(query), String(limit)]
        )

        return rows.map { row in
            EpisodeResult(
                id: row["id"] ?? "",
                summary: row["summary"] ?? "",
                timestamp: row["timestamp"] ?? ""
            )
        }
    }

    // MARK: - Combined Search

    /// Search both facts and episodes, returning formatted results.
    func search(query: String, limit: Int = 10) throws -> String {
        var results: [String] = []

        let facts = try searchFacts(query: query, limit: limit)
        if !facts.isEmpty {
            results.append("FACTS:")
            for fact in facts {
                results.append("- [\(fact.category)] \(fact.content) (saved: \(fact.createdAt))")
            }
        }

        let episodes = try searchEpisodes(query: query, limit: limit)
        if !episodes.isEmpty {
            results.append("\nEPISODES:")
            for ep in episodes {
                results.append("- \(ep.summary) (\(ep.timestamp))")
            }
        }

        if results.isEmpty {
            return "No memories found matching '\(query)'."
        }

        return results.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Sanitize FTS5 query — escape special characters and wrap terms.
    private func sanitizeFTSQuery(_ query: String) -> String {
        // FTS5 uses simple tokens; remove special chars that could break syntax
        let cleaned = query
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return "\"\"" }

        // Wrap each word with * for prefix matching
        let terms = cleaned.split(separator: " ").map { "\($0)*" }
        return terms.joined(separator: " ")
    }
}

// MARK: - Result Types

struct FactResult: Sendable {
    let id: String
    let content: String
    let category: String
    let createdAt: String
}

struct EpisodeResult: Sendable {
    let id: String
    let summary: String
    let timestamp: String
}
