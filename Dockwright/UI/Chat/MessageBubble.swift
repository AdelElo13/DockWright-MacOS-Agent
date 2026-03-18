import SwiftUI

/// Renders a single chat message — ChatGPT-style layout:
///   User: right-aligned dark pill
///   Assistant: left-aligned plain text, no bubble
struct MessageBubble: View {
    let message: ChatMessage
    @State private var isHovered = false

    /// User-configurable chat font size from Settings → General.
    private var chatFont: Font { .system(size: AppPreferences.shared.chatFontSize) }

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

    // MARK: - User Bubble (right-aligned dark pill)

    private var userBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 80)

            VStack(alignment: .trailing, spacing: 6) {
                // Attached images
                ForEach(Array(message.images.enumerated()), id: \.offset) { _, img in
                    if let nsImage = imageFromBase64(img) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 240, maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                if !message.content.isEmpty {
                    Text(message.content)
                        .font(chatFont)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .contextMenu {
                            Button { copyToClipboard(message.content) } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                }
            }

            userAvatar
        }
        .padding(.horizontal, DockwrightTheme.Spacing.xl)
        .padding(.vertical, DockwrightTheme.Spacing.sm)
    }

    // MARK: - Assistant Bubble (left-aligned, no background)

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 8) {
        assistantAvatar
        VStack(alignment: .leading, spacing: DockwrightTheme.Spacing.sm) {
            // Tool outputs
            if !message.toolOutputs.isEmpty {
                ForEach(message.toolOutputs) { output in
                    ToolCardView(output: output)
                }
            }

            // Thinking content (shown when "Show agent thinking" is on)
            if !message.thinkingContent.isEmpty,
               UserDefaults.standard.object(forKey: "showAgentThinking") as? Bool ?? true {
                DisclosureGroup {
                    Text(message.thinkingContent)
                        .font(.system(size: AppPreferences.shared.chatFontSize - 1))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Thinking", systemImage: "brain")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .tint(.secondary)
            }

            // Content — displayContent strips ##, |---|, --- etc. always
            if !message.content.isEmpty {
                Group {
                    if message.isStreaming {
                        Text(message.displayContent)
                    } else {
                        Text(LocalizedStringKey(message.displayContent))
                    }
                }
                .font(chatFont)
                .foregroundStyle(.primary.opacity(0.92))
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

            // Action bar on hover
            if !message.isStreaming && isHovered && !message.content.isEmpty {
                HStack(spacing: DockwrightTheme.Spacing.md) {
                    Button { copyToClipboard(message.content) } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
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
        } // HStack
        .padding(.horizontal, DockwrightTheme.Spacing.xl)
        .padding(.trailing, 80)
        .padding(.vertical, DockwrightTheme.Spacing.sm)
    }

    // MARK: - Error Bubble

    private var errorBubble: some View {
        HStack(alignment: .top, spacing: DockwrightTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(DockwrightTheme.error)

            Text(message.content)
                .font(chatFont)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: DockwrightTheme.Layout.maxBubbleWidth, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(DockwrightTheme.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DockwrightTheme.error.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, DockwrightTheme.Spacing.xl)
        .padding(.trailing, 80)
        .padding(.vertical, DockwrightTheme.Spacing.sm)
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
            .background(Color.primary.opacity(0.04))
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

    private func imageFromBase64(_ img: ImageContent) -> NSImage? {
        guard let data = Data(base64Encoded: img.data) else { return nil }
        return NSImage(data: data)
    }

    private var relativeTime: String {
        let interval = Date().timeIntervalSince(message.timestamp)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    // MARK: - Avatars

    private var userAvatar: some View {
        Group {
            if let img = ProfileSettingsView.loadUserAvatar() {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
            } else {
                let name = AppPreferences.shared.userName
                if name.isEmpty {
                    Circle()
                        .fill(DockwrightTheme.primary.opacity(0.15))
                        .frame(width: 26, height: 26)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(DockwrightTheme.primary.opacity(0.5))
                        }
                } else {
                    let parts = name.split(separator: " ")
                    let initials = "\(parts.first?.prefix(1) ?? "")\(parts.count > 1 ? parts.last!.prefix(1) : "")".uppercased()
                    Circle()
                        .fill(DockwrightTheme.primary.opacity(0.2))
                        .frame(width: 26, height: 26)
                        .overlay {
                            Text(initials)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DockwrightTheme.primary)
                        }
                }
            }
        }
    }

    private var assistantAvatar: some View {
        ProfileSettingsView.dockwrightAvatarView(size: 26)
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
        .background(Color.primary.opacity(0.06))
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
