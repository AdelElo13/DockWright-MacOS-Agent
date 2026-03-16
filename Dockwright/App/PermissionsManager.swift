import Foundation
import AVFoundation
import EventKit
import Speech
import UserNotifications
import AppKit

// MARK: - Permission Types

enum PermissionType: String, CaseIterable {
    case accessibility
    case microphone
    case speechRecognition
    case calendar
    case reminders
    case fullDiskAccess
    case notifications
}

enum PermissionState: String {
    case granted
    case denied
    case notDetermined
}

// MARK: - Permissions Manager

/// Central permissions manager — checks and requests all permissions automatically.
/// Modeled after Jarvis's PermissionsManager with just-in-time requests and startup healing.
@Observable
final class PermissionsManager {
    static let shared = PermissionsManager()

    var statuses: [PermissionType: PermissionState] = [:]

    private var activationObserver: NSObjectProtocol?

    private init() {
        refreshAll()
    }

    // MARK: - Bulk Operations

    /// Refresh all permission statuses.
    func refreshAll() {
        for type in PermissionType.allCases {
            statuses[type] = checkStatus(type)
        }
        // Notifications is async
        refreshNotificationStatus()
    }

    /// Request all critical permissions that haven't been determined yet.
    /// Called at startup to trigger native system dialogs automatically.
    func requestAllUndetermined() {
        for type in PermissionType.allCases {
            let status = checkStatus(type)
            if status == .notDetermined {
                Task { await request(type) }
            }
        }
    }

    // MARK: - Status Checks

    func checkStatus(_ type: PermissionType) -> PermissionState {
        switch type {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .notDetermined

        case .microphone:
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            switch status {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }

        case .speechRecognition:
            let status = SFSpeechRecognizer.authorizationStatus()
            switch status {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }

        case .calendar:
            let status = EKEventStore.authorizationStatus(for: .event)
            switch status {
            case .fullAccess, .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            case .writeOnly: return .granted
            @unknown default: return .notDetermined
            }

        case .reminders:
            let status = EKEventStore.authorizationStatus(for: .reminder)
            switch status {
            case .fullAccess, .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            case .writeOnly: return .granted
            @unknown default: return .notDetermined
            }

        case .fullDiskAccess:
            let safariDB = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Safari/History.db")
            if FileManager.default.fileExists(atPath: safariDB.path) {
                return FileManager.default.isReadableFile(atPath: safariDB.path) ? .granted : .denied
            }
            let tccPath = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
            return FileManager.default.isReadableFile(atPath: tccPath) ? .granted : .denied

        case .notifications:
            return statuses[.notifications] ?? .notDetermined
        }
    }

    // MARK: - Permission Requests

    /// Request a specific permission. If already denied, opens System Settings.
    func request(_ type: PermissionType) async {
        let current = checkStatus(type)

        switch type {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)

        case .microphone:
            if current == .denied {
                openSettings("Privacy_Microphone")
            } else {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    Task { @MainActor in self.refreshAll() }
                }
            }

        case .speechRecognition:
            if current == .denied {
                openSettings("Privacy_SpeechRecognition")
            } else {
                SFSpeechRecognizer.requestAuthorization { _ in
                    Task { @MainActor in self.refreshAll() }
                }
            }

        case .calendar:
            if current == .denied {
                openSettings("Privacy_Calendars")
            } else {
                let store = EKEventStore()
                _ = try? await store.requestFullAccessToEvents()
                refreshAll()
            }

        case .reminders:
            if current == .denied {
                openSettings("Privacy_Reminders")
            } else {
                let store = EKEventStore()
                _ = try? await store.requestFullAccessToReminders()
                refreshAll()
            }

        case .fullDiskAccess:
            openSettings("Privacy_AllFiles")

        case .notifications:
            if current == .denied {
                openSettings("Privacy_Notifications")
            } else {
                let center = UNUserNotificationCenter.current()
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                refreshNotificationStatus()
            }
        }

        // Refresh after request
        statuses[type] = checkStatus(type)
    }

    /// Ensure a permission is granted — request if needed. Returns true if granted.
    func ensure(_ type: PermissionType) async -> Bool {
        let current = checkStatus(type)
        if current == .granted { return true }
        await request(type)
        return checkStatus(type) == .granted
    }

    // MARK: - Monitoring

    /// Start monitoring for permission changes (call when Privacy settings view appears).
    func startMonitoring() {
        refreshAll()

        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    self?.refreshAll()
                }
            }
        }
    }

    /// Stop monitoring (call when Privacy settings view disappears).
    func stopMonitoring() {
        if let obs = activationObserver {
            NotificationCenter.default.removeObserver(obs)
            activationObserver = nil
        }
    }

    // MARK: - Startup Healing

    /// Check permissions at startup and show alert if critical ones are missing.
    func healIfNeeded() {
        refreshAll()

        var missing: [(String, String)] = []
        if checkStatus(.microphone) != .granted { missing.append(("Microphone", "Privacy_Microphone")) }
        if checkStatus(.speechRecognition) != .granted { missing.append(("Speech Recognition", "Privacy_SpeechRecognition")) }
        if checkStatus(.accessibility) != .granted { missing.append(("Accessibility", "Privacy_Accessibility")) }

        guard !missing.isEmpty else { return }

        // Auto-request undetermined ones (triggers native dialogs)
        requestAllUndetermined()
    }

    // MARK: - Helpers

    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshNotificationStatus() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let state: PermissionState
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: state = .granted
            case .denied: state = .denied
            case .notDetermined: state = .notDetermined
            @unknown default: state = .notDetermined
            }
            statuses[.notifications] = state
        }
    }
}
