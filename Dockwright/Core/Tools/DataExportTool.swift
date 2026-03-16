import Foundation
import os

/// Structured data export tool: CSV, JSON, HTML reports, spreadsheets.
/// Saves files to ~/Desktop/Dockwright Exports/.
nonisolated struct DataExportTool: Tool, @unchecked Sendable {
    let name = "data_export"
    let description = """
        Export structured data as files. Actions:
        - export_csv: Export data as CSV. Params: headers (array), rows (array of arrays), filename
        - export_json: Export structured data as formatted JSON. Params: data (object/array), filename
        - export_html_report: Generate a styled HTML report. Params: title, sections (array of {heading, body?, table?})
        - create_spreadsheet: Create a Numbers-compatible CSV with metadata. Params: headers, rows, filename, sheet_name
        - list_exports: List recently exported files
        """

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "Action: export_csv, export_json, export_html_report, create_spreadsheet, list_exports",
            "enum": ["export_csv", "export_json", "export_html_report", "create_spreadsheet", "list_exports"]
        ] as [String: Any],
        "headers": [
            "type": "array",
            "description": "Column headers for CSV/spreadsheet export",
            "optional": true
        ] as [String: Any],
        "rows": [
            "type": "array",
            "description": "Array of arrays representing rows of data",
            "optional": true
        ] as [String: Any],
        "data": [
            "type": "object",
            "description": "Structured data for JSON export (object or array)",
            "optional": true
        ] as [String: Any],
        "filename": [
            "type": "string",
            "description": "Output filename (without path, extension added automatically)",
            "optional": true
        ] as [String: Any],
        "title": [
            "type": "string",
            "description": "Report title for HTML export",
            "optional": true
        ] as [String: Any],
        "sections": [
            "type": "array",
            "description": "Array of section objects {heading, body?, table?} for HTML report",
            "optional": true
        ] as [String: Any],
        "sheet_name": [
            "type": "string",
            "description": "Sheet name for spreadsheet export",
            "optional": true
        ] as [String: Any]
    ]

    private static let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "DataExportTool")

    /// Base export directory.
    private static var exportDir: String {
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("Dockwright Exports")
            .path
        return desktop
    }

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing required parameter: action", isError: true)
        }

        switch action {
        case "export_csv":
            return exportCSV(arguments: arguments)
        case "export_json":
            return exportJSON(arguments: arguments)
        case "export_html_report":
            return exportHTMLReport(arguments: arguments)
        case "create_spreadsheet":
            return createSpreadsheet(arguments: arguments)
        case "list_exports":
            return listExports()
        default:
            return ToolResult("Unknown action: \(action)", isError: true)
        }
    }

    // MARK: - CSV Export

    private func exportCSV(arguments: [String: Any]) -> ToolResult {
        guard let headers = arguments["headers"] as? [String] else {
            return ToolResult("Missing required parameter: headers (array of strings)", isError: true)
        }
        guard let rows = arguments["rows"] as? [[Any]] else {
            return ToolResult("Missing required parameter: rows (array of arrays)", isError: true)
        }

        let filename = sanitizeFilename(arguments["filename"] as? String ?? "export_\(timestamp())")

        var csv = headers.map { escapeCSV($0) }.joined(separator: ",") + "\n"
        for row in rows {
            let line = row.map { escapeCSV(stringValue($0)) }.joined(separator: ",")
            csv += line + "\n"
        }

        return writeExport(content: csv, filename: filename, extension: "csv")
    }

    // MARK: - JSON Export

    private func exportJSON(arguments: [String: Any]) -> ToolResult {
        guard let data = arguments["data"] else {
            return ToolResult("Missing required parameter: data", isError: true)
        }

        let filename = sanitizeFilename(arguments["filename"] as? String ?? "export_\(timestamp())")

        // Validate it's a valid JSON object
        guard JSONSerialization.isValidJSONObject(data) else {
            // Try wrapping scalar values
            let wrapped = ["value": data]
            guard JSONSerialization.isValidJSONObject(wrapped) else {
                return ToolResult("Data is not valid JSON", isError: true)
            }
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: wrapped, options: [.prettyPrinted, .sortedKeys])
                let json = String(data: jsonData, encoding: .utf8) ?? "{}"
                return writeExport(content: json, filename: filename, extension: "json")
            } catch {
                return ToolResult("JSON serialization failed: \(error.localizedDescription)", isError: true)
            }
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            let json = String(data: jsonData, encoding: .utf8) ?? "{}"
            return writeExport(content: json, filename: filename, extension: "json")
        } catch {
            return ToolResult("JSON serialization failed: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - HTML Report

    private func exportHTMLReport(arguments: [String: Any]) -> ToolResult {
        let title = arguments["title"] as? String ?? "Dockwright Report"
        let sections = arguments["sections"] as? [[String: Any]] ?? []
        let filename = sanitizeFilename(arguments["filename"] as? String ?? "report_\(timestamp())")

        var html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(escapeHTML(title))</title>
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    line-height: 1.6;
                    color: #1d1d1f;
                    max-width: 900px;
                    margin: 0 auto;
                    padding: 40px 20px;
                    background: #fafafa;
                }
                h1 {
                    font-size: 28px;
                    font-weight: 700;
                    margin-bottom: 8px;
                    color: #1d1d1f;
                }
                .meta {
                    color: #86868b;
                    font-size: 13px;
                    margin-bottom: 32px;
                    padding-bottom: 16px;
                    border-bottom: 1px solid #e5e5e7;
                }
                .section {
                    margin-bottom: 32px;
                }
                h2 {
                    font-size: 20px;
                    font-weight: 600;
                    margin-bottom: 12px;
                    color: #1d1d1f;
                }
                p {
                    margin-bottom: 12px;
                    color: #424245;
                }
                table {
                    width: 100%;
                    border-collapse: collapse;
                    margin: 16px 0;
                    font-size: 14px;
                }
                th {
                    background: #f5f5f7;
                    text-align: left;
                    padding: 10px 12px;
                    font-weight: 600;
                    border-bottom: 2px solid #d2d2d7;
                }
                td {
                    padding: 8px 12px;
                    border-bottom: 1px solid #e5e5e7;
                }
                tr:hover td { background: #f5f5f7; }
                .footer {
                    margin-top: 40px;
                    padding-top: 16px;
                    border-top: 1px solid #e5e5e7;
                    color: #86868b;
                    font-size: 12px;
                }
            </style>
        </head>
        <body>
            <h1>\(escapeHTML(title))</h1>
            <div class="meta">Generated by Dockwright on \(formattedDate(Date()))</div>
        """

        if sections.isEmpty {
            html += "    <p>No sections provided.</p>\n"
        }

        for section in sections {
            html += "    <div class=\"section\">\n"

            if let heading = section["heading"] as? String {
                html += "        <h2>\(escapeHTML(heading))</h2>\n"
            }

            if let body = section["body"] as? String {
                let paragraphs = body.components(separatedBy: "\n\n")
                for para in paragraphs {
                    let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        html += "        <p>\(escapeHTML(trimmed))</p>\n"
                    }
                }
            }

            // Table: expects {headers: [String], rows: [[Any]]}
            if let table = section["table"] as? [String: Any],
               let tableHeaders = table["headers"] as? [String],
               let tableRows = table["rows"] as? [[Any]] {
                html += "        <table>\n"
                html += "            <thead><tr>\n"
                for h in tableHeaders {
                    html += "                <th>\(escapeHTML(h))</th>\n"
                }
                html += "            </tr></thead>\n"
                html += "            <tbody>\n"
                for row in tableRows {
                    html += "            <tr>\n"
                    for cell in row {
                        html += "                <td>\(escapeHTML(stringValue(cell)))</td>\n"
                    }
                    html += "            </tr>\n"
                }
                html += "            </tbody>\n"
                html += "        </table>\n"
            }

            html += "    </div>\n"
        }

        html += """
            <div class="footer">
                Exported from Dockwright &mdash; \(formattedDate(Date()))
            </div>
        </body>
        </html>
        """

        return writeExport(content: html, filename: filename, extension: "html")
    }

    // MARK: - Spreadsheet (Numbers-compatible CSV)

    private func createSpreadsheet(arguments: [String: Any]) -> ToolResult {
        guard let headers = arguments["headers"] as? [String] else {
            return ToolResult("Missing required parameter: headers", isError: true)
        }
        guard let rows = arguments["rows"] as? [[Any]] else {
            return ToolResult("Missing required parameter: rows", isError: true)
        }

        let filename = sanitizeFilename(arguments["filename"] as? String ?? "spreadsheet_\(timestamp())")
        let sheetName = arguments["sheet_name"] as? String ?? "Sheet1"

        // Add BOM for Excel/Numbers UTF-8 compatibility
        let bom = "\u{FEFF}"

        var csv = bom
        // Add metadata comment (Numbers ignores these, but useful)
        csv += "# Sheet: \(sheetName)\n"
        csv += "# Generated: \(formattedDate(Date()))\n"
        csv += "# Source: Dockwright\n"

        // Headers
        csv += headers.map { escapeCSV($0) }.joined(separator: ",") + "\n"

        // Data rows
        for row in rows {
            let line = row.map { escapeCSV(stringValue($0)) }.joined(separator: ",")
            csv += line + "\n"
        }

        // Summary row
        csv += "\n# Total rows: \(rows.count)\n"

        return writeExport(content: csv, filename: filename, extension: "csv")
    }

    // MARK: - List Exports

    private func listExports() -> ToolResult {
        let fm = FileManager.default
        let dir = Self.exportDir

        guard fm.fileExists(atPath: dir) else {
            return ToolResult("No exports yet. Export directory does not exist: \(dir)")
        }

        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
            return ToolResult("Cannot list export directory: \(dir)", isError: true)
        }

        if entries.isEmpty {
            return ToolResult("Export directory is empty: \(dir)")
        }

        // Get file info and sort by modification date (newest first)
        var fileInfos: [(name: String, size: UInt64, modified: Date)] = []
        for entry in entries where !entry.hasPrefix(".") {
            let fullPath = (dir as NSString).appendingPathComponent(entry)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath) {
                let size = attrs[.size] as? UInt64 ?? 0
                let modified = attrs[.modificationDate] as? Date ?? Date.distantPast
                fileInfos.append((entry, size, modified))
            }
        }

        fileInfos.sort { $0.modified > $1.modified }

        var lines: [String] = ["Dockwright Exports (\(dir)):"]
        lines.append("")
        for info in fileInfos.prefix(50) {
            let sizeStr = formatBytes(info.size)
            let dateStr = formattedDate(info.modified)
            lines.append("  \(info.name)  (\(sizeStr), \(dateStr))")
        }

        if fileInfos.count > 50 {
            lines.append("  ... and \(fileInfos.count - 50) more files")
        }

        lines.append("")
        lines.append("Total: \(fileInfos.count) file(s)")

        return ToolResult(lines.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private func writeExport(content: String, filename: String, extension ext: String) -> ToolResult {
        let fm = FileManager.default
        let dir = Self.exportDir

        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return ToolResult("Cannot create export directory: \(error.localizedDescription)", isError: true)
        }

        let fullFilename = filename.hasSuffix(".\(ext)") ? filename : "\(filename).\(ext)"
        let path = (dir as NSString).appendingPathComponent(fullFilename)

        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            let size = (content as NSString).length
            Self.logger.info("Exported \(fullFilename) (\(size) chars)")
            return ToolResult("Exported to: \(path) (\(formatBytes(UInt64(content.utf8.count))))")
        } catch {
            return ToolResult("Write failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func stringValue(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let b = value as? Bool { return b ? "true" : "false" }
        return "\(value)"
    }

    private func sanitizeFilename(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "export_\(timestamp())" : String(cleaned.prefix(100))
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: Date())
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
