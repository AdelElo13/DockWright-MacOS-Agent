import Foundation
import AppKit
/// LLM tool for direct UI automation — click buttons, type text, read UI elements, press keys.
/// Uses macOS Accessibility API (AXUIElement) for reliable, semantic-level control of ANY app.
nonisolated struct UIAutomationTool: Tool, @unchecked Sendable {
    let name = "ui_automation"
    let description = """
    Control any macOS app's UI directly: click buttons, type text, read elements, press keyboard shortcuts. \
    Much more reliable than AppleScript — works with every app that supports Accessibility. \
    IMPORTANT: For 'click' and 'find_element', you MUST provide either 'meaning' (e.g. "send button", "message input") \
    or 'role'+'title' (e.g. role:"AXTextArea", title:"Message"). \
    Typical workflow: 1) click with meaning:"text input field", 2) type_text with text:"your message", 3) press_key with key:"return".
    """

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: list_elements, find_element, click, click_at, type_text, set_value, press_key, focused_app, read_focused",
        ] as [String: Any],
        "role": [
            "type": "string",
            "description": "AX role to search for (e.g. AXButton, AXTextField, AXMenuItem, AXLink, AXCheckBox)",
            "optional": true,
        ] as [String: Any],
        "title": [
            "type": "string",
            "description": "Element title/label to find (partial match, case-insensitive)",
            "optional": true,
        ] as [String: Any],
        "text": [
            "type": "string",
            "description": "Text to type or set as value",
            "optional": true,
        ] as [String: Any],
        "key": [
            "type": "string",
            "description": "Key to press (e.g. 'return', 'tab', 'escape', 'a', 'space'). For shortcuts use modifiers param.",
            "optional": true,
        ] as [String: Any],
        "modifiers": [
            "type": "string",
            "description": "Comma-separated modifier keys: cmd, shift, alt, ctrl (e.g. 'cmd,shift')",
            "optional": true,
        ] as [String: Any],
        "x": [
            "type": "number",
            "description": "X screen coordinate for click_at",
            "optional": true,
        ] as [String: Any],
        "y": [
            "type": "number",
            "description": "Y screen coordinate for click_at",
            "optional": true,
        ] as [String: Any],
        "app": [
            "type": "string",
            "description": "Bundle ID of target app (optional, defaults to frontmost app)",
            "optional": true,
        ] as [String: Any],
        "meaning": [
            "type": "string",
            "description": "Semantic description of element to find (e.g. 'save button', 'email field'). Uses ProcessSymbiosis live model.",
            "optional": true,
        ] as [String: Any],
    ]

    let requiredParams: [String] = ["action"]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing 'action'. Use: list_elements, find_element, click, click_at, type_text, set_value, press_key, focused_app, read_focused", isError: true)
        }

        let ax = AccessibilityController.shared

        // Check permission first
        let hasPermission = await ax.checkPermission()
        if !hasPermission && action != "focused_app" {
            await ax.requestPermission()
            return ToolResult("Accessibility permission required. A system dialog should appear — grant access to Dockwright, then try again.", isError: true)
        }

        switch action {
        case "list_elements":
            return await listElements(ax: ax, arguments: arguments)
        case "find_element":
            return await findElement(ax: ax, arguments: arguments)
        case "click":
            return await clickElement(ax: ax, arguments: arguments)
        case "click_at":
            return await clickAtPosition(ax: ax, arguments: arguments)
        case "type_text":
            return await typeText(ax: ax, arguments: arguments)
        case "set_value":
            return await setValue(ax: ax, arguments: arguments)
        case "press_key":
            return await pressKey(ax: ax, arguments: arguments)
        case "focused_app":
            return await focusedApp()
        case "read_focused":
            return await readFocused(ax: ax)
        default:
            return ToolResult("Unknown action '\(action)'.", isError: true)
        }
    }

    // MARK: - Actions

    private func listElements(ax: AccessibilityController, arguments: [String: Any]) async -> ToolResult {
        do {
            let elements = try await ax.listElements(inWindow: true, maxDepth: 8)
            if elements.isEmpty { return ToolResult("No UI elements found in focused window.") }

            // Filter to actionable elements only (skip containers/groups)
            let actionable = elements.filter { el in
                guard let role = el.role else { return false }
                return ["AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
                        "AXPopUpButton", "AXComboBox", "AXMenuItem", "AXLink", "AXSlider",
                        "AXTabGroup", "AXTab", "AXSecureTextField", "AXStaticText"].contains(role)
            }

            var result = "Found \(actionable.count) actionable elements (of \(elements.count) total):\n\n"
            for (i, el) in actionable.prefix(40).enumerated() {
                result += "\(i + 1). \(el.descriptionText)\n"
            }
            if actionable.count > 40 {
                result += "... and \(actionable.count - 40) more. Use find_element to narrow down."
            }
            return ToolResult(result)
        } catch {
            return ToolResult("Error listing elements: \(error.localizedDescription)", isError: true)
        }
    }

    private func findElement(ax: AccessibilityController, arguments: [String: Any]) async -> ToolResult {
        // Try semantic search first (ProcessSymbiosis)
        if let meaning = arguments["meaning"] as? String, !meaning.isEmpty {
            if let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                if let found = await ProcessSymbiosis.shared.findElement(inApp: app, meaning: meaning) {
                    return ToolResult("Found: \(found.descriptionText)")
                }
            }
        }

        // Fall back to role+title search
        guard let role = arguments["role"] as? String else {
            return ToolResult("Missing identifier. Use meaning (e.g. meaning:\"send button\") or role+title (e.g. role:\"AXButton\", title:\"Send\").", isError: true)
        }
        let title = arguments["title"] as? String ?? ""
        let bundleID = arguments["app"] as? String

        do {
            let element = try await ax.findElement(role: role, title: title, inApp: bundleID)
            return ToolResult("Found: \(element.descriptionText)")
        } catch {
            return ToolResult("Not found: \(error.localizedDescription)", isError: true)
        }
    }

    private func clickElement(ax: AccessibilityController, arguments: [String: Any]) async -> ToolResult {
        // Find by meaning, role+title, or use ProcessSymbiosis
        let element: UIElementInfo
        do {
            if let meaning = arguments["meaning"] as? String, !meaning.isEmpty {
                // Try ProcessSymbiosis first
                if let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                   let found = await ProcessSymbiosis.shared.findElement(inApp: app, meaning: meaning) {
                    element = found
                } else {
                    // Semantic search failed — try to find by scanning for input fields if meaning suggests text input
                    let isInputMeaning = ["input", "text", "field", "type", "message", "search", "ask", "chat", "prompt", "write"].contains(where: { meaning.lowercased().contains($0) })
                    if isInputMeaning {
                        let elements = try await ax.listElements(inWindow: true, maxDepth: 10)
                        let inputFields = elements.filter { el in
                            guard let role = el.role else { return false }
                            return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
                        }
                        if let firstInput = inputFields.first {
                            element = firstInput
                        } else {
                            // Try focused element as last resort
                            if let focused = await ax.getFocusedElement() {
                                element = await ax.getElementInfoPublic(focused)
                            } else {
                                return ToolResult("No text input field found. Available elements:\n" + (try await listElements(ax: ax, arguments: arguments)).output, isError: true)
                            }
                        }
                    } else {
                        return ToolResult("Element not found for meaning: \"\(meaning)\". Try list_elements first, then click with role+title.", isError: true)
                    }
                }
            } else if let role = arguments["role"] as? String {
                let title = arguments["title"] as? String ?? ""
                element = try await ax.findElement(role: role, title: title, inApp: arguments["app"] as? String)
            } else {
                // No identifier provided — auto list elements and highlight input fields
                let elements = try await ax.listElements(inWindow: true, maxDepth: 8)
                let actionable = elements.filter { el in
                    guard let role = el.role else { return false }
                    return ["AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
                            "AXPopUpButton", "AXComboBox", "AXMenuItem", "AXLink", "AXSlider",
                            "AXTab", "AXSecureTextField", "AXSearchField"].contains(role)
                }
                // Find text input fields specifically
                let inputFields = actionable.filter { el in
                    let role = el.role ?? ""
                    return ["AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox", "AXSearchField"].contains(role)
                }
                var result = ""
                if !inputFields.isEmpty {
                    result += "⚡ TEXT INPUT FIELDS (click one of these to type):\n"
                    for (i, el) in inputFields.enumerated() {
                        result += "  \(i + 1). \(el.descriptionText)\n"
                    }
                    result += "\nTo type in a field: first action:\"click\" role:\"\(inputFields[0].role ?? "AXTextArea")\" title:\"\(inputFields[0].title ?? "")\", then action:\"type_text\" text:\"your message\"\n\n"
                }
                result += "All \(actionable.count) clickable elements:\n"
                for (i, el) in actionable.prefix(25).enumerated() {
                    result += "\(i + 1). \(el.descriptionText)\n"
                }
                result += "\nIMPORTANT: Use action:\"click\" with role+title from the list above. Do NOT use click_at — coordinates are unreliable."
                return ToolResult(result)
            }
        } catch {
            return ToolResult("Cannot find element to click: \(error.localizedDescription)", isError: true)
        }

        do {
            try await ax.click(element: element.element)
            let desc = element.title ?? element.label ?? element.role ?? "element"
            return ToolResult("Clicked: \(desc)")
        } catch {
            // If AX click fails, try clicking by position
            if let pos = element.position, let size = element.size {
                let centerX = pos.x + size.width / 2
                let centerY = pos.y + size.height / 2
                do {
                    try await ax.clickAt(x: centerX, y: centerY)
                    return ToolResult("Clicked at center of \(element.role ?? "element") (\(Int(centerX)),\(Int(centerY)))")
                } catch {
                    return ToolResult("Click failed: \(error.localizedDescription)", isError: true)
                }
            }
            return ToolResult("Click failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func clickAtPosition(ax: AccessibilityController, arguments: [String: Any]) async -> ToolResult {
        guard let x = arguments["x"] as? Double, let y = arguments["y"] as? Double else {
            return ToolResult("Missing 'x' and 'y' coordinates.", isError: true)
        }
        do {
            try await ax.clickAt(x: CGFloat(x), y: CGFloat(y))
            return ToolResult("Clicked at (\(Int(x)), \(Int(y)))")
        } catch {
            return ToolResult("Click failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func typeText(ax: AccessibilityController, arguments: [String: Any]) async -> ToolResult {
        guard let text = arguments["text"] as? String, !text.isEmpty else {
            return ToolResult("Missing 'text' to type.", isError: true)
        }

        // Strategy 1: Try to find focused element and set value directly (fastest, most reliable)
        if let focused = await ax.getFocusedElement() {
            let isTextField = { () -> Bool in
                var role: AnyObject?
                guard AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &role) == .success,
                      let r = role as? String else { return false }
                return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(r)
            }()

            if isTextField {
                // Get current value and append (some fields need append, not replace)
                var currentValue: AnyObject?
                let hasValue = AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &currentValue) == .success
                let current = (hasValue ? currentValue as? String : nil) ?? ""
                let newValue = current + text
                let result = AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, newValue as CFTypeRef)
                if result == .success {
                    return ToolResult("Typed \(text.count) characters into focused text field (via AX set value)")
                }
                // If AX set value failed, fall through to CGEvent typing
            }
        }

        // Strategy 2: CGEvent Unicode typing (works for all characters)
        do {
            try await ax.typeText(text)
            return ToolResult("Typed \(text.count) characters (via keyboard simulation)")
        } catch {
            // Strategy 3: Clipboard paste fallback
            let pasteboard = NSPasteboard.general
            let oldContents = pasteboard.string(forType: .string)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            do {
                try await ax.pressKey(key: "v", modifiers: .maskCommand)
                // Restore old clipboard after small delay
                try? await Task.sleep(for: .milliseconds(200))
                if let old = oldContents {
                    pasteboard.clearContents()
                    pasteboard.setString(old, forType: .string)
                }
                return ToolResult("Typed \(text.count) characters (via clipboard paste)")
            } catch {
                return ToolResult("All typing methods failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func setValue(ax: AccessibilityController, arguments: [String: Any]) async -> ToolResult {
        guard let text = arguments["text"] as? String else {
            return ToolResult("Missing 'text' value to set.", isError: true)
        }

        let element: UIElementInfo
        do {
            if let role = arguments["role"] as? String {
                let title = arguments["title"] as? String ?? ""
                element = try await ax.findElement(role: role, title: title, inApp: arguments["app"] as? String)
            } else if let meaning = arguments["meaning"] as? String, !meaning.isEmpty,
                      let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                      let found = await ProcessSymbiosis.shared.findElement(inApp: app, meaning: meaning) {
                element = found
            } else {
                return ToolResult("Provide 'role'+'title' or 'meaning' to find the element.", isError: true)
            }
        } catch {
            return ToolResult("Cannot find element: \(error.localizedDescription)", isError: true)
        }

        do {
            try await ax.setText(element: element.element, text: text)
            return ToolResult("Set value on \(element.role ?? "element")")
        } catch {
            return ToolResult("Set value failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func pressKey(ax: AccessibilityController, arguments: [String: Any]) async -> ToolResult {
        guard let key = arguments["key"] as? String, !key.isEmpty else {
            return ToolResult("Missing 'key' to press.", isError: true)
        }

        var flags: CGEventFlags = []
        if let mods = arguments["modifiers"] as? String {
            for mod in mods.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                switch mod {
                case "cmd", "command": flags.insert(.maskCommand)
                case "shift": flags.insert(.maskShift)
                case "alt", "option": flags.insert(.maskAlternate)
                case "ctrl", "control": flags.insert(.maskControl)
                default: break
                }
            }
        }

        do {
            try await ax.pressKey(key: key, modifiers: flags)
            let modStr = arguments["modifiers"] as? String
            return ToolResult("Pressed \(modStr != nil ? "\(modStr!)+" : "")\(key)")
        } catch {
            return ToolResult("Key press failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func focusedApp() async -> ToolResult {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ToolResult("No frontmost application.")
        }
        let name = app.localizedName ?? "Unknown"
        let bundleID = app.bundleIdentifier ?? "Unknown"
        let pid = app.processIdentifier

        var result = "Focused app: \(name) (\(bundleID), pid \(pid))"

        // Add symbiosis context if available
        let symbContext = await ProcessSymbiosis.shared.contextString()
        if !symbContext.isEmpty {
            result += "\n\nLive UI state:\n\(symbContext)"
        }

        return ToolResult(result)
    }

    private func readFocused(ax: AccessibilityController) async -> ToolResult {
        guard let focused = await ax.getFocusedElement() else {
            return ToolResult("No focused UI element.")
        }

        func axStr(_ el: AXUIElement, _ attr: String) -> String? {
            var v: AnyObject?
            guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
            return v as? String
        }

        let role = axStr(focused, kAXRoleAttribute) ?? "unknown"
        let title = axStr(focused, kAXTitleAttribute) ?? ""
        let value = axStr(focused, kAXValueAttribute) ?? ""
        let label = axStr(focused, kAXDescriptionAttribute) ?? ""

        let isSecure = ax.isSecureTextField(focused)
        let displayValue = isSecure ? "[SECURE]" : value

        return ToolResult("Focused element: role=\(role) title=\"\(title)\" label=\"\(label)\" value=\"\(displayValue)\"")
    }
}
