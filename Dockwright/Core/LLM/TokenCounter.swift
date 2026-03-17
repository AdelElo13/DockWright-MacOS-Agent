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

    var totalTokens: Int {
        lock.withLock { _totalInputTokens + _totalOutputTokens }
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
    /// Displays in local currency based on system locale.
    func formattedCost() -> String {
        let (input, output) = lock.withLock { (_totalInputTokens, _totalOutputTokens) }
        let inputCost = Double(input) / 1_000_000 * 3.0
        let outputCost = Double(output) / 1_000_000 * 15.0
        let totalUSD = inputCost + outputCost

        let (symbol, rate) = Self.localCurrency
        let total = totalUSD * rate

        if total < 0.01 {
            return String(format: "\(symbol)%.4f", total)
        }
        return String(format: "\(symbol)%.2f", total)
    }

    /// Returns (symbol, rateFromUSD) based on system locale currency.
    private static var localCurrency: (String, Double) {
        let code = Locale.current.currency?.identifier ?? "USD"
        switch code {
        case "EUR": return ("€", 0.92)
        case "GBP": return ("£", 0.79)
        case "JPY": return ("¥", 150.0)
        case "CNY": return ("¥", 7.25)
        case "CHF": return ("CHF ", 0.88)
        case "CAD": return ("CA$", 1.36)
        case "AUD": return ("A$", 1.53)
        case "BRL": return ("R$", 4.95)
        case "KRW": return ("₩", 1320.0)
        case "INR": return ("₹", 83.0)
        case "SEK": return ("kr ", 10.5)
        case "NOK": return ("kr ", 10.7)
        case "DKK": return ("kr ", 6.9)
        case "PLN": return ("zł ", 4.0)
        case "MXN": return ("MX$", 17.2)
        default:    return ("$", 1.0)
        }
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
