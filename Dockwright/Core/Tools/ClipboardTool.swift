import AppKit

/// LLM tool for interacting with the system clipboard.
/// Actions: read, write, clear, history.
nonisolated struct ClipboardTool: Tool, @unchecked Sendable {
    let name = "clipboard"
    let description = "Interact with the system clipboard: read current content, write text, clear, or show recent items."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: read, write, clear, history",
        ] as [String: Any],
        "text": [
            "type": "string",
            "description": "Text to write to clipboard (for write action)",
            "optional": true,
        ] as [String: Any],
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult(
                "Missing 'action' parameter. Use: read, write, clear, history",
                isError: true
            )
        }

        switch action {
        case "read":
            return readClipboard()
        case "write":
            return writeClipboard(arguments)
        case "clear":
            return clearClipboard()
        case "history":
            return clipboardHistory()
        default:
            return ToolResult(
                "Unknown action: \(action). Use: read, write, clear, history",
                isError: true
            )
        }
    }

    // MARK: - Actions

    private func readClipboard() -> ToolResult {
        let pasteboard = NSPasteboard.general

        // Check for text content
        if let text = pasteboard.string(forType: .string) {
            let charCount = text.count
            let lineCount = text.components(separatedBy: .newlines).count
            let preview = charCount > 5000
                ? String(text.prefix(5000)) + "\n\n[Truncated at 5,000 of \(charCount) characters]"
                : text
            return ToolResult("Clipboard contains text (\(charCount) chars, \(lineCount) lines):\n\n\(preview)")
        }

        // Check for image content
        if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            if let image = NSImage(data: imageData) {
                let size = image.size
                let byteCount = imageData.count
                let typeName = pasteboard.data(forType: .png) != nil ? "PNG" : "TIFF"
                return ToolResult("Clipboard contains an image (\(typeName), \(Int(size.width))x\(Int(size.height)) pixels, \(byteCount) bytes)")
            }
            return ToolResult("Clipboard contains image data (\(imageData.count) bytes)")
        }

        // Check for file URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let fileList = urls.map { $0.path }.joined(separator: "\n")
            return ToolResult("Clipboard contains \(urls.count) file reference(s):\n\(fileList)")
        }

        // Check what types are available
        let types = pasteboard.types?.map { $0.rawValue } ?? []
        if types.isEmpty {
            return ToolResult("Clipboard is empty.")
        }

        return ToolResult("Clipboard contains data of type(s): \(types.joined(separator: ", "))\n(No text or image content detected)")
    }

    private func writeClipboard(_ args: [String: Any]) -> ToolResult {
        guard let text = args["text"] as? String, !text.isEmpty else {
            return ToolResult("Missing 'text' parameter for write action.", isError: true)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        return ToolResult("Wrote \(text.count) characters to clipboard.")
    }

    private func clearClipboard() -> ToolResult {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return ToolResult("Clipboard cleared.")
    }

    private func clipboardHistory() -> ToolResult {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        let types = pasteboard.types?.map { $0.rawValue } ?? []

        var info = "macOS does not provide a clipboard history API.\n"
        info += "Current clipboard change count: \(changeCount)\n"
        if types.isEmpty {
            info += "Clipboard is currently empty."
        } else {
            info += "Current content types: \(types.joined(separator: ", "))\n"
            if let text = pasteboard.string(forType: .string) {
                let preview = String(text.prefix(200))
                info += "Current text preview: \(preview)"
                if text.count > 200 { info += "..." }
            }
        }

        return ToolResult(info)
    }
}
