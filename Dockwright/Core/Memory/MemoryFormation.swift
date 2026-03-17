import Foundation
import os

/// Automatically extracts facts from conversations and saves them to MemoryStore.
///
/// Runs after each completed conversation turn (when the LLM finishes responding).
/// Uses regex-based extraction for speed — no extra LLM call needed.
/// Extracted facts are deduplicated against existing memory.
nonisolated final class MemoryFormation: @unchecked Sendable {
    private let store: MemoryStore
    private let queue = DispatchQueue(label: "com.dockwright.memoryformation")

    /// Patterns that indicate a user preference or personal fact.
    private static let preferencePatterns: [(pattern: String, category: String)] = [
        // "I like/love/prefer/hate/want..."
        (#"(?i)\b(?:i|ik)\s+(?:like|love|prefer|hate|dislike|enjoy|want|need|use|always|never|usually)\s+(.{3,80})"#, "preference"),
        // "My name is / I'm called / I am..."
        (#"(?i)\b(?:my name is|i'?m called|i am|ik heet|ik ben|mijn naam is)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)"#, "fact"),
        // "I work at / I'm a / My job is..."
        (#"(?i)\b(?:i work (?:at|for)|i'?m a|my (?:job|role|title) is|ik werk bij|ik ben een)\s+(.{3,60})"#, "fact"),
        // "I live in / I'm from / My home is..."
        (#"(?i)\b(?:i live in|i'?m from|my home is|ik woon in|ik kom uit)\s+(.{3,40})"#, "fact"),
        // "Remember that / Don't forget / Always..."
        (#"(?i)\b(?:remember (?:that|this)|don'?t forget|always remember|onthoud|vergeet niet)\s+(.{5,120})"#, "context"),
        // "My favorite / My go-to..."
        (#"(?i)\b(?:my (?:fav(?:ou?rite)?|go-?to))\s+(.{3,60})"#, "preference"),
        // Email/phone: "my email is / my number is..."
        (#"(?i)\b(?:my (?:email|e-mail|mail|phone|nummer|telefoon) (?:is|address))\s+(\S+)"#, "fact"),
        // Dutch preferences
        (#"(?i)\b(?:ik (?:hou|houd) van|ik vind .{1,10} (?:leuk|lekker|mooi|fijn))\s+(.{3,60})"#, "preference"),
    ]

    /// Things we should NOT memorize (security/privacy).
    private static let blockPatterns: [String] = [
        #"(?i)(?:password|wachtwoord|api.?key|token|secret|credential|ssn|social.?security)"#,
        #"(?i)(?:credit.?card|bank.?account|routing.?number|cvv|pin.?code)"#,
    ]

    init(store: MemoryStore) {
        self.store = store
    }

    // MARK: - Extract from a conversation turn

    /// Process user messages from a conversation and extract facts.
    /// Call this after each completed LLM turn.
    func processMessages(_ messages: [ChatMessage]) {
        queue.async { [self] in
            let userMessages = messages
                .filter { $0.role == .user }
                .map { $0.content }

            var extracted: [(content: String, category: String)] = []

            for text in userMessages {
                // Skip short messages (unlikely to contain facts)
                guard text.count > 10 else { continue }

                // Check block patterns first
                let isBlocked = Self.blockPatterns.contains { pattern in
                    text.range(of: pattern, options: .regularExpression) != nil
                }
                if isBlocked { continue }

                // Try each extraction pattern
                for (pattern, category) in Self.preferencePatterns {
                    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
                    let range = NSRange(text.startIndex..., in: text)
                    let matches = regex.matches(in: text, range: range)

                    for match in matches {
                        // Get the full match for context
                        if let fullRange = Range(match.range, in: text) {
                            let fact = String(text[fullRange])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))

                            // Skip if too short or too long
                            guard fact.count >= 5, fact.count <= 200 else { continue }

                            extracted.append((content: fact, category: category))
                        }
                    }
                }
            }

            // Deduplicate against existing memory and save
            for (content, category) in extracted {
                saveDeduplicated(content: content, category: category)
            }

            if !extracted.isEmpty {
                log.info("[MemoryFormation] Extracted \(extracted.count) fact(s) from conversation")
            }
        }
    }

    /// Process only the last user message (more efficient for per-turn extraction).
    func processLastUserMessage(in messages: [ChatMessage]) {
        // Find the last user message
        guard let lastUser = messages.last(where: { $0.role == .user }) else { return }

        queue.async { [self] in
            let text = lastUser.content
            guard text.count > 10 else { return }

            // Block sensitive content
            let isBlocked = Self.blockPatterns.contains { pattern in
                text.range(of: pattern, options: .regularExpression) != nil
            }
            if isBlocked { return }

            var extracted: [(content: String, category: String)] = []

            for (pattern, category) in Self.preferencePatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                let matches = regex.matches(in: text, range: range)

                for match in matches {
                    if let fullRange = Range(match.range, in: text) {
                        let fact = String(text[fullRange])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))

                        guard fact.count >= 5, fact.count <= 200 else { continue }
                        extracted.append((content: fact, category: category))
                    }
                }
            }

            for (content, category) in extracted {
                saveDeduplicated(content: content, category: category)
            }

            if !extracted.isEmpty {
                log.info("[MemoryFormation] Auto-extracted \(extracted.count) fact(s)")
            }
        }
    }

    // MARK: - Deduplication

    /// Save a fact only if nothing similar already exists.
    private func saveDeduplicated(content: String, category: String) {
        do {
            // Search for similar existing facts
            let searchTerms = content.split(separator: Character(" "))
                .filter { $0.count > 3 }
                .prefix(3)
                .map(String.init)
                .joined(separator: " ")

            guard !searchTerms.isEmpty else { return }

            let existing = try store.searchFacts(query: searchTerms, limit: 5)

            // Check for duplicates using simple word overlap (Jaccard-like)
            let newWords = Set(content.lowercased().split(separator: " ").map(String.init))
            for fact in existing {
                let existingWords = Set(fact.content.lowercased().split(separator: " ").map(String.init))
                let intersection = newWords.intersection(existingWords)
                let union = newWords.union(existingWords)
                let overlap = Double(intersection.count) / Double(max(union.count, 1))

                if overlap > 0.6 {
                    // Too similar — skip
                    log.debug("[MemoryFormation] Skipped duplicate: \(content.prefix(50))...")
                    return
                }
            }

            // Not a duplicate — save it
            try store.saveFact(content: content, category: category)
            log.info("[MemoryFormation] Saved: [\(category)] \(content.prefix(60))...")
        } catch {
            log.error("[MemoryFormation] Save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Conversation Summary (for episode memory)

    /// Create a brief episode summary from a completed conversation.
    func summarizeConversation(_ messages: [ChatMessage]) {
        queue.async { [self] in
            let userMsgs = messages.filter { $0.role == .user }.map { $0.content }

            guard !userMsgs.isEmpty else { return }

            // Simple summary: topic from first message + count
            let topic = String(userMsgs.first!.prefix(100))
            let turns = userMsgs.count
            let toolsUsed = Set(messages.flatMap { $0.toolOutputs.map { $0.toolName } })
            let toolList = toolsUsed.isEmpty ? "" : " Tools: \(toolsUsed.joined(separator: ", "))."

            let summary = "User asked about: \(topic) (\(turns) turns).\(toolList)"

            do {
                try store.saveEpisode(summary: summary)
                log.debug("[MemoryFormation] Saved episode: \(summary.prefix(80))...")
            } catch {
                log.error("[MemoryFormation] Episode save failed: \(error.localizedDescription)")
            }
        }
    }
}
