import SwiftUI

/// Renders a single chat message as a styled bubble.
struct MessageBubble: View {
    let message: ChatMessage
    @State private var isHovered = false

    var body: some View {
        Group {
            switch message.role {
            case .user:
                userBubble
            case .assistant:
                assistantBubble
            case .error:
                errorBubble
            case .system:
                systemBubble
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }

    // MARK: - User Bubble

    private var userBubble: some View {
        HStack(alignment: .top, spacing: DockwrightTheme.Spacing.lg) {
            Spacer(minLength: 60)

            Text(message.content)
                .font(DockwrightTheme.Typography.body)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, DockwrightTheme.Spacing.lg)
                .background(DockwrightTheme.userBubbleGradient)
                .clipShape(BubbleShape(isUser: true))
                .shadow(color: .black.opacity(DockwrightTheme.Opacity.tintSubtle), radius: 8, y: 2)
                .frame(maxWidth: DockwrightTheme.Layout.maxBubbleWidth, alignment: .trailing)
                .contextMenu {
                    Button { copyToClipboard(message.content) } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }

            // User avatar
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: DockwrightTheme.Layout.avatarSize, height: DockwrightTheme.Layout.avatarSize)
                Image(systemName: "person.fill")
                    .font(DockwrightTheme.Typography.label)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DockwrightTheme.Spacing.xl)
        .padding(.vertical, DockwrightTheme.Spacing.xs)
    }

    // MARK: - Assistant Bubble

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: DockwrightTheme.Spacing.lg) {
            // Avatar
            ZStack {
                Circle()
                    .fill(DockwrightTheme.assistantAvatarGradient)
                    .frame(width: DockwrightTheme.Layout.avatarSize, height: DockwrightTheme.Layout.avatarSize)
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: DockwrightTheme.Spacing.sm) {
                // Tool outputs
                if !message.toolOutputs.isEmpty {
                    ForEach(message.toolOutputs) { output in
                        ToolCardView(output: output)
                    }
                }

                // Content
                if !message.content.isEmpty {
                    Text(LocalizedStringKey(message.content))
                        .font(DockwrightTheme.Typography.body)
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: DockwrightTheme.Layout.maxBubbleWidth, alignment: .leading)
                }

                // Streaming cursor
                if message.isStreaming && message.content.isEmpty && message.toolOutputs.isEmpty {
                    ThinkingDotsView()
                }

                if message.isStreaming && !message.content.isEmpty {
                    StreamingCursorView()
                }

                // Action bar (copy, etc.) on hover
                if !message.isStreaming && isHovered && !message.content.isEmpty {
                    HStack(spacing: DockwrightTheme.Spacing.lg) {
                        Button {
                            copyToClipboard(message.content)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.on.doc")
                                Text("Copy")
                            }
                            .font(DockwrightTheme.Typography.microMedium)
                            .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)

                        Text(relativeTime)
                            .font(DockwrightTheme.Typography.microMono)
                            .foregroundStyle(.quaternary)
                    }
                    .transition(.opacity)
                }
            }

            Spacer(minLength: 60)
        }
        .padding(.horizontal, DockwrightTheme.Spacing.xl)
        .padding(.vertical, DockwrightTheme.Spacing.xs)
    }

    // MARK: - Error Bubble

    private var errorBubble: some View {
        HStack(alignment: .top, spacing: DockwrightTheme.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(DockwrightTheme.error.opacity(DockwrightTheme.Opacity.tintStrong))
                    .frame(width: DockwrightTheme.Layout.avatarSize, height: DockwrightTheme.Layout.avatarSize)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(DockwrightTheme.Typography.label)
                    .foregroundStyle(DockwrightTheme.error)
            }

            Text(message.content)
                .font(DockwrightTheme.Typography.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, DockwrightTheme.Spacing.lg)
                .background(DockwrightTheme.error.opacity(DockwrightTheme.Opacity.tintSubtle))
                .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: DockwrightTheme.Radius.card)
                        .stroke(DockwrightTheme.error.opacity(0.2), lineWidth: 1)
                )
                .frame(maxWidth: DockwrightTheme.Layout.maxBubbleWidth, alignment: .leading)

            Spacer(minLength: 60)
        }
        .padding(.horizontal, DockwrightTheme.Spacing.xl)
        .padding(.vertical, DockwrightTheme.Spacing.xs)
    }

    // MARK: - System Bubble

    private var systemBubble: some View {
        HStack {
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .font(DockwrightTheme.Typography.micro)
                Text(message.content)
                    .font(DockwrightTheme.Typography.captionMedium)
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, DockwrightTheme.Spacing.lg)
            .padding(.vertical, DockwrightTheme.Spacing.xs)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
            Spacer()
        }
        .padding(.vertical, DockwrightTheme.Spacing.xs)
    }

    // MARK: - Helpers

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var relativeTime: String {
        let interval = Date().timeIntervalSince(message.timestamp)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

// MARK: - Thinking Dots

struct ThinkingDotsView: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(phase == i ? DockwrightTheme.primary : DockwrightTheme.primary.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                withAnimation(.easeInOut(duration: 0.3)) {
                    phase = (phase + 1) % 3
                }
            }
        }
    }
}

// MARK: - Streaming Cursor

struct StreamingCursorView: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(DockwrightTheme.primary)
            .frame(width: 2.5, height: 16)
            .opacity(visible ? 1 : 0)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(530))
                    withAnimation(.easeInOut(duration: 0.15)) {
                        visible.toggle()
                    }
                }
            }
    }
}
