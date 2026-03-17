import Foundation

/// Structured event log for agent/tool activity — drives the Inspector Panel.
/// All events are timestamped and categorized for real-time display.

struct AgentEvent: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let kind: Kind
    let detail: String
    let toolName: String?
    let isError: Bool
    let durationMs: Int?

    enum Kind: String, Sendable, CaseIterable {
        case toolStarted     = "tool_started"
        case toolCompleted   = "tool_completed"
        case toolFailed      = "tool_failed"
        case llmRequest      = "llm_request"
        case llmResponse     = "llm_response"
        case planCreated     = "plan_created"
        case stepStarted     = "step_started"
        case stepCompleted   = "step_completed"
        case stepFailed      = "step_failed"
        case agentStarted    = "agent_started"
        case agentCompleted  = "agent_completed"
        case info            = "info"
    }

    init(
        kind: Kind,
        detail: String,
        toolName: String? = nil,
        isError: Bool = false,
        durationMs: Int? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.kind = kind
        self.detail = detail
        self.toolName = toolName
        self.isError = isError
        self.durationMs = durationMs
    }

    /// SF Symbol name for this event kind.
    var iconName: String {
        switch kind {
        case .toolStarted:    return "gearshape.arrow.triangle.2.circlepath"
        case .toolCompleted:  return "checkmark.circle.fill"
        case .toolFailed:     return "xmark.circle.fill"
        case .llmRequest:     return "arrow.up.circle"
        case .llmResponse:    return "arrow.down.circle"
        case .planCreated:    return "list.bullet.clipboard"
        case .stepStarted:    return "play.circle"
        case .stepCompleted:  return "checkmark.diamond.fill"
        case .stepFailed:     return "exclamationmark.triangle.fill"
        case .agentStarted:   return "brain"
        case .agentCompleted: return "flag.checkered"
        case .info:           return "info.circle"
        }
    }

    /// Short human-readable label.
    var label: String {
        switch kind {
        case .toolStarted:    return "Tool Started"
        case .toolCompleted:  return "Tool Done"
        case .toolFailed:     return "Tool Failed"
        case .llmRequest:     return "LLM Request"
        case .llmResponse:    return "LLM Response"
        case .planCreated:    return "Plan Created"
        case .stepStarted:    return "Step Started"
        case .stepCompleted:  return "Step Done"
        case .stepFailed:     return "Step Failed"
        case .agentStarted:   return "Agent Started"
        case .agentCompleted: return "Agent Done"
        case .info:           return "Info"
        }
    }

    /// Compact time string like "14:32:05".
    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

/// Observable event log that UI binds to. Thread-safe for MainActor.
@Observable
final class AgentEventLog {
    var events: [AgentEvent] = []
    private let maxEvents = 500

    func append(_ event: AgentEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    func clear() {
        events.removeAll()
    }

    /// Convenience: log a tool start event.
    func toolStarted(name: String, args: [String: Any]) {
        let argsPreview = args.keys.sorted().prefix(3).joined(separator: ", ")
        append(AgentEvent(kind: .toolStarted, detail: "Calling \(name)(\(argsPreview))", toolName: name))
    }

    /// Convenience: log a tool completion.
    func toolCompleted(name: String, output: String, durationMs: Int) {
        let preview = String(output.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        append(AgentEvent(
            kind: .toolCompleted,
            detail: preview,
            toolName: name,
            durationMs: durationMs
        ))
    }

    /// Convenience: log a tool failure.
    func toolFailed(name: String, error: String) {
        append(AgentEvent(kind: .toolFailed, detail: error, toolName: name, isError: true))
    }

    /// Convenience: log an LLM request.
    func llmRequest(model: String, messageCount: Int) {
        append(AgentEvent(kind: .llmRequest, detail: "\(model) — \(messageCount) messages"))
    }

    /// Convenience: log an LLM response.
    func llmResponse(model: String, tokens: Int, toolCalls: Int) {
        let detail = toolCalls > 0
            ? "\(tokens) tokens, \(toolCalls) tool call(s)"
            : "\(tokens) tokens"
        append(AgentEvent(kind: .llmResponse, detail: detail))
    }

    /// Convenience: log agent plan creation.
    func planCreated(goal: String, steps: Int) {
        append(AgentEvent(kind: .planCreated, detail: "\(steps) steps — \(goal.prefix(80))"))
    }

    /// Active tool count (started but not yet completed/failed).
    var activeToolCount: Int {
        var active = Set<String>()
        for event in events.reversed() {
            switch event.kind {
            case .toolStarted:
                if let name = event.toolName, !active.contains(name) {
                    // Only count if not already completed
                    active.insert(name)
                }
            case .toolCompleted, .toolFailed:
                if let name = event.toolName {
                    active.remove(name)
                }
            default:
                break
            }
        }
        return active.count
    }
}
