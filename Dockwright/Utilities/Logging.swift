import os
import Foundation

let log = Logger(subsystem: "com.Aatje.Dockwright", category: "general")

nonisolated enum AppLog {
    static let llm = Logger(subsystem: "com.Aatje.Dockwright", category: "llm")
    static let tools = Logger(subsystem: "com.Aatje.Dockwright", category: "tools")
    static let ui = Logger(subsystem: "com.Aatje.Dockwright", category: "ui")
    static let storage = Logger(subsystem: "com.Aatje.Dockwright", category: "storage")
    static let security = Logger(subsystem: "com.Aatje.Dockwright", category: "security")
    static let voice = Logger(subsystem: "com.Aatje.Dockwright", category: "voice")
    static let memory = Logger(subsystem: "com.Aatje.Dockwright", category: "memory")
}

// MARK: - Retry Utility

/// Generic retry wrapper with exponential backoff.
/// Retries on any thrown error up to `maxAttempts` times.
/// Useful for network calls, flaky I/O, and transient failures.
func withRetry<T>(
    maxAttempts: Int = 3,
    delay: TimeInterval = 1.0,
    backoffMultiplier: Double = 2.0,
    operation: () async throws -> T
) async throws -> T {
    var lastError: Error?
    var currentDelay = delay

    for attempt in 1...maxAttempts {
        do {
            return try await operation()
        } catch {
            lastError = error
            if attempt < maxAttempts {
                log.warning("[Retry] Attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription). Retrying in \(String(format: "%.1f", currentDelay))s...")
                try? await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                currentDelay *= backoffMultiplier
            }
            if Task.isCancelled { throw error }
        }
    }

    throw lastError ?? CancellationError()
}
