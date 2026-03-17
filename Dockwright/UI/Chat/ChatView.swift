import SwiftUI
import UniformTypeIdentifiers

// MARK: - Localized Empty State Strings

/// Provides localized strings for the empty chat state based on the app language setting.
enum EmptyStateStrings {
    private static var lang: String { VoiceService.effectiveLanguage }
    private static var isNL: Bool { lang.hasPrefix("nl") }
    private static var isDE: Bool { lang.hasPrefix("de") }
    private static var isFR: Bool { lang.hasPrefix("fr") }
    private static var isES: Bool { lang.hasPrefix("es") }

    static var title: String {
        if isNL { return "Waarmee kan ik je helpen?" }
        if isDE { return "Wie kann ich dir helfen?" }
        if isFR { return "Comment puis-je vous aider ?" }
        if isES { return "¿En qué puedo ayudarte?" }
        return "What can I help you with?"
    }
    static var checkEmails: String {
        if isNL { return "Check mijn e-mails" }
        if isDE { return "E-Mails prüfen" }
        if isFR { return "Vérifier mes e-mails" }
        if isES { return "Revisar mis correos" }
        return "Check my emails"
    }
    static var calendar: String {
        if isNL { return "Wat staat er op mijn agenda?" }
        if isDE { return "Was steht im Kalender?" }
        if isFR { return "Mon calendrier ?" }
        if isES { return "¿Qué hay en mi calendario?" }
        return "What's on my calendar?"
    }
    static var reminders: String {
        if isNL { return "Toon mijn herinneringen" }
        if isDE { return "Erinnerungen anzeigen" }
        if isFR { return "Mes rappels" }
        if isES { return "Mis recordatorios" }
        return "Show my reminders"
    }
    static var playing: String {
        if isNL { return "Wat speelt er?" }
        if isDE { return "Was läuft?" }
        if isFR { return "Qu'est-ce qui joue ?" }
        if isES { return "¿Qué suena?" }
        return "What's playing?"
    }
    static var screenshot: String {
        if isNL { return "Maak een screenshot" }
        if isDE { return "Screenshot machen" }
        if isFR { return "Capture d'écran" }
        if isES { return "Tomar captura" }
        return "Take a screenshot"
    }
    static var clipboard: String {
        if isNL { return "Lees mijn klembord" }
        if isDE { return "Zwischenablage lesen" }
        if isFR { return "Lire le presse-papiers" }
        if isES { return "Leer portapapeles" }
        return "Read my clipboard"
    }
    static var contacts: String {
        if isNL { return "Zoek contacten" }
        if isDE { return "Kontakte suchen" }
        if isFR { return "Chercher contacts" }
        if isES { return "Buscar contactos" }
        return "Search contacts"
    }
    static var notes: String {
        if isNL { return "Toon mijn notities" }
        if isDE { return "Notizen anzeigen" }
        if isFR { return "Mes notes" }
        if isES { return "Mis notas" }
        return "Show my notes"
    }
    static var battery: String {
        if isNL { return "Batterijstatus" }
        if isDE { return "Akkustatus" }
        if isFR { return "État de la batterie" }
        if isES { return "Estado de batería" }
        return "Battery status"
    }
    static var goals: String {
        if isNL { return "Toon mijn doelen" }
        if isDE { return "Meine Ziele" }
        if isFR { return "Mes objectifs" }
        if isES { return "Mis metas" }
        return "Show my goals"
    }
    static var browser: String {
        if isNL { return "Wat staat er in mijn browser?" }
        if isDE { return "Was ist im Browser?" }
        if isFR { return "Mon navigateur ?" }
        if isES { return "¿Qué hay en mi navegador?" }
        return "What's in my browser?"
    }
    static var systemInfo: String {
        if isNL { return "Systeeminfo" }
        if isDE { return "Systeminfo" }
        if isFR { return "Infos système" }
        if isES { return "Info del sistema" }
        return "System info"
    }
    static var createSkill: String {
        if isNL { return "Maak een skill" }
        if isDE { return "Skill erstellen" }
        if isFR { return "Créer une compétence" }
        if isES { return "Crear habilidad" }
        return "Create a skill"
    }
    static var dropHint: String {
        if isNL { return "Sleep afbeeldingen of bestanden hierheen" }
        if isDE { return "Bilder oder Dateien hierher ziehen" }
        if isFR { return "Déposez des images ou fichiers ici" }
        if isES { return "Arrastra imágenes o archivos aquí" }
        return "Drop images or files to include them"
    }
}

