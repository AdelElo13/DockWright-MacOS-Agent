import Foundation
@preconcurrency import Vision
import AppKit
/// In-process OCR using Apple Vision framework.
/// Extracts text from screenshot images for screen awareness.
nonisolated final class VisionOCRService: @unchecked Sendable {
    static let shared = VisionOCRService()

    private init() {}

    // MARK: - Public API

    /// Recognize text from an image file at the given path.
    /// Returns the full extracted text joined by newlines.
    func recognizeText(imagePath: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw OCRError.imageLoadFailed("File not found: \(imagePath)")
        }

        // Check file size -- skip empty/corrupt files
        let attrs = try? FileManager.default.attributesOfItem(atPath: imagePath)
        let fileSize = attrs?[.size] as? UInt64 ?? 0
        guard fileSize > 100 else {
            throw OCRError.imageLoadFailed("Image file too small or empty (\(fileSize) bytes)")
        }

        guard let nsImage = NSImage(contentsOfFile: imagePath),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.imageLoadFailed("Cannot decode image: \(imagePath)")
        }

        // Validate image dimensions
        guard cgImage.width > 0 && cgImage.height > 0 else {
            throw OCRError.imageLoadFailed("Image has zero dimensions")
        }

        return try await recognizeText(cgImage: cgImage)
    }

    /// Recognize text from a CGImage.
    func recognizeText(cgImage: CGImage) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, error in
                    if let error = error {
                        continuation.resume(throwing: OCRError.recognitionFailed(error.localizedDescription))
                        return
                    }

                    guard let observations = request.results as? [VNRecognizedTextObservation] else {
                        continuation.resume(returning: "")
                        return
                    }

                    let lines = observations.compactMap { observation -> String? in
                        observation.topCandidates(1).first?.string
                    }

                    let fullText = lines.joined(separator: "\n")
                    continuation.resume(returning: fullText)
                }

                // Configure for accuracy
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: OCRError.requestFailed(error.localizedDescription))
                }
            }
        }
    }
}

// MARK: - Errors

enum OCRError: LocalizedError {
    case imageLoadFailed(String)
    case recognitionFailed(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed(let path):
            return "Failed to load image: \(path)"
        case .recognitionFailed(let msg):
            return "OCR recognition failed: \(msg)"
        case .requestFailed(let msg):
            return "OCR request failed: \(msg)"
        }
    }
}
