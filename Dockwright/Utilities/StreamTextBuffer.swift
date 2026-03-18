import Foundation
import os

/// Throttles streaming text updates to the UI at ~30Hz.
/// For providers that send large chunks (Anthropic), enables typewriter mode
/// that drips characters out smoothly for a ChatGPT-like feel.
final class StreamTextBuffer: @unchecked Sendable {
    private let onFlush: @Sendable @MainActor (String) -> Void
    private let lock = NSLock()
    private var accumulated = ""        // All text received from API
    private var displayed = ""          // Text currently shown in UI
    private var typewriterTimer: DispatchSourceTimer?
    private let typewriterMode: Bool
    private static let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "StreamBuffer")

    /// - Parameters:
    ///   - typewriter: If true, drip characters one-by-one for smooth typing effect.
    ///                 Use for providers that send large chunks (Anthropic, Gemini).
    ///                 Set false for providers that already send small tokens (OpenAI).
    ///   - onFlush: Called on MainActor with the text to display.
    init(typewriter: Bool = false, onFlush: @escaping @Sendable @MainActor (String) -> Void) {
        self.typewriterMode = typewriter
        self.onFlush = onFlush

        if typewriter {
            startTypewriterTimer()
        }
    }

    /// Append a text delta from the API.
    func append(_ delta: String) {
        lock.lock()
        accumulated += delta
        lock.unlock()

        if !typewriterMode {
            // Direct mode: flush at 30Hz (word boundaries)
            directFlush(delta: delta)
        }
        // Typewriter mode: timer handles dripping
    }

    // MARK: - Direct Mode (30Hz throttle for OpenAI-like providers)

    private var lastFlushTime: CFAbsoluteTime = 0
    private var flushScheduled = false

    private func directFlush(delta: String) {
        lock.lock()
        let current = accumulated
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastFlushTime
        let isWordBoundary = delta.last?.isWhitespace == true || delta.last?.isNewline == true

        if (elapsed >= 0.033 || isWordBoundary) && !flushScheduled {
            flushScheduled = true
            lastFlushTime = now
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.flushScheduled = false
                self.lock.unlock()
                self.onFlush(current)
            }
        } else if !flushScheduled {
            flushScheduled = true
            let remaining = 0.033 - elapsed
            lock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let text = self.accumulated
                self.flushScheduled = false
                self.lastFlushTime = CFAbsoluteTimeGetCurrent()
                self.lock.unlock()
                self.onFlush(text)
            }
        } else {
            lock.unlock()
        }
    }

    // MARK: - Typewriter Mode (character-by-character drip)

    private func startTypewriterTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // ~60 chars/sec = fast typing speed, feels natural
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            self?.typewriterTick()
        }
        timer.resume()
        typewriterTimer = timer
    }

    private func typewriterTick() {
        lock.lock()
        let acc = accumulated
        let disp = displayed
        lock.unlock()

        guard disp.count < acc.count else { return }

        // Release 1-3 characters per tick for natural speed
        let remaining = acc.count - disp.count
        let charsToShow = remaining > 50 ? 3 : (remaining > 20 ? 2 : 1)
        let newEnd = acc.index(acc.startIndex, offsetBy: min(disp.count + charsToShow, acc.count))
        let newDisplayed = String(acc[acc.startIndex..<newEnd])

        lock.lock()
        displayed = newDisplayed
        lock.unlock()

        onFlush(newDisplayed)
    }

    /// Force immediate flush — call when stream ends. Must be called on MainActor.
    @MainActor func flush() {
        typewriterTimer?.cancel()
        typewriterTimer = nil

        lock.lock()
        let current = accumulated
        displayed = current
        flushScheduled = false
        lock.unlock()

        onFlush(current)
    }

    /// Reset for reuse.
    func reset() {
        typewriterTimer?.cancel()
        typewriterTimer = nil
        lock.lock()
        accumulated = ""
        displayed = ""
        lastFlushTime = 0
        flushScheduled = false
        lock.unlock()
    }

    deinit {
        typewriterTimer?.cancel()
    }
}
