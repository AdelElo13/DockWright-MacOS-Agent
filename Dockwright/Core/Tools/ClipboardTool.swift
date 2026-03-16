import Foundation
import AppKit

/// Clipboard tool: read, write, and detect clipboard content type.
/// The LLM can use this to copy results, read what the user pasted, etc.
struct ClipboardTool: Tool, Sendable {
    let name = "clipboard"
    let description = """
        Read and write the system clipboard. Actions:
        - read: Read current clipboard text content
        - write: Write text to clipboard
        - detect: Detect what type of content is on the clipboard (text, image, file paths, code)
        - read_files: Read file paths from clipboard (if files were copied in Finder)
        """

    let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "Action: read, write, detect, read_files",
            "enum": ["read", "write", "detect", "read_files"]
        ] as [String: Any],
        "content": [
            "type": "string",
            "description": "Text to write to clipboard (for write action)",
            "optional": true
        ] as [String: Any]
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing required parameter: action", isError: true)
        }

        switch action {
        case "read":
            return readClipboard()
        case "write":
            guard let content = arguments["content"] as? String else {
                return ToolResult("Missing required parameter: content for write action", isError: true)
            }
            return writeClipboard(content)
        case "detect":
            return detectClipboard()
        case "read_files":
            return readClipboardFiles()
        default:
            return ToolResult("Unknown action: \(action). Use: read, write, detect, read_files", isError: true)
        }
    }

    // MARK: - Actions

    private func readClipboard() -> ToolResult {
        let pb = NSPasteboard.general
        if let text = pb.string(forType: .string) {
            if text.count > 50_000 {
                return ToolResult(String(text.prefix(50_000)) + "\n[truncated at 50000 chars]")
            }
            return ToolResult(text)
        }
        return ToolResult("Clipboard is empty or contains non-text content.", isError: true)
    }

    private func writeClipboard(_ text: String) -> ToolResult {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return ToolResult("Copied \(text.count) characters to clipboard.")
    }

    private func detectClipboard() -> ToolResult {
        let pb = NSPasteboard.general
        var types: [String] = []

        if pb.string(forType: .string) != nil {
            let text = pb.string(forType: .string) ?? ""
            types.append("text (\(text.count) chars)")

            // Detect if it looks like code
            if looksLikeCode(text) {
                types.append("likely_code")
            }

            // Detect if it looks like a URL
            if text.hasPrefix("http://") || text.hasPrefix("https://") {
                types.append("url")
            }

            // Detect if it looks like a file path
            if text.hasPrefix("/") || text.hasPrefix("~") {
                types.append("file_path")
            }
        }

        if pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil {
            types.append("image")
        }

        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let fileURLs = urls.filter { $0.isFileURL }
            if !fileURLs.isEmpty {
                types.append("files (\(fileURLs.count))")
            }
        }

        if types.isEmpty {
            return ToolResult("Clipboard is empty.")
        }

        return ToolResult("Clipboard contains: \(types.joined(separator: ", "))")
    }

    private func readClipboardFiles() -> ToolResult {
        let pb = NSPasteboard.general

        // Try file URLs
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let fileURLs = urls.filter { $0.isFileURL }
            if !fileURLs.isEmpty {
                let paths = fileURLs.map { $0.path }
                return ToolResult("Clipboard files (\(paths.count)):\n" + paths.joined(separator: "\n"))
            }
        }

        // Try filenames from pasteboard
        if let filenames = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            if !filenames.isEmpty {
                return ToolResult("Clipboard files (\(filenames.count)):\n" + filenames.joined(separator: "\n"))
            }
        }

        return ToolResult("No files on clipboard.")
    }

    // MARK: - Code Detection

    private func looksLikeCode(_ text: String) -> Bool {
        let codeIndicators = [
            "func ", "var ", "let ", "class ", "struct ", "enum ",  // Swift
            "function ", "const ", "import ", "export ",             // JS/TS
            "def ", "self.", "print(",                               // Python
            "public ", "private ", "static ", "void ",              // Java/C#
            "if (", "for (", "while (", "return ",                  // General
            "<!DOCTYPE", "<html", "<div",                           // HTML
            "{", "}", "=>", "->",                                   // Syntax
        ]
        let lines = text.components(separatedBy: "\n")
        let sampleLines = lines.prefix(20)
        var hits = 0
        for line in sampleLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for indicator in codeIndicators {
                if trimmed.contains(indicator) { hits += 1; break }
            }
        }
        return hits >= 3 || (lines.count > 3 && hits >= 2)
    }

    // MARK: - Static Helpers

    /// Check if clipboard has text that looks like code (used for proactive suggestions).
    static func clipboardHasCode() -> Bool {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string) else { return false }
        let tool = ClipboardTool()
        return tool.looksLikeCode(text)
    }

    /// Get clipboard text preview (first 200 chars).
    static func clipboardPreview() -> String? {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string), !text.isEmpty else { return nil }
        if text.count > 200 {
            return String(text.prefix(200)) + "..."
        }
        return text
    }
}
