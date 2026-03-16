import Foundation

// MARK: - LLM Message (API-level)

struct LLMMessage: Codable, Sendable {
    let role: String  // "system", "user", "assistant", "tool"
    var content: String?
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    var images: [ImageContent]?

    // Convenience constructors
    static func system(_ text: String) -> LLMMessage {
        LLMMessage(role: "system", content: text)
    }

    static func user(_ text: String) -> LLMMessage {
        LLMMessage(role: "user", content: text)
    }

    static func assistant(_ text: String, toolCalls: [ToolCall]? = nil) -> LLMMessage {
        LLMMessage(role: "assistant", content: text, toolCalls: toolCalls)
    }

    static func tool(callId: String, content: String) -> LLMMessage {
        LLMMessage(role: "tool", content: content, toolCallId: callId)
    }
}

// MARK: - Tool Call

struct ToolCall: Codable, Sendable {
    let id: String
    let type: String  // always "function"
    let function: ToolCallFunction
}

struct ToolCallFunction: Codable, Sendable {
    let name: String
    let arguments: String  // JSON string
}

// MARK: - Image Content

struct ImageContent: Codable, Sendable {
    let type: String       // "base64"
    let mediaType: String  // "image/png"
    let data: String
}

// MARK: - LLM Response

struct LLMResponse: Sendable {
    let content: String?
    let toolCalls: [ToolCall]?
    let finishReason: String?
    let inputTokens: Int
    let outputTokens: Int
    var thinkingContent: String?
}

// MARK: - Stream Events

enum StreamChunk: Sendable {
    case textDelta(String)
    case toolStarted(String)
    case toolCompleted(name: String, preview: String, output: String)
    case toolFailed(name: String, error: String)
    case thinking(String)
    case activity(StreamActivity)
    case done(String)
}

enum StreamActivity: Sendable, Equatable {
    case thinking
    case searching(String)
    case reading(String)
    case executing(String)
    case generating
}

// MARK: - Chat Message (UI Display)

struct ChatMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date
    var isStreaming: Bool
    var toolOutputs: [ToolOutput]
    var thinkingContent: String

    init(role: MessageRole, content: String, isStreaming: Bool = false) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isStreaming = isStreaming
        self.toolOutputs = []
        self.thinkingContent = ""
    }
}

enum MessageRole: String, Codable, Sendable {
    case user, assistant, system, error
}

// MARK: - Tool Output

struct ToolOutput: Identifiable, Codable, Sendable {
    let id: UUID
    let toolName: String
    let output: String
    let isError: Bool
    let timestamp: Date

    init(toolName: String, output: String, isError: Bool = false) {
        self.id = UUID()
        self.toolName = toolName
        self.output = output
        self.isError = isError
        self.timestamp = Date()
    }
}

// MARK: - Conversation

struct Conversation: Identifiable, Codable, Sendable {
    let id: String
    var title: String
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date

    init(title: String = "New Chat") {
        self.id = "conv_\(UUID().uuidString.prefix(12).lowercased())"
        self.title = title
        self.messages = []
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    mutating func touch() {
        updatedAt = Date()
    }
}

// MARK: - Conversation Summary

struct ConversationSummary: Identifiable, Codable, Sendable {
    let id: String
    var title: String
    var preview: String
    var messageCount: Int
    var createdAt: Date
    var updatedAt: Date

    init(from conversation: Conversation) {
        self.id = conversation.id
        self.title = conversation.title
        self.preview = conversation.messages.last(where: { $0.role == .user })?.content.prefix(100).description ?? ""
        self.messageCount = conversation.messages.count
        self.createdAt = conversation.createdAt
        self.updatedAt = conversation.updatedAt
    }
}
