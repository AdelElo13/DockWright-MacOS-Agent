import Foundation

/// Tracks token usage and calculates costs per session.
final class TokenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _totalInputTokens: Int = 0
    private var _totalOutputTokens: Int = 0

    nonisolated init() {}

    var totalInputTokens: Int {
        lock.withLock { _totalInputTokens }
    }

    var totalOutputTokens: Int {
        lock.withLock { _totalOutputTokens }
    }

    func recordUsage(input: Int, output: Int) {
        lock.withLock {
            _totalInputTokens += input
            _totalOutputTokens += output
        }
    }

    func reset() {
        lock.withLock {
            _totalInputTokens = 0
            _totalOutputTokens = 0
        }
    }

    /// Calculate cost based on claude-sonnet-4-20250514 pricing.
    /// Input: $3/MTok, Output: $15/MTok
    func formattedCost() -> String {
        let (input, output) = lock.withLock { (_totalInputTokens, _totalOutputTokens) }
        let inputCost = Double(input) / 1_000_000 * 3.0
        let outputCost = Double(output) / 1_000_000 * 15.0
        let total = inputCost + outputCost

        if total < 0.01 {
            return String(format: "$%.4f", total)
        }
        return String(format: "$%.2f", total)
    }

    var formattedTokens: String {
        let (input, output) = lock.withLock { (_totalInputTokens, _totalOutputTokens) }
        return "\(formatNumber(input)) in / \(formatNumber(output)) out"
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
