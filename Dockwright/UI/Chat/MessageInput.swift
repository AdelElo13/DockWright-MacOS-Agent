import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Localized input placeholder strings.
enum InputStrings {
    private static var lang: String { VoiceService.effectiveLanguage }

    static var placeholder: String {
        if lang.hasPrefix("nl") { return "Vraag Dockwright iets, + om bij te voegen, 🎤 om te dicteren" }
        if lang.hasPrefix("de") { return "Frag Dockwright etwas, + zum Anhängen, 🎤 zum Diktieren" }
        if lang.hasPrefix("fr") { return "Demandez à Dockwright, + pour joindre, 🎤 pour dicter" }
        if lang.hasPrefix("es") { return "Pregunta a Dockwright, + para adjuntar, 🎤 para dictar" }
        return "Ask Dockwright anything, + to attach, 🎤 to dictate"
    }

    static var redirect: String {
        if lang.hasPrefix("nl") { return "Stuur Dockwright bij..." }
        if lang.hasPrefix("de") { return "Dockwright umleiten..." }
        if lang.hasPrefix("fr") { return "Rediriger Dockwright..." }
        if lang.hasPrefix("es") { return "Redirigir Dockwright..." }
        return "Redirect Dockwright..."
    }
}

/// Chat text input with send/stop button, mic toggle, drag-and-drop, paste handler, and slash commands.
/// Enter sends, Shift+Enter inserts newline.
struct MessageInput: View {
    let isProcessing: Bool
    let voiceState: AppState.VoiceState
    let voiceMode: Bool
    let onSend: (String) -> Void
    var onStop: (() -> Void)?
    var onToggleVoice: (() -> Void)?
    var onToggleVoiceConversation: (() -> Void)?
    var onImagePaste: ((NSImage) -> Void)?
    var onFileDrop: (([URL]) -> Void)?
    var onSlashCommand: ((String) -> Void)?
    var onClearImages: (() -> Void)?

    // Slash command state
    var showSlashCommands: Binding<Bool>?
    var slashFilter: Binding<String>?
    var slashCommands: [AppState.SlashCommand] = []

    @Binding var text: String
    @FocusState private var isFocused: Bool
    @State private var sendHovered = false
    @State private var micHovered = false
    @State private var attachHovered = false
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

            // Text input row (full width)
            HStack(alignment: .bottom, spacing: DockwrightTheme.Spacing.sm) {
                textEditor
            }
            .padding(.horizontal, DockwrightTheme.Spacing.md)
            .padding(.top, DockwrightTheme.Spacing.sm)

