import SwiftUI

/// Collapsible card showing tool output.
struct ToolCardView: View {
    let output: ToolOutput
    @State private var isExpanded = false

    private var icon: String {
        switch output.toolName {
        case "shell": return "terminal"
        case "file": return "folder"
        case "web_search": return "magnifyingglass"
        default: return "gearshape"
        }
    }

    private var tintColor: Color {
        if output.isError { return DockwrightTheme.error }
        switch output.toolName {
        case "shell": return DockwrightTheme.success
        case "file": return DockwrightTheme.secondary
        case "web_search": return DockwrightTheme.info
        default: return DockwrightTheme.primary
        }
    }

    private var summaryLine: String {
        let text = output.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.components(separatedBy: .newlines).first ?? text
        return String(firstLine.prefix(80))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)

                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tintColor)

                    Text(output.toolName.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if !isExpanded {
                        Text("- \(summaryLine)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer()

                    if output.isError {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(DockwrightTheme.error)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)

                ScrollView {
                    Text(output.output)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .background(tintColor.opacity(DockwrightTheme.Opacity.tintSubtle))
        .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md)
                .stroke(tintColor.opacity(DockwrightTheme.Opacity.tintMedium), lineWidth: 0.5)
        )
    }
}
