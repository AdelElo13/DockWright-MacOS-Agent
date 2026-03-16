import Foundation

// MARK: - Tool Protocol

nonisolated protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parametersSchema: [String: Any] { get }
    func execute(arguments: [String: Any]) async throws -> ToolResult
}

// MARK: - Tool Result

struct ToolResult: Sendable {
    let output: String
    let isError: Bool

    init(_ output: String, isError: Bool = false) {
        self.output = output
        self.isError = isError
    }
}

// MARK: - Tool Registry

final class ToolRegistry: @unchecked Sendable {
    static let shared = ToolRegistry()

    private let lock = NSLock()
    private var tools: [String: any Tool] = [:]

    private init() {
        // Register built-in tools
        register(ShellTool())
        register(FileTool())
        register(WebSearchTool())
    }

    func register(_ tool: any Tool) {
        lock.withLock {
            tools[tool.name] = tool
        }
    }

    func get(name: String) -> (any Tool)? {
        lock.withLock { tools[name] }
    }

    var allTools: [any Tool] {
        lock.withLock { Array(tools.values) }
    }

    /// Generate Anthropic-format tool definitions array.
    func anthropicToolDefinitions() -> [[String: Any]] {
        let toolList = allTools
        return toolList.map { tool in
            [
                "name": sanitizeName(tool.name),
                "description": tool.description,
                "input_schema": [
                    "type": "object",
                    "properties": tool.parametersSchema,
                    "required": requiredParams(from: tool.parametersSchema)
                ] as [String: Any]
            ] as [String: Any]
        }
    }

    /// Sanitize tool name to match Anthropic's pattern: ^[a-zA-Z0-9_-]{1,64}$
    private func sanitizeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let sanitized = String(name.unicodeScalars.filter { allowed.contains($0) })
        return String(sanitized.prefix(64))
    }

    /// Extract required parameters from schema (those without "default" key).
    private func requiredParams(from schema: [String: Any]) -> [String] {
        schema.compactMap { key, value in
            guard let propDict = value as? [String: Any] else { return nil }
            if propDict["optional"] as? Bool == true { return nil }
            return key
        }
    }
}
