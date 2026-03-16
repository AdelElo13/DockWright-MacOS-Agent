import Foundation
import Speech
import AVFoundation
import os

// MARK: - Free function for wake word audio tap

/// Installs an audio tap for wake word detection outside @MainActor to avoid isolation.
private func _installWakeWordTap(
    on inputNode: AVAudioInputNode,
    format: AVAudioFormat,
    request: SFSpeechAudioBufferRecognitionRequest
) {
    nonisolated(unsafe) let req = request
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        req.append(buffer)
    }
}

/// Creates a recognition handler for wake word detection outside @MainActor.
private func _makeWakeWordHandler(
    detector: WakeWordDetector,
    wakeWords: [String]
) -> (SFSpeechRecognitionResult?, Error?) -> Void {
    return { [weak detector] result, error in
        let transcription = result?.bestTranscription.formattedString.lowercased()
        let errorCode = (error as? NSError)?.code

        let captured = detector
        Task { @MainActor in
            guard let d = captured, d.isActive else { return }

            if let transcription = transcription {
                // Check for wake words using fuzzy matching
                for wakeWord in wakeWords {
                    if transcription.contains(wakeWord) ||
                       d.fuzzyMatch(transcription, target: wakeWord) {
                        log.info("[WakeWord] Detected: '\(wakeWord)' in '\(transcription)'")
                        d.handleWakeWordDetected()
                        return
                    }
                }
            }

            if errorCode != nil {
                // Restart on error (timeout, etc.)
                log.debug("[WakeWord] Recognition error \(errorCode ?? 0) — restarting")
                d.restartDetection()
            }
        }
    }
}

/// SFSpeechRecognizer-based wake word detector.
/// Listens for "hey dockwright", "dockwright", "hey dock" and fires a callback.
/// Auto-restarts on timeout (Apple caps recognition at ~60s).
@MainActor
@Observable
final class WakeWordDetector: NSObject {
    static let shared = WakeWordDetector()

    // MARK: - State
    private(set) var isActive = false
    var errorMessage: String?

    // MARK: - Callbacks
    var onWakeWord: (() -> Void)?

    // MARK: - Configuration
    let wakeWords: [String] = [
        "hey dockwright",
        "dockwright",
        "hey dock",
        "hey doc right",
        "dock right",
    ]

    // MARK: - Private
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var restartTimer: Timer?
    private let proactiveRestartInterval: TimeInterval = 50

    private override init() {
        super.init()
    }

    // MARK: - Start / Stop

    func start() {
        guard !isActive else { return }
        log.info("[WakeWord] Starting SFSpeechRecognizer-based detection")

        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer not available for wake word detection."
            return
        }

        startRecognition()
    }

    func stop() {
        guard isActive else { return }
        log.info("[WakeWord] Stopping detection")

        restartTimer?.invalidate()
        restartTimer = nil

        cleanupAudio()
        isActive = false
    }

    // MARK: - Internal

    fileprivate func handleWakeWordDetected() {
        // Stop detection temporarily — caller should re-start after processing
        cleanupAudio()
        isActive = false
        restartTimer?.invalidate()
        restartTimer = nil
        onWakeWord?()
    }

    fileprivate func restartDetection() {
        guard isActive else { return }
        cleanupAudio()

        // Small delay before restart to avoid rapid cycling
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.startRecognition()
            }
        }
    }

    /// Levenshtein-based fuzzy match. Returns true if distance/length ratio < 0.35.
    fileprivate func fuzzyMatch(_ input: String, target: String) -> Bool {
        let words = input.split(separator: " ").map(String.init)
        let targetWords = target.split(separator: " ").map(String.init)
        let targetLen = targetWords.count

        // Sliding window over input words
        guard words.count >= targetLen else {
            return levenshteinRatio(input, target) < 0.35
        }

        for start in 0...(words.count - targetLen) {
            let window = words[start..<start + targetLen].joined(separator: " ")
            if levenshteinRatio(window, target) < 0.35 {
                return true
            }
        }

        return false
    }

    private func levenshteinRatio(_ s1: String, _ s2: String) -> Double {
        let dist = levenshteinDistance(Array(s1), Array(s2))
        let maxLen = max(s1.count, s2.count)
        guard maxLen > 0 else { return 0 }
        return Double(dist) / Double(maxLen)
    }

    private func levenshteinDistance(_ s1: [Character], _ s2: [Character]) -> Int {
        let m = s1.count
        let n = s2.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                if s1[i - 1] == s2[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
                }
            }
        }

        return dp[m][n]
    }

    // MARK: - Audio Management

    private func startRecognition() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.channelCount > 0 && format.sampleRate > 0 else {
            errorMessage = "Microphone not ready for wake word detection."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search

        _installWakeWordTap(on: inputNode, format: format, request: request)

        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(
            with: request,
            resultHandler: _makeWakeWordHandler(detector: self, wakeWords: wakeWords)
        )

        do {
            engine.prepare()
            try engine.start()
            audioEngine = engine
            isActive = true

            // Schedule proactive restart at 50s
            scheduleRestart()
        } catch {
            errorMessage = "Wake word audio engine failed: \(error.localizedDescription)"
            log.error("[WakeWord] Audio engine failed: \(error.localizedDescription)")
        }
    }

    private func scheduleRestart() {
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: proactiveRestartInterval, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    log.debug("[WakeWord] Proactive restart at 50s")
                    self.restartDetection()
                }
            }
        }
    }

    private func cleanupAudio() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }
}
