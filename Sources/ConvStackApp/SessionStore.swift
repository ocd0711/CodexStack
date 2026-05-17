import Foundation

@MainActor
final class SessionStore: ObservableObject {
    static let allProjectsLabel = "All Projects"
    nonisolated static func defaultCodexRootPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex").path
    }

    @Published private(set) var sessions: [CodexSession] = []
    @Published var searchText: String = ""
    @Published var scope: SessionScope = .active
    @Published var selectedProject: String = SessionStore.allProjectsLabel
    @Published var selectedIDs: Set<String> = []
    @Published private(set) var codexRootPath: String
    @Published private(set) var usage: UsageSnapshot = .empty
    @Published private(set) var lastError: String?

    init(codexRootPath: String = SessionStore.defaultCodexRootPath()) {
        self.codexRootPath = codexRootPath
    }

    var filteredSessions: [CodexSession] {
        sessions.filter { session in
            let scopeMatch: Bool
            switch scope {
            case .active:
                scopeMatch = !session.isArchived
            case .archived:
                scopeMatch = session.isArchived
            case .all:
                scopeMatch = true
            }

            if !scopeMatch { return false }
            if selectedProject != SessionStore.allProjectsLabel && session.projectName != selectedProject {
                return false
            }
            if searchText.isEmpty { return true }
            let query = searchText.lowercased()
            return session.title.lowercased().contains(query) || session.id.lowercased().contains(query)
        }
    }

    var selectedSessions: [CodexSession] {
        sessions.filter { selectedIDs.contains($0.id) }
    }

    var activeCount: Int {
        sessions.filter { !$0.isArchived }.count
    }

    var archivedCount: Int {
        sessions.filter { $0.isArchived }.count
    }

    var totalSizeBytes: Int64 {
        sessions.reduce(0) { $0 + $1.sizeInBytes }
    }

    var projectOptions: [String] {
        let names = Set(sessions.map(\.projectName))
        return [SessionStore.allProjectsLabel] + names.sorted()
    }

    private var service: CodexSessionService {
        CodexSessionService(codexRoot: URL(fileURLWithPath: expandedPath(codexRootPath), isDirectory: true))
    }

    func refresh() {
        do {
            try service.reconcileSessionIndex()
            sessions = try service.loadSessions()
            usage = UsageMetricsService().loadUsageSnapshot(codexRoot: service.codexRootURL)
            selectedIDs = selectedIDs.intersection(Set(sessions.map(\.id)))
            if !projectOptions.contains(selectedProject) {
                selectedProject = SessionStore.allProjectsLabel
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func archiveSelected() {
        do {
            try service.archive(selectedSessions)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func unarchiveSelected() {
        do {
            try service.unarchive(selectedSessions)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func trashSelected() {
        do {
            try service.trash(selectedSessions)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func trashProject(named projectName: String) {
        let targets = sessions.filter { $0.projectName == projectName }
        do {
            try service.trash(targets)
            selectedIDs.removeAll()
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateCodexRootPath(_ newPath: String) {
        let trimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        codexRootPath = trimmed.isEmpty ? SessionStore.defaultCodexRootPath() : expandedPath(trimmed)
        selectedIDs.removeAll()
        refresh()
    }

    func clearError() {
        lastError = nil
    }

    func recentSessions(limit: Int = 6) -> [CodexSession] {
        Array(sessions.prefix(limit))
    }

    private func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}
