import Foundation
import AppKit
import os.log

/// Screen capture service using screencapture CLI via posix_spawn.
/// On macOS 15+ uses responsibility disclaim to avoid TCC issues.
nonisolated final class ScreenCaptureService: @unchecked Sendable {
    static let shared = ScreenCaptureService()

    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "screen-capture")

    private init() {}

    // MARK: - Public API

    /// Capture the full screen to a temp PNG. Returns the file path.
    func captureScreen() async throws -> String {
        let path = generateTempPath()

        if #available(macOS 15.0, *) {
            do {
                try await captureWithDisclaimedCLI(outputPath: path)
                return path
            } catch {
                logger.warning("Disclaimed CLI failed: \(error.localizedDescription, privacy: .public). Trying standard CLI.")
                try await captureWithStandardCLI(outputPath: path)
                return path
            }
        } else {
            try await captureWithStandardCLI(outputPath: path)
            return path
        }
    }

    /// Delete a screenshot file after OCR is done.
    func cleanup(path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Disclaimed CLI (macOS 15+)

    /// Spawn screencapture via posix_spawn with POSIX_SPAWN_RESPONSIBLE_FLAG
    /// to break the TCC "responsible process" chain.
    private func captureWithDisclaimedCLI(outputPath: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var attrs: posix_spawnattr_t? = nil
                posix_spawnattr_init(&attrs)

                // Set responsible flag (0x800) so screencapture uses its own TCC grant
                let POSIX_SPAWN_RESPONSIBLE_FLAG: Int32 = 0x800
                var flags: Int16 = 0
                posix_spawnattr_getflags(&attrs, &flags)
                posix_spawnattr_setflags(&attrs, flags | Int16(POSIX_SPAWN_RESPONSIBLE_FLAG))

                let execPath = "/usr/sbin/screencapture"
                let argv: [UnsafeMutablePointer<CChar>?] = [
                    strdup(execPath),
                    strdup("-x"),       // silent
                    strdup("-t"),       // type
                    strdup("png"),      // PNG format
                    strdup(outputPath),
                    nil
                ]
                defer { argv.forEach { free($0) } }

                var pid: pid_t = 0
                let spawnResult = posix_spawn(&pid, execPath, nil, &attrs, argv, environ)
                posix_spawnattr_destroy(&attrs)

                guard spawnResult == 0 else {
                    continuation.resume(throwing: ScreenCaptureError.captureFailed(Int(spawnResult)))
                    return
                }

                // Wait with timeout (max 10s)
                var status: Int32 = 0
                let deadline = DispatchTime.now() + .seconds(10)
                var exited = false
                while DispatchTime.now() < deadline {
                    let wr = waitpid(pid, &status, WNOHANG)
                    if wr > 0 { exited = true; break }
                    if wr < 0 { exited = true; break }
                    usleep(50_000)
                }
                if !exited {
                    kill(pid, SIGTERM)
                    usleep(200_000)
                    kill(pid, SIGKILL)
                    waitpid(pid, &status, 0)
                    continuation.resume(throwing: ScreenCaptureError.timeout)
                    return
                }

                let exitCode = (status >> 8) & 0xFF
                guard exitCode == 0 else {
                    continuation.resume(throwing: ScreenCaptureError.captureFailed(Int(exitCode)))
                    return
                }

                guard FileManager.default.fileExists(atPath: outputPath) else {
                    continuation.resume(throwing: ScreenCaptureError.noFileCreated)
                    return
                }

                self.logger.info("Captured screen via disclaimed CLI")
                continuation.resume(returning: ())
            }
        }
    }

    // MARK: - Standard CLI Fallback

    private func captureWithStandardCLI(outputPath: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                proc.arguments = ["-x", "-t", "png", outputPath]

                do {
                    try proc.run()

                    let sem = DispatchSemaphore(value: 0)
                    proc.terminationHandler = { _ in sem.signal() }
                    if sem.wait(timeout: .now() + 10) == .timedOut {
                        if proc.isRunning { proc.terminate() }
                        continuation.resume(throwing: ScreenCaptureError.timeout)
                        return
                    }

                    guard proc.terminationStatus == 0 else {
                        continuation.resume(throwing: ScreenCaptureError.captureFailed(Int(proc.terminationStatus)))
                        return
                    }

                    guard FileManager.default.fileExists(atPath: outputPath) else {
                        continuation.resume(throwing: ScreenCaptureError.noFileCreated)
                        return
                    }

                    self.logger.info("Captured screen via standard CLI")
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: ScreenCaptureError.captureFailed(1))
                }
            }
        }
    }

    // MARK: - Helpers

    private func generateTempPath() -> String {
        let tempDir = NSTemporaryDirectory()
        let filename = "dockwright_screen_\(Int(Date().timeIntervalSince1970)).png"
        return (tempDir as NSString).appendingPathComponent(filename)
    }
}

// MARK: - Errors

enum ScreenCaptureError: LocalizedError {
    case captureFailed(Int)
    case timeout
    case noFileCreated
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .captureFailed(let code):
            if code == 1 {
                return "Screen capture permission denied. Grant access in System Settings > Privacy & Security > Screen & System Audio Recording."
            }
            return "Screen capture failed with exit code \(code)."
        case .timeout:
            return "Screen capture timed out after 10 seconds."
        case .noFileCreated:
            return "Screen capture completed but no file was created. Screen capture permission may be needed."
        case .permissionDenied:
            return "Screen capture permission denied. Grant access in System Settings > Privacy & Security > Screen & System Audio Recording."
        }
    }
}