/// Main chat view with message list + input, drag & drop support, and agent mode indicator.
struct ChatView: View {
    @Bindable var appState: AppState
    @State private var isDragOver = false
    @State private var isDictating = false
    @State private var dictationPollTask: Task<Void, Never>?
    @State private var promptText = ""
    private var voice: VoiceService { VoiceService.shared }

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
                voiceState: isDictating ? .listening : appState.voiceState,
                voiceMode: isDictating || appState.voiceMode,
                onSend: { msg in
                    promptText = ""
                    Task {
                        await appState.sendMessage(msg)
                    }
                },
                onStop: {
                    appState.stopProcessing()
                },
                onToggleVoice: {
                    toggleDictation()
                },
                onToggleVoiceConversation: {
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
                onClearImages: {
                    appState.pendingImages.removeAll()
                },
                showSlashCommands: $appState.showSlashCommands,
                slashFilter: $appState.slashFilter,
                slashCommands: appState.filteredSlashCommands,
                text: $promptText
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
        .onChange(of: appState.voiceLiveText) { _, newValue in
            // Sync voice conversation live text to the input field
            if appState.voiceMode {
                promptText = newValue
            }
        }
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

    @State private var autoScrollTask: Task<Void, Never>?

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(appState.currentConversation.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.top, DockwrightTheme.Spacing.lg)
                .padding(.bottom, DockwrightTheme.Spacing.md)
            }
            .onChange(of: appState.currentConversation.messages.count) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: appState.isProcessing) { _, processing in
                if processing {
                    startAutoScroll(proxy: proxy)
                } else {
                    stopAutoScroll()
                    scrollToBottom(proxy: proxy)
                }
            }
        }
    }

    /// Start a periodic scroll while streaming (every 400ms).
    private func startAutoScroll(proxy: ScrollViewProxy) {
        stopAutoScroll()
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                scrollToBottom(proxy: proxy)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastId = appState.currentConversation.messages.last?.id {
            withAnimation(.easeOut(duration: 0.15)) {
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

            Text(EmptyStateStrings.title)
                .font(DockwrightTheme.Typography.displayMedium)
                .foregroundStyle(.primary)

            // Suggestion chips
            VStack(spacing: DockwrightTheme.Spacing.sm) {
                HStack(spacing: DockwrightTheme.Spacing.sm) {
                    suggestionChip(EmptyStateStrings.checkEmails, icon: "envelope")
                    suggestionChip(EmptyStateStrings.calendar, icon: "calendar")
                    suggestionChip(EmptyStateStrings.reminders, icon: "checklist")
                }
                HStack(spacing: DockwrightTheme.Spacing.sm) {
                    suggestionChip(EmptyStateStrings.playing, icon: "music.note")
                    suggestionChip(EmptyStateStrings.screenshot, icon: "camera.viewfinder")
                    suggestionChip(EmptyStateStrings.clipboard, icon: "doc.on.clipboard")
                }
                HStack(spacing: DockwrightTheme.Spacing.sm) {
                    suggestionChip(EmptyStateStrings.contacts, icon: "person.crop.circle")
                    suggestionChip(EmptyStateStrings.notes, icon: "note.text")
                    suggestionChip(EmptyStateStrings.battery, icon: "battery.100")
                }
                HStack(spacing: DockwrightTheme.Spacing.sm) {
                    suggestionChip(EmptyStateStrings.goals, icon: "target")
                    suggestionChip(EmptyStateStrings.browser, icon: "safari")
                    suggestionChip(EmptyStateStrings.systemInfo, icon: "desktopcomputer")
                    suggestionChip(EmptyStateStrings.createSkill, icon: "wand.and.stars")
                }
            }

            // Drag & drop hint
            HStack(spacing: DockwrightTheme.Spacing.xs) {
                Image(systemName: "arrow.down.doc")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                Text(EmptyStateStrings.dropHint)
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
                    .stroke(Color.primary.opacity(DockwrightTheme.Opacity.borderSubtle), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Dictation (matches Jarvis pattern)

    private func toggleDictation() {
        if isDictating {
            // Stop dictation — keep whatever text was transcribed
            voice.onFinalTranscription = nil
            voice.stopListening()
            isDictating = false
            appState.voiceState = .idle
            dictationPollTask?.cancel()
            dictationPollTask = nil
            return
        }
        // Respect user's "Enable Voice Mode" preference toggle (same check as AppState.startVoice)
        guard UserDefaults.standard.object(forKey: "voiceEnabled") as? Bool ?? true else {
            appState.appendError("Voice mode is disabled. Enable it in Settings → Voice.")
            return
        }
        // Start dictation
        voice.requestAuthorization()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard voice.voiceEnabled else { return }
            voice.onFinalTranscription = { text in
                Task { @MainActor in
                    isDictating = false
                    appState.voiceState = .idle
                    dictationPollTask?.cancel()
                    dictationPollTask = nil
                }
            }
            voice.startListening()
            isDictating = true
            appState.voiceState = .listening
            // Poll recognizedText every 100ms for live updates
            dictationPollTask = Task { @MainActor in
                while isDictating && !Task.isCancelled {
                    let live = voice.recognizedText
                    if !live.isEmpty {
                        promptText = live
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
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