            // Controls row: plus | voice | spacer | mic | send
            HStack(spacing: DockwrightTheme.Spacing.sm) {
                plusMenuButton
                voiceConversationButton
                Spacer()
                micButton
                sendButton
            }
            .padding(.horizontal, DockwrightTheme.Spacing.md)
            .padding(.vertical, DockwrightTheme.Spacing.sm)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isDragOver ? DockwrightTheme.primary.opacity(0.1) : DockwrightTheme.Surface.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isDragOver
                        ? DockwrightTheme.primary.opacity(0.6)
                        : voiceMode && voiceState == .listening
                            ? DockwrightTheme.success.opacity(0.6)
                            : isFocused
                                ? DockwrightTheme.primary.opacity(DockwrightTheme.Opacity.borderFocused)
                                : Color.primary.opacity(DockwrightTheme.Opacity.borderSubtle),
                    lineWidth: isDragOver ? 2 : (voiceMode && voiceState == .listening ? 2 : 1)
                )
                .allowsHitTesting(false)
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

                    Button {
                        pendingImageCount = 0
                        onClearImages?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DockwrightTheme.primary.opacity(0.1))
                .clipShape(Capsule())
            }

            ForEach(Array(pendingFileNames.enumerated()), id: \.offset) { idx, name in
                HStack(spacing: 4) {
                    Image(systemName: "doc")
                        .font(.caption)
                        .foregroundStyle(DockwrightTheme.accent)
                    Text(name)
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(DockwrightTheme.accent)
                        .lineLimit(1)

                    Button {
                        pendingFileNames.remove(at: idx)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
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
                            .foregroundStyle(.primary)
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
                .background(Color.primary.opacity(0.03))
            }
        }
        .background(DockwrightTheme.Surface.elevated)
        .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Plus Menu Button

    private var plusMenuButton: some View {
        Menu {
            Button {
                takeCameraPhoto()
            } label: {
                Label("Take Photo", systemImage: "camera")
            }

            Button {
                takeScreenshot()
            } label: {
                Label("Take Screenshot", systemImage: "rectangle.dashed.badge.record")
            }

            Divider()

            Button {
                pasteClipboardImage()
            } label: {
                Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
            }
            .disabled(!VisionTool.clipboardHasImage())

            Button {
                openFilePicker()
            } label: {
                Label("Attach File", systemImage: "paperclip")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: DockwrightTheme.Layout.inputButtonSize, height: DockwrightTheme.Layout.inputButtonSize)
                .background(attachHovered ? Color.primary.opacity(0.08) : Color.clear)
                .clipShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: DockwrightTheme.Layout.inputButtonSize)
        .help("Attach files, take photo, or screenshot")
        .onHover { h in attachHovered = h }
    }

    // MARK: - File Picker

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .image, .pdf, .plainText, .json, .html,
            UTType(filenameExtension: "swift") ?? .plainText,
            UTType(filenameExtension: "py") ?? .plainText,
            UTType(filenameExtension: "js") ?? .plainText,
            UTType(filenameExtension: "ts") ?? .plainText,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "csv") ?? .plainText,
            .zip, .data,
        ]
        if panel.runModal() == .OK {
            for url in panel.urls {
                onFileDrop?([url])
                pendingFileNames.append(url.lastPathComponent)
            }
        }
    }

    // MARK: - Voice Conversation Button

    @State private var voiceHovered = false

    private var voiceConversationButton: some View {
        Button {
            onToggleVoiceConversation?()
        } label: {
            Image(systemName: voiceMode && voiceState == .speaking ? "waveform.circle.fill" : "waveform")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(voiceMode ? DockwrightTheme.primary : .secondary)
                .frame(width: DockwrightTheme.Layout.inputButtonSize, height: DockwrightTheme.Layout.inputButtonSize)
                .background(voiceHovered ? Color.primary.opacity(0.08) : Color.clear)
                .clipShape(Circle())
                .symbolEffect(.variableColor.iterative, isActive: voiceMode && voiceState == .speaking)
        }
        .buttonStyle(.plain)
        .onHover { h in voiceHovered = h }
        .help(voiceMode ? "Stop voice conversation" : "Voice conversation")
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

    // MARK: - Dictate Button

    private var isRecording: Bool {
        voiceState == .listening || voiceState == .transcribing
    }

    private var micButton: some View {
        Button {
            onToggleVoice?()
        } label: {
            ZStack {
                Circle()
                    .fill(
                        isRecording
                            ? AnyShapeStyle(DockwrightTheme.success)
                            : AnyShapeStyle(Color.primary.opacity(0.1))
                    )
                    .frame(width: DockwrightTheme.Layout.inputButtonSize, height: DockwrightTheme.Layout.inputButtonSize)

                Image(systemName: isRecording ? "stop.fill" : "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isRecording ? Color(nsColor: .windowBackgroundColor) : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .opacity(micHovered ? 0.85 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { h in micHovered = h }
        .help(isRecording ? "Stop dictation" : "Dictate")
    }

    // MARK: - Text Editor

    private var textEditor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(isProcessing ? InputStrings.redirect : InputStrings.placeholder)
                    .font(.system(size: AppPreferences.shared.chatFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.leading, DockwrightTheme.Spacing.sm)
                    .padding(.top, DockwrightTheme.Spacing.sm)
                    .allowsHitTesting(false) // Let taps pass through to TextEditor
            }

            TextEditor(text: $text)
                .font(.system(size: AppPreferences.shared.chatFontSize))
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

                    // Enter to send (without Shift) — only when sendWithReturn is enabled
                    guard AppPreferences.shared.sendWithReturn,
                          newValue.hasSuffix("\n"),
                          newValue.count == oldValue.count + 1,
                          !NSEvent.modifierFlags.contains(.shift) else { return }
                    text = String(newValue.dropLast())
                    if canSend {
                        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        text = ""
                        pendingImageCount = 0
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
                pendingImageCount = 0
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
                                ? AnyShapeStyle(Color.primary)
                                : AnyShapeStyle(Color.primary.opacity(0.15))
                    )
                    .frame(width: DockwrightTheme.Layout.inputButtonSize, height: DockwrightTheme.Layout.inputButtonSize)

                Image(systemName: isProcessing ? (canSend ? "arrow.uturn.forward" : "stop.fill") : "arrow.up")
                    .font(.system(size: isProcessing && !canSend ? 10 : 12, weight: .bold))
                    .foregroundStyle(
                        isProcessing && !canSend
                            ? Color(nsColor: .windowBackgroundColor)
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
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImageCount > 0
    }

    // MARK: - Camera Capture

    @State private var showCameraPreview = false

    private func takeCameraPhoto() {
        Task {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .notDetermined {
                await AVCaptureDevice.requestAccess(for: .video)
            }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                PermissionsManager.shared.openSettings("Privacy_Camera")
                return
            }
            showCameraPreview = true
            CameraPreviewPanel.show { image in
                if let image {
                    onImagePaste?(image)
                    pendingImageCount += 1
                }
                showCameraPreview = false
            }
        }
    }

    private func takeScreenshot() {
        Task {
            // Use screencapture CLI — works without ScreenCaptureKit entitlement
            let tmpPath = NSTemporaryDirectory() + "dockwright_screenshot_\(UUID().uuidString).png"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-t", "png", tmpPath]
            try? process.run()
            process.waitUntilExit()

            if let image = NSImage(contentsOfFile: tmpPath) {
                onImagePaste?(image)
                pendingImageCount += 1
            }
            try? FileManager.default.removeItem(atPath: tmpPath)
        }
    }

    private func pasteClipboardImage() {
        if let image = VisionTool.clipboardImage() {
            onImagePaste?(image)
            pendingImageCount += 1
        }
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

// MARK: - Camera Preview Panel

/// Shows a live camera preview in a floating NSPanel with Take Photo / Cancel buttons.
final class CameraPreviewPanel: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private static var current: CameraPreviewPanel?
    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var onComplete: ((NSImage?) -> Void)?

    static func show(onComplete: @escaping (NSImage?) -> Void) {
        let instance = CameraPreviewPanel()
        current = instance
        instance.onComplete = onComplete
        instance.setup()
    }

    private func setup() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            onComplete?(nil)
            return
        }

        let session = AVCaptureSession()
        session.sessionPreset = .photo
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            onComplete?(nil)
            return
        }
        session.addInput(input)

        let photoOutput = AVCapturePhotoOutput()
        session.addOutput(photoOutput)
        self.session = session
        self.photoOutput = photoOutput

        // Create the preview layer
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill

        // Build the SwiftUI content
        let cameraView = CameraPreviewView(
            previewLayer: previewLayer,
            onTakePhoto: { [weak self] in self?.capturePhoto() },
            onCancel: { [weak self] in self?.cancel() }
        )

        let hostingController = NSHostingController(rootView: cameraView)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 480, height: 420)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Take Photo"
        panel.contentViewController = hostingController
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        session.startRunning()
    }

    private func capturePhoto() {
        guard let photoOutput else { return }
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func cancel() {
        session?.stopRunning()
        panel?.close()
        onComplete?(nil)
        CameraPreviewPanel.current = nil
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        session?.stopRunning()
        panel?.close()
        if let data = photo.fileDataRepresentation(), let image = NSImage(data: data) {
            onComplete?(image)
        } else {
            onComplete?(nil)
        }
        CameraPreviewPanel.current = nil
    }
}

// MARK: - Camera Preview SwiftUI View

/// Wraps AVCaptureVideoPreviewLayer in an NSViewRepresentable + Take Photo / Cancel buttons.
private struct CameraPreviewView: View {
    let previewLayer: AVCaptureVideoPreviewLayer
    let onTakePhoto: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CameraLayerView(previewLayer: previewLayer)
                .frame(width: 480, height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 20) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button {
                    onTakePhoto()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.fill")
                        Text("Take Photo")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(nsColor: .windowBackgroundColor))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(DockwrightTheme.primary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(DockwrightTheme.Surface.canvas)
    }
}

/// NSViewRepresentable wrapping AVCaptureVideoPreviewLayer for live camera feed.
private struct CameraLayerView: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        previewLayer.frame = view.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = CALayer()
        view.layer?.addSublayer(previewLayer)
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        previewLayer.frame = nsView.bounds
    }
}
