import Foundation
@preconcurrency import ApplicationServices
import AppKit
import os.log

// AXUIElement is a thread-safe CFType — retroactive Sendable conformance
extension AXUIElement: @retroactive @unchecked Sendable {}

nonisolated private let axLog = Logger(subsystem: "com.Aatje.Dockwright", category: "Accessibility")

/// Controls macOS UI programmatically via AXUIElement APIs.
/// Enables: finding UI elements, clicking buttons, typing text, pressing keys, reading values.
actor AccessibilityController {
    static let shared = AccessibilityController()
    private init() {}

    // MARK: - Permission

    func checkPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Find Elements

    func getFocusedApp() throws -> AXUIElement {
        guard checkPermission() else { throw AXControllerError.permissionDenied }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw AXControllerError.noFocusedApp
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    func getFocusedWindow() throws -> AXUIElement {
        let app = try getFocusedApp()
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        guard result == .success, let window = value,
              CFGetTypeID(window) == AXUIElementGetTypeID() else {
            throw AXControllerError.noFocusedWindow
        }
        return window as! AXUIElement  // Safe: CFGetTypeID guard above
    }

    /// Find UI element by role and title text.
    func findElement(role: String, title: String, inApp bundleID: String? = nil) async throws -> UIElementInfo {
        guard checkPermission() else { throw AXControllerError.permissionDenied }

        let app: AXUIElement
        if let bundleID = bundleID {
            guard let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
                throw AXControllerError.appNotFound(bundleID)
            }
            app = AXUIElementCreateApplication(running.processIdentifier)
        } else {
            app = try getFocusedApp()
        }

        var matches: [UIElementInfo] = []
        searchRecursive(element: app, role: role, title: title, matches: &matches, depth: 0, maxDepth: 10)
        guard let first = matches.first else {
            throw AXControllerError.elementNotFound(role: role, title: title)
        }
        return first
    }

    /// List all visible UI elements in the focused window.
    func listElements(inWindow: Bool = true, maxDepth: Int = 10) async throws -> [UIElementInfo] {
        guard checkPermission() else { throw AXControllerError.permissionDenied }
        let root: AXUIElement = inWindow ? try getFocusedWindow() : try getFocusedApp()
        var elements: [UIElementInfo] = []
        collectAll(from: root, into: &elements, depth: 0, maxDepth: maxDepth)
        return elements
    }

    /// Get the currently focused UI element.
    func getFocusedElement() -> AXUIElement? {
        guard checkPermission(),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focused: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let el = focused as! AXUIElement  // Safe: CFGetTypeID guard above
        return el
    }

    // MARK: - Password Detection

    nonisolated func isSecureTextField(_ element: AXUIElement) -> Bool {
        var subrole: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let s = subrole as? String, s == "AXSecureTextField" { return true }
        var role: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let r = role as? String, r == "AXSecureTextField" { return true }
        return false
    }

    // MARK: - Actions

    /// Click a UI element via AX press action.
    func click(element: AXUIElement) throws {
        guard checkPermission() else { throw AXControllerError.permissionDenied }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else { throw AXControllerError.actionFailed("click", result) }
        axLog.info("Clicked UI element")
    }

    /// Set text value of a text field. Suppresses logging for password fields.
    func setText(element: AXUIElement, text: String) throws {
        guard checkPermission() else { throw AXControllerError.permissionDenied }
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
        guard result == .success else { throw AXControllerError.actionFailed("setText", result) }
        if isSecureTextField(element) {
            axLog.info("Set text in secure field: [REDACTED]")
        } else {
            axLog.info("Set text: \(text.prefix(50), privacy: .public)")
        }
    }

    /// Press a keyboard shortcut.
    func pressKey(key: String, modifiers: CGEventFlags = []) throws {
        guard checkPermission() else { throw AXControllerError.permissionDenied }
        guard let keyCode = KeyCodeMapper.keyCode(for: key) else {
            throw AXControllerError.invalidKey(key)
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw AXControllerError.eventCreationFailed
        }
        down.flags = modifiers
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        axLog.info("Pressed key: \(key, privacy: .public)")
    }

    /// Type a full string using Unicode CGEvent injection.
    /// Handles ALL characters: uppercase, special chars (?!@#), Unicode (émojis, accents), etc.
    func typeText(_ text: String) throws {
        guard checkPermission() else { throw AXControllerError.permissionDenied }
        for char in text {
            let utf16 = Array(String(char).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(15_000) // 15ms between keystrokes
        }
    }

    /// Click at screen coordinates.
    func clickAt(x: CGFloat, y: CGFloat) throws {
        guard checkPermission() else { throw AXControllerError.permissionDenied }
        let point = CGPoint(x: x, y: y)
        guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw AXControllerError.eventCreationFailed
        }
        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
        axLog.info("Clicked at (\(x), \(y))")
    }

    /// Get element frame on screen.
    nonisolated func getElementFrame(_ element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        var posValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              let posRef = posValue, CFGetTypeID(posRef) == AXValueGetTypeID(),
              AXValueGetValue(posRef as! AXValue, .cgPoint, &position) else { return nil }
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let sizeRef = sizeValue, CFGetTypeID(sizeRef) == AXValueGetTypeID(),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Public wrapper for getElementInfo.
    func getElementInfoPublic(_ element: AXUIElement) -> UIElementInfo {
        return getElementInfo(element)
    }

    // MARK: - Private Traversal

    private func searchRecursive(element: AXUIElement, role: String, title: String, matches: inout [UIElementInfo], depth: Int, maxDepth: Int) {
        guard depth < maxDepth else { return }
        let info = getElementInfo(element)
        let roleMatches = info.role == role
        let titleMatches = title.isEmpty || info.title?.localizedCaseInsensitiveContains(title) == true || info.label?.localizedCaseInsensitiveContains(title) == true
        if roleMatches && titleMatches {
            matches.append(info)
        }
        guard let children = info.children else { return }
        for child in children {
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { continue }
            searchRecursive(element: child as! AXUIElement, role: role, title: title, matches: &matches, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    private func collectAll(from root: AXUIElement, into elements: inout [UIElementInfo], depth: Int, maxDepth: Int) {
        guard depth < maxDepth else { return }
        let info = getElementInfo(root)
        elements.append(info)
        guard let children = info.children else { return }
        for child in children {
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { continue }
            collectAll(from: child as! AXUIElement, into: &elements, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    private func getElementInfo(_ element: AXUIElement) -> UIElementInfo {
        func axStr(_ attr: String) -> String? {
            var v: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success else { return nil }
            return v as? String
        }

        let role = axStr(kAXRoleAttribute)
        let subrole = axStr(kAXSubroleAttribute)
        let title = axStr(kAXTitleAttribute)
        let label = axStr(kAXDescriptionAttribute)

        let isSecure = subrole == "AXSecureTextField" || role == "AXSecureTextField"
        var value: Any?
        if isSecure {
            value = "[SECURE]"
        } else {
            var v: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &v) == .success { value = v }
        }

        var position: CGPoint?
        var posValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
           let posRef = posValue, CFGetTypeID(posRef) == AXValueGetTypeID() {
            var point = CGPoint.zero
            if AXValueGetValue(posRef as! AXValue, .cgPoint, &point) { position = point }
        }

        var size: CGSize?
        var sizeValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let sizeRef = sizeValue, CFGetTypeID(sizeRef) == AXValueGetTypeID() {
            var s = CGSize.zero
            if AXValueGetValue(sizeRef as! AXValue, .cgSize, &s) { size = s }
        }

        var children: [AnyObject]?
        var childrenValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success {
            children = childrenValue as? [AnyObject]
        }

        return UIElementInfo(element: element, role: role, subrole: subrole, title: title, label: label,
                             value: value, position: position, size: size, children: children)
    }
}

// MARK: - Data Structures

struct UIElementInfo: @unchecked Sendable {
    let element: AXUIElement
    let role: String?
    let subrole: String?
    let title: String?
    let label: String?
    nonisolated(unsafe) let value: Any?
    let position: CGPoint?
    let size: CGSize?
    nonisolated(unsafe) let children: [AnyObject]?

    var isSecureTextField: Bool {
        subrole == "AXSecureTextField" || role == "AXSecureTextField"
    }

    /// Nonisolated description for use from any context (e.g. nonisolated Tool structs).
    nonisolated var descriptionText: String {
        var parts: [String] = []
        if let role = role { parts.append("role=\(role)") }
        if let subrole = subrole { parts.append("subrole=\(subrole)") }
        if let title = title, !title.isEmpty { parts.append("title=\"\(title)\"") }
        if let label = label, !label.isEmpty { parts.append("label=\"\(label)\"") }
        let secure = subrole == "AXSecureTextField" || role == "AXSecureTextField"
        if secure { parts.append("value=[SECURE]") }
        else if let value = value { parts.append("value=\"\(value)\"") }
        if let position = position { parts.append("pos=(\(Int(position.x)),\(Int(position.y)))") }
        if let size = size { parts.append("size=\(Int(size.width))x\(Int(size.height))") }
        return parts.joined(separator: " ")
    }

    var description: String { descriptionText }
}

// MARK: - Errors

enum AXControllerError: LocalizedError {
    case permissionDenied
    case noFocusedApp
    case noFocusedWindow
    case appNotFound(String)
    case elementNotFound(role: String, title: String)
    case actionFailed(String, AXError)
    case invalidKey(String)
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Accessibility permission denied. Go to System Settings → Privacy & Security → Accessibility and enable Dockwright."
        case .noFocusedApp: return "No focused application found."
        case .noFocusedWindow: return "No focused window found."
        case .appNotFound(let id): return "Application not found: \(id)"
        case .elementNotFound(let role, let title): return "UI element not found: role=\(role) title=\"\(title)\""
        case .actionFailed(let action, let error): return "Action '\(action)' failed: \(error.rawValue)"
        case .invalidKey(let key): return "Invalid key: \(key)"
        case .eventCreationFailed: return "Failed to create keyboard/mouse event."
        }
    }
}

// MARK: - Key Code Mapper

enum KeyCodeMapper {
    nonisolated static func keyCode(for key: String) -> CGKeyCode? {
        let mapping: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "minus": 27, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
            "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51,
            "backspace": 51, "escape": 53, "esc": 53,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        ]
        return mapping[key.lowercased()]
    }
}
