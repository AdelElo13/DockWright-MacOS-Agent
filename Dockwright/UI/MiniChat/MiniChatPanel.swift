import SwiftUI
import AppKit

/// Menu bar popover chat — anchored to the status item like WiFi/Bluetooth dropdowns.
/// Shows the same ChatView backed by the same AppState — no separate routing.
@MainActor
final class MiniChatPanel: NSObject, NSPopoverDelegate {
    static let shared = MiniChatPanel()

    private var popover: NSPopover?
    private var statusItem: NSStatusItem?
    private weak var appState: AppState?
    private(set) var isPinned = false

    enum PanelSize: String {
        case small, medium

        var size: NSSize {
            switch self {
            case .small: return NSSize(width: 380, height: 600)
            case .medium: return NSSize(width: 520, height: 800)
            }
        }
        var toggled: PanelSize { self == .small ? .medium : .small }
    }

    var currentSize: PanelSize = .small
    var isVisible: Bool { popover?.isShown ?? false }

    /// Setup the status item (call once from app startup)
    func setup(appState: AppState) {
        self.appState = appState

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = Self.makeMenuBarIcon(size: 18)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        if let p = popover, p.isShown {
            p.performClose(nil)
            return
        }
        showPopover()
    }

    func toggle(appState: AppState) {
        self.appState = appState
        togglePopover()
    }

    private func showPopover() {
        guard let appState, let button = statusItem?.button else { return }

        let chatView = MiniChatContentView(
            appState: appState,
            onClose: { [weak self] in self?.close() },
            onToggleSize: { [weak self] in self?.toggleSize() },
            onTogglePin: { [weak self] in self?.togglePin() }
        )

        let hosting = NSHostingController(rootView: chatView)
        hosting.preferredContentSize = currentSize.size

        let p = NSPopover()
        p.contentViewController = hosting
        p.contentSize = currentSize.size
        p.behavior = .transient
        p.delegate = self
        p.animates = true

        popover = p
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() {
        popover?.performClose(nil)
        popover = nil
    }

    func toggleSize() {
        currentSize = currentSize.toggled
        if let p = popover {
            p.contentSize = currentSize.size
            p.contentViewController?.preferredContentSize = currentSize.size
        }
    }

    func togglePin() {
        isPinned.toggle()
        if isPinned {
            popover?.behavior = .applicationDefined
        } else {
            popover?.behavior = .transient
        }
    }

    // MARK: - NSPopoverDelegate

    nonisolated func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        false
    }

    /// Remove the status item (e.g. when preference is toggled off)
    func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Draw the Dockwright ship wheel icon programmatically — black on transparent.
    /// Matches the app icon design: 8-spoke helm with outer ring and center hub.
    static func makeMenuBarIcon(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let ctx = NSGraphicsContext.current!.cgContext
            let c = CGPoint(x: size / 2, y: size / 2)
            let outerR = size * 0.46
            let innerR = size * 0.32
            let hubR = size * 0.10
            let spokeW = size * 0.08
            let handleR = size * 0.06
            let handleDist = size * 0.50

            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(size * 0.06)

            // Outer ring
            ctx.strokeEllipse(in: CGRect(x: c.x - outerR, y: c.y - outerR, width: outerR * 2, height: outerR * 2))

            // Inner ring
            ctx.setLineWidth(size * 0.04)
            ctx.strokeEllipse(in: CGRect(x: c.x - innerR, y: c.y - innerR, width: innerR * 2, height: innerR * 2))

            // Center hub
            ctx.fillEllipse(in: CGRect(x: c.x - hubR, y: c.y - hubR, width: hubR * 2, height: hubR * 2))

            // 8 spokes from hub to outer ring
            ctx.setLineWidth(spokeW)
            for i in 0..<8 {
                let angle = CGFloat(i) * .pi / 4
                let x1 = c.x + hubR * cos(angle)
                let y1 = c.y + hubR * sin(angle)
                let x2 = c.x + outerR * cos(angle)
                let y2 = c.y + outerR * sin(angle)
                ctx.move(to: CGPoint(x: x1, y: y1))
                ctx.addLine(to: CGPoint(x: x2, y: y2))
                ctx.strokePath()
            }

            // 8 handles (knobs) at spoke ends outside ring
            for i in 0..<8 {
                let angle = CGFloat(i) * .pi / 4
                let hx = c.x + handleDist * cos(angle)
                let hy = c.y + handleDist * sin(angle)
                ctx.fillEllipse(in: CGRect(x: hx - handleR, y: hy - handleR, width: handleR * 2, height: handleR * 2))
            }

            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - Mini Chat Content View

/// Compact chat view for the popover — same AppState, no sidebar.
struct MiniChatContentView: View {
    @Bindable var appState: AppState
    var onClose: () -> Void
    var onToggleSize: () -> Void
    var onTogglePin: () -> Void
    @State private var pinned = false
    @State private var sizeIsSmall = true

    var body: some View {
        VStack(spacing: 0) {
            // Compact header
            HStack(spacing: 8) {
                if let img = NSImage(named: "AppIcon") {
                    Image(nsImage: img)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "helm.and.ship.wheel")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DockwrightTheme.primary)
                }
                Text("Dockwright")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()

                // Status indicator
                if appState.isProcessing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                        Text(appState.currentActivity?.label ?? "Working...")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // Model badge
                Text(LLMModels.allModels.first { $0.id == appState.selectedModel }?.displayName ?? "")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Capsule())

                // Pin on top
                Button {
                    onTogglePin()
                    pinned.toggle()
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundStyle(pinned ? DockwrightTheme.primary : .secondary)
                        .padding(4)
                        .background(pinned ? DockwrightTheme.primary.opacity(0.15) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help(pinned ? "Unpin" : "Pin on top")

                // Resize
                Button {
                    onToggleSize()
                    sizeIsSmall.toggle()
                } label: {
                    Image(systemName: sizeIsSmall
                        ? "arrow.up.left.and.arrow.down.right"
                        : "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Toggle size")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))

            Divider()

            // Same ChatView — exact same data
            ChatView(appState: appState)
        }
        .background(DockwrightTheme.Surface.canvas)
    }
}

// MARK: - Activity Label Extension

extension StreamActivity {
    var label: String {
        switch self {
        case .thinking: return "Thinking..."
        case .searching(let q): return "Searching \(q.prefix(20))..."
        case .reading(let f): return "Reading \(f.prefix(20))..."
        case .executing(let t): return "Running \(t.prefix(20))..."
        case .generating: return "Generating..."
        }
    }
}
