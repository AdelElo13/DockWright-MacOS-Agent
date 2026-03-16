import SwiftUI
import UniformTypeIdentifiers

/// Main chat view with message list + input, drag & drop support, and agent mode indicator.
struct ChatView: View {
    @Bindable var appState: AppState
    @State private var isDragOver = false

    // Text file extensions we can read
    private static let readableExtensions: Set<String> = [
        "txt", "swift", "py", "js", "ts", "jsx", "tsx", "json", "md", "csv",
        "html", "css", "xml", "yaml", "yml", "toml", "sh", "bash", "zsh",
        "rb", "go", "rs", "java", "kt", "c", "cpp", "h", "hpp", "m",
        "sql", "r", "lua", "pl", "php", "env", "conf", "ini", "log",
        "gitignore", "dockerfile", "makefile"
    ]

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Agent mode banner
            if appState.agentMode {
                agentBanner
            }

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
                },
                onImagePaste: { image in
                    handleImagePaste(image)
                },
                onFileDrop: { urls in
                    handleFileDrop(urls)
                },
                onSlashCommand: { command in
                    Task {
                        await appState.executeSlashCommand(command)
                    }
                },
                showSlashCommands: $appState.showSlashCommands,
                slashFilter: $appState.slashFilter,
                slashCommands: appState.filteredSlashCommands
            )
            .padding(.horizontal, DockwrightTheme.Spacing.lg)
            .padding(.bottom, DockwrightTheme.Spacing.md)
        }
        .background(isDragOver ? DockwrightTheme.primary.opacity(0.05) : DockwrightTheme.Surface.canvas)
        .overlay {
            if isDragOver {
                dropOverlay
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDragOver) { providers in
            handleViewDrop(providers)
        }
        .animation(.easeInOut(duration: 0.2), value: appState.isProcessing)
        .animation(.easeInOut(duration: 0.2), value: isDragOver)
    }

    // MARK: - Agent Mode Banner

    private var agentBanner: some View {
        HStack(spacing: DockwrightTheme.Spacing.sm) {
            Image(systemName: "brain")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DockwrightTheme.secondary)
            Text("Agent Mode")
                .font(DockwrightTheme.Typography.captionMedium)
                .foregroundStyle(DockwrightTheme.secondary)

            if case .executing(let step, let total, let desc) = appState.agentState {
                Text("Step \(step)/\(total): \(desc)")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                appState.agentMode = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DockwrightTheme.Spacing.lg)
        .padding(.vertical, DockwrightTheme.Spacing.xs)
        .background(DockwrightTheme.secondary.opacity(0.08))
    }

    // MARK: - Drop Overlay

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .stroke(DockwrightTheme.primary, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                .padding(DockwrightTheme.Spacing.lg)

            VStack(spacing: DockwrightTheme.Spacing.md) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(DockwrightTheme.primary)
                Text("Drop files or images here")
                    .font(DockwrightTheme.Typography.heading)
                    .foregroundStyle(DockwrightTheme.primary)
                Text("Images, code files, text files, and folders supported")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .background(DockwrightTheme.Surface.canvas.opacity(0.9))
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
            VStack(spacing: DockwrightTheme.Spacing.sm) {
                HStack(spacing: DockwrightTheme.Spacing.sm) {
                    suggestionChip("Summarize my clipboard", icon: "doc.on.clipboard")
                    suggestionChip("Search for Swift tutorials", icon: "magnifyingglass")
                    suggestionChip("List files in Downloads", icon: "folder")
                }
                HStack(spacing: DockwrightTheme.Spacing.sm) {
                    suggestionChip("Show system info", icon: "desktopcomputer")
                    suggestionChip("Watch Downloads for changes", icon: "eye")
                    suggestionChip("Toggle dark mode", icon: "moon")
                }
            }

            // Drag & drop hint
            HStack(spacing: DockwrightTheme.Spacing.xs) {
                Image(systemName: "arrow.down.doc")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                Text("Drop images or files to include them")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.quaternary)
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

    // MARK: - Image & File Handling

    private func handleImagePaste(_ image: NSImage) {
        if let imageContent = VisionTool.encodeImage(image) {
            appState.pendingImages.append(imageContent)
        }
    }

    private func handleFileDrop(_ urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()

            if Self.imageExtensions.contains(ext) {
                // Image file — encode for vision
                if let data = try? Data(contentsOf: url) {
                    let mediaType: String
                    switch ext {
                    case "png": mediaType = "image/png"
                    case "jpg", "jpeg": mediaType = "image/jpeg"
                    case "gif": mediaType = "image/gif"
                    case "webp": mediaType = "image/webp"
                    default: mediaType = "image/png"
                    }
                    let imageContent = VisionTool.encodeData(data, mediaType: mediaType)
                    appState.pendingImages.append(imageContent)
                }
            } else if Self.readableExtensions.contains(ext) || ext.isEmpty {
                // Text file — read content
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    let truncated = String(content.prefix(50_000))
                    appState.pendingFileContents.append((name: url.lastPathComponent, content: truncated))
                }
            } else {
                // Unknown file — just report the path
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    // Directory — list contents
                    if let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
                        let listing = items.sorted().prefix(100).joined(separator: "\n")
                        appState.pendingFileContents.append(
                            (name: "\(url.lastPathComponent)/", content: "Directory contents:\n\(listing)")
                        )
                    }
                } else {
                    appState.pendingFileContents.append(
                        (name: url.lastPathComponent, content: "[Binary file at \(url.path)]")
                    )
                }
            }
        }
    }

    private func handleViewDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        handleFileDrop([url])
                    }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    Task { @MainActor in
                        handleImagePaste(image)
                    }
                }
                handled = true
            }
        }

        return handled
    }
}
