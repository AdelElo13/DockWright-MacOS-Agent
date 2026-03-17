import SwiftUI

/// Live agent activity panel — shows real-time tool executions, LLM calls, and agent events.
/// Slides in from the right side of the main view.
struct InspectorPanelView: View {
    let eventLog: AgentEventLog
    let agentState: AgentExecutor.AgentState
    @Binding var isVisible: Bool
    @State private var filterKind: AgentEvent.Kind?
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            eventList
        }
        .frame(width: 320)
        .background(DockwrightTheme.glassBackground.opacity(0.98))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "waveform.badge.magnifyingglass")
                .foregroundStyle(DockwrightTheme.primary)
            Text("Inspector")
                .font(.system(size: 14, weight: .semibold))
            Spacer()

            if !eventLog.events.isEmpty {
                Button {
                    eventLog.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear log")
            }

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isVisible = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Agent Status Badge

    private var agentStatusBadge: some View {
        Group {
            switch agentState {
            case .idle:
                EmptyView()
            case .planning:
                statusPill("Planning...", color: .orange, icon: "brain")
            case .executing(let step, let total, let desc):
                statusPill("Step \(step)/\(total): \(desc.prefix(30))", color: DockwrightTheme.primary, icon: "play.fill")
            case .retrying(let step, let attempt):
                statusPill("Retrying step \(step) (#\(attempt))", color: .orange, icon: "arrow.counterclockwise")
            case .completed:
                statusPill("Completed", color: .green, icon: "checkmark.circle.fill")
            case .cancelled:
                statusPill("Cancelled", color: .secondary, icon: "stop.circle")
            case .failed(let err):
                statusPill("Failed: \(err.prefix(30))", color: .red, icon: "xmark.circle")
            }
        }
    }

    private func statusPill(_ text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                agentStatusBadge

                filterChip(nil, label: "All", count: eventLog.events.count)
                filterChip(.toolStarted, label: "Tools", count: eventLog.events.filter { $0.kind == .toolStarted || $0.kind == .toolCompleted || $0.kind == .toolFailed }.count)
                filterChip(.llmRequest, label: "LLM", count: eventLog.events.filter { $0.kind == .llmRequest || $0.kind == .llmResponse }.count)
                filterChip(.stepStarted, label: "Steps", count: eventLog.events.filter { $0.kind == .stepStarted || $0.kind == .stepCompleted || $0.kind == .stepFailed }.count)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func filterChip(_ kind: AgentEvent.Kind?, label: String, count: Int) -> some View {
        let isSelected = filterKind == kind
        return Button {
            filterKind = isSelected ? nil : kind
        } label: {
            HStack(spacing: 3) {
                Text(label)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? .white : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? DockwrightTheme.primary.opacity(0.8) : Color.secondary.opacity(0.08))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Event List

    private var filteredEvents: [AgentEvent] {
        guard let kind = filterKind else { return eventLog.events }
        switch kind {
        case .toolStarted:
            return eventLog.events.filter { $0.kind == .toolStarted || $0.kind == .toolCompleted || $0.kind == .toolFailed }
        case .llmRequest:
            return eventLog.events.filter { $0.kind == .llmRequest || $0.kind == .llmResponse }
        case .stepStarted:
            return eventLog.events.filter { $0.kind == .stepStarted || $0.kind == .stepCompleted || $0.kind == .stepFailed || $0.kind == .planCreated }
        default:
            return eventLog.events.filter { $0.kind == kind }
        }
    }

    private var eventList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if filteredEvents.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "waveform.slash")
                                .font(.system(size: 28))
                                .foregroundStyle(.tertiary)
                            Text("No activity yet")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Text("Tool calls and agent events\nwill appear here in real time.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 60)
                    } else {
                        ForEach(filteredEvents) { event in
                            EventRowView(event: event)
                                .id(event.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onChange(of: eventLog.events.count) { _, _ in
                if autoScroll, let last = filteredEvents.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Event Row

private struct EventRowView: View {
    let event: AgentEvent
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: event.iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if let toolName = event.toolName {
                            Text(toolName)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(iconColor)
                        } else {
                            Text(event.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                        }

                        if let ms = event.durationMs {
                            Text("\(ms)ms")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        Text(event.timeString)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    Text(event.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(event.isError ? Color.red.opacity(0.06) : Color.clear)
        )
    }

    private var iconColor: Color {
        switch event.kind {
        case .toolStarted:    return .blue
        case .toolCompleted:  return .green
        case .toolFailed:     return .red
        case .llmRequest:     return .purple
        case .llmResponse:    return .purple
        case .planCreated:    return .orange
        case .stepStarted:    return .blue
        case .stepCompleted:  return .green
        case .stepFailed:     return .red
        case .agentStarted:   return DockwrightTheme.primary
        case .agentCompleted: return .green
        case .info:           return .secondary
        }
    }
}
