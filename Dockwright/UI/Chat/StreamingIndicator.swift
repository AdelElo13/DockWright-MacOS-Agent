import SwiftUI

/// Activity pill showing what Dockwright is currently doing.
struct StreamingIndicator: View {
    let activity: StreamActivity

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tintColor)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: 14, height: 14)

            Text(label)
                .font(DockwrightTheme.Typography.captionMedium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tintColor.opacity(DockwrightTheme.Opacity.tintSubtle))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(tintColor.opacity(DockwrightTheme.Opacity.tintMedium), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.2), value: iconName)
    }

    private var iconName: String {
        switch activity {
        case .thinking: return "brain"
        case .searching: return "magnifyingglass"
        case .reading: return "doc.text"
        case .executing: return "terminal"
        case .generating: return "text.cursor"
        }
    }

    private var label: String {
        switch activity {
        case .thinking: return "Thinking..."
        case .searching(let q): return "Searching: \(q)"
        case .reading(let f): return "Reading: \(f)"
        case .executing(let t): return "Running: \(t)"
        case .generating: return "Writing..."
        }
    }

    private var tintColor: Color {
        switch activity {
        case .thinking: return DockwrightTheme.primary
        case .searching: return DockwrightTheme.info
        case .reading: return DockwrightTheme.secondary
        case .executing: return DockwrightTheme.success
        case .generating: return DockwrightTheme.primary
        }
    }
}
