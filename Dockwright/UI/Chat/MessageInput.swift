import SwiftUI
import UniformTypeIdentifiers

/// Chat text input with send/stop button, mic toggle, drag-and-drop, paste handler, and slash commands.
/// Enter sends, Shift+Enter inserts newline.
struct MessageInput: View {
    let isProcessing: Bool
    let voiceState: AppState.VoiceState
    let voiceMode: Bool
    let onSend: (String) -> Void
    var onStop: (() -> Void)?
    var onToggleVoice: (() -> Void)?
    var onImagePaste: ((NSImage) -> Void)?
    var onFileDrop: (([URL]) -> Void)?
    var onSlashCommand: ((String) -> Void)?

    // Slash command state
    var showSlashCommands: Binding<Bool>?
    var slashFilter: Binding<String>?
    var slashCommands: [AppState.SlashCommand] = []

    @State private var text = ""
    @FocusState private var isFocused: Bool
    @State private var sendHovered = false
    @State private var micHovered = false
    @State private var isDragOver = false
    @State private var pendingImageCount = 0
    @State private var pendingFileNames: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // Voice state indicator
            if voiceMode {
                voiceIndicator
                    .padding(.top, DockwrightTheme.Spacing.sm)
                    .padding(.horizontal, DockwrightTheme.Spacing.md)
            }

            // Pending attachments indicator
            if pendingImageCount > 0 || !pendingFileNames.isEmpty {
                attachmentIndicator
                    .padding(.top, DockwrightTheme.Spacing.sm)
                    .padding(.horizontal, DockwrightTheme.Spacing.md)
            }

            // Slash command autocomplete
            if let showSlash = showSlashCommands?.wrappedValue, showSlash {
                slashCommandList
                    .padding(.top, DockwrightTheme.Spacing.sm)
                    .padding(.horizontal, DockwrightTheme.Spacing.md)
            }

