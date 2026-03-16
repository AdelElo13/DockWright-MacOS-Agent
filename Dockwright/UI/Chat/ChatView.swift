import SwiftUI

/// Main chat view with message list + input.
struct ChatView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if appState.currentConversation.messages.isEmpty {
                emptyState
            } else {
                messageList
            }

            // Streaming indicator
            if appState.isProcessing, let activity = appState.currentActivity {
                StreamingIndicator(activity: activity)
                    .padding(.horizontal, DockwrightTheme.Spacing.xl)
                    .padding(.bottom, DockwrightTheme.Spacing.sm)
                    .transition(.opacity)
            }

            MessageInput(
                isProcessing: appState.isProcessing,
                voiceState: appState.voiceState,
                voiceMode: appState.voiceMode,
                onSend: { text in
                    Task {
                        await appState.sendMessage(text)
                    }
                },
                onStop: {
                    appState.stopProcessing()
                },
                onToggleVoice: {
                    Task {
                        await appState.toggleVoiceMode()
                    }
                }
            )
            .padding(.horizontal, DockwrightTheme.Spacing.lg)
            .padding(.bottom, DockwrightTheme.Spacing.md)
        }
        .background(DockwrightTheme.Surface.canvas)
        .animation(.easeInOut(duration: 0.2), value: appState.isProcessing)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(appState.currentConversation.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, DockwrightTheme.Spacing.lg)
            }
            .onChange(of: appState.currentConversation.messages.count) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: appState.streamingText) {
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastId = appState.currentConversation.messages.last?.id {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DockwrightTheme.Spacing.xxl) {
            Spacer()

            // Logo orb
            ZStack {
                Circle()
                    .fill(DockwrightTheme.orbGradient)
                    .frame(width: 60, height: 60)
                    .blur(radius: 1)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.3), .clear],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 30
                        )
                    )
                    .frame(width: 48, height: 48)
            }

            Text("What can I help you with?")
                .font(DockwrightTheme.Typography.displayMedium)
                .foregroundStyle(.white)

            // Suggestion chips
            HStack(spacing: DockwrightTheme.Spacing.sm) {
                suggestionChip("Summarize my clipboard", icon: "doc.on.clipboard")
                suggestionChip("Search for Swift tutorials", icon: "magnifyingglass")
                suggestionChip("List files in Downloads", icon: "folder")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func suggestionChip(_ text: String, icon: String) -> some View {
        Button {
            Task { await appState.sendMessage(text) }
        } label: {
            HStack(spacing: DockwrightTheme.Spacing.sm) {
                Image(systemName: icon)
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(DockwrightTheme.primary)
                Text(text)
                    .font(DockwrightTheme.Typography.captionMedium)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DockwrightTheme.Spacing.md)
            .padding(.vertical, DockwrightTheme.Spacing.sm)
            .background(DockwrightTheme.Surface.card)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(DockwrightTheme.Opacity.borderSubtle), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
