import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var showTrashConfirm = false
    @State private var showProjectTrashConfirm = false
    @State private var pendingProjectName: String?
    @State private var expandedProjects: Set<String> = []

    private var selectedSession: CodexSession? {
        store.selectedSessions.first
    }

    private var canArchive: Bool {
        !store.selectedSessions.isEmpty && store.selectedSessions.contains { !$0.isArchived }
    }

    private var canUnarchive: Bool {
        !store.selectedSessions.isEmpty && store.selectedSessions.contains { $0.isArchived }
    }

    private var canTrash: Bool {
        !store.selectedSessions.isEmpty
    }

    private var canRename: Bool {
        selectedSession != nil && !store.isMutating
    }

    private var groupedSessions: [ProjectSessionGroup] {
        let grouped = Dictionary(grouping: store.filteredSessions, by: \.projectName)
        let mapped = grouped.map { name, sessions -> ProjectSessionGroup in
            let sortedSessions = sessions.sorted { $0.updatedAt > $1.updatedAt }
            return ProjectSessionGroup(
                id: name,
                name: name,
                sessions: sortedSessions,
                latest: sortedSessions.first?.updatedAt ?? .distantPast
            )
        }
        return mapped.sorted { $0.latest > $1.latest }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            controlsBar
            Divider()
            HSplitView {
                sidebar
                    .frame(minWidth: 420, idealWidth: 500)
                detailPane
                    .frame(minWidth: 480, idealWidth: 560)
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .background(.regularMaterial)
        .confirmationDialog(
            "Move selected session files to Trash?",
            isPresented: $showTrashConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                store.trashSelected()
            }
        }
        .confirmationDialog(
            "Move all sessions in this project to Trash?",
            isPresented: $showProjectTrashConfirm,
            titleVisibility: .visible
        ) {
            Button("Move Project to Trash", role: .destructive) {
                if let pendingProjectName {
                    store.trashProject(named: pendingProjectName)
                }
                pendingProjectName = nil
            }
            Button("Cancel", role: .cancel) {
                pendingProjectName = nil
            }
        } message: {
            if let pendingProjectName {
                Text(
                    String.localizedStringWithFormat(
                        NSLocalizedString("Project: %@", bundle: .module, comment: ""),
                        pendingProjectName
                    )
                )
            }
        }
        .alert("Operation Failed", isPresented: .constant(store.lastError != nil), actions: {
            Button("OK") {
                store.clearError()
            }
        }, message: {
            Text(store.lastError ?? "")
        })
        .onAppear {
            if store.sessions.isEmpty {
                store.refresh()
            }
            if expandedProjects.isEmpty {
                expandedProjects = Set(groupedSessions.map(\.id))
            }
        }
        .onChange(of: groupedSessions.map(\.id)) { ids in
            let idSet = Set(ids)
            expandedProjects = expandedProjects.intersection(idSet)
            for id in idSet where !expandedProjects.contains(id) {
                expandedProjects.insert(id)
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("codexStack")
                    .font(.title2.weight(.semibold))
                Text("Codex session manager")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatBadge(label: "Active", value: "\(store.activeCount)", systemImage: "circle.fill")
            StatBadge(label: "Archived", value: "\(store.archivedCount)", systemImage: "archivebox")
            StatBadge(
                label: "Size",
                value: ByteCountFormatter.string(fromByteCount: store.totalSizeBytes, countStyle: .file),
                systemImage: "externaldrive"
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var controlsBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextField("Search title or session id", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 280)

                Picker("Scope", selection: $store.scope) {
                    ForEach(SessionScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }

            HStack(spacing: 8) {
                Button {
                    if let selectedSession {
                        openRename(for: selectedSession)
                    }
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .disabled(!canRename)

                Button(action: store.archiveSelected) {
                    Label("Archive", systemImage: "archivebox")
                }
                .disabled(!canArchive || store.isMutating)

                Button(action: store.unarchiveSelected) {
                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                }
                .disabled(!canUnarchive || store.isMutating)

                Button(role: .destructive) {
                    showTrashConfirm = true
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .disabled(!canTrash || store.isMutating)

                Button(action: store.refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isBusy)

                if store.isMutating, let message = store.mutationMessage {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }

                Spacer()
                Text(selectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projects")
                    .font(.headline)
                Spacer()
                Text(
                    String.localizedStringWithFormat(
                        NSLocalizedString("%d sessions", bundle: .module, comment: ""),
                        store.filteredSessions.count
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            List(selection: $store.selectedIDs) {
                ForEach(groupedSessions) { group in
                    DisclosureGroup(
                        isExpanded: expansionBinding(for: group.id),
                        content: {
                            ForEach(group.sessions) { session in
                                HStack(spacing: 8) {
                                    SessionRow(session: session)
                                    Spacer(minLength: 6)
                                    sessionMenu(session)
                                }
                                .tag(session.id)
                                .help(session.title)
                            }
                        },
                        label: {
                            ProjectHeaderRow(
                                group: group,
                                onSelect: {
                                    store.selectedIDs = Set(group.sessions.map(\.id))
                                },
                                onTrash: {
                                    pendingProjectName = group.name
                                    showProjectTrashConfirm = true
                                }
                            )
                        }
                    )
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.ultraThinMaterial)
    }

    private var detailPane: some View {
        SessionDetailView(session: selectedSession)
            .background(.regularMaterial)
    }

    private var selectionSummary: String {
        if store.selectedIDs.isEmpty {
            return String.localizedStringWithFormat(
                NSLocalizedString("%d sessions", bundle: .module, comment: ""),
                store.filteredSessions.count
            )
        }
        return "\(store.selectedIDs.count) selected"
    }

    private func sessionMenu(_ session: CodexSession) -> some View {
        Menu {
            Button("Rename...") {
                openRename(for: session)
            }
            Button(session.isArchived ? "Unarchive" : "Archive") {
                if session.isArchived {
                    store.unarchiveSession(id: session.id)
                } else {
                    store.archiveSession(id: session.id)
                }
            }
            Button("Delete Conversation...", role: .destructive) {
                store.selectedIDs = [session.id]
                showTrashConfirm = true
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
    }

    private func expansionBinding(for projectID: String) -> Binding<Bool> {
        Binding(
            get: { expandedProjects.contains(projectID) },
            set: { isExpanded in
                if isExpanded {
                    expandedProjects.insert(projectID)
                } else {
                    expandedProjects.remove(projectID)
                }
            }
        )
    }

    private func openRename(for session: CodexSession) {
        if let newTitle = DialogPresenter.promptRename(initialTitle: session.title) {
            store.renameSession(id: session.id, newTitle: newTitle)
        }
    }
}

private struct ProjectSessionGroup: Identifiable {
    let id: String
    let name: String
    let sessions: [CodexSession]
    let latest: Date
}

private struct ProjectHeaderRow: View {
    let group: ProjectSessionGroup
    let onSelect: () -> Void
    let onTrash: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(Color(nsColor: .controlAccentColor))
                .font(.caption.weight(.semibold))
                .frame(width: 16)

            Text(group.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(group.name)

            Spacer(minLength: 8)

            Text("\(group.sessions.count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.thinMaterial)
                .clipShape(Capsule())

            Menu {
                Button("Select Project Sessions", action: onSelect)
                Button("Move Project to Trash", role: .destructive, action: onTrash)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 2)
    }
}

private struct SessionRow: View {
    let session: CodexSession

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: session.isArchived ? "archivebox" : "bubble.left.and.text.bubble.right")
                .font(.caption)
                .foregroundStyle(session.isArchived ? .orange : Color(nsColor: .controlAccentColor))
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text(session.updatedAt.formatted(date: .numeric, time: .shortened))
                    Text(session.isArchived ? "Archived" : "Active")
                        .foregroundStyle(session.isArchived ? .orange : .secondary)
                    Spacer(minLength: 6)
                    Text(session.sizeLabel)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct SessionDetailView: View {
    let session: CodexSession?
    @State private var messages: [SessionMessage] = []
    @State private var messageCount: Int?
    @State private var isLoadingMessages = false
    @State private var isLoadingMessageCount = false
    @State private var showConversationPreview = false

    var body: some View {
        Group {
            if let session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: session.isArchived ? "archivebox" : "bubble.left.and.text.bubble.right")
                                    .font(.title3)
                                    .foregroundStyle(session.isArchived ? .orange : Color(nsColor: .controlAccentColor))
                                    .frame(width: 28, height: 28)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.title)
                                        .font(.title3.weight(.semibold))
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                    Text(session.projectName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }

                            HStack(spacing: 8) {
                                InfoPill(
                                    text: session.isArchived ? "Archived" : "Active",
                                    systemImage: session.isArchived ? "archivebox" : "checkmark.circle"
                                )
                                InfoPill(
                                    text: session.updatedAt.formatted(date: .abbreviated, time: .shortened),
                                    systemImage: "clock"
                                )
                                InfoPill(text: session.sizeLabel, systemImage: "doc")
                            }
                        }
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        DetailSection(title: "Session Details") {
                            DetailRow(label: "Title", value: session.title)
                            DetailRow(label: "Session ID", value: session.id, monospace: true)
                            DetailRow(
                                label: "Updated",
                                value: session.updatedAt.formatted(date: .abbreviated, time: .standard)
                            )
                            DetailRow(label: "Scope", value: session.isArchived ? "Archived" : "Active")
                            DetailRow(label: "Project", value: session.projectName)
                            if let projectPath = session.projectPath {
                                DetailRow(label: "Project Path", value: projectPath, monospace: true)
                            }
                            DetailRow(label: "Size", value: session.sizeLabel)
                            DetailRow(label: "File", value: session.fileURL.path, monospace: true)
                        }

                        HStack(spacing: 8) {
                            Button {
                                showConversationPreview = true
                                loadConversation(for: session)
                            } label: {
                                Label("Preview Conversation", systemImage: "text.bubble")
                            }
                            .buttonStyle(.borderedProminent)

                            if isLoadingMessages {
                                ProgressView()
                                    .controlSize(.small)
                            } else if isLoadingMessageCount {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Counting messages...")
                                }
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            } else if let messageCount, messageCount > 0 {
                                Text(
                                    String.localizedStringWithFormat(
                                        NSLocalizedString("%d messages", bundle: .module, comment: ""),
                                        messageCount
                                    )
                                )
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            } else {
                                Text("No messages yet")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            Spacer()
                        }
                    }
                    .padding(18)
                }
                .sheet(isPresented: $showConversationPreview) {
                    ConversationPreviewSheet(
                        sessionTitle: session.title,
                        messages: messages,
                        isLoading: isLoadingMessages
                    )
                }
                .task(id: session.id) {
                    await loadMessageCount(for: session)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("Select a session from the sidebar")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func loadMessageCount(for session: CodexSession) async {
        messages = []
        messageCount = nil
        isLoadingMessageCount = true
        let count = await Task.detached(priority: .utility) {
            CodexSessionService().countConversationMessages(for: session)
        }.value
        await MainActor.run {
            messageCount = count
            isLoadingMessageCount = false
        }
    }

    private func loadConversation(for session: CodexSession) {
        isLoadingMessages = true
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                CodexSessionService().loadConversationPreview(for: session, maxMessages: 400)
            }.value
            await MainActor.run {
                messages = loaded
                if messageCount == nil {
                    messageCount = loaded.count
                }
                isLoadingMessages = false
            }
        }
    }
}

private struct MessageBubble: View {
    let message: SessionMessage

    private var tint: Color {
        switch message.role {
        case .user:
            return .blue
        case .assistant:
            return .green
        case .system:
            return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.role.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                if let timestamp = message.timestamp {
                    Text(timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(message.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct ConversationPreviewSheet: View {
    let sessionTitle: String
    let messages: [SessionMessage]
    let isLoading: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(sessionTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Close") {
                    dismiss()
                }
            }

            if isLoading {
                VStack {
                    ProgressView()
                    Text("Loading conversation...")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                Text("No conversation content in this session file.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 540)
        .background(.regularMaterial)
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(spacing: 0) {
                content
            }
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var monospace = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(monospace ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .textSelection(.enabled)
                .lineLimit(monospace ? 2 : 3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.45)
        }
    }
}

private struct InfoPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial)
            .clipShape(Capsule())
    }
}

private struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            )
    }
}

private struct StatBadge: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(Color(nsColor: .controlAccentColor))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