            HStack(alignment: .bottom, spacing: DockwrightTheme.Spacing.sm) {
                micButton

                textEditor

                sendButton
            }
            .padding(.horizontal, DockwrightTheme.Spacing.md)
            .padding(.vertical, DockwrightTheme.Spacing.sm)
        }
        .background(isDragOver ? DockwrightTheme.primary.opacity(0.1) : DockwrightTheme.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isDragOver
                        ? DockwrightTheme.primary.opacity(0.6)
                        : voiceMode && voiceState == .listening
                            ? DockwrightTheme.success.opacity(0.6)
                            : isFocused
                                ? DockwrightTheme.primary.opacity(DockwrightTheme.Opacity.borderFocused)
                                : Color.white.opacity(DockwrightTheme.Opacity.borderSubtle),
                    lineWidth: isDragOver ? 2 : (voiceMode && voiceState == .listening ? 2 : 1)
                )
        )
        .shadow(color: .black.opacity(DockwrightTheme.Opacity.shadow), radius: 8, y: 2)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .animation(.easeInOut(duration: 0.2), value: voiceState)
        .animation(.easeInOut(duration: 0.15), value: isDragOver)
        .onAppear { isFocused = true }
        .onDrop(of: supportedDropTypes, isTargeted: $isDragOver) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Attachment Indicator

    private var attachmentIndicator: some View {
        HStack(spacing: DockwrightTheme.Spacing.xs) {
            if pendingImageCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(DockwrightTheme.primary)
                    Text("\(pendingImageCount) image\(pendingImageCount > 1 ? "s" : "")")
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(DockwrightTheme.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DockwrightTheme.primary.opacity(0.1))
                .clipShape(Capsule())
            }

            ForEach(Array(pendingFileNames.enumerated()), id: \.offset) { _, name in
                HStack(spacing: 4) {
                    Image(systemName: "doc")
                        .font(.caption)
                        .foregroundStyle(DockwrightTheme.accent)
                    Text(name)
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(DockwrightTheme.accent)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DockwrightTheme.accent.opacity(0.1))
                .clipShape(Capsule())
            }

            Spacer()
        }
    }

    // MARK: - Slash Command List

    private var slashCommandList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(slashCommands.prefix(8)) { cmd in
                Button {
                    onSlashCommand?(cmd.command)
                    text = ""
                    showSlashCommands?.wrappedValue = false
                    slashFilter?.wrappedValue = ""
                } label: {
                    HStack(spacing: DockwrightTheme.Spacing.sm) {
                        Image(systemName: cmd.icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DockwrightTheme.primary)
                            .frame(width: 20)
                        Text(cmd.command)
                            .font(DockwrightTheme.Typography.bodyMedium)
                            .foregroundStyle(.white)
                        Text(cmd.label)
                            .font(DockwrightTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, DockwrightTheme.Spacing.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.03))
            }
        }
        .background(DockwrightTheme.Surface.elevated)
        .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Voice Indicator

    private var voiceIndicator: some View {
        HStack(spacing: DockwrightTheme.Spacing.xs) {
            switch voiceState {
            case .idle:
                Image(systemName: "mic.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Voice mode -- press mic to start")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.secondary)

            case .listening:
                Circle()
                    .fill(DockwrightTheme.success)
                    .frame(width: 6, height: 6)
                    .modifier(PulseModifier())
                Text("Listening...")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(DockwrightTheme.success)

            case .transcribing:
                ProgressView()
                    .controlSize(.mini)
                Text("Processing speech...")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(.secondary)

            case .speaking:
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(DockwrightTheme.primary)
                    .symbolEffect(.variableColor.iterative)
                Text("Speaking...")
                    .font(DockwrightTheme.Typography.caption)
                    .foregroundStyle(DockwrightTheme.primary)
            }

            Spacer()
        }
    }

    // MARK: - Mic Button

    private var micButton: some View {
        Button {
            onToggleVoice?()
        } label: {
            ZStack {
                Circle()
                    .fill(
                        voiceMode
                            ? (voiceState == .listening
                                ? AnyShapeStyle(DockwrightTheme.success)
                                : AnyShapeStyle(DockwrightTheme.primary))
                            : AnyShapeStyle(Color.white.opacity(0.1))
                    )
                    .frame(width: DockwrightTheme.Layout.inputButtonSize, height: DockwrightTheme.Layout.inputButtonSize)

                Image(systemName: voiceMode ? (voiceState == .listening ? "mic.fill" : "mic.badge.xmark") : "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(voiceMode ? Color.white : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .opacity(micHovered ? 0.85 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { h in micHovered = h }
        .help(voiceMode ? "Stop voice mode" : "Start voice mode")
    }

    // MARK: - Text Editor

    private var textEditor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(isProcessing ? "Redirect Dockwright..." : "Ask Dockwright anything... (type / for commands)")
                    .font(DockwrightTheme.Typography.body)
                    .foregroundStyle(.secondary)
                    .padding(.leading, DockwrightTheme.Spacing.sm)
                    .padding(.top, DockwrightTheme.Spacing.sm)
            }

            TextEditor(text: $text)
                .font(DockwrightTheme.Typography.body)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .frame(minHeight: 40, maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DockwrightTheme.Spacing.xs)
                .padding(.bottom, DockwrightTheme.Spacing.xs)
                .padding(.horizontal, DockwrightTheme.Spacing.xs)
                .onChange(of: text) { oldValue, newValue in
                    // Slash command detection
                    handleSlashDetection(newValue)

                    // Enter to send (without Shift)
                    guard newValue.hasSuffix("\n"),
                          newValue.count == oldValue.count + 1,
                          !NSEvent.modifierFlags.contains(.shift) else { return }
                    text = String(newValue.dropLast())
                    if canSend {
                        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        text = ""
                        showSlashCommands?.wrappedValue = false
                        onSend(msg)
                    }
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    if showSlashCommands?.wrappedValue == true {
                        showSlashCommands?.wrappedValue = false
                        return .handled
                    }
                    if isProcessing {
                        onStop?()
                        return .handled
                    }
                    return .ignored
                }
                .onPasteCommand(of: [.image, .png, .tiff, .fileURL]) { providers in
                    handlePaste(providers)
                }
        }
    }

    // MARK: - Send Button

    private var sendButton: some View {
        Button {
            if canSend {
                let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = ""
                showSlashCommands?.wrappedValue = false
                onSend(msg)
            } else if isProcessing {
                onStop?()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        isProcessing && !canSend
                            ? AnyShapeStyle(DockwrightTheme.error)
                            : canSend
                                ? AnyShapeStyle(Color.white)
                                : AnyShapeStyle(Color.white.opacity(0.15))
                    )
                    .frame(width: DockwrightTheme.Layout.inputButtonSize, height: DockwrightTheme.Layout.inputButtonSize)

                Image(systemName: isProcessing ? (canSend ? "arrow.uturn.forward" : "stop.fill") : "arrow.up")
                    .font(.system(size: isProcessing && !canSend ? 10 : 12, weight: .bold))
                    .foregroundStyle(
                        isProcessing && !canSend
                            ? Color.white
                            : canSend
                                ? Color.black
                                : Color(nsColor: .tertiaryLabelColor)
                    )
                    .contentTransition(.symbolEffect(.replace))
            }
            .opacity(sendHovered && (canSend || isProcessing) ? 0.85 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !isProcessing)
        .keyboardShortcut(.return, modifiers: .command)
        .onHover { h in sendHovered = h }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Slash Command Detection

    private func handleSlashDetection(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") && !trimmed.contains(" ") {
            showSlashCommands?.wrappedValue = true
            slashFilter?.wrappedValue = String(trimmed.dropFirst())
        } else {
            showSlashCommands?.wrappedValue = false
        }
    }

    // MARK: - Drag & Drop

    private var supportedDropTypes: [UTType] {
        [.image, .png, .jpeg, .gif, .fileURL, .plainText, .utf8PlainText]
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handledAny = false

        for provider in providers {
            // Image drop
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    Task { @MainActor in
                        onImagePaste?(image)
                        pendingImageCount += 1
                    }
                }
                handledAny = true
                continue
            }

            // File URL drop
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        onFileDrop?([url])
                        pendingFileNames.append(url.lastPathComponent)
                    }
                }
                handledAny = true
            }
        }

        return handledAny
    }

    // MARK: - Paste Handler

    private func handlePaste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in
                        onImagePaste?(image)
                        pendingImageCount += 1
                    }
                }
            }
        }
    }
}

// MARK: - Pulse Animation Modifier

private struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
