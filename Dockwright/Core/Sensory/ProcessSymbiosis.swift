import Foundation
import Cocoa
@preconcurrency import ApplicationServices
import os

nonisolated private let symbLog = Logger(subsystem: "com.Aatje.Dockwright", category: "ProcessSymbiosis")

/// Serial queue for ALL AX observer setup — never on main thread.
private let symbiosisSetupQueue = DispatchQueue(label: "com.Aatje.Dockwright.Symbiosis.setup", qos: .userInitiated)
private let symbiosisAXQueue = DispatchQueue(label: "com.Aatje.Dockwright.Symbiosis.ax", qos: .userInitiated)

/// Dedicated background thread + run loop for AXObserver sources.
/// Keeps ALL accessibility event callbacks OFF the main run loop so they
/// never starve scroll-wheel, keyboard, or mouse events.
private final class AXRunLoopThread: Thread, @unchecked Sendable {
    private(set) var runLoop: CFRunLoop!
    private let ready = DispatchSemaphore(value: 0)

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        ready.signal()
        // Keep the run loop alive forever with a dummy source
        let ctx = CFRunLoopSourceContext()
        let dummySource = withUnsafePointer(to: ctx) { ptr in
            var mutable = ptr.pointee
            return CFRunLoopSourceCreate(nil, 0, &mutable)!
        }
        CFRunLoopAddSource(runLoop, dummySource, .defaultMode)
        CFRunLoopRun()
    }

    func waitUntilReady() {
        ready.wait()
    }
}

private let axRunLoopThread: AXRunLoopThread = {
    let t = AXRunLoopThread()
    t.name = "com.Aatje.Dockwright.AXRunLoop"
    t.qualityOfService = .userInitiated
    t.start()
    t.waitUntilReady()
    return t
}()

/// Live, bidirectional integration with running macOS applications via Accessibility API event stream.
/// Replaces screenshot→OCR→pixel-click with AXObserver→semantic-model→direct-action.
@MainActor
final class ProcessSymbiosis {
    static let shared = ProcessSymbiosis()

    private let accessibilityController = AccessibilityController.shared

    // Active observers keyed by PID
    private var observers: [pid_t: AXObserver] = [:]
    private var observerContexts: [pid_t: SymbiosisObserverContext] = [:]

    // Persistent UI models keyed by bundle ID
    private var appModels: [String: AppUIModel] = [:]

    // Events since last query (bounded ring buffer)
    private var eventBuffer: [AppUIEvent] = []
    private let maxEventBuffer = 200

    // Monitoring state
    private var monitoredApps: Set<pid_t> = []
    private var workspaceObserver: NSObjectProtocol?
    private var isRunning = false

