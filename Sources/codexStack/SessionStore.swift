import Foundation
import UserNotifications
@MainActor
final class SessionStore: ObservableObject {
    static let allProjectsLabel = "All Projects"
    nonisolated static func defaultCodexRootPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex").path
    }

    @Published private(set) var sessions: [CodexSession] = []
    @Published private(set) var projects: [CodexProject] = []
    @Published var searchText: String = ""
    @Published var scope: SessionScope = .active {
        didSet {
            if oldValue != scope {
                selectedIDs.removeAll()
            }
        }
    }
    @Published var selectedProject: String = SessionStore.allProjectsLabel
    @Published var selectedIDs: Set<String> = []
    @Published var utilizationProgressMode: UtilizationProgressMode
    @Published var refreshInterval: RefreshInterval
    @Published private(set) var codexRootPath: String
    @Published private(set) var usage: UsageSnapshot = .empty
    @Published private(set) var preferredAccountID: String?
    @Published var autoSwitchEnabled: Bool
    @Published var autoSwitchSessionThreshold: Double
    @Published var autoSwitchWeeklyThreshold: Double
    @Published var autoSwitchNotificationEnabled: Bool
    @Published var celebrateWeeklyReset: Bool
    static let preferredAccountIDDefaultsKey = "preferredAccountID"
    static let autoSwitchEnabledDefaultsKey = "autoSwitchEnabled"
    static let autoSwitchSessionThresholdDefaultsKey = "autoSwitchSessionThreshold"
    static let autoSwitchWeeklyThresholdDefaultsKey = "autoSwitchWeeklyThreshold"
    static let autoSwitchNotificationEnabledDefaultsKey = "autoSwitchNotificationEnabled"
    static let celebrateWeeklyResetDefaultsKey = "celebrateWeeklyReset"
    private static let lastWeeklyResetSeenKey = "lastWeeklyResetSeen"
    
    @Published var activeProvider: String? = nil
    @Published var availableProviders: [String] = []
    
    var onResetCelebration: ((ResetCelebrationKind) -> Void)?
    var onAutoSwitchPerformed: ((String) -> Void)?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMutating = false
    @Published private(set) var mutationMessage: String?
    @Published private(set) var lastError: String?
    private var refreshTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?

    init(
        codexRootPath: String = SessionStore.defaultCodexRootPath(),
        utilizationProgressMode: UtilizationProgressMode = .remaining,
        refreshInterval: RefreshInterval = .off,
        preferredAccountID: String? = nil,
        autoSwitchEnabled: Bool = false,
        autoSwitchSessionThreshold: Double = 90.0,
        autoSwitchWeeklyThreshold: Double = 90.0,
        autoSwitchNotificationEnabled: Bool = true,
        celebrateWeeklyReset: Bool = true
    ) {
        self.codexRootPath = codexRootPath
        self.utilizationProgressMode = utilizationProgressMode
        self.refreshInterval = refreshInterval
        self.preferredAccountID = preferredAccountID
        self.autoSwitchEnabled = autoSwitchEnabled
        self.autoSwitchSessionThreshold = autoSwitchSessionThreshold
        self.autoSwitchWeeklyThreshold = autoSwitchWeeklyThreshold
        self.autoSwitchNotificationEnabled = autoSwitchNotificationEnabled
        self.celebrateWeeklyReset = celebrateWeeklyReset
        refresh()
        scheduleAutoRefresh()
        
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        
        NotificationCenter.default.addObserver(forName: .pricingUpdated, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        autoRefreshTask?.cancel()
        refreshTask?.cancel()
        mutationTask?.cancel()
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
        var names = Set(sessions.map(\.projectName))
        names.formUnion(projects.map(\.name))
        return [SessionStore.allProjectsLabel] + names.sorted()
    }

    var projectMoveTargets: [ProjectMoveTarget] {
        var targetsByPath: [String: ProjectMoveTarget] = [:]

        for project in projects {
            targetsByPath[project.path] = ProjectMoveTarget(name: project.name, path: project.path)
        }

        for session in sessions {
            guard let projectPath = session.projectPath, !projectPath.isEmpty else {
                continue
            }
            targetsByPath[projectPath] = ProjectMoveTarget(name: session.projectName, path: projectPath)
        }

        let sortedTargets = targetsByPath.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return [.chats] + sortedTargets
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
        loadConfigProviders()
        let rootPath = expandedPath(codexRootPath)
        let preferredID = preferredAccountID

        refreshTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.computeRefreshResult(codexRootPath: rootPath, preferredAccountID: preferredID)
            }.value

            await MainActor.run {
                refreshTask = nil
                isRefreshing = false
                switch result {
                case let .success(snapshot):
                    sessions = snapshot.sessions
                    projects = snapshot.projects
                    detectResetCelebrations(in: snapshot.usage)
                    usage = snapshot.usage
                    performAutoSwitchIfNeeded(for: snapshot.usage)
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

    private func performAutoSwitchIfNeeded(for newUsage: UsageSnapshot) {
        guard autoSwitchEnabled else { return }
        guard activeProvider == nil else { return }
        
        let currentID = preferredAccountID ?? newUsage.accounts.first?.id
        guard let currentAccount = newUsage.accounts.first(where: { $0.id == currentID }) else { return }
        
        let sessionPct = (currentAccount.sessionUsedRatio ?? 0) * 100
        let weeklyPct = (currentAccount.weeklyUsedRatio ?? 0) * 100
        
        let triggersSession = sessionPct >= autoSwitchSessionThreshold
        let triggersWeekly = weeklyPct >= autoSwitchWeeklyThreshold
        
        if triggersSession || triggersWeekly {
            if let bestAccount = newUsage.accounts.filter({ $0.id != currentID }).min(by: { a, b in
                let aMax = max((a.sessionUsedRatio ?? 0), (a.weeklyUsedRatio ?? 0))
                let bMax = max((b.sessionUsedRatio ?? 0), (b.weeklyUsedRatio ?? 0))
                return aMax < bMax
            }) {
                let bestSession = (bestAccount.sessionUsedRatio ?? 0) * 100
                let bestWeekly = (bestAccount.weeklyUsedRatio ?? 0) * 100
                if bestSession < autoSwitchSessionThreshold && bestWeekly < autoSwitchWeeklyThreshold {
                    do {
                        try syncToAuthJSON(accountID: bestAccount.id)
                        setPreferredAccountID(bestAccount.id)
                        
                        if autoSwitchNotificationEnabled && Bundle.main.bundleIdentifier != nil {
                            let content = UNMutableNotificationContent()
                            content.title = NSLocalizedString("CodexStack Auto-Switch", bundle: .module, comment: "")
                            let maxPct = max(sessionPct, weeklyPct)
                            content.body = String.localizedStringWithFormat(
                                NSLocalizedString("Switched to account %@ because current usage reached %.0f%%.", bundle: .module, comment: ""),
                                bestAccount.name ?? bestAccount.email ?? "Codex", maxPct
                            )
                            content.sound = .default
                            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                            UNUserNotificationCenter.current().add(request)
                        }
                        
                        onAutoSwitchPerformed?(bestAccount.id)
                    } catch {
                        lastError = "Auto-switch failed: \(error.localizedDescription)"
                    }
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
            .trashProject(projectPath: nil, projectName: projectName),
            message: localized("mutation.removing_project"),
            clearSelectionOnSuccess: true
        )
    }

    func trashProject(path projectPath: String) {
        runMutation(
            .trashProject(projectPath: projectPath, projectName: nil),
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

    func moveSession(id: String, to target: ProjectMoveTarget) {
        runMutation(.move(ids: [id], projectPath: target.path), message: localized("mutation.moving"))
    }

    func moveSelected(to target: ProjectMoveTarget) {
        let ids = Set(selectedSessions.map(\.id))
        guard !ids.isEmpty else { return }
        runMutation(.move(ids: ids, projectPath: target.path), message: localized("mutation.moving"))
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

    func updateRefreshInterval(_ newInterval: RefreshInterval) {
        guard refreshInterval != newInterval else { return }
        refreshInterval = newInterval
        scheduleAutoRefresh()
    }

    func setCelebrateWeeklyReset(_ newValue: Bool) {
        guard celebrateWeeklyReset != newValue else { return }
        celebrateWeeklyReset = newValue
        UserDefaults.standard.set(newValue, forKey: SessionStore.celebrateWeeklyResetDefaultsKey)
    }

    private func detectResetCelebrations(in newUsage: UsageSnapshot) {
        let defaults = UserDefaults.standard
        let accountPrefix = newUsage.accountEmail ?? "default"
        let weeklyKey = "\(SessionStore.lastWeeklyResetSeenKey)_\(accountPrefix)_wasAbove"
        
        // Clean up legacy Date-based key from previous implementation if it exists
        let legacyWeeklyKey = "\(SessionStore.lastWeeklyResetSeenKey)_\(accountPrefix)"
        if defaults.object(forKey: legacyWeeklyKey) != nil {
            defaults.removeObject(forKey: legacyWeeklyKey)
        }

        var triggeredWeekly = false

        if let weeklyUsedRatio = newUsage.weeklyUsedRatio {
            let wasAbove = defaults.object(forKey: weeklyKey) as? Bool ?? false
            let currentAbove = weeklyUsedRatio > 0.01

            if wasAbove && !currentAbove && celebrateWeeklyReset {
                triggeredWeekly = true
            }
            defaults.set(currentAbove, forKey: weeklyKey)
        }

        if triggeredWeekly {
            onResetCelebration?(.weekly)
        }
    }

    func setPreferredAccountID(_ newID: String?) {
        guard preferredAccountID != newID else { return }
        preferredAccountID = newID
        UserDefaults.standard.set(newID, forKey: SessionStore.preferredAccountIDDefaultsKey)

        if let matching = usage.accounts.first(where: { $0.id == newID }) ?? usage.accounts.first {
            usage = UsageSnapshot(
                updatedAt: matching.updatedAt ?? usage.updatedAt,
                accountEmail: matching.email,
                accountName: matching.name,
                planType: matching.planType,
                source: matching.source,
                sessionUsedRatio: matching.sessionUsedRatio,
                weeklyUsedRatio: matching.weeklyUsedRatio,
                sessionResetAt: matching.sessionResetAt,
                weeklyResetAt: matching.weeklyResetAt,
                todayTokens: usage.todayTokens,
                last30DaysTokens: usage.last30DaysTokens,
                todayCostUSD: usage.todayCostUSD,
                last30DaysCostUSD: usage.last30DaysCostUSD,
                dailyCostSeries: usage.dailyCostSeries,
                accounts: reorderAccounts(usage.accounts, preferring: matching.id)
            )
        }
        refresh()
    }

    func syncToAuthJSON(accountID: String) throws {
        guard let account = AccountCredentialStore.loadAccounts().first(where: { $0.id == accountID }) else {
            throw NSError(domain: "codexStack", code: 404, userInfo: [NSLocalizedDescriptionKey: "Account details could not be loaded."])
        }

        let codexRoot = URL(fileURLWithPath: expandedPath(codexRootPath), isDirectory: true)
        let authURL = codexRoot.appending(path: "auth.json")
        
        var tokens: [String: Any] = ["access_token": account.accessToken]
        if let idToken = account.idToken { tokens["id_token"] = idToken }
        if let refreshToken = account.refreshToken { tokens["refresh_token"] = refreshToken }
        if let accountID = account.accountID { tokens["account_id"] = accountID }
        
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        
        let dict: [String: Any] = [
            "auth_mode": account.type == "codex" ? "chatgpt" : (account.type ?? "chatgpt"),
            "OPENAI_API_KEY": NSNull(),
            "tokens": tokens,
            "last_refresh": formatter.string(from: Date())
        ]

        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: authURL)
    }

    private func reorderAccounts(
        _ accounts: [UsageAccountSnapshot],
        preferring id: String
    ) -> [UsageAccountSnapshot] {
        guard let match = accounts.first(where: { $0.id == id }) else { return accounts }
        return [match] + accounts.filter { $0.id != id }
    }

    func clearError() {
        lastError = nil
    }

    func clearSelection() {
        selectedIDs.removeAll()
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

    private func scheduleAutoRefresh() {
        autoRefreshTask?.cancel()
        guard let seconds = refreshInterval.seconds else {
            autoRefreshTask = nil
            return
        }

        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return
                }

                await MainActor.run {
                    guard let self, !self.isBusy else { return }
                    self.refresh()
                }
            }
        }
    }

    private func runMutation(
        _ mutation: SessionMutation,
        message: String,
        clearSelectionOnSuccess: Bool = false
    ) {
        guard mutationTask == nil else { return }
        let rootPath = expandedPath(codexRootPath)
        let preferredID = preferredAccountID

        isMutating = true
        mutationMessage = message
        lastError = nil

        mutationTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.performMutation(codexRootPath: rootPath, mutation: mutation)
            }.value
            let refreshResult = await Task.detached(priority: .userInitiated) {
                Self.computeRefreshResult(codexRootPath: rootPath, preferredAccountID: preferredID)
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
                        projects = snapshot.projects
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

    nonisolated private static func computeRefreshResult(
        codexRootPath: String,
        preferredAccountID: String? = nil
    ) -> RefreshComputationResult {
        do {
            let service = CodexSessionService(codexRoot: URL(fileURLWithPath: codexRootPath, isDirectory: true))
            try service.reconcileSessionIndex()
            var rawSessions = try service.loadSessions()
            let projects = service.loadProjects(including: rawSessions)
            
            // Enrich sessions with usage metrics
            let usageService = UsageMetricsService()
            let usage = usageService.loadUsageSnapshot(
                codexRoot: service.codexRootURL,
                preferredAccountID: preferredAccountID
            )
            
            // Load metrics from cache (now persistent) to populate session list
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let cacheURL = appSupport.appendingPathComponent("codexStack/usage_cache.json")
            if let data = try? Data(contentsOf: cacheURL),
               let cache = try? JSONDecoder().decode(UsageCacheProxy.self, from: data) {
                for i in 0..<rawSessions.count {
                    if let metrics = cache.sessions[rawSessions[i].id]?.metrics {
                        rawSessions[i].usageTokens = metrics.tokens
                        rawSessions[i].usageCostUSD = metrics.cost
                    }
                }
            }
            
            return .success(
                RefreshSnapshot(
                    sessions: rawSessions,
                    projects: projects,
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
            case let .trashProject(projectPath, projectName):
                let targets: [CodexSession]
                if let projectPath {
                    targets = allSessions.filter { $0.projectPath == projectPath }
                } else if let projectName {
                    targets = allSessions.filter { $0.projectName == projectName && !$0.isChatsProject }
                } else {
                    targets = []
                }
                try service.trash(targets)
                if let projectPath {
                    _ = try service.removeSavedWorkspaceRoot(projectPath)
                }
            case let .rename(id, newTitle):
                try service.renameSession(id: id, newTitle: newTitle)
            case let .move(ids, projectPath):
                let targets = ids.compactMap { byID[$0] }
                try service.moveSessions(targets, toProjectPath: projectPath)
            }
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func loadConfigProviders() {
        let codexRoot = URL(fileURLWithPath: expandedPath(codexRootPath), isDirectory: true)
        let configURL = codexRoot.appending(path: "config.toml")
        guard FileManager.default.fileExists(atPath: configURL.path),
              let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return
        }
        
        var currentActive: String? = nil
        var providers: [String] = []
        
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("model_provider"), let equalsRange = trimmed.range(of: "=") {
                var value = String(trimmed[equalsRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                currentActive = value
            } else if trimmed.hasPrefix("[model_providers.") {
                let name = trimmed.replacingOccurrences(of: "[model_providers.", with: "").replacingOccurrences(of: "]", with: "")
                if !name.isEmpty && !providers.contains(name) {
                    providers.append(name)
                }
            }
        }
        
        DispatchQueue.main.async {
            self.activeProvider = currentActive
            self.availableProviders = providers
        }
    }

    private func syncConfigProvider(accountType: String?, codexRoot: URL) {
        let configURL = codexRoot.appending(path: "config.toml")
        guard FileManager.default.fileExists(atPath: configURL.path),
              let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return
        }
        
        let targetProvider = (accountType == nil || accountType == "codex" || accountType == "chatgpt") ? nil : accountType!
        
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found = false
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("model_provider") || trimmed.hasPrefix("#model_provider") || trimmed.hasPrefix("# model_provider") {
                if let target = targetProvider {
                    lines[i] = "model_provider = \"\(target)\""
                } else {
                    if !trimmed.hasPrefix("#") {
                        lines[i] = "#\(line)"
                    }
                }
                found = true
                break
            }
        }
        
        if !found, let target = targetProvider {
            if let firstModelIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("model ") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("model=") }) {
                lines.insert("model_provider = \"\(target)\"", at: firstModelIndex + 1)
            } else {
                lines.insert("model_provider = \"\(target)\"", at: 0)
            }
        }
        
        try? lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
    }

    func applyConfigProvider(_ targetProvider: String?) throws {
        let codexRoot = URL(fileURLWithPath: expandedPath(codexRootPath), isDirectory: true)
        syncConfigProvider(accountType: targetProvider, codexRoot: codexRoot)
        let syncService = ProviderSyncService(codexRoot: codexRoot)
        _ = try? syncService.sync()
        loadConfigProviders()
        Task { @MainActor in
            self.refresh()
        }
        NotificationCenter.default.post(name: NSNotification.Name("CodexConfigProviderChanged"), object: nil)
    }
}

private struct RefreshSnapshot: Sendable {
    let sessions: [CodexSession]
    let projects: [CodexProject]
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
    case trashProject(projectPath: String?, projectName: String?)
    case rename(id: String, newTitle: String)
    case move(ids: Set<String>, projectPath: String?)
}

// Proxy types to read UsageMetricsService internal cache without public exposure
private struct UsageCacheProxy: Decodable {
    var sessions: [String: CachedSessionMetricsProxy]
}

private struct CachedSessionMetricsProxy: Decodable {
    let metrics: SessionMetricsProxy
}

private struct SessionMetricsProxy: Decodable {
    var tokens: Int64
    var cost: Double
}
