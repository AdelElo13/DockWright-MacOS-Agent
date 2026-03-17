import Foundation
import os
import Speech
import AVFoundation

// MARK: - Free function for audio tap (must be outside @MainActor class)

/// Installs an audio tap that feeds buffers to the speech recognition request and updates
/// audio level on the main actor. Being a free function ensures the closure is NOT @MainActor-isolated,
/// preventing dispatch_assert_queue_fail on the audio thread.
private func _installVoiceAudioTap(
    on inputNode: AVAudioInputNode,
    format: AVAudioFormat,
    request: SFSpeechAudioBufferRecognitionRequest,
    stoppingLock: OSAllocatedUnfairLock<Bool>,
    speechThreshold: Float,
    silenceThreshold: Float,
    service: VoiceService
) {
    nonisolated(unsafe) let req = request

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak service] buffer, _ in
        guard !stoppingLock.withLock({ $0 }) else { return }
        req.append(buffer)

        let frames = buffer.frameLength
        guard frames > 0 else { return }
        guard let data = buffer.floatChannelData?[0] else { return }

        var sum: Float = 0
        for i in 0..<Int(frames) {
            sum += abs(data[i])
        }
        let avg = sum / Float(frames)

        let captured = service
        Task { @MainActor in
            guard let s = captured else { return }
            guard s.isListening else { return }

            if avg > speechThreshold {
                s.speechDetected = true
                s.lastSpeechTime = Date()
            } else if s.speechDetected && avg > silenceThreshold {
                s.lastSpeechTime = Date()
            }

            let now = Date()
            if now.timeIntervalSince(s.lastLevelUpdate) >= 0.1 {
                s.audioLevel = avg
                s.lastLevelUpdate = now
                s.onLevel?(avg)
            }
        }
    }
}

/// Creates a recognition task result handler outside @MainActor to avoid isolation inheritance.
private func _makeRecognitionHandler(
    service: VoiceService
) -> (SFSpeechRecognitionResult?, Error?) -> Void {
    return { [weak service] result, error in
        let transcription = result?.bestTranscription.formattedString
        let isFinal = result?.isFinal ?? false
        let errorCode = (error as? NSError)?.code
        let errorDesc = error?.localizedDescription

        let captured = service
        Task { @MainActor in
            guard let s = captured else { return }
            guard s.isListening else { return }

            if let transcription = transcription {
                s.recognizedText = s.accumulatedText + transcription
                s.sttErrorRetries = 0
                // NOTE: Do NOT call onTranscription here — it's only called from
                // finalizeRecording() after silence detection (matches Jarvis pattern).

                if isFinal {
                    let elapsed = Date().timeIntervalSince(s.recordingStartTime)
                    if elapsed < s.maxRecordingDuration && s.speechDetected {
                        s.accumulatedText = s.recognizedText + " "
                        s.restartRecognition()
                        return
                    }
                    s.finalizeRecording()
                }
            }

            if let errorCode = errorCode {
                let elapsed = Date().timeIntervalSince(s.recordingStartTime)
                log.debug("[STT] Recognition error \(errorCode): \(errorDesc ?? "unknown") elapsed=\(String(format: "%.1f", elapsed))s")

                if elapsed < s.maxRecordingDuration && s.sttErrorRetries < 3 {
                    s.sttErrorRetries += 1
                    s.accumulatedText = s.recognizedText.isEmpty ? "" : s.recognizedText + " "
                    s.restartRecognition()
                    return
                }

                if s.isListening {
                    s.finalizeRecording()
                }
            }
        }
    }
}

/// Voice input service using macOS native Speech framework (STT only).
@MainActor
@Observable
final class VoiceService: NSObject {
    static let shared = VoiceService()

    // MARK: - State
    var isListening = false
    var isRecording = false
    var recognizedText = ""
    var audioLevel: Float = 0
    var errorMessage: String?
    var voiceEnabled = false

    // MARK: - Callbacks
    var onTranscription: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFinalTranscription: ((String) -> Void)?

    // MARK: - STT Language

    static let supportedSTTLanguages: [(id: String, label: String)] = [
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("nl-NL", "Dutch (Nederlands)"),
        ("fr-FR", "French (France)"),
        ("de-DE", "German (Deutsch)"),
        ("es-ES", "Spanish (Espanol)"),
        ("it-IT", "Italian (Italiano)"),
        ("pt-BR", "Portuguese (Brazil)"),
        ("ja-JP", "Japanese"),
        ("zh-CN", "Chinese (Mandarin)"),
    ]