    // Throttle: buffer events on background, flush to main max 4x/sec
    private nonisolated(unsafe) static var pendingEvents: [(notification: String, bundleID: String, pid: pid_t, role: String, title: String?, value: String?, desc: String?)] = []
    private nonisolated(unsafe) static var flushScheduled = false
    private static let pendingLock = NSLock()

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            Task { @MainActor in
                ProcessSymbiosis.shared.ensureMonitoring(app: app, bundleID: bundleID)
            }
        }

        if let front = NSWorkspace.shared.frontmostApplication,
           let bundleID = front.bundleIdentifier {
            ensureMonitoring(app: front, bundleID: bundleID)
        }

        symbLog.info("ProcessSymbiosis started — live app integration active")
    }

    func stop() {
        isRunning = false
        for (pid, observer) in observers {
            removeObserver(observer, pid: pid)
        }
        observers.removeAll()
        observerContexts.removeAll()
        monitoredApps.removeAll()
        if let wo = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wo)
            workspaceObserver = nil
        }
        symbLog.info("ProcessSymbiosis stopped")
    }

    // MARK: - Observer Management

    func ensureMonitoring(app: NSRunningApplication, bundleID: String) {
        let pid = app.processIdentifier
        guard !monitoredApps.contains(pid) else { return }
        // CRITICAL: Never monitor ourselves — AX queries on our own SwiftUI tree deadlock the main thread
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        guard bundleID != "com.Aatje.Dockwright.Dockwright" else { return }
        guard AXIsProcessTrusted() else {
            symbLog.warning("Accessibility not trusted — ProcessSymbiosis degraded")
            return
        }

        // Mark as monitored immediately to prevent duplicate setup
        monitoredApps.insert(pid)

        if appModels[bundleID] == nil {
            appModels[bundleID] = AppUIModel(bundleID: bundleID)
        }

        let context = SymbiosisObserverContext(bundleID: bundleID, pid: pid)

        // Do ALL AX observer setup OFF the main thread to prevent deadlock.
        // AXObserverCreate + AXObserverAddNotification can take internal locks
        // that conflict with SwiftUI accessibility resolution on main thread.
        symbiosisSetupQueue.async { [weak self] in
            var observer: AXObserver?
            let err = AXObserverCreate(pid, { observer, element, notification, refcon in
                guard let refcon = refcon else { return }
                let ctx = Unmanaged<SymbiosisObserverContext>.fromOpaque(refcon).takeUnretainedValue()
                let notifStr = notification as String
                let bundleID = ctx.bundleID
                let pid = ctx.pid
                let elementCopy = element

                symbiosisAXQueue.async {
                    AXUIElementSetMessagingTimeout(elementCopy, 1.0)
                    let role = symbiosisAXStringAttr(elementCopy, kAXRoleAttribute) ?? "unknown"
                    let title = symbiosisAXStringAttr(elementCopy, kAXTitleAttribute)
                    let value = symbiosisAXStringAttr(elementCopy, kAXValueAttribute)
                    let desc = symbiosisAXStringAttr(elementCopy, kAXDescriptionAttribute)

                    // Buffer event and coalesce — flush to main at most 4x/sec
                    ProcessSymbiosis.pendingLock.lock()
                    ProcessSymbiosis.pendingEvents.append((notifStr, bundleID, pid, role, title, value, desc))
                    // Cap buffer to avoid unbounded growth
                    if ProcessSymbiosis.pendingEvents.count > 50 {
                        ProcessSymbiosis.pendingEvents.removeFirst(ProcessSymbiosis.pendingEvents.count - 50)
                    }
                    let needsSchedule = !ProcessSymbiosis.flushScheduled
                    if needsSchedule { ProcessSymbiosis.flushScheduled = true }
                    ProcessSymbiosis.pendingLock.unlock()

                    if needsSchedule {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            ProcessSymbiosis.pendingLock.lock()
                            let batch = ProcessSymbiosis.pendingEvents
                            ProcessSymbiosis.pendingEvents.removeAll()
                            ProcessSymbiosis.flushScheduled = false
                            ProcessSymbiosis.pendingLock.unlock()

                            for ev in batch {
                                ProcessSymbiosis.shared.handleEventPreExtracted(
                                    notification: ev.notification, bundleID: ev.bundleID, pid: ev.pid,
                                    role: ev.role, title: ev.title, value: ev.value, desc: ev.desc
                                )
                            }
                        }
                    }
                }
            }, &observer)

            guard err == .success, let obs = observer else {
                symbLog.warning("AXObserverCreate failed for \(bundleID) pid=\(pid): \(err.rawValue)")
                DispatchQueue.main.async { self?.monitoredApps.remove(pid) }
                return
            }

            let appElement = AXUIElementCreateApplication(pid)
            let notifications: [String] = [
                kAXFocusedUIElementChangedNotification,
                kAXValueChangedNotification,
                kAXTitleChangedNotification,
                kAXWindowCreatedNotification,
                kAXWindowMovedNotification,
                kAXSelectedTextChangedNotification,
                kAXCreatedNotification,
                kAXUIElementDestroyedNotification,
            ]

            let contextPtr = Unmanaged.passUnretained(context).toOpaque()
            for notif in notifications {
                AXObserverAddNotification(obs, appElement, notif as CFString, contextPtr)
            }

            // Add run loop source on BACKGROUND thread — never the main run loop.
            // AX events from monitored apps fire frequently; putting them on main
            // starves scroll-wheel, keyboard, and mouse events.
            let bgRunLoop = axRunLoopThread.runLoop!
            CFRunLoopAddSource(bgRunLoop, AXObserverGetRunLoopSource(obs), .defaultMode)
            CFRunLoopWakeUp(bgRunLoop)

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.observers[pid] = obs
                self.observerContexts[pid] = context
                symbLog.info("Monitoring \(bundleID) (pid \(pid)) — \(notifications.count) event types")
            }

            // Refresh app model on background — with timeout to avoid hanging
            Task.detached {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await ProcessSymbiosis.shared.refreshAppModel(bundleID: bundleID)
                    }
                    group.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000) }
                    _ = await group.next()
                    group.cancelAll()
                }
            }
        }

        symbLog.info("Queued monitoring setup for \(bundleID) (pid \(pid))")
    }

    private func removeObserver(_ observer: AXObserver, pid: pid_t) {
        let bgRunLoop = axRunLoopThread.runLoop!
        CFRunLoopRemoveSource(bgRunLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        observerContexts[pid] = nil
    }

    // MARK: - Event Handling

    func handleEventPreExtracted(notification: String, bundleID: String, pid: pid_t,
                                  role: String, title: String?, value: String?, desc: String?) {
        guard isRunning else { return }

        let event = AppUIEvent(
            timestamp: Date(), bundleID: bundleID, notification: notification,
            elementRole: role, elementTitle: title, elementValue: value, elementDescription: desc
        )

        eventBuffer.append(event)
        if eventBuffer.count > maxEventBuffer {
            eventBuffer.removeFirst(eventBuffer.count - maxEventBuffer)
        }

        if let model = appModels[bundleID] {
            model.processEvent(event)
        }
    }

    // MARK: - App UI Model

    func model(for bundleID: String) -> AppUIModel? { appModels[bundleID] }

    func refreshAppModel(bundleID: String) async {
        guard let model = appModels[bundleID] else { return }
        // Don't refresh our own app — deadlocks
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        guard bundleID != "com.Aatje.Dockwright.Dockwright" else { return }
        do {
            let elements = try await accessibilityController.listElements(inWindow: true)
            model.rebuildFromSnapshot(elements)
            symbLog.debug("Refreshed \(bundleID): \(elements.count) elements")
        } catch {
            symbLog.warning("Snapshot refresh failed for \(bundleID): \(error.localizedDescription)")
        }
    }

    // MARK: - Semantic Actions

    func findElement(inApp bundleID: String, meaning: String) async -> UIElementInfo? {
        if let model = appModels[bundleID], let cached = model.findByMeaning(meaning) {
            return cached
        }
        do {
            let elements = try await accessibilityController.listElements(inWindow: true)
            return elements.first { el in
                [el.role, el.title, el.label].compactMap { $0 }.joined(separator: " ").lowercased().contains(meaning.lowercased())
            }
        } catch {
            return nil
        }
    }

    func performAction(_ action: String, element: AXUIElement) throws {
        let axAction: String
        switch action.lowercased() {
        case "click", "press", "tap", "activate": axAction = kAXPressAction
        case "confirm", "ok", "accept": axAction = kAXConfirmAction
        case "cancel", "dismiss": axAction = kAXCancelAction
        case "increment": axAction = kAXIncrementAction
        case "decrement": axAction = kAXDecrementAction
        default: axAction = kAXPressAction
        }
        let err = AXUIElementPerformAction(element, axAction as CFString)
        guard err == .success else {
            throw SymbiosisError.actionFailed(action: action, error: err.rawValue)
        }
    }

    // MARK: - Context for LLM

    func contextString() -> String {
        guard isRunning, !appModels.isEmpty else { return "" }
        var lines: [String] = []

        let recent = eventBuffer.suffix(10).filter { isSignificant($0.notification) }
        if !recent.isEmpty {
            let descs = recent.map { ev in
                let what = ev.elementTitle ?? ev.elementRole
                let short = ev.notification.replacingOccurrences(of: "AX", with: "").replacingOccurrences(of: "Notification", with: "")
                return "\(ev.bundleID.split(separator: ".").last ?? "app"):\(short)(\(what))"
            }
            lines.append("LIVE UI: \(descs.joined(separator: ", "))")
        }

        for (bundleID, model) in appModels {
            let summary = model.briefSummary()
            if !summary.isEmpty {
                let short = String(bundleID.split(separator: ".").last ?? Substring(bundleID))
                lines.append("\(short.uppercased()): \(summary)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// How many apps are currently being monitored.
    var monitoredAppCount: Int { monitoredApps.count }

    private func isSignificant(_ notification: String) -> Bool {
        [kAXValueChangedNotification, kAXFocusedUIElementChangedNotification,
         kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
         kAXSelectedTextChangedNotification].contains(notification)
    }
}

// MARK: - AX Helper

nonisolated private func symbiosisAXStringAttr(_ element: AXUIElement, _ attr: String) -> String? {
    var v: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success else { return nil }
    return v as? String
}

// MARK: - Supporting Types

final class SymbiosisObserverContext: @unchecked Sendable {
    let bundleID: String
    let pid: pid_t
    init(bundleID: String, pid: pid_t) { self.bundleID = bundleID; self.pid = pid }
}

@MainActor
final class AppUIModel {
    let bundleID: String
    private(set) var elements: [String: UIElementInfo] = [:]
    private(set) var focusedElement: String?
    private(set) var windowTitle: String?
    private(set) var lastUpdate: Date = Date()
    private(set) var eventCount: Int = 0
    private var semanticCache: [String: String] = [:]

    init(bundleID: String) { self.bundleID = bundleID }

    func processEvent(_ event: AppUIEvent) {
        lastUpdate = Date()
        eventCount += 1
        switch event.notification {
        case kAXFocusedUIElementChangedNotification:
            focusedElement = "\(event.elementRole):\(event.elementTitle ?? "?")"
        case kAXTitleChangedNotification:
            if event.elementRole == "AXWindow" { windowTitle = event.elementValue ?? event.elementTitle }
        default: break
        }
    }

    func rebuildFromSnapshot(_ snapshot: [UIElementInfo]) {
        elements.removeAll()
        for el in snapshot {
            let key = "\(el.role ?? "?"):\(el.title ?? "?")"
            elements[key] = el
        }
        lastUpdate = Date()
    }

    func findByMeaning(_ meaning: String) -> UIElementInfo? {
        if let key = semanticCache[meaning.lowercased()], let el = elements[key] { return el }
        let lower = meaning.lowercased()
        for (key, el) in elements {
            let combined = [el.role, el.title, el.label].compactMap { $0 }.joined(separator: " ").lowercased()
            if combined.contains(lower) { semanticCache[lower] = key; return el }
        }
        return nil
    }

    func briefSummary() -> String {
        var parts: [String] = []
        if let win = windowTitle { parts.append("window: \(win)") }
        if let focus = focusedElement { parts.append("focus: \(focus)") }
        parts.append("\(elements.count) elements, \(eventCount) events")
        return parts.joined(separator: ", ")
    }
}

struct AppUIEvent: Sendable {
    let timestamp: Date
    let bundleID: String
    let notification: String
    let elementRole: String
    let elementTitle: String?
    let elementValue: String?
    let elementDescription: String?
}

enum SymbiosisError: Error, LocalizedError {
    case actionFailed(action: String, error: Int32)
    case appNotMonitored(bundleID: String)

    var errorDescription: String? {
        switch self {
        case .actionFailed(let action, let error): return "AX action '\(action)' failed: \(error)"
        case .appNotMonitored(let id): return "'\(id)' is not being monitored"
        }
    }
}
