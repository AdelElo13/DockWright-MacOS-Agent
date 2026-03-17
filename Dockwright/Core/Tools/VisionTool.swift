import Foundation
import AppKit

/// Vision tool: encode images as base64 for Claude's vision API.
/// Supports reading from file paths and clipboard.
struct VisionTool: Tool, Sendable {
    let name = "vision"
    let description = "Analyze images using AI vision. Can read images from file paths or the clipboard. Returns base64-encoded image data for the LLM to analyze."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "Action: 'analyze_file' (read image from path), 'analyze_clipboard' (read image from clipboard)",
            "enum": ["analyze_file", "analyze_clipboard"]
        ] as [String: Any],
        "path": [
            "type": "string",
            "description": "Path to image file (for analyze_file action)",
            "optional": true
        ] as [String: Any],
        "question": [
            "type": "string",
            "description": "Question about the image (optional, default: 'Describe this image')",
            "optional": true
        ] as [String: Any]
    ]

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Missing required parameter: action", isError: true)
        }

        switch action {
        case "analyze_file":
            guard let path = arguments["path"] as? String else {
                return ToolResult("Missing required parameter: path for analyze_file", isError: true)
            }
            let expandedPath = (path as NSString).expandingTildeInPath
            return await encodeImageFile(at: expandedPath)

        case "analyze_clipboard":
            return await encodeClipboardImage()

        default:
            return ToolResult("Unknown action: \(action). Use: analyze_file, analyze_clipboard", isError: true)
        }
    }

    // MARK: - Image Encoding

    /// Max raw bytes before we downscale — keeps base64 under ~1.3MB (~350K tokens).
    private static let maxImageBytes = 1_000_000

    private func encodeImageFile(at path: String) async -> ToolResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return ToolResult("Image file not found: \(path)", isError: true)
        }

        guard let data = fm.contents(atPath: path) else {
            return ToolResult("Cannot read image file: \(path)", isError: true)
        }

        // 20MB limit
        guard data.count < 20_000_000 else {
            return ToolResult("Image too large (\(data.count / 1_000_000)MB). Max 20MB.", isError: true)
        }

        let mediaType = detectMediaType(path: path, data: data)
        guard mediaType != "unknown" else {
            return ToolResult("Unsupported image format. Supported: PNG, JPEG, GIF, WebP.", isError: true)
        }

        // Downscale large images to stay within API token limits
        let finalData: Data
        let finalMediaType: String
        if data.count > Self.maxImageBytes, let image = NSImage(contentsOfFile: path) {
            let scale = sqrt(Double(Self.maxImageBytes) / Double(data.count))
            let newSize = NSSize(
                width: max(1, image.size.width * scale),
                height: max(1, image.size.height * scale)
            )
            let resized = NSImage(size: newSize)
            resized.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: newSize),
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .copy, fraction: 1.0)
            resized.unlockFocus()

            if let tiff = resized.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                finalData = jpeg
                finalMediaType = "image/jpeg"
            } else {
                finalData = data
                finalMediaType = mediaType
            }
        } else {
            finalData = data
            finalMediaType = mediaType
        }

        let base64 = finalData.base64EncodedString()
        return ToolResult("[IMAGE_BASE64:\(finalMediaType):\(base64)]")
    }

    private func encodeClipboardImage() async -> ToolResult {
        let pb = NSPasteboard.general

        // Try to get image from clipboard and downscale if needed
        if let image = NSImage(pasteboard: pb) {
            if let encoded = Self.encodeImage(image) {
                return ToolResult("[IMAGE_BASE64:\(encoded.mediaType):\(encoded.data)]")
            }
        }

        // Try file URL on clipboard
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) {
                    return await encodeImageFile(at: url.path)
                }
            }
        }

        return ToolResult("No image found on clipboard.", isError: true)
    }

    private func detectMediaType(path: String, data: Data) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default:
            // Detect by magic bytes
            if data.count >= 4 {
                let bytes = [UInt8](data.prefix(4))
                if bytes[0] == 0x89 && bytes[1] == 0x50 { return "image/png" }
                if bytes[0] == 0xFF && bytes[1] == 0xD8 { return "image/jpeg" }
                if bytes[0] == 0x47 && bytes[1] == 0x49 { return "image/gif" }
                if bytes[0] == 0x52 && bytes[1] == 0x49 { return "image/webp" }
            }
            return "unknown"
        }
    }

    // MARK: - Static Helpers

    /// Encode an NSImage to base64 PNG for the LLM API.
    static func encodeImage(_ image: NSImage) -> ImageContent? {
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            return nil
        }

        // Resize if too large (keep under 5MB base64)
        let maxBytes = 3_750_000 // ~5MB base64
        let finalData: Data
        if pngData.count > maxBytes {
            // Downscale
            let scale = sqrt(Double(maxBytes) / Double(pngData.count))
            let newSize = NSSize(
                width: image.size.width * scale,
                height: image.size.height * scale
            )
            let resized = NSImage(size: newSize)
            resized.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: newSize),
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .copy, fraction: 1.0)
            resized.unlockFocus()

            guard let resizedTiff = resized.tiffRepresentation,
                  let resizedBitmap = NSBitmapImageRep(data: resizedTiff),
                  let jpegData = resizedBitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                return nil
            }
            finalData = jpegData
            return ImageContent(
                type: "base64",
                mediaType: "image/jpeg",
                data: finalData.base64EncodedString()
            )
        } else {
            finalData = pngData
        }

        return ImageContent(
            type: "base64",
            mediaType: "image/png",
            data: finalData.base64EncodedString()
        )
    }

    /// Encode raw Data to ImageContent with auto-detected type.
    static func encodeData(_ data: Data, mediaType: String = "image/png") -> ImageContent {
        ImageContent(
            type: "base64",
            mediaType: mediaType,
            data: data.base64EncodedString()
        )
    }

    /// Check if clipboard contains an image.
    static func clipboardHasImage() -> Bool {
        let pb = NSPasteboard.general
        return pb.data(forType: .png) != nil ||
               pb.data(forType: .tiff) != nil
    }

    /// Get clipboard image as NSImage.
    static func clipboardImage() -> NSImage? {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) {
            return NSImage(data: data)
        }
        if let data = pb.data(forType: .tiff) {
            return NSImage(data: data)
        }
        return nil
    }
}
