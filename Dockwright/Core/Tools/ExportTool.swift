import Foundation
import AppKit

/// Export tool: export conversations as Markdown or PDF.
struct ExportTool: Tool, Sendable {
    let name = "export"
    let description = """
        Export the current conversation. Actions:
        - markdown: Export as a .md markdown file. Params: path (optional, defaults to ~/Desktop/dockwright_export.md)
        - pdf: Export as a .pdf file. Params: path (optional, defaults to ~/Desktop/dockwright_export.pdf)
        """

    let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "Export format: markdown or pdf",
            "enum": ["markdown", "pdf"]
        ] as [String: Any],
        "path": [
            "type": "string",
            "description": "Output file path (optional, defaults to ~/Desktop/)",
            "optional": true
        ] as [String: Any]
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing required parameter: action", isError: true)
        }

        // Get conversation from ExportDataBridge (set before calling tool)
        guard let conversation = ExportDataBridge.shared.currentConversation else {
            return ToolResult("No conversation to export.", isError: true)
        }

        let defaultName = "dockwright_\(conversation.id)"

        switch action {
        case "markdown":
            let path = arguments["path"] as? String
                ?? "~/Desktop/\(defaultName).md"
            let expandedPath = (path as NSString).expandingTildeInPath
            return exportMarkdown(conversation: conversation, to: expandedPath)

        case "pdf":
            let path = arguments["path"] as? String
                ?? "~/Desktop/\(defaultName).pdf"
            let expandedPath = (path as NSString).expandingTildeInPath
            return await exportPDF(conversation: conversation, to: expandedPath)

        default:
            return ToolResult("Unknown format: \(action). Use: markdown, pdf", isError: true)
        }
    }

    // MARK: - Markdown Export

    private func exportMarkdown(conversation: Conversation, to path: String) -> ToolResult {
        var md = "# \(conversation.title)\n\n"
        md += "_Exported from Dockwright on \(formattedDate(Date()))_\n\n"
        md += "---\n\n"

        for message in conversation.messages {
            switch message.role {
            case .user:
                md += "## User\n\n"
                md += message.content + "\n\n"

            case .assistant:
                md += "## Dockwright\n\n"
                md += message.content + "\n\n"

                // Include tool outputs
                for tool in message.toolOutputs {
                    md += "<details>\n<summary>Tool: \(tool.toolName)</summary>\n\n"
                    md += "```\n\(tool.output.prefix(2000))\n```\n\n"
                    md += "</details>\n\n"
                }

            case .error:
                md += "> **Error:** \(message.content)\n\n"

            case .system:
                break
            }
        }

        md += "---\n\n"
        md += "_\(conversation.messages.count) messages_\n"

        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try md.write(toFile: path, atomically: true, encoding: .utf8)
            return ToolResult("Exported conversation as Markdown to: \(path) (\(md.count) chars)")
        } catch {
            return ToolResult("Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - PDF Export

    private func exportPDF(conversation: Conversation, to path: String) async -> ToolResult {
        // Build attributed string for PDF
        let content = NSMutableAttributedString()

        let titleFont = NSFont.systemFont(ofSize: 18, weight: .bold)
        let headingFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let metaFont = NSFont.systemFont(ofSize: 10, weight: .regular)

        let titleColor = NSColor.labelColor
        let userColor = NSColor.systemBlue
        let assistantColor = NSColor.systemGreen
        let metaColor = NSColor.secondaryLabelColor

        // Title
        content.append(NSAttributedString(
            string: "\(conversation.title)\n\n",
            attributes: [.font: titleFont, .foregroundColor: titleColor]
        ))

        content.append(NSAttributedString(
            string: "Exported from Dockwright on \(formattedDate(Date()))\n\n",
            attributes: [.font: metaFont, .foregroundColor: metaColor]
        ))

        for message in conversation.messages {
            switch message.role {
            case .user:
                content.append(NSAttributedString(
                    string: "User:\n",
                    attributes: [.font: headingFont, .foregroundColor: userColor]
                ))
                content.append(NSAttributedString(
                    string: message.content + "\n\n",
                    attributes: [.font: bodyFont, .foregroundColor: titleColor]
                ))

            case .assistant:
                content.append(NSAttributedString(
                    string: "Dockwright:\n",
                    attributes: [.font: headingFont, .foregroundColor: assistantColor]
                ))
                content.append(NSAttributedString(
                    string: message.content + "\n\n",
                    attributes: [.font: bodyFont, .foregroundColor: titleColor]
                ))

                for tool in message.toolOutputs {
                    content.append(NSAttributedString(
                        string: "[\(tool.toolName)]\n",
                        attributes: [.font: codeFont, .foregroundColor: metaColor]
                    ))
                    content.append(NSAttributedString(
                        string: String(tool.output.prefix(1000)) + "\n\n",
                        attributes: [.font: codeFont, .foregroundColor: metaColor]
                    ))
                }

            case .error:
                content.append(NSAttributedString(
                    string: "Error: \(message.content)\n\n",
                    attributes: [.font: bodyFont, .foregroundColor: NSColor.systemRed]
                ))

            case .system:
                break
            }
        }

        // Create PDF using NSTextView print
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            let pageSize = NSSize(width: 612, height: 792) // US Letter
            let margin: CGFloat = 72 // 1 inch
            let printableArea = NSRect(
                x: margin, y: margin,
                width: pageSize.width - 2 * margin,
                height: pageSize.height - 2 * margin
            )

            let textStorage = NSTextStorage(attributedString: content)
            let layoutManager = NSLayoutManager()
            textStorage.addLayoutManager(layoutManager)

            let textContainer = NSTextContainer(size: NSSize(
                width: printableArea.width,
                height: CGFloat.greatestFiniteMagnitude
            ))
            layoutManager.addTextContainer(textContainer)

            // Force layout
            layoutManager.ensureLayout(for: textContainer)

            let totalHeight = layoutManager.usedRect(for: textContainer).height
            let pagesNeeded = Int(ceil(totalHeight / printableArea.height))

            let pdfData = NSMutableData()
            var mediaBox = CGRect(origin: .zero, size: CGSize(width: pageSize.width, height: pageSize.height))

            guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                return ToolResult("Failed to create PDF context", isError: true)
            }

            for page in 0..<max(1, pagesNeeded) {
                context.beginPDFPage(nil)

                let yOffset = CGFloat(page) * printableArea.height
                let glyphRange = layoutManager.glyphRange(
                    forBoundingRect: NSRect(x: 0, y: yOffset, width: printableArea.width, height: printableArea.height),
                    in: textContainer
                )

                let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
                NSGraphicsContext.current = nsContext

                context.translateBy(x: margin, y: pageSize.height - margin)
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: 0, y: -yOffset)

                layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: NSPoint(x: 0, y: 0))

                NSGraphicsContext.current = nil
                context.endPDFPage()
            }

            context.closePDF()

            try pdfData.write(toFile: path, options: .atomic)
            return ToolResult("Exported conversation as PDF to: \(path) (\(pagesNeeded) pages, \(conversation.messages.count) messages)")
        } catch {
            return ToolResult("PDF export failed: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Helpers

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Export Data Bridge

/// Bridge to pass conversation data to the export tool without making it depend on AppState.
final class ExportDataBridge: @unchecked Sendable {
    static let shared = ExportDataBridge()
    private let lock = NSLock()
    private var _conversation: Conversation?

    var currentConversation: Conversation? {
        get { lock.withLock { _conversation } }
        set { lock.withLock { _conversation = newValue } }
    }

    private init() {}
}