    /// Detect the macOS system language and map to a supported STT locale.
    static func systemLanguageDefault() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en-US"
        // Match against our supported list
        let supportedIds = Set(supportedSTTLanguages.map(\.id))
        if supportedIds.contains(preferred) { return preferred }
        // Try prefix match (e.g. "nl" → "nl-NL")
        let prefix = String(preferred.prefix(2))
        if let match = supportedSTTLanguages.first(where: { $0.id.hasPrefix(prefix) }) {
            return match.id
        }
        return "en-US"
    }

    /// Resolve the effective language: user setting or system default.
    static var effectiveLanguage: String {
        UserDefaults.standard.string(forKey: "voice.sttLanguage") ?? systemLanguageDefault()
    }

    var sttLanguage: String = UserDefaults.standard.string(forKey: "voice.sttLanguage") ?? systemLanguageDefault() {
        didSet {
            UserDefaults.standard.set(sttLanguage, forKey: "voice.sttLanguage")
            updateRecognizer()
        }
    }

    // MARK: - Private
    private var speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier:
        UserDefaults.standard.string(forKey: "voice.sttLanguage") ?? systemLanguageDefault()
    ))

    private func updateRecognizer() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: sttLanguage))
    }

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    // MARK: - Proactive STT Restart (60-second timeout prevention)

    private func scheduleSTTRestart() {
        sttRestartTimer?.invalidate()
        sttRestartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isListening else { return }
                    log.debug("[STT] Proactive restart at 50s to prevent Apple's 60s timeout")
                    self.accumulatedText = self.recognizedText.isEmpty ? "" : self.recognizedText + " "
                    self.restartRecognition()
                    self.scheduleSTTRestart()
                }
            }
        }
    }

    // MARK: - Silence Detection
    private let speechThreshold: Float = 0.018
    private let minRecordingTime: TimeInterval = 0.8
    fileprivate let maxRecordingDuration: TimeInterval = 55

    var silenceThreshold: Float {
        get { UserDefaults.standard.object(forKey: "voiceSilenceThreshold") as? Float ?? 0.013 }
        set { UserDefaults.standard.set(newValue, forKey: "voiceSilenceThreshold") }
    }
    var silenceDuration: TimeInterval {
        get { UserDefaults.standard.object(forKey: "voiceSilenceDuration") as? TimeInterval ?? 0.8 }
        set { UserDefaults.standard.set(newValue, forKey: "voiceSilenceDuration") }
    }

    fileprivate var speechDetected = false
    fileprivate var lastSpeechTime: Date = .distantPast
    fileprivate var recordingStartTime: Date = .distantPast
    private var silenceTimer: Timer?
    fileprivate var lastLevelUpdate: Date = .distantPast
    private let _isStopping = OSAllocatedUnfairLock(initialState: false)
    private var isStopping: Bool {
        get { _isStopping.withLock { $0 } }
        set { _isStopping.withLock { $0 = newValue } }
    }
    fileprivate var accumulatedText = ""
    fileprivate var sttErrorRetries = 0
    private var sttRestartTimer: Timer?
    private var finalizeWorkItem: DispatchWorkItem?
    private var isFinalizingRecording = false
    private let transcriptionFinalizeGrace: TimeInterval = 0.4

    private override init() {
        super.init()
    }

    // MARK: - Authorization

    nonisolated private static func requestMicrophoneAuthorizationIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    nonisolated private static func requestSpeechAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    @discardableResult
    private func applyAuthorizationState(microphoneGranted: Bool, speechStatus: SFSpeechRecognizerAuthorizationStatus) -> Bool {
        guard microphoneGranted else {
            voiceEnabled = false
            errorMessage = "Microphone permission denied. Enable it in System Settings > Privacy & Security > Microphone."
            return false
        }

        switch speechStatus {
        case .authorized:
            voiceEnabled = true
            errorMessage = nil
            return true
        case .denied:
            voiceEnabled = false
            errorMessage = "Speech recognition permission denied. Enable it in System Settings > Privacy & Security > Speech Recognition."
            return false
        case .restricted:
            voiceEnabled = false
            errorMessage = "Speech recognition is restricted on this device."
            return false
        case .notDetermined:
            voiceEnabled = false
            errorMessage = "Voice permissions are still pending."
            return false
        @unknown default:
            voiceEnabled = false
            errorMessage = "Voice permissions are unavailable on this device."
            return false
        }
    }

    @discardableResult
    func ensureAuthorization() async -> Bool {
        let microphoneGranted = await Self.requestMicrophoneAuthorizationIfNeeded()
        let speechStatus = await Self.requestSpeechAuthorizationIfNeeded()
        return applyAuthorizationState(microphoneGranted: microphoneGranted, speechStatus: speechStatus)
    }

    nonisolated func requestAuthorization() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.ensureAuthorization()
        }
    }

    // MARK: - Speech-to-Text (STT)

    func startListening() {
        log.debug("[STT] startListening — voiceEnabled=\(self.voiceEnabled) isListening=\(self.isListening)")
        guard voiceEnabled else {
            errorMessage = "Voice not authorized. Call requestAuthorization() first."
            return
        }
        guard !isListening else { return }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer not available."
            return
        }

        // Clean up any previous session — ALWAYS remove tap to prevent crash
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }

        recognizedText = ""
        accumulatedText = ""
        errorMessage = nil
        speechDetected = false
        sttErrorRetries = 0
        isStopping = false
        isFinalizingRecording = false
        lastSpeechTime = .distantPast
        lastLevelUpdate = .distantPast
        recordingStartTime = Date()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.channelCount > 0 && recordingFormat.sampleRate > 0 else {
            errorMessage = "Microphone not ready -- try again"
            log.warning("[STT] Invalid audio format: channels=\(recordingFormat.channelCount) rate=\(recordingFormat.sampleRate)")
            return
        }

        _installVoiceAudioTap(
            on: inputNode,
            format: recordingFormat,
            request: request,
            stoppingLock: _isStopping,
            speechThreshold: speechThreshold,
            silenceThreshold: silenceThreshold,
            service: self
        )

        recognitionRequest = request
        let handler = _makeRecognitionHandler(service: self)
        recognitionTask = recognizer.recognitionTask(with: request, resultHandler: handler)

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            isRecording = true
            startSilenceTimer()
            scheduleSTTRestart()
        } catch {
            errorMessage = "Audio engine failed: \(error.localizedDescription)"
        }
    }

    func stopListening() {
        finalizeWorkItem?.cancel()
        finalizeWorkItem = nil
        isFinalizingRecording = false
        guard !isStopping else { return }
        isStopping = true
        silenceTimer?.invalidate()
        silenceTimer = nil
        sttRestartTimer?.invalidate()
        sttRestartTimer = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
        isRecording = false
        audioLevel = 0
        speechDetected = false
        accumulatedText = ""
        onTranscription = nil
        onLevel = nil
        // NOTE: onFinalTranscription is NOT cleared here — the caller manages it.
        // Clearing it here would break the voice conversation loop where
        // finalizeRecording's grace period callback needs to fire.
        isStopping = false
    }

    // MARK: - Recognition Restart

    fileprivate func restartRecognition() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.finish()
        recognitionTask = nil

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        recognitionRequest = request

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        _installVoiceAudioTap(
            on: inputNode,
            format: recordingFormat,
            request: request,
            stoppingLock: _isStopping,
            speechThreshold: speechThreshold,
            silenceThreshold: silenceThreshold,
            service: self
        )

        recognitionTask = recognizer.recognitionTask(with: request, resultHandler: _makeRecognitionHandler(service: self))
    }

    // MARK: - Silence Detection

    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.checkSilence()
                }
            }
        }
    }

    private func checkSilence() {
        guard isListening else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(recordingStartTime)

        if elapsed >= maxRecordingDuration {
            finalizeRecording()
            return
        }

        guard elapsed >= minRecordingTime else { return }

        guard speechDetected else {
            if elapsed >= 8.0 {
                finalizeRecording()
            }
            return
        }

        if now.timeIntervalSince(lastSpeechTime) >= silenceDuration {
            finalizeRecording()
        }
    }

    fileprivate func finalizeRecording() {
        guard isListening, !isFinalizingRecording else { return }
        isFinalizingRecording = true
        finalizeWorkItem?.cancel()
        finalizeWorkItem = nil

        let callback = onTranscription ?? onFinalTranscription
        silenceTimer?.invalidate()
        silenceTimer = nil
        sttRestartTimer?.invalidate()
        sttRestartTimer = nil

        isStopping = true
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()
        isRecording = false
        audioLevel = 0
        speechDetected = false

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let finalText = self.recognizedText
            self.recognitionTask?.cancel()
            self.recognitionTask = nil
            self.recognitionRequest = nil
            self.isListening = false
            self.isRecording = false
            self.accumulatedText = ""
            self.isStopping = false
            self.isFinalizingRecording = false
            self.finalizeWorkItem = nil
            callback?(finalText)
        }
        finalizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + transcriptionFinalizeGrace, execute: workItem)
    }
}
