import SwiftUI

/// Chat text input with send/stop button and mic toggle for voice mode.
/// Enter sends, Shift+Enter inserts newline.
struct MessageInput: View {
    let isProcessing: Bool
    let voiceState: AppState.VoiceState
    let voiceMode: Bool
    let onSend: (String) -> Void
    var onStop: (() -> Void)?
    var onToggleVoice: (() -> Void)?

    @State private var text = ""
    @FocusState private var isFocused: Bool
    @State private var sendHovered = false
    @State private var micHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // Voice state indicator
            if voiceMode {
                voiceIndicator
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
        .background(DockwrightTheme.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    voiceMode && voiceState == .listening
                        ? DockwrightTheme.success.opacity(0.6)
                        : isFocused
                            ? DockwrightTheme.primary.opacity(DockwrightTheme.Opacity.borderFocused)
                            : Color.white.opacity(DockwrightTheme.Opacity.borderSubtle),
                    lineWidth: voiceMode && voiceState == .listening ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(DockwrightTheme.Opacity.shadow), radius: 8, y: 2)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .animation(.easeInOut(duration: 0.2), value: voiceState)
        .onAppear { isFocused = true }
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
                Text(isProcessing ? "Redirect Dockwright..." : "Ask Dockwright anything...")
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
                    // Enter to send (without Shift)
                    guard newValue.hasSuffix("\n"),
                          newValue.count == oldValue.count + 1,
                          !NSEvent.modifierFlags.contains(.shift) else { return }
                    text = String(newValue.dropLast())
                    if canSend {
                        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        text = ""
                        onSend(msg)
                    }
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    if isProcessing {
                        onStop?()
                        return .handled
                    }
                    return .ignored
                }
        }
    }

    // MARK: - Send Button

    private var sendButton: some View {
        Button {
            if canSend {
                let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = ""
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
