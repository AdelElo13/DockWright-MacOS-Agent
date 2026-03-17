import Foundation
import os

/// SQLite + FTS5 memory store for facts and episodes.
/// Provides full-text search with importance × recency ranking.
/// Max 5 facts injected per query to keep prompts lean.
nonisolated final class MemoryStore: @unchecked Sendable {
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

        // Facts table — with importance, access tracking, staleness
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS facts (
                id TEXT PRIMARY KEY,
                content TEXT NOT NULL,
                category TEXT NOT NULL DEFAULT 'general',
                importance INTEGER NOT NULL DEFAULT 3,
                access_count INTEGER NOT NULL DEFAULT 0,
                last_accessed TEXT,
                created_at TEXT NOT NULL
            )
        """)

        // Migrate old tables: add columns if they don't exist
        migrateFactsTable()

        // Episodes table — stores conversation summaries
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS episodes (
                id TEXT PRIMARY KEY,
                summary TEXT NOT NULL,
                timestamp TEXT NOT NULL
            )
        """)

        // FTS5 virtual table for full-text search on facts
        do {
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(
                    content, category,
                    content_rowid='rowid',
                    tokenize='porter unicode61'
                )
            """)
        } catch {
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

    /// Add importance/access columns to existing DB if missing.
    private func migrateFactsTable() {
        // Check if columns exist by querying pragma
        let columns = (try? db.query(sql: "PRAGMA table_info(facts)")) ?? []
        let columnNames = Set(columns.compactMap { $0["name"] })

        if !columnNames.contains("importance") {
            try? db.execute(sql: "ALTER TABLE facts ADD COLUMN importance INTEGER NOT NULL DEFAULT 3")
            log.info("[Memory] Migrated: added importance column")
        }
        if !columnNames.contains("access_count") {
            try? db.execute(sql: "ALTER TABLE facts ADD COLUMN access_count INTEGER NOT NULL DEFAULT 0")
            log.info("[Memory] Migrated: added access_count column")
        }
        if !columnNames.contains("last_accessed") {
            try? db.execute(sql: "ALTER TABLE facts ADD COLUMN last_accessed TEXT")
            log.info("[Memory] Migrated: added last_accessed column")
        }
    }

    // MARK: - Facts

    /// Save a fact to memory (after poison guard + supersede check).
    /// If a highly similar existing fact is found (same topic), it gets replaced instead of duplicated.
    func saveFact(content: String, category: String = "general", importance: Int = 3) throws {
        // Poison guard — reject bad facts before they enter the DB
        if let reason = MemoryPoisonGuard.shared.evaluate(content) {
            log.warning("[Memory] Rejected fact: \(reason)")
            throw MemoryError.poisonBlocked(reason)
        }

        let clampedImportance = max(1, min(5, importance))

        // Supersede check — find existing facts on the same topic and replace them
        if let supersededId = findSupersedable(newContent: content, category: category) {
            let now = ISO8601DateFormatter().string(from: Date())
            // Update in place: new content, bump importance to max of old+new, reset access tracking
            try db.execute(
                sql: "UPDATE facts SET content = ?, importance = MAX(importance, ?), created_at = ?, last_accessed = NULL WHERE id = ?",
                params: [content, String(clampedImportance), now, supersededId]
            )
            // Rebuild FTS entry — delete old, insert updated
            // Get the rowid for this fact
            let rows = try db.query(sql: "SELECT rowid FROM facts WHERE id = ?", params: [supersededId])
            if let rowid = rows.first?["rowid"] {
                try? db.execute(sql: "DELETE FROM facts_fts WHERE rowid = ?", params: [rowid])
                try db.execute(
                    sql: "INSERT INTO facts_fts (rowid, content, category) VALUES (?, ?, ?)",
                    params: [rowid, content, category]
                )
            }
            log.info("[Memory] Superseded existing fact \(supersededId.prefix(8))... with: \(content.prefix(50))...")
            return
        }

        // No supersede — insert new fact
        let id = UUID().uuidString
        let createdAt = ISO8601DateFormatter().string(from: Date())

        try db.execute(
            sql: "INSERT INTO facts (id, content, category, importance, access_count, created_at) VALUES (?, ?, ?, ?, 0, ?)",
            params: [id, content, category, String(clampedImportance), createdAt]
        )

        // Insert into FTS index
        try db.execute(
            sql: "INSERT INTO facts_fts (rowid, content, category) VALUES (last_insert_rowid(), ?, ?)",
            params: [content, category]
        )

        log.debug("[Memory] Saved fact (importance=\(clampedImportance)): \(content.prefix(50))...")
    }

    /// Search facts using FTS5, ranked by relevance × importance × recency.
    /// Returns max `limit` results (default 5 to keep prompts lean).
    func searchFacts(query: String, limit: Int = 5) throws -> [FactResult] {
        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty, sanitized != "\"\"" else { return [] }

        // FTS5 rank + importance weighting + recency boost
        let rows = try db.query(
            sql: """
                SELECT f.id, f.content, f.category, f.importance, f.access_count, f.created_at,
                       rank AS fts_rank
                FROM facts f
                JOIN facts_fts fts ON f.rowid = fts.rowid
                WHERE facts_fts MATCH ?
                ORDER BY (f.importance * 0.4 + rank * -0.6) DESC
                LIMIT ?
            """,
            params: [sanitized, String(limit)]
        )

        let now = ISO8601DateFormatter().string(from: Date())

        // Bump access count for returned results
        for row in rows {
            if let id = row["id"] {
                try? db.execute(
                    sql: "UPDATE facts SET access_count = access_count + 1, last_accessed = ? WHERE id = ?",
                    params: [now, id]
                )
            }
        }

        return rows.map { row in
            FactResult(
                id: row["id"] ?? "",
                content: row["content"] ?? "",
                category: row["category"] ?? "general",
                importance: Int(row["importance"] ?? "3") ?? 3,
                accessCount: Int(row["access_count"] ?? "0") ?? 0,
                createdAt: row["created_at"] ?? ""
            )
        }
    }

    /// Get the top N most relevant facts for a user message.
    /// Used for automatic context injection — keeps it to max 5 concise facts.
    func topRelevant(forMessage message: String, limit: Int = 5) -> [FactResult] {
        // Extract key terms (skip stop words, take meaningful words)
        let stopWords: Set<String> = ["the", "a", "an", "is", "are", "was", "were", "be", "been",
                                       "have", "has", "had", "do", "does", "did", "will", "would",
                                       "could", "should", "may", "might", "can", "shall", "to", "of",
                                       "in", "for", "on", "with", "at", "by", "from", "it", "this",
                                       "that", "and", "or", "but", "not", "what", "how", "why",
                                       "de", "het", "een", "van", "in", "op", "met", "voor", "naar",
                                       "is", "zijn", "was", "waren", "en", "of", "maar", "niet",
                                       "wat", "hoe", "waarom", "die", "dat", "er", "ook", "nog",
                                       "kan", "kun", "wil", "mag", "moet", "je", "jij", "ik", "mijn"]

        let words = message.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }

        guard !words.isEmpty else { return [] }

        // Take up to 5 most meaningful words for search
        let searchTerms = Array(words.prefix(5)).joined(separator: " ")

        do {
            return try searchFacts(query: searchTerms, limit: limit)
        } catch {
            log.debug("[Memory] Auto-retrieval failed: \(error.localizedDescription)")
            return []
        }
    }

    /// List all facts, optionally filtered by category.
    func listFacts(category: String? = nil, limit: Int = 50) throws -> [FactResult] {
        let sql: String
        let params: [String]

        if let category = category {
            sql = "SELECT id, content, category, importance, access_count, created_at FROM facts WHERE category = ? ORDER BY importance DESC, created_at DESC LIMIT ?"
            params = [category, String(limit)]
        } else {
            sql = "SELECT id, content, category, importance, access_count, created_at FROM facts ORDER BY importance DESC, created_at DESC LIMIT ?"
            params = [String(limit)]
        }

        let rows = try db.query(sql: sql, params: params)
        return rows.map { row in
            FactResult(
                id: row["id"] ?? "",
                content: row["content"] ?? "",
                category: row["category"] ?? "general",
                importance: Int(row["importance"] ?? "3") ?? 3,
                accessCount: Int(row["access_count"] ?? "0") ?? 0,
                createdAt: row["created_at"] ?? ""
            )
        }
    }

    /// Find an existing fact that the new content supersedes (same topic, updated info).
    /// Two-pass detection:
    ///   1. Subject-pattern match — detects "lives in X" vs "lives in Y" style updates
    ///   2. Keyword overlap — catches broader topic matches (>50% shared keywords)
    /// Returns the ID of the fact to replace, or nil if this is genuinely new.
    private func findSupersedable(newContent: String, category: String) -> String? {
        let newWords = extractKeywords(newContent)
        guard newWords.count >= 2 else { return nil }

        let newSubject = extractSubjectPattern(newContent)

        let existing = (try? db.query(
            sql: "SELECT id, content FROM facts WHERE category = ? ORDER BY created_at DESC LIMIT 50",
            params: [category]
        )) ?? []

        for row in existing {
            guard let id = row["id"], let content = row["content"] else { continue }

            // Pass 1: Subject-pattern match (e.g., both match "lives in *" or "works at *")
            if let newSubj = newSubject, let oldSubj = extractSubjectPattern(content) {
                if newSubj == oldSubj {
                    log.debug("[Memory] Subject pattern match '\(newSubj)' — superseding '\(content.prefix(40))...'")
                    return id
                }
            }

            // Pass 2: Keyword overlap
            let oldWords = extractKeywords(content)
            guard !oldWords.isEmpty else { continue }

            let shared = newWords.intersection(oldWords)
            let smaller = min(newWords.count, oldWords.count)
            let overlap = Double(shared.count) / Double(smaller)

            if overlap > 0.5 {
                log.debug("[Memory] Keyword overlap \(Int(overlap * 100))% — superseding '\(content.prefix(40))...'")
                return id
            }
        }
        return nil
    }

    /// Detect the "subject pattern" of a fact — the verb/relation that defines what topic it's about.
    /// Returns a normalized pattern like "lives_in", "works_at", "favorite_color", etc.
    /// This allows matching "lives in Amsterdam" with "lives in Rotterdam" even across languages.
    private func extractSubjectPattern(_ text: String) -> String? {
        let lower = text.lowercased()

        // English patterns
        let patterns: [(regex: String, label: String)] = [
            (#"(?:lives?|living|moved?|resides?|woont|verhuisd)\s+(?:in|to|naar)"#, "lives_in"),
            (#"(?:works?|working|employed|werkt)\s+(?:at|for|bij|voor)"#, "works_at"),
            (#"(?:favorite|favourite|preferred|favo(?:riete)?)\s+(?:color|colour|kleur)"#, "fav_color"),
            (#"(?:favorite|favourite|preferred|favo(?:riete)?)\s+(?:food|eten|gerecht)"#, "fav_food"),
            (#"(?:favorite|favourite|preferred|favo(?:riete)?)\s+(?:language|taal|programming)"#, "fav_language"),
            (#"(?:favorite|favourite|preferred|favo(?:riete)?)\s+(?:music|song|band|genre|muziek)"#, "fav_music"),
            (#"(?:born|birthday|geboren|verjaardag)\s"#, "birthday"),
            (#"(?:speaks?|spreekt|language|taal)"#, "speaks_language"),
            (#"(?:age|old|leeftijd|jaar\s+oud)"#, "age"),
            (#"(?:name|naam)\s+(?:is|=)"#, "name"),
            (#"(?:email|e-mail)\s"#, "email"),
            (#"(?:phone|nummer|telefoon)"#, "phone"),
            (#"(?:pet|huisdier|dog|cat|hond|kat)"#, "pet"),
            (#"(?:hobby|hobbies|hobby's)"#, "hobby"),
            (#"(?:drives?|car|auto|rijdt)"#, "drives"),
            (#"(?:studies|studying|studeert|student)"#, "studies"),
        ]

        for (regex, label) in patterns {
            if lower.range(of: regex, options: .regularExpression) != nil {
                return label
            }
        }
        return nil
    }

    /// Extract meaningful keywords from text (lowercase, no stop words, 3+ chars).
    private func extractKeywords(_ text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "can", "shall", "to", "of", "in", "for",
            "on", "with", "at", "by", "from", "it", "its", "this", "that", "and",
            "or", "but", "not", "what", "how", "why", "who", "which", "their",
            "they", "them", "there", "than", "then", "also", "very", "just",
            "about", "into", "over", "such", "some", "like", "now",
            // Dutch
            "de", "het", "een", "van", "op", "met", "voor", "naar",
            "zijn", "waren", "en", "maar", "niet",
            "dat", "die", "ook", "nog", "wel", "geen", "wordt"
        ]
        return Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !stopWords.contains($0) }
        )
    }

    /// Delete a fact by ID.
    func deleteFact(id: String) throws {
        try db.execute(sql: "DELETE FROM facts WHERE id = ?", params: [id])
    }

    /// Total fact count.
    func factCount() -> Int {
        let rows = (try? db.query(sql: "SELECT COUNT(*) as cnt FROM facts")) ?? []
        return Int(rows.first?["cnt"] ?? "0") ?? 0
    }

    // MARK: - Consolidation (lightweight)

    /// Periodic cleanup: dedup near-duplicates, prune stale zero-access facts.
    /// Call this in the background (e.g. on app launch or every few hours).
    func consolidate() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let startCount = factCount()
            var removed = 0

            // 1. Remove old facts (>90 days) that were never accessed and low importance
            let cutoffDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-90 * 24 * 3600))
            do {
                try db.execute(
                    sql: "DELETE FROM facts WHERE access_count = 0 AND importance <= 2 AND created_at < ?",
                    params: [cutoffDate]
                )
                let afterPrune = factCount()
                let pruned = startCount - afterPrune
                if pruned > 0 {
                    removed += pruned
                    log.info("[Memory] Pruned \(pruned) stale zero-access facts")
                }
            } catch {
                log.debug("[Memory] Prune failed: \(error.localizedDescription)")
            }

            // 2. Deduplicate: find pairs with very high word overlap (Jaccard > 0.8)
            //    Keep the one with higher importance/access_count
            do {
                let allFacts = try db.query(
                    sql: "SELECT id, content, importance, access_count FROM facts ORDER BY importance DESC, access_count DESC",
                    params: []
                )

                var seen: [(id: String, words: Set<String>)] = []
                var idsToDelete: [String] = []

                for row in allFacts {
                    guard let id = row["id"], let content = row["content"] else { continue }
                    let words = Set(content.lowercased().split(separator: " ").map(String.init))

                    // Check against already-seen facts
                    var isDup = false
                    for existing in seen {
                        let intersection = words.intersection(existing.words)
                        let union = words.union(existing.words)
                        let overlap = Double(intersection.count) / Double(max(union.count, 1))
                        if overlap > 0.8 {
                            // This is a duplicate of an earlier (higher importance) fact
                            idsToDelete.append(id)
                            isDup = true
                            break
                        }
                    }

                    if !isDup {
                        seen.append((id: id, words: words))
                    }
                }

                for id in idsToDelete {
                    try? db.execute(sql: "DELETE FROM facts WHERE id = ?", params: [id])
                }

                if !idsToDelete.isEmpty {
                    removed += idsToDelete.count
                    log.info("[Memory] Deduplicated \(idsToDelete.count) near-duplicate facts")
                }
            } catch {
                log.debug("[Memory] Dedup failed: \(error.localizedDescription)")
            }

            if removed > 0 {
                log.info("[Memory] Consolidation complete: removed \(removed) facts, \(self.factCount()) remaining")
            }
        }
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
    func searchEpisodes(query: String, limit: Int = 5) throws -> [EpisodeResult] {
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
    /// Max 5 facts + 3 episodes to keep output concise.
    func search(query: String, limit: Int = 5) throws -> String {
        var results: [String] = []

        let facts = try searchFacts(query: query, limit: limit)
        if !facts.isEmpty {
            results.append("FACTS:")
            for fact in facts {
                let stars = String(repeating: "★", count: fact.importance)
                results.append("- [\(fact.category)] \(fact.content) \(stars)")
            }
        }

        let episodes = try searchEpisodes(query: query, limit: 3)
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

// MARK: - Error Type

enum MemoryError: Error, LocalizedError {
    case poisonBlocked(String)

    var errorDescription: String? {
        switch self {
        case .poisonBlocked(let reason): return reason
        }
    }
}

// MARK: - Result Types

nonisolated struct FactResult: Sendable {
    let id: String
    let content: String
    let category: String
    let importance: Int
    let accessCount: Int
    let createdAt: String
}

nonisolated struct EpisodeResult: Sendable {
    let id: String
    let summary: String
    let timestamp: String
}
