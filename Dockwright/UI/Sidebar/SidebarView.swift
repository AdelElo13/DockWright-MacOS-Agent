import SwiftUI

/// Sidebar with thread list, new thread button, and search.
struct SidebarView: View {
    @Bindable var appState: AppState
    @Binding var showSettings: Bool
    @State private var searchQuery = ""
    @State private var showSearch = false
    @State private var hoveredConversationId: String?

    var body: some View {
        VStack(spacing: 0) {
            // New thread button
            Button {
                appState.newConversation()
            } label: {
                HStack(spacing: DockwrightTheme.Spacing.sm) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 20, alignment: .center)
                    Text("New thread")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.vertical, DockwrightTheme.Spacing.xs)
                .padding(.horizontal, DockwrightTheme.Spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DockwrightTheme.Spacing.sm)
            .padding(.top, 16)

            // Threads header
            HStack {
                Text("Threads")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showSearch.toggle()
                        if !showSearch { searchQuery = "" }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DockwrightTheme.Spacing.lg)
            .padding(.top, DockwrightTheme.Spacing.md)
            .padding(.bottom, DockwrightTheme.Spacing.xs)

            // Search bar
            if showSearch {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                    TextField("Search threads...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !searchQuery.isEmpty {
                        Button { searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DockwrightTheme.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: DockwrightTheme.Radius.sm))
                .padding(.horizontal, DockwrightTheme.Spacing.md)
                .padding(.bottom, DockwrightTheme.Spacing.xs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Conversation list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let filtered = filteredConversations
                    let grouped = groupConversations(filtered)

                    ForEach(grouped, id: \.label) { group in
                        if !group.items.isEmpty {
                            sectionHeader(group.label)
                            ForEach(group.items) { conv in
                                conversationRow(conv)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // Bottom buttons
            Divider().opacity(0.2)

            Button {
                appState.showScheduler.toggle()
            } label: {
                HStack(spacing: DockwrightTheme.Spacing.sm) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Text("Scheduler")
                        .font(DockwrightTheme.Typography.body)
                        .foregroundStyle(.white)
                    Spacer()
                    let jobCount = appState.cronStore.listAll().count
                    if jobCount > 0 {
                        Text("\(jobCount)")
                            .font(DockwrightTheme.Typography.captionMono)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DockwrightTheme.Spacing.md)
                .padding(.vertical, DockwrightTheme.Spacing.sm)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DockwrightTheme.Spacing.sm)

            Button {
                showSettings = true
            } label: {
                HStack(spacing: DockwrightTheme.Spacing.sm) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Text("Settings")
                        .font(DockwrightTheme.Typography.body)
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DockwrightTheme.Spacing.md)
                .padding(.vertical, DockwrightTheme.Spacing.sm)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DockwrightTheme.Spacing.sm)
            .padding(.bottom, DockwrightTheme.Spacing.sm)
        }
        .frame(maxHeight: .infinity)
        .background(DockwrightTheme.Surface.sidebar)
    }

    // MARK: - Conversation Row

    private func conversationRow(_ conv: ConversationSummary) -> some View {
        let isActive = conv.id == appState.currentConversation.id
        _ = hoveredConversationId == conv.id

        return Button {
            appState.loadConversation(conv.id)
        } label: {
            HStack(spacing: 6) {
                Text(conv.title)
                    .font(.system(size: 14, weight: isActive ? .medium : .regular))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(relativeDate(conv.updatedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, DockwrightTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DockwrightTheme.Radius.sm)
                    .fill(isActive ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DockwrightTheme.Spacing.sm)
        .onHover { h in hoveredConversationId = h ? conv.id : nil }
        .contextMenu {
            Button("Delete", role: .destructive) {
                appState.deleteConversation(conv.id)
            }
        }
    }

    // MARK: - Date Grouping

    private struct ConversationGroup {
        let label: String
        let items: [ConversationSummary]
    }

    private var filteredConversations: [ConversationSummary] {
        if searchQuery.isEmpty { return appState.conversations }
        let q = searchQuery.lowercased()
        return appState.conversations.filter {
            $0.title.lowercased().contains(q) || $0.preview.lowercased().contains(q)
        }
    }

    private func groupConversations(_ convs: [ConversationSummary]) -> [ConversationGroup] {
        let cal = Calendar.current
        let now = Date()
        let sorted = convs.sorted { $0.updatedAt > $1.updatedAt }

        var today: [ConversationSummary] = []
        var yesterday: [ConversationSummary] = []
        var thisWeek: [ConversationSummary] = []
        var older: [ConversationSummary] = []

        for conv in sorted {
            if cal.isDateInToday(conv.updatedAt) {
                today.append(conv)
            } else if cal.isDateInYesterday(conv.updatedAt) {
                yesterday.append(conv)
            } else if let weekAgo = cal.date(byAdding: .day, value: -7, to: now),
                      conv.updatedAt >= weekAgo {
                thisWeek.append(conv)
            } else {
                older.append(conv)
            }
        }

        var groups: [ConversationGroup] = []
        if !today.isEmpty { groups.append(ConversationGroup(label: "Today", items: today)) }
        if !yesterday.isEmpty { groups.append(ConversationGroup(label: "Yesterday", items: yesterday)) }
        if !thisWeek.isEmpty { groups.append(ConversationGroup(label: "This Week", items: thisWeek)) }
        if !older.isEmpty { groups.append(ConversationGroup(label: "Older", items: older)) }
        return groups
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(DockwrightTheme.Typography.sectionHeader)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DockwrightTheme.Spacing.lg)
            .padding(.top, DockwrightTheme.Spacing.md)
            .padding(.bottom, DockwrightTheme.Spacing.xs)
    }

    private func relativeDate(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let days = hours / 24
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if hours < 24 { return "\(hours)h" }
        if days < 7 { return "\(days)d" }
        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w" }
        return "\(days / 30)mo"
    }
}
