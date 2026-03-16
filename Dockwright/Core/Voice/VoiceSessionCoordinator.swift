import Foundation

/// Ensures only one view at a time owns voice singleton callbacks.
/// When a view claims ownership, the previous owner's callbacks are automatically cleared
/// and all audio services are stopped to prevent AVAudioEngine double-tap crashes.
@MainActor
final class VoiceSessionCoordinator {
    static let shared = VoiceSessionCoordinator()

    enum Owner: Equatable {
        case mainChat
        case menuBar
        case none
    }

    private(set) var currentOwner: Owner = .none

    private init() {}

    /// Claim voice ownership. Returns false if already owned by the same owner.
    /// Automatically stops all audio services and clears previous owner's callbacks.
    @discardableResult
    func claim(_ owner: Owner) -> Bool {
        if currentOwner == owner { return false }

        // Stop all audio services and clear callbacks from previous owner
        if currentOwner != .none {
            let tts = TTSService.shared
            let voice = VoiceService.shared
            let wakeWord = WakeWordDetector.shared

            // Stop audio services FIRST (prevents double-tap crash on AVAudioEngine)
            wakeWord.stop()
            voice.stopListening()
            tts.stopSpeaking()

            // Then clear callbacks
            tts.onSpeakingComplete = nil
            voice.onTranscription = nil
            voice.onLevel = nil
            voice.onFinalTranscription = nil
            wakeWord.onWakeWord = nil
        }

        currentOwner = owner
        return true
    }

    /// Release ownership. Only the current owner can release.
    func release(_ owner: Owner) {
        if currentOwner == owner {
            // Clean up before releasing
            let tts = TTSService.shared
            let voice = VoiceService.shared
            let wakeWord = WakeWordDetector.shared

            wakeWord.stop()
            voice.stopListening()
            tts.stopSpeaking()

            tts.onSpeakingComplete = nil
            voice.onTranscription = nil
            voice.onLevel = nil
            voice.onFinalTranscription = nil
            wakeWord.onWakeWord = nil

            currentOwner = .none
        }
    }

    /// Check if a given owner currently has ownership.
    func isOwner(_ owner: Owner) -> Bool {
        currentOwner == owner
    }
}
