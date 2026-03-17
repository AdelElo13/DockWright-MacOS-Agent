import Foundation
import AVFoundation
import os

/// TTS with selectable providers: macOS system or ElevenLabs.
/// Supports streaming: buffers text and speaks on sentence boundaries (. ! ?).
@MainActor
@Observable
final class TTSService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSService()

    // MARK: - Provider

    enum TTSProvider: String, CaseIterable, Identifiable {
        case system = "macOS TTS"
        case elevenLabs = "ElevenLabs"
        var id: String { rawValue }
    }

    var provider: TTSProvider = {
        TTSProvider(rawValue: UserDefaults.standard.string(forKey: "tts.provider") ?? "macOS TTS") ?? .system
    }() {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "tts.provider") }
    }

    // MARK: - ElevenLabs

    var elevenLabsVoiceId: String = UserDefaults.standard.string(forKey: "tts.elevenLabsVoice") ?? "21m00Tcm4TlvDq8ikWAM" {
        didSet { UserDefaults.standard.set(elevenLabsVoiceId, forKey: "tts.elevenLabsVoice") }
    }

    var elevenLabsVoices: [(id: String, label: String)] = []
    var isLoadingVoices = false

    // MARK: - System TTS Voice

    var systemVoiceId: String = UserDefaults.standard.string(forKey: "tts.systemVoice") ?? "" {
        didSet { UserDefaults.standard.set(systemVoiceId, forKey: "tts.systemVoice") }
    }

    /// Novelty/joke voices to hide from the picker.
    private static let noveltyVoices: Set<String> = [
        "Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos",
        "Good News", "Jester", "Organ", "Superstar", "Trinoids", "Whisper",
        "Wobble", "Zarvox"
    ]

    /// Available system voices for a given language, filtered and sorted by quality.
    static func systemVoices(for language: String) -> [(id: String, label: String)] {
        let langPrefix = String(language.prefix(2)) // "nl" from "nl-NL"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(langPrefix) && !noveltyVoices.contains($0.name) }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                return lhs.name < rhs.name
            }
            .map { v in
                // Strip existing quality suffix from name (e.g. "Xander (Enhanced)" → "Xander")
                let baseName = v.name.replacingOccurrences(of: " \\(Enhanced\\)", with: "", options: .regularExpression)
                    .replacingOccurrences(of: " \\(Premium\\)", with: "", options: .regularExpression)
                let q = v.quality == .enhanced ? " (Enhanced)" : v.quality == .premium ? " (Premium)" : ""
                return (id: v.identifier, label: "\(baseName)\(q)")
            }
    }

    func fetchElevenLabsVoices() {
        guard let apiKey = KeychainHelper.read(key: "elevenlabs_api_key"), !apiKey.isEmpty else { return }
        guard !isLoadingVoices else { return }
        isLoadingVoices = true

        Task {
            defer { Task { @MainActor in self.isLoadingVoices = false } }
            guard let url = URL(string: "https://api.elevenlabs.io/v1/voices") else { return }
            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            request.timeoutInterval = 10

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let voices = json["voices"] as? [[String: Any]] else { return }

            let parsed: [(id: String, label: String)] = voices.compactMap { v in
                guard let id = v["voice_id"] as? String, let name = v["name"] as? String else { return nil }
                let category = v["category"] as? String ?? ""
                // On free plan, only "premade" and "cloned" voices work via API
                // "professional", "famous", and library voices return 402
                let suffix = category == "premade" ? "" : category == "cloned" ? " (cloned)" : " (paid)"
                return (id: id, label: "\(name)\(suffix)")
            }.sorted { $0.label < $1.label }

            await MainActor.run {
                self.elevenLabsVoices = parsed
                if !parsed.contains(where: { $0.id == self.elevenLabsVoiceId }),
                   let first = parsed.first { self.elevenLabsVoiceId = first.id }
            }
        }
    }

    // MARK: - State
    var isSpeaking = false
    var isPaused = false

    // MARK: - Callbacks
    var onSpeakingComplete: (() -> Void)?
    var lastError: String?

    // MARK: - Configuration
    var rate: Float = 0.52
    var pitch: Float = 1.0
    var volume: Float = 1.0

    // MARK: - Private
    private let synthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
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

        switch provider {
        case .elevenLabs:
            speakWithElevenLabs(sentence)
        case .system:
            speakWithSystem(sentence)
        }
    }

    private func speakWithSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        utterance.volume = volume
        utterance.preUtteranceDelay = 0.0
        utterance.postUtteranceDelay = 0.05

        // Use selected system voice, or fall back to STT language
        if !systemVoiceId.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: systemVoiceId) {
            utterance.voice = voice
        } else {
            let lang = UserDefaults.standard.string(forKey: "voice.sttLanguage") ?? "en-US"
            if let voice = AVSpeechSynthesisVoice(language: lang) {
                utterance.voice = voice
            }
        }

        synthesizer.speak(utterance)
    }

    private func speakWithElevenLabs(_ text: String) {
        guard let apiKey = KeychainHelper.read(key: "elevenlabs_api_key"), !apiKey.isEmpty else {
            log.warning("[TTS] No ElevenLabs API key — falling back to system TTS")
            speakWithSystem(text)
            return
        }

        let voiceId = elevenLabsVoiceId
        log.info("[TTS] ElevenLabs: voiceId=\(voiceId), text=\(text.prefix(40))")
        Task {
            do {
                guard let encoded = voiceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(encoded)") else {
                    log.error("[TTS] ElevenLabs: bad URL for voiceId=\(voiceId)")
                    await MainActor.run { self.speakWithSystem(text) }
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 15

                let body: [String: Any] = [
                    "text": text,
                    "model_id": "eleven_multilingual_v2",
                    "voice_settings": ["stability": 0.5, "similarity_boost": 0.75]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let http = response as? HTTPURLResponse
                    let bodyStr = String(data: data, encoding: .utf8) ?? "n/a"
                    log.error("[TTS] ElevenLabs API error: status=\(http?.statusCode ?? -1) body=\(bodyStr.prefix(200))")
                    // Parse error message for UI
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let detail = json["detail"] as? [String: Any],
                       let msg = detail["message"] as? String {
                        await MainActor.run { self.lastError = msg }
                    } else {
                        await MainActor.run { self.lastError = "ElevenLabs error (HTTP \(http?.statusCode ?? -1))" }
                    }
                    await MainActor.run { self.speakWithSystem(text) }
                    return
                }

                log.info("[TTS] ElevenLabs: got \(data.count) bytes audio")

                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dw_tts_\(UUID().uuidString).mp3")
                try data.write(to: tempURL)

                let audioFile = try AVAudioFile(forReading: tempURL)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: audioFile.processingFormat,
                    frameCapacity: AVAudioFrameCount(audioFile.length)
                ) else {
                    log.error("[TTS] ElevenLabs: failed to create PCM buffer")
                    try? FileManager.default.removeItem(at: tempURL)
                    await MainActor.run { self.speakWithSystem(text) }
                    return
                }
                try audioFile.read(into: buffer)
                try? FileManager.default.removeItem(at: tempURL)

                await MainActor.run {
                    self.playElevenLabsBuffer(buffer, format: audioFile.processingFormat)
                }
            } catch {
                log.error("[TTS] ElevenLabs exception: \(error.localizedDescription)")
                await MainActor.run { self.speakWithSystem(text) }
            }
        }
    }

    private func playElevenLabsBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        if !audioEngine.isRunning {
            if !audioEngine.attachedNodes.contains(playerNode) {
                audioEngine.attach(playerNode)
            }
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
            try? audioEngine.start()
        }

        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                self?.speakNextSentence()
            }
        }
        playerNode.play()
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
