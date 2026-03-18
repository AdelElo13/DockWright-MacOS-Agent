import Foundation
import AppKit
import os.log

/// Central sensory state hub. Tracks screen content, browser tabs, frontmost app,
/// battery level, dark mode, and more. Provides a contextString() for LLM injection.
///
/// Thread-safe via concurrent DispatchQueue with barrier writes.
nonisolated final class WorldModel: @unchecked Sendable {
    static let shared = WorldModel()

    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "world-model")
    private let queue = DispatchQueue(label: "com.dockwright.worldmodel", attributes: .concurrent)

    // State — written behind barrier, read with queue.sync
    private var state = WorldState()

    // Ambient loop
    private var ambientLoopRunning = false
    private var lastOCRText = ""
    private var lastScreenshotHash: Int = 0

    // Services
    private let screenCapture = ScreenCaptureService.shared
    private let ocr = VisionOCRService.shared

    private init() {
        logger.info("WorldModel initialized")
    }

    // MARK: - State Reading

    /// Thread-safe snapshot of current frontmost app bundle ID.
    var frontmostAppBundleID: String {
        queue.sync { state.frontmostAppBundleID }
    }

    /// Build a compact context string for LLM system prompt injection.
    func contextString() -> String {
        let s: WorldState = queue.sync { state }
        var parts: [String] = []

        // User & machine context
        parts.append("User home: \(NSHomeDirectory())")
        parts.append("Username: \(NSUserName())")

        // Time awareness
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMM d yyyy 'at' HH:mm"
        fmt.locale = Locale(identifier: "en_US")
        parts.append("Right now: \(fmt.string(from: now))")

        // Frontmost app
        if !s.frontmostApp.isEmpty {
            parts.append("Active app: \(s.frontmostApp)")
        }

        // Open apps
        if !s.openApplications.isEmpty {
            parts.append("Open apps: \(s.openApplications.prefix(10).joined(separator: ", "))")
        }

        // Battery
        if s.batteryLevel >= 0 {
            let source = s.isOnBattery ? "battery" : "plugged in"
            parts.append("Battery: \(s.batteryLevel)% (\(source))")
        }

        // Dark mode
        parts.append("Dark mode: \(s.isDarkMode ? "on" : "off")")

        // Screen content
        if !s.screenContentSummary.isEmpty {
            let timeSince = s.lastScreenChangeTime.map { Int(now.timeIntervalSince($0)) } ?? 0
            let timeStr = timeSince > 0 ? " (\(timeSince)s ago)" : ""
            parts.append("Screen content\(timeStr): \(s.screenContentSummary)")
        }

        // Frontmost document
        if !s.frontmostDocumentHint.isEmpty {
            parts.append("Active document: \(s.frontmostDocumentHint)")
        }

        // Browser tabs
        if !s.browserTabs.isEmpty {
            let activeTab: String
            if s.activeBrowserTabIndex >= 0 && s.activeBrowserTabIndex < s.browserTabs.count {
                activeTab = s.browserTabs[s.activeBrowserTabIndex].title
            } else {
                activeTab = s.browserTabs.first?.title ?? ""
            }
            parts.append("Browser: \(activeTab) (+\(max(0, s.browserTabs.count - 1)) tabs)")
        }

        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: "\n")
    }

    // MARK: - State Updates (barrier writes)

    func updateScreenContent(summary: String) {
        queue.async(flags: .barrier) {
            self.state.screenContentSummary = String(summary.prefix(500))
            self.state.lastScreenChangeTime = Date()
        }
    }

    func updateBrowserTabs(_ tabs: [BrowserTab], activeIndex: Int) {
        queue.async(flags: .barrier) {
            self.state.browserTabs = tabs
            self.state.activeBrowserTabIndex = activeIndex
        }
    }

    func updateSystemState() {
        Task { @MainActor in
            // All AppKit calls guaranteed on main thread
            let frontApp = NSWorkspace.shared.frontmostApplication
            let frontName = frontApp?.localizedName ?? ""
            let frontBundle = frontApp?.bundleIdentifier ?? ""
            let openApps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.localizedName }
            let appearance = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            let isDark = (appearance == .darkAqua)

            self.queue.async(flags: .barrier) {
                self.state.frontmostApp = frontName
                self.state.frontmostAppBundleID = frontBundle
                self.state.openApplications = openApps
                self.state.isDarkMode = isDark

                // Battery
                self.updateBatteryInfo()

                // Time
                self.state.currentHour = Calendar.current.component(.hour, from: Date())

                // Frontmost document path detection
                self.detectFrontmostDocument()
            }
        }
    }

    /// Detect the document path of the frontmost app via Accessibility / AppleScript.
    private func detectFrontmostDocument() {
        let bundleID = state.frontmostAppBundleID
        guard !bundleID.isEmpty else { return }

        // Use AppleScript to get the frontmost document path for known apps
        let script: String?
        switch bundleID {
        case "com.apple.dt.Xcode":
            script = """
            tell application "System Events"
                tell process "Xcode"
                    set winTitle to name of front window
                end tell
            end tell
            return winTitle
            """
        case "com.apple.TextEdit":
            script = """
            tell application "TextEdit"
                if (count of documents) > 0 then
                    return path of front document
                end if
            end tell
            return ""
            """
        case "com.sublimetext.3", "com.sublimetext.4":
            script = """
            tell application "System Events"
                tell process "Sublime Text"
                    set winTitle to name of front window
                end tell
            end tell
            return winTitle
            """
        case "com.microsoft.VSCode":
            script = """
            tell application "System Events"
                tell process "Code"
                    set winTitle to name of front window
                end tell
            end tell
            return winTitle
            """
        default:
            script = nil
        }

        if let script {
            // Run in background to avoid blocking
            DispatchQueue.global(qos: .utility).async {
                var error: NSDictionary?
                guard let appleScript = NSAppleScript(source: script) else { return }
                let result = appleScript.executeAndReturnError(&error)
                if error == nil, let title = result.stringValue, !title.isEmpty {
                    self.queue.async(flags: .barrier) {
                        self.state.frontmostDocumentHint = String(title.prefix(200))
                    }
                }
            }
        }
    }

    private func updateBatteryInfo() {
        // Use IOKit via Process for battery info
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-g", "batt"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            // Parse "XX%" from pmset output
            if let range = output.range(of: #"\d+%"#, options: .regularExpression) {
                let pctStr = output[range].dropLast() // remove %
                self.state.batteryLevel = Int(pctStr) ?? -1
            }

            self.state.isOnBattery = output.contains("Battery Power")
        } catch {
            self.state.batteryLevel = -1
        }
    }

    // MARK: - Ambient Loop

    /// Start the 15-second ambient screen capture + OCR cycle.
    /// Uses Jaccard distance to detect meaningful screen changes.
    func startAmbientLoop() {
        queue.async(flags: .barrier) {
            guard !self.ambientLoopRunning else { return }
            self.ambientLoopRunning = true
            self.logger.info("Ambient loop started")
        }

        // Initial system state update
        updateSystemState()

        // Start browser tab watcher
        BrowserTabWatcher.shared.start()

        // Schedule the loop
        scheduleAmbientTick()
    }

    func stopAmbientLoop() {
        queue.async(flags: .barrier) {
            self.ambientLoopRunning = false
            self.logger.info("Ambient loop stopped")
        }
        BrowserTabWatcher.shared.stop()
    }

    private func scheduleAmbientTick() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }

            let running: Bool = self.queue.sync { self.ambientLoopRunning }
            guard running else { return }

            Task {
                await self.ambientTick()
                self.scheduleAmbientTick()
            }
        }
    }

    private var consecutiveScreenCaptureFailures = 0
    private let maxConsecutiveFailures = 5

    private func ambientTick() async {
        // Update system state (frontmost app, battery, etc.)
        updateSystemState()

        // Skip screen capture if too many consecutive failures (permission likely denied)
        guard consecutiveScreenCaptureFailures < maxConsecutiveFailures else {
            // Reset counter periodically to retry
            if consecutiveScreenCaptureFailures == maxConsecutiveFailures {
                consecutiveScreenCaptureFailures += 1 // Only log once
                logger.info("Pausing screen capture after \(self.maxConsecutiveFailures) failures. Will retry later.")
            }
            // Reset every 20 ticks (5 minutes) to retry
            if consecutiveScreenCaptureFailures > maxConsecutiveFailures + 20 {
                consecutiveScreenCaptureFailures = 0
            } else {
                consecutiveScreenCaptureFailures += 1
            }
            return
        }

        // Screen capture + OCR (skip OCR if screenshot unchanged)
        do {
            let path = try await screenCapture.captureScreen()
            defer { screenCapture.cleanup(path: path) }

            // Quick pixel hash — skip expensive OCR if screen didn't change
            // Downsample to tiny image and hash the raw pixels (ignores PNG metadata)
            let currentHash = Self.quickImageHash(path: path)
            if currentHash != 0 && currentHash == lastScreenshotHash {
                consecutiveScreenCaptureFailures = 0
                return // Screen visually identical — skip OCR entirely
            }
            lastScreenshotHash = currentHash

            let ocrText = try await ocr.recognizeText(imagePath: path)
            consecutiveScreenCaptureFailures = 0 // Reset on success

            // Jaccard distance change detection
            let changed = hasSignificantChange(old: lastOCRText, new: ocrText, threshold: 0.15)

            if changed {
                let summary = summarizeScreenContent(ocrText)
                updateScreenContent(summary: summary)
                queue.async(flags: .barrier) {
                    self.lastOCRText = ocrText
                }
                logger.debug("Screen content changed, updated summary")
            }
        } catch {
            consecutiveScreenCaptureFailures += 1
            logger.debug("Ambient capture/OCR failed (\(self.consecutiveScreenCaptureFailures)x): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Change Detection

    /// Jaccard distance between two texts (word-level).
    /// Returns true if distance > threshold (meaning content changed significantly).
    /// Fast perceptual hash: downsample screenshot to 16x16 grayscale and hash the pixels.
    /// Ignores PNG metadata, cursor blink, and minor rendering differences.
    private static func quickImageHash(path: String) -> Int {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return 0 }

        // Draw into tiny 16x16 grayscale bitmap
        let size = 16
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return 0 }

        // Hash the 256 bytes of pixel data
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var hash = 0
        for i in 0..<(size * size) {
            // Quantize to reduce noise (divide by 8 = ignore bottom 3 bits)
            hash = hash &* 31 &+ Int(pixels[i] / 8)
        }
        return hash
    }

    private func hasSignificantChange(old: String, new: String, threshold: Double) -> Bool {
        if old.isEmpty { return !new.isEmpty }
        if new.isEmpty { return true }

        let oldWords = Set(old.lowercased().split(separator: " ").map(String.init))
        let newWords = Set(new.lowercased().split(separator: " ").map(String.init))

        let intersection = oldWords.intersection(newWords).count
        let union = oldWords.union(newWords).count

        guard union > 0 else { return false }

        let similarity = Double(intersection) / Double(union)
        let distance = 1.0 - similarity

        return distance > threshold
    }

    /// Summarize OCR text to fit in context window.
    /// Takes first ~500 chars, focusing on unique content.
    private func summarizeScreenContent(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Deduplicate similar lines
        var seen = Set<String>()
        var uniqueLines: [String] = []
        for line in lines {
            let normalized = line.lowercased()
            if !seen.contains(normalized) {
                seen.insert(normalized)
                uniqueLines.append(line)
            }
        }

        // Join and truncate to 500 chars
        let joined = uniqueLines.joined(separator: " | ")
        if joined.count > 500 {
            return String(joined.prefix(497)) + "..."
        }
        return joined
    }
}

// MARK: - World State

private nonisolated struct WorldState {
    var frontmostApp: String = ""
    var frontmostAppBundleID: String = ""
    var openApplications: [String] = []
    var isDarkMode: Bool = false
    var batteryLevel: Int = -1
    var isOnBattery: Bool = false
    var currentHour: Int = Calendar.current.component(.hour, from: Date())

    // Screen awareness
    var screenContentSummary: String = ""
    var lastScreenChangeTime: Date?

    // Browser
    var browserTabs: [BrowserTab] = []
    var activeBrowserTabIndex: Int = -1

    // Frontmost document hint (for proactive context)
    var frontmostDocumentHint: String = ""
}
