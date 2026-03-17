import Foundation
import os

/// Prevents poisoned, fabricated, or injection-style facts from being saved to memory.
///
/// Checks for:
/// - Prompt injection patterns ("always remember", "your instructions are", "from now on")
/// - Secrets and credentials (API keys, tokens, passwords)
/// - Instruction-like patterns that try to modify assistant behavior
/// - Nonsensical or too-generic facts
nonisolated final class MemoryPoisonGuard: @unchecked Sendable {
    static let shared = MemoryPoisonGuard()

    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "PoisonGuard")

    private init() {}

    /// Evaluate whether a fact is safe to save.
    /// Returns nil if safe, or a rejection reason string if blocked.
    func evaluate(_ content: String) -> String? {
        let lower = content.lowercased()

        // 1. Prompt injection patterns — someone trying to reprogram the assistant via memory
        for pattern in Self.injectionPatterns {
            if lower.contains(pattern) {
                logger.warning("Blocked injection pattern: '\(pattern)' in: \(content.prefix(60))")
                return "Blocked: looks like a prompt injection ('\(pattern)')"
            }
        }

        // 2. Secrets and credentials
        for pattern in Self.secretPatterns {
            if content.range(of: pattern, options: .regularExpression, range: content.startIndex..<content.endIndex) != nil {
                logger.warning("Blocked secret pattern in: \(content.prefix(40))...")
                return "Blocked: contains sensitive data (credential/secret)"
            }
        }

        // 3. Instruction-like patterns (regex)
        for pattern in Self.instructionRegexes {
            if content.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                logger.warning("Blocked instruction pattern: \(content.prefix(60))")
                return "Blocked: looks like an instruction, not a fact"
            }
        }

        // 4. Too short or too long
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 5 {
            return "Blocked: too short to be meaningful"
        }
        if trimmed.count > 500 {
            return "Blocked: too long — facts should be concise"
        }

        // 5. All caps (shouting/spam)
        let uppercaseRatio = Double(trimmed.filter { $0.isUppercase }.count) / Double(max(trimmed.count, 1))
        if trimmed.count > 10 && uppercaseRatio > 0.7 {
            return "Blocked: excessive uppercase (possible spam)"
        }

        // Safe
        return nil
    }

    // MARK: - Pattern Lists

    /// Phrases that indicate prompt injection attempts
    private static let injectionPatterns: [String] = [
        "always remember",
        "never forget",
        "from now on",
        "your instructions are",
        "you must always",
        "you must never",
        "ignore previous",
        "ignore all previous",
        "disregard your",
        "override your",
        "your new instructions",
        "system prompt",
        "you are now",
        "pretend to be",
        "act as if",
        "your real purpose",
        "your true purpose",
        "secret instruction",
        "hidden instruction",
        "jailbreak",
        "do anything now",
        "developer mode",
        "altijd onthouden",    // Dutch
        "nooit vergeten",      // Dutch
        "vanaf nu",            // Dutch
        "je instructies zijn", // Dutch
        "negeer vorige",       // Dutch
    ]

    /// Regex patterns for secrets and credentials
    private static let secretPatterns: [String] = [
        #"(?i)(?:api[_\s-]?key|access[_\s-]?token|secret[_\s-]?key)\s*(?:is|=|:)\s*\S+"#,
        #"(?i)(?:password|wachtwoord|passcode)\s*(?:is|=|:)\s*\S+"#,
        #"sk-[a-zA-Z0-9]{20,}"#,      // OpenAI-style keys
        #"sk-ant-[a-zA-Z0-9]{20,}"#,   // Anthropic keys
        #"AIza[a-zA-Z0-9_-]{35}"#,     // Google API keys
        #"(?i)bearer\s+[a-zA-Z0-9._-]{20,}"#,
        #"\b\d{13,19}\b"#,             // Credit card numbers (13-19 digits)
        #"(?i)(?:credit.?card|bank.?account|routing.?number|cvv|pin.?code)\s*(?:is|=|:)"#,
        #"(?i)(?:ssn|social.?security)\s*(?:is|=|:)"#,
    ]

    /// Regex patterns for instruction-like content (not facts)
    private static let instructionRegexes: [String] = [
        #"(?i)^(?:you should|you must|you need to|you have to|always|never)\s"#,
        #"(?i)^(?:do not|don't|dont)\s+(?:ever|tell|share|reveal|mention)"#,
        #"(?i)^(?:when asked|if someone|if anyone|if they)\s"#,
        #"(?i)(?:respond with|reply with|answer with|say that)\s"#,
    ]
}
