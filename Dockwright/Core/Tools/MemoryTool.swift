import Foundation

/// LLM tool for searching and saving to persistent memory.
/// Actions: memory_search, memory_save, memory_list
struct MemoryTool: Tool {
    nonisolated let name = "memory"
    nonisolated let description = "Search, save, and list persistent memories. Use 'save' to remember facts about the user or important information. Use 'search' to recall previously saved information. Use 'list' to see recent memories."

    nonisolated let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "Action to perform: 'search', 'save', or 'list'",
            "enum": ["search", "save", "list"]
        ] as [String: Any],
        "query": [
            "type": "string",
            "description": "Search query (for 'search' action) or content to save (for 'save' action)",
            "optional": true
        ] as [String: Any],
        "category": [
            "type": "string",
            "description": "Category for organizing facts: 'preference', 'fact', 'context', 'general'. Default: 'general'",
            "optional": true
        ] as [String: Any]
    ]

    private let store: MemoryStore

    init(store: MemoryStore) {
        self.store = store
    }

    nonisolated func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult("Error: 'action' parameter is required. Use 'search', 'save', or 'list'.", isError: true)
        }

        switch action {
        case "search":
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                return ToolResult("Error: 'query' parameter is required for search.", isError: true)
            }
            do {
                let results = try store.search(query: query)
                return ToolResult(results)
            } catch {
                return ToolResult("Error searching memory: \(error.localizedDescription)", isError: true)
            }

        case "save":
            guard let content = arguments["query"] as? String, !content.isEmpty else {
                return ToolResult("Error: 'query' parameter is required for save (contains the content to save).", isError: true)
            }
            let category = arguments["category"] as? String ?? "general"
            do {
                try store.saveFact(content: content, category: category)
                return ToolResult("Saved to memory: \"\(content)\" [category: \(category)]")
            } catch let error as MemoryError {
                // Poison guard rejection — inform the LLM why it was blocked
                return ToolResult("Memory save blocked: \(error.localizedDescription)", isError: true)
            } catch {
                return ToolResult("Error saving to memory: \(error.localizedDescription)", isError: true)
            }

        case "list":
            let category = arguments["category"] as? String
            do {
                let facts = try store.listFacts(category: category, limit: 20)
                if facts.isEmpty {
                    return ToolResult("No memories stored yet.")
                }
                var output = "Stored memories (\(facts.count)):\n"
                for fact in facts {
                    output += "- [\(fact.category)] \(fact.content) (saved: \(fact.createdAt))\n"
                }
                return ToolResult(output)
            } catch {
                return ToolResult("Error listing memories: \(error.localizedDescription)", isError: true)
            }

        default:
            return ToolResult("Unknown action '\(action)'. Use 'search', 'save', or 'list'.", isError: true)
        }
    }
}
