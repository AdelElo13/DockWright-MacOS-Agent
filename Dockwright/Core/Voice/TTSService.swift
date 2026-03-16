import Foundation
import AVFoundation
import os

/// System text-to-speech using AVSpeechSynthesizer.
/// Supports streaming: buffers text and speaks on sentence boundaries (. ! ?).
@MainActor
@Observable
final class TTSService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSService()

    // MARK: - State
    var isSpeaking = false
    var isPaused = false

    // MARK: - Callbacks
    var onSpeakingComplete: (() -> Void)?

    // MARK: - Configuration
    var rate: Float = 0.52
    var pitch: Float = 1.0
    var volume: Float = 1.0

    // MARK: - Private
    private let synthesizer = AVSpeechSynthesizer()
    private var sentenceBuffer = ""
    private var pendingSentences: [String] = []
    private var isProcessingQueue = false

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    /// Speak a complete text. Splits into sentences and speaks sequentially.
    func speak(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        stopSpeaking()

        let sentences = splitIntoSentences(text)
        pendingSentences = sentences
        isSpeaking = true
        isPaused = false

        speakNextSentence()
    }

    /// Feed streaming text chunk. Buffers until sentence boundary, then speaks.
    func feedStreamingChunk(_ chunk: String) {
        sentenceBuffer += chunk

        // Check for sentence boundaries
        while let range = sentenceBuffer.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?\n")) {
            let endIndex = sentenceBuffer.index(after: range.lowerBound)
            let sentence = String(sentenceBuffer[sentenceBuffer.startIndex..<endIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sentenceBuffer = String(sentenceBuffer[endIndex...])

            if !sentence.isEmpty {
                pendingSentences.append(sentence)
                if !isProcessingQueue {
                    isSpeaking = true
                    speakNextSentence()
                }
            }
        }
    }

    /// Flush any remaining buffered text (call when streaming ends).
    func flushBuffer() {
        let remaining = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        sentenceBuffer = ""

        if !remaining.isEmpty {
            pendingSentences.append(remaining)
            if !isProcessingQueue {
                isSpeaking = true
                speakNextSentence()
            }
        }
    }

    /// Stop all speech immediately.
    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        pendingSentences.removeAll()
        sentenceBuffer = ""
        isSpeaking = false
        isPaused = false
        isProcessingQueue = false
    }

    /// Pause current speech.
    func pauseSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
            isPaused = true
        }
    }

    /// Resume paused speech.
    func resumeSpeaking() {
        if isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
        }
    }

    // MARK: - Private

    private func speakNextSentence() {
        guard !pendingSentences.isEmpty else {
            isProcessingQueue = false
            isSpeaking = false
            onSpeakingComplete?()
            return
        }

        isProcessingQueue = true
        let sentence = pendingSentences.removeFirst()

        let utterance = AVSpeechUtterance(string: sentence)
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        utterance.volume = volume
        utterance.preUtteranceDelay = 0.0
        utterance.postUtteranceDelay = 0.05

        // Use a high-quality voice if available
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }

        synthesizer.speak(utterance)
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        for char in text {
            current.append(char)
            if char == "." || char == "!" || char == "?" || char == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                current = ""
            }
        }

        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            sentences.append(remaining)
        }

        return sentences
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.speakNextSentence()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.pendingSentences.isEmpty {
                self.isSpeaking = false
                self.isProcessingQueue = false
            }
        }
    }
}
