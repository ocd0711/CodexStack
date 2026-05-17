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
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("ConvStack")
                    .font(.title2.weight(.semibold))
                Spacer()
                StatBadge(label: "Active", value: "\(store.activeCount)")
                StatBadge(label: "Archived", value: "\(store.archivedCount)")
                StatBadge(
                    label: "Size",
                    value: ByteCountFormatter.string(fromByteCount: store.totalSizeBytes, countStyle: .file)
                )
            }
            .padding(.horizontal, 6)

            HStack(spacing: 8) {
                TextField("Search title or session id", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Scope", selection: $store.scope) {
                    ForEach(SessionScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
            }

            HStack(spacing: 8) {
                Button("Archive", action: store.archiveSelected)
                    .disabled(!canArchive)
                Button("Unarchive", action: store.unarchiveSelected)
                    .disabled(!canUnarchive)
                Button("Move to Trash") {
                    showTrashConfirm = true
                }
                .disabled(!canTrash)
                Button("Refresh", action: store.refresh)
                Spacer()
                Text("\(store.filteredSessions.count) sessions")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)

            HSplitView {
                GlassCard {
                    List(selection: $store.selectedIDs) {
                        ForEach(groupedSessions) { group in
                            DisclosureGroup(
                                isExpanded: expansionBinding(for: group.id),
                                content: {
                                    ForEach(group.sessions) { session in
                                        SessionRow(session: session)
                                            .tag(session.id)
                                    }
                                },
                                label: {
                                    HStack {
                                        Text(group.name)
                                        Spacer()
                                        Menu {
                                            Button("Select Project Sessions") {
                                                store.selectedIDs = Set(group.sessions.map(\.id))
                                            }
                                            Button("Move Project to Trash", role: .destructive) {
                                                pendingProjectName = group.name
                                                showProjectTrashConfirm = true
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                                .foregroundStyle(.secondary)
                                        }
                                        .menuStyle(.borderlessButton)

                                        Text("\(group.sessions.count)")
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                }
                            )
                        }
                    }
                    .listStyle(.sidebar)
                }
                .frame(minWidth: 560, minHeight: 460)

                GlassCard {
                    SessionDetailView(session: selectedSession)
                }
                .frame(minWidth: 420, idealWidth: 460)
            }
        }
        .padding(14)
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
                Text("Project: \(pendingProjectName)")
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
}

private struct ProjectSessionGroup: Identifiable {
    let id: String
    let name: String
    let sessions: [CodexSession]
    let latest: Date
}

private struct SessionRow: View {
    let session: CodexSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            HStack(spacing: 8) {
                Label(
                    session.updatedAt.formatted(date: .numeric, time: .shortened),
                    systemImage: "clock"
                )
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)

                Text("·")
                    .foregroundStyle(.tertiary)

                Text(session.isArchived ? "Archived" : "Active")
                    .foregroundStyle(session.isArchived ? .orange : .secondary)

                Spacer()

                Text(session.sizeLabel)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct SessionDetailView: View {
    let session: CodexSession?
    @State private var messages: [SessionMessage] = []
    @State private var isLoadingMessages = false
    @State private var showConversationPreview = false

    var body: some View {
        Group {
            if let session {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Session Details")
                        .font(.headline)

                    VStack(spacing: 8) {
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
                    .padding(12)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(0.15), lineWidth: 1)
                    )

                    HStack(spacing: 8) {
                        Button("Preview Conversation") {
                            showConversationPreview = true
                            loadConversation(for: session)
                        }
                        .buttonStyle(.borderedProminent)

                        if isLoadingMessages {
                            ProgressView()
                                .controlSize(.small)
                        } else if messages.isEmpty {
                            Text("No messages yet")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        } else {
                            Text("\(messages.count) messages")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }

                    Spacer()
                }
                .sheet(isPresented: $showConversationPreview) {
                    ConversationPreviewSheet(
                        sessionTitle: session.title,
                        messages: messages,
                        isLoading: isLoadingMessages
                    )
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("Select a session from the sidebar")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
    }

    private func loadConversation(for session: CodexSession) {
        isLoadingMessages = true
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                CodexSessionService().loadConversationPreview(for: session, maxMessages: 400)
            }.value
            await MainActor.run {
                messages = loaded
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

private struct DetailRow: View {
    let label: String
    let value: String
    var monospace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospace ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.weight(.semibold))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
