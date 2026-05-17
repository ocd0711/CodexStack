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
    @Published var utilizationProgressMode: UtilizationProgressMode
    @Published private(set) var codexRootPath: String
    @Published private(set) var usage: UsageSnapshot = .empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMutating = false
    @Published private(set) var mutationMessage: String?
    @Published private(set) var lastError: String?
    private var refreshTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?

    init(
        codexRootPath: String = SessionStore.defaultCodexRootPath(),
        utilizationProgressMode: UtilizationProgressMode = .remaining
    ) {
        self.codexRootPath = codexRootPath
        self.utilizationProgressMode = utilizationProgressMode
        refresh()
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

    var isBusy: Bool {
        isRefreshing || isMutating
    }

    private var service: CodexSessionService {
        CodexSessionService(codexRoot: URL(fileURLWithPath: expandedPath(codexRootPath), isDirectory: true))
    }

    func refresh() {
        guard refreshTask == nil else { return }
        isRefreshing = true
        let rootPath = expandedPath(codexRootPath)

        refreshTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.computeRefreshResult(codexRootPath: rootPath)
            }.value

            await MainActor.run {
                refreshTask = nil
                isRefreshing = false
                switch result {
                case let .success(snapshot):
                    sessions = snapshot.sessions
                    usage = snapshot.usage
                    selectedIDs = selectedIDs.intersection(Set(sessions.map(\.id)))
                    if !projectOptions.contains(selectedProject) {
                        selectedProject = SessionStore.allProjectsLabel
                    }
                    lastError = nil
                case let .failure(message):
                    lastError = message
                }
            }
        }
    }

    func archiveSelected() {
        let ids = Set(selectedSessions.filter { !$0.isArchived }.map(\.id))
        guard !ids.isEmpty else { return }
        runMutation(.archive(ids: ids), message: localized("mutation.archiving"))
    }

    func unarchiveSelected() {
        let ids = Set(selectedSessions.filter { $0.isArchived }.map(\.id))
        guard !ids.isEmpty else { return }
        runMutation(.unarchive(ids: ids), message: localized("mutation.unarchiving"))
    }

    func trashSelected() {
        let ids = Set(selectedSessions.map(\.id))
        guard !ids.isEmpty else { return }
        runMutation(.trash(ids: ids), message: localized("mutation.trashing"), clearSelectionOnSuccess: true)
    }

    func trashSession(id: String) {
        runMutation(.trash(ids: [id]), message: localized("mutation.trashing"), clearSelectionOnSuccess: true)
    }

    func trashProject(named projectName: String) {
        runMutation(
            .trashProject(projectName: projectName),
            message: localized("mutation.removing_project"),
            clearSelectionOnSuccess: true
        )
    }

    func archiveSession(id: String) {
        runMutation(.archive(ids: [id]), message: localized("mutation.archiving"))
    }

    func unarchiveSession(id: String) {
        runMutation(.unarchive(ids: [id]), message: localized("mutation.unarchiving"))
    }

    func renameSession(id: String, newTitle: String) {
        runMutation(.rename(id: id, newTitle: newTitle), message: localized("mutation.renaming"))
    }

    func updateCodexRootPath(_ newPath: String) {
        let trimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        codexRootPath = trimmed.isEmpty ? SessionStore.defaultCodexRootPath() : expandedPath(trimmed)
        selectedIDs.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        refresh()
    }

    func updateUtilizationProgressMode(_ newMode: UtilizationProgressMode) {
        utilizationProgressMode = newMode
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

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }

    private func runMutation(
        _ mutation: SessionMutation,
        message: String,
        clearSelectionOnSuccess: Bool = false
    ) {
        guard mutationTask == nil else { return }
        let rootPath = expandedPath(codexRootPath)

        isMutating = true
        mutationMessage = message
        lastError = nil

        mutationTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.performMutation(codexRootPath: rootPath, mutation: mutation)
            }.value
            let refreshResult = await Task.detached(priority: .userInitiated) {
                Self.computeRefreshResult(codexRootPath: rootPath)
            }.value

            await MainActor.run {
                mutationTask = nil
                isMutating = false
                mutationMessage = nil

                switch result {
                case .success:
                    switch refreshResult {
                    case let .success(snapshot):
                        sessions = snapshot.sessions
                        usage = snapshot.usage
                        if clearSelectionOnSuccess {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = selectedIDs.intersection(Set(sessions.map(\.id)))
                        }
                        if !projectOptions.contains(selectedProject) {
                            selectedProject = SessionStore.allProjectsLabel
                        }
                        lastError = nil
                    case let .failure(message):
                        lastError = message
                    }
                case let .failure(message):
                    lastError = message
                }
            }
        }
    }

    nonisolated private static func computeRefreshResult(codexRootPath: String) -> RefreshComputationResult {
        do {
            let service = CodexSessionService(codexRoot: URL(fileURLWithPath: codexRootPath, isDirectory: true))
            try service.reconcileSessionIndex()
            let sessions = try service.loadSessions()
            let usage = UsageMetricsService().loadUsageSnapshot(codexRoot: service.codexRootURL)
            return .success(
                RefreshSnapshot(
                    sessions: sessions,
                    usage: usage
                )
            )
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    nonisolated private static func performMutation(
        codexRootPath: String,
        mutation: SessionMutation
    ) -> MutationComputationResult {
        do {
            let service = CodexSessionService(codexRoot: URL(fileURLWithPath: codexRootPath, isDirectory: true))
            let allSessions = try service.loadSessions()
            let byID = Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, $0) })

            switch mutation {
            case let .archive(ids):
                let targets = ids.compactMap { byID[$0] }.filter { !$0.isArchived }
                try service.archive(targets)
            case let .unarchive(ids):
                let targets = ids.compactMap { byID[$0] }.filter { $0.isArchived }
                try service.unarchive(targets)
            case let .trash(ids):
                let targets = ids.compactMap { byID[$0] }
                try service.trash(targets)
            case let .trashProject(projectName):
                let targets = allSessions.filter { $0.projectName == projectName }
                try service.trash(targets)
            case let .rename(id, newTitle):
                try service.renameSession(id: id, newTitle: newTitle)
            }
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

private struct RefreshSnapshot: Sendable {
    let sessions: [CodexSession]
    let usage: UsageSnapshot
}

private enum RefreshComputationResult: Sendable {
    case success(RefreshSnapshot)
    case failure(String)
}

private enum MutationComputationResult: Sendable {
    case success
    case failure(String)
}

private enum SessionMutation: Sendable {
    case archive(ids: Set<String>)
    case unarchive(ids: Set<String>)
    case trash(ids: Set<String>)
    case trashProject(projectName: String)
    case rename(id: String, newTitle: String)
}
