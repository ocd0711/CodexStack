import AppKit
import ServiceManagement
import SwiftUI

@main
struct CodexStackApp: App {
    private static let codexRootPathDefaultsKey = "codexRootPath"
    private static let utilizationProgressModeDefaultsKey = "utilizationProgressMode"
    private static let showMenuBarPercentageDefaultsKey = "showMenuBarPercentage"
    private static let refreshIntervalDefaultsKey = "refreshInterval"
    private static let launchAtLoginDefaultsKey = "launchAtLogin"
    @NSApplicationDelegateAdaptor(CodexStackAppDelegate.self) private var appDelegate
    @StateObject private var store: SessionStore
    @State private var showMenuBarPercentage: Bool
    @State private var launchAtLogin: Bool

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.codexRootPathDefaultsKey)
            ?? SessionStore.defaultCodexRootPath()
        let savedModeRaw = UserDefaults.standard.string(forKey: Self.utilizationProgressModeDefaultsKey)
        let savedMode = UtilizationProgressMode(rawValue: savedModeRaw ?? "") ?? .remaining
        let showPercentage = UserDefaults.standard.object(forKey: Self.showMenuBarPercentageDefaultsKey) as? Bool ?? true
        let savedRefreshRaw = UserDefaults.standard.object(forKey: Self.refreshIntervalDefaultsKey) as? Int
        let savedRefreshInterval = RefreshInterval(rawValue: savedRefreshRaw ?? 0) ?? .off
        let launchAtLoginEnabled = LaunchAtLoginController.isEnabled
        let preferredAccountID = UserDefaults.standard.string(forKey: SessionStore.preferredAccountIDDefaultsKey)
        let celebrateSession = (UserDefaults.standard.object(forKey: SessionStore.celebrateSessionResetDefaultsKey) as? Bool) ?? true
        let celebrateWeekly = (UserDefaults.standard.object(forKey: SessionStore.celebrateWeeklyResetDefaultsKey) as? Bool) ?? true
        let store = SessionStore(
            codexRootPath: saved,
            utilizationProgressMode: savedMode,
            refreshInterval: savedRefreshInterval,
            preferredAccountID: preferredAccountID,
            celebrateSessionReset: celebrateSession,
            celebrateWeeklyReset: celebrateWeekly
        )
        store.onResetCelebration = { kind in
            ResetCelebrationController.shared.present(kind: kind)
        }
        _store = StateObject(wrappedValue: store)
        _showMenuBarPercentage = State(initialValue: showPercentage)
        _launchAtLogin = State(initialValue: launchAtLoginEnabled)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(
                onOpenSettings: {
                    SettingsWindowController.shared.show(
                        currentPath: store.codexRootPath,
                        currentProgressMode: store.utilizationProgressMode,
                        showMenuBarPercentage: showMenuBarPercentage,
                        refreshInterval: store.refreshInterval,
                        launchAtLogin: launchAtLogin,
                        celebrateSessionReset: store.celebrateSessionReset,
                        celebrateWeeklyReset: store.celebrateWeeklyReset,
                        onSave: { newPath, progressMode, showPercentage, refreshInterval, launchAtLoginEnabled in
                        let expanded = NSString(string: newPath).expandingTildeInPath
                        UserDefaults.standard.set(expanded, forKey: Self.codexRootPathDefaultsKey)
                        UserDefaults.standard.set(
                            progressMode.rawValue,
                            forKey: Self.utilizationProgressModeDefaultsKey
                        )
                        UserDefaults.standard.set(showPercentage, forKey: Self.showMenuBarPercentageDefaultsKey)
                        UserDefaults.standard.set(refreshInterval.rawValue, forKey: Self.refreshIntervalDefaultsKey)
                        UserDefaults.standard.set(launchAtLoginEnabled, forKey: Self.launchAtLoginDefaultsKey)
                        if expanded != store.codexRootPath {
                            store.updateCodexRootPath(expanded)
                        }
                        store.updateUtilizationProgressMode(progressMode)
                        store.updateRefreshInterval(refreshInterval)
                        showMenuBarPercentage = showPercentage
                        launchAtLogin = launchAtLoginEnabled
                        },
                        onCelebrationChanged: { sessionOn, weeklyOn in
                            store.setCelebrateSessionReset(sessionOn)
                            store.setCelebrateWeeklyReset(weeklyOn)
                        },
                        onAccountsChanged: {
                            store.refresh()
                        }
                    )
                }
            )
            .environmentObject(store)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: statusBarIcon)
                    .resizable()
                    .frame(width: 18, height: 18)
                if showMenuBarPercentage, let percent = menuBarPercent {
                    Text("\(percent)%")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
            }
            .accessibilityLabel(menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }

    private var statusBarIcon: NSImage {
        StatusIconRenderer.makeIcon(
            sessionUsedRatio: store.usage.sessionUsedRatio,
            weeklyUsedRatio: store.usage.weeklyUsedRatio,
            progressMode: store.utilizationProgressMode
        )
    }

    private var menuBarTitle: String {
        guard let percent = menuBarPercent else { return "codexStack" }
        let suffix = store.utilizationProgressMode == .used
            ? NSLocalizedString("Used", bundle: .module, comment: "")
            : NSLocalizedString("Remaining", bundle: .module, comment: "")
        return "codexStack \(percent)% \(suffix)"
    }

    private var menuBarPercent: Int? {
        let ratio = store.usage.weeklyUsedRatio ?? store.usage.sessionUsedRatio
        guard let ratio else { return nil }
        let clamped = min(1, max(0, ratio))
        let value = store.utilizationProgressMode == .used ? clamped : (1 - clamped)
        return Int((value * 100).rounded())
    }
}

final class CodexStackAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
private enum LaunchAtLoginController {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

private enum MenuDrilldownPane {
    case none
    case cost
    case projects
}

private struct MenuBarPanel: View {
    @EnvironmentObject private var store: SessionStore
    let onOpenSettings: () -> Void
    @State private var activePane: MenuDrilldownPane = .none
    @State private var hoveredCostDayID: TimeInterval?
    @State private var hoverCostCard = false
    @State private var hoverProjectsCard = false
    @State private var hoverDetailPane = false
    @State private var closePaneTask: Task<Void, Never>?
    @AppStorage("accountsSortOption") private var accountsSortRaw: String = AccountsSortOption.importedNewest.rawValue
    @AppStorage("accountsManualOrder") private var accountsManualOrderRaw: String = ""
    @AppStorage("accountsPinActive") private var accountsPinActive: Bool = false

    private var rawSortedAccounts: [UsageAccountSnapshot] {
        let sortOption = AccountsSortOption(rawValue: accountsSortRaw) ?? .importedNewest
        let manualOrderIDs = accountsManualOrderRaw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        return sortOption.sort(store.usage.accounts, manualOrder: manualOrderIDs)
    }

    private var sortedAccounts: [UsageAccountSnapshot] {
        var accounts = rawSortedAccounts
        if accountsPinActive, let activeID = activeAccountID, let index = accounts.firstIndex(where: { $0.id == activeID }), index != 0 {
            let active = accounts.remove(at: index)
            accounts.insert(active, at: 0)
        }
        return accounts
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            UtilizationSection(
                usage: store.usage,
                accounts: sortedAccounts,
                progressMode: store.utilizationProgressMode,
                activeAccountID: activeAccountID
            )
            costSummaryCard
            projectsSummaryCard
            actionsRow
        }
        .padding(12)
        .frame(minWidth: 360, idealWidth: 390, maxWidth: 420)
        .background(.regularMaterial)
        .animation(.easeInOut(duration: 0.12), value: activePane)
        .onDisappear {
            cancelClosePaneTask()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex")
                    .font(.title3.weight(.semibold))
                accountSwitcher
                if let updatedAt = store.usage.updatedAt {
                    Text("\(store.usage.source.label) · Updated \(updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(store.usage.source.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(planLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else if store.isMutating {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var accountSwitcher: some View {
        let accounts = sortedAccounts
        if accounts.count > 1 {
            Menu {
                ForEach(accounts) { account in
                    Button {
                        store.setPreferredAccountID(account.id)
                    } label: {
                        if account.id == activeAccountID {
                            Label(accountMenuLabel(for: account), systemImage: "checkmark")
                        } else {
                            Text(accountMenuLabel(for: account))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(accountLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            Text(accountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var activeAccountID: String? {
        store.preferredAccountID ?? rawSortedAccounts.first?.id
    }

    private func accountMenuLabel(for account: UsageAccountSnapshot) -> String {
        var parts: [String] = [accountDisplayLabel(for: account) ?? account.displayName]
        if let plan = account.planType, !plan.isEmpty {
            parts.append(plan.uppercased())
        }
        if account.isCredentialExpired {
            parts.append("Expired")
        }
        return parts.joined(separator: " · ")
    }

    private var costSummaryCard: some View {
        Button {
            activePane = .cost
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Cost")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(
                        String.localizedStringWithFormat(
                            NSLocalizedString("Today: %@ · %@", bundle: .module, comment: ""),
                            formatUSD(store.usage.todayCostUSD),
                            formatTokens(store.usage.todayTokens)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Text(
                        String.localizedStringWithFormat(
                            NSLocalizedString("Last 30 days: %@ · %@", bundle: .module, comment: ""),
                            formatUSD(store.usage.last30DaysCostUSD),
                            formatTokens(store.usage.last30DaysTokens)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: isCostPopoverPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
            costDetailPane
                .frame(width: costPopoverWidth)
                .onHover { hovering in
                    hoverDetailPane = hovering
                    if hovering {
                        cancelClosePaneTask()
                    } else {
                        scheduleClosePaneIfNeeded()
                    }
                }
        }
        .onHover { hovering in
            hoverCostCard = hovering
            if hovering {
                cancelClosePaneTask()
                activePane = .cost
            } else {
                scheduleClosePaneIfNeeded()
            }
        }
    }

    private var projectsSummaryCard: some View {
        Button {
            activePane = .projects
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Projects")
                        .font(.headline)
                    Spacer()
                    Text(
                        String.localizedStringWithFormat(
                            NSLocalizedString("%d sessions", bundle: .module, comment: ""),
                            store.sessions.count
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if groupedProjects().isEmpty {
                    Text("No sessions found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(recentProjectLabels, id: \.self) { label in
                            Text(label)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: isProjectsPopoverPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
            projectsDetailPane
                .frame(width: projectsPopoverWidth)
                .onHover { hovering in
                    hoverDetailPane = hovering
                    if hovering {
                        cancelClosePaneTask()
                    } else {
                        scheduleClosePaneIfNeeded()
                    }
                }
        }
        .onHover { hovering in
            hoverProjectsCard = hovering
            if hovering {
                cancelClosePaneTask()
                activePane = .projects
            } else {
                scheduleClosePaneIfNeeded()
            }
        }
    }

    private var costDetailPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cost")
                    .font(.headline)
                Spacer()
                Text(
                    String.localizedStringWithFormat(
                        NSLocalizedString("Est. total (30d): %@", bundle: .module, comment: ""),
                        formatUSD(store.usage.last30DaysCostUSD)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            CostBarsView(
                dailySeries: store.usage.dailyCostSeries,
                selectedDayID: selectedCostDay?.id,
                onHoverDay: { day in
                    hoveredCostDayID = day?.timeIntervalSince1970
                }
            )

            if let selectedCostDay {
                HStack {
                    Text(selectedCostDay.dayStart.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(formatUSD(selectedCostDay.costUSD)) · \(formatTokens(selectedCostDay.tokens)) tokens")
                        .font(.caption)
                }
                if selectedCostDay.modelBreakdowns.isEmpty {
                    Text(NSLocalizedString("No per-model breakdown", bundle: .module, comment: ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(height: 24, alignment: .leading)
                } else {
                    let visibleRows = Array(selectedCostDay.modelBreakdowns.prefix(3))
                    ForEach(visibleRows) { item in
                        HStack(spacing: 8) {
                            Rectangle()
                                .fill(Color.teal.opacity(0.65))
                                .frame(width: 2, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.modelName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text("\(formatUSD(item.costUSD)) · \(formatTokens(item.tokens))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .frame(height: 24, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var projectsDetailPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Projects")
                    .font(.headline)
                Spacer()
                Text(
                    String.localizedStringWithFormat(
                        NSLocalizedString("%d sessions", bundle: .module, comment: ""),
                        store.sessions.count
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if groupedProjects().isEmpty {
                Text("No sessions found")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groupedProjects()) { project in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(project.projectName)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .help(project.projectName)
                                    Spacer()
                                    Text("\(project.sessions.count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !project.isChatsProject {
                                        Menu {
                                            Button("Remove Project...", role: .destructive) {
                                                confirmProjectDeletion(project: project)
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                ForEach(project.sessions) { session in
                                    HStack {
                                        Text(session.title)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .help(session.title)
                                        Spacer()
                                        Menu {
                                            Button(session.isArchived ? "Unarchive" : "Archive") {
                                                if session.isArchived {
                                                    store.unarchiveSession(id: session.id)
                                                } else {
                                                    store.archiveSession(id: session.id)
                                                }
                                            }
                                            Button("Rename...") {
                                                if let newTitle = DialogPresenter.promptRename(initialTitle: session.title) {
                                                    store.renameSession(id: session.id, newTitle: newTitle)
                                                }
                                            }
                                            Button("Move to Project...") {
                                                if let target = DialogPresenter.promptMoveProject(targets: moveTargets(for: session)) {
                                                    store.moveSession(id: session.id, to: target)
                                                }
                                            }
                                            .disabled(moveTargets(for: session).isEmpty)
                                            Button("Delete Conversation...", role: .destructive) {
                                                confirmSessionDeletion(session: session)
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis")
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                if project.sessions.isEmpty {
                                    Text("No chats in this scope")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220, maxHeight: projectsPopoverHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .overlay(alignment: .bottomLeading) {
            if store.isMutating, let message = store.mutationMessage {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }

    private var actionsRow: some View {
        HStack {
            Button("Open Manager") {
                ManagerWindowController.shared.show(with: store)
            }
            Button("Refresh") {
                store.refresh()
            }
            .disabled(store.isBusy)
            Button("Settings...") {
                activePane = .none
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    onOpenSettings()
                }
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .buttonStyle(.bordered)
        .disabled(store.isMutating)
    }

    private var recentProjectLabels: [String] {
        groupedProjects().prefix(3).map { "\($0.projectName) · \($0.sessions.count)" }
    }

    private var projectsPopoverWidth: CGFloat {
        420
    }

    private var costPopoverWidth: CGFloat {
        340
    }

    private var projectsPopoverHeight: CGFloat {
        let projectCount = groupedProjects().count
        let rowEstimate = CGFloat(max(1, projectCount)) * 36
        return min(520, max(220, rowEstimate + 160))
    }

    private var costDisplaySeries: [UsageDailyCost] {
        guard !store.usage.dailyCostSeries.isEmpty else {
            let today = Calendar.current.startOfDay(for: Date())
            return stride(from: 6, through: 0, by: -1).compactMap { offset in
                guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: today) else { return nil }
                return UsageDailyCost(dayStart: day, tokens: 0, costUSD: 0, modelBreakdowns: [])
            }
        }
        return store.usage.dailyCostSeries
    }

    private var selectedCostDay: UsageDailyCost? {
        if let hoveredCostDayID {
            return costDisplaySeries.first(where: { $0.id == hoveredCostDayID })
        }
        return costDisplaySeries.last
    }

    private func groupedProjects() -> [ProjectMenuGroup] {
        let recent = store.sessions.sorted { $0.updatedAt > $1.updatedAt }
        var grouped = Dictionary(grouping: recent, by: \.projectID)
        for project in store.projects {
            if grouped[project.id] == nil {
                grouped[project.id] = []
            }
        }

        let groups = grouped.compactMap { _, value -> ProjectMenuGroup? in
            guard let first = value.first else { return nil }
            return ProjectMenuGroup(
                id: first.projectID,
                projectName: first.projectName,
                projectPath: first.projectPath,
                latest: value.first?.updatedAt ?? .distantPast,
                sessions: value
            )
        } + store.projects.compactMap { project -> ProjectMenuGroup? in
            guard grouped[project.id]?.isEmpty == true else { return nil }
            return ProjectMenuGroup(
                id: project.id,
                projectName: project.name,
                projectPath: project.path,
                latest: .distantPast,
                sessions: []
            )
        }
        return groups.sorted { $0.latest > $1.latest }
    }

    private var accountLabel: String {
        let activeID = activeAccountID
        let active = sortedAccounts.first { $0.id == activeID } ?? sortedAccounts.first
        if let active, let label = accountDisplayLabel(for: active) {
            return label
        }
        if let email = store.usage.accountEmail, !email.isEmpty {
            return email
        }
        if let name = store.usage.accountName, !name.isEmpty {
            return name
        }
        return "Account unavailable"
    }

    private func accountDisplayLabel(for account: UsageAccountSnapshot) -> String? {
        let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = account.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (email?.isEmpty == false ? email : nil, nickname?.isEmpty == false ? nickname : nil) {
        case let (email?, nickname?):
            return "\(email) (\(nickname))"
        case let (email?, nil):
            return email
        case let (nil, nickname?):
            return nickname
        default:
            if let id = account.accountID, !id.isEmpty { return id }
            return nil
        }
    }

    private var planLabel: String {
        let activeID = activeAccountID
        let activeAccount = sortedAccounts.first { $0.id == activeID } ?? sortedAccounts.first
        guard let plan = activeAccount?.planType ?? store.usage.planType, !plan.isEmpty else {
            return "No Plan"
        }
        return plan.uppercased()
    }

    private func formatTokens(_ value: Int64) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private func formatUSD(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    private func confirmProjectDeletion(project: ProjectMenuGroup) {
        guard let projectPath = project.projectPath else { return }
        let message = String.localizedStringWithFormat(
            NSLocalizedString("Project: %@", bundle: .module, comment: ""),
            project.projectName
        )
        if DialogPresenter.confirmDestructive(
            title: NSLocalizedString(
                project.sessions.isEmpty ? "Remove this project from Codex?" : "Delete all conversations in this project?",
                bundle: .module,
                comment: ""
            ),
            message: message,
            buttonTitle: NSLocalizedString(
                project.sessions.isEmpty ? "Remove Project" : "Delete Project",
                bundle: .module,
                comment: ""
            )
        ) {
            store.trashProject(path: projectPath)
        }
    }

    private func confirmSessionDeletion(session: CodexSession) {
        if DialogPresenter.confirmDestructive(
            title: NSLocalizedString("Delete this conversation?", bundle: .module, comment: ""),
            message: session.title,
            buttonTitle: NSLocalizedString("Delete Conversation", bundle: .module, comment: "")
        ) {
            store.trashSession(id: session.id)
        }
    }

    private func moveTargets(for session: CodexSession) -> [ProjectMoveTarget] {
        store.projectMoveTargets.filter { $0.path != session.projectPath }
    }

    private func scheduleClosePaneIfNeeded() {
        cancelClosePaneTask()
        closePaneTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if !hoverCostCard && !hoverProjectsCard && !hoverDetailPane {
                    activePane = .none
                }
            }
        }
    }

    private func cancelClosePaneTask() {
        closePaneTask?.cancel()
        closePaneTask = nil
    }

    private var isCostPopoverPresented: Binding<Bool> {
        Binding(
            get: { activePane == .cost },
            set: { isPresented in
                if !isPresented, activePane == .cost {
                    hoverDetailPane = false
                    activePane = .none
                }
            }
        )
    }

    private var isProjectsPopoverPresented: Binding<Bool> {
        Binding(
            get: { activePane == .projects },
            set: { isPresented in
                if !isPresented, activePane == .projects {
                    hoverDetailPane = false
                    activePane = .none
                }
            }
        )
    }
}

private struct CostBarsView: View {
    let dailySeries: [UsageDailyCost]
    var selectedDayID: TimeInterval? = nil
    var onHoverDay: ((Date?) -> Void)? = nil
    private let chartHeight: CGFloat = 88
    private let maxBarHeight: CGFloat = 58
    private let minBarHeight: CGFloat = 5

    private var displaySeries: [UsageDailyCost] {
        guard !dailySeries.isEmpty else {
            let today = Calendar.current.startOfDay(for: Date())
            return stride(from: 6, through: 0, by: -1).compactMap { offset in
                guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: today) else { return nil }
                return UsageDailyCost(dayStart: day, tokens: 0, costUSD: 0, modelBreakdowns: [])
            }
        }
        return dailySeries
    }

    private var maxCost: Double {
        displaySeries.map(\.costUSD).max() ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let count = max(1, displaySeries.count)
            let slotWidth = width / CGFloat(count)
            let barWidth = min(22, max(10, slotWidth * 0.46))

            ZStack(alignment: .topLeading) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(displaySeries.enumerated()), id: \.element.id) { _, point in
                        VStack(spacing: 4) {
                            let height = barHeight(for: point.costUSD)
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(
                                        point.id == selectedDayID
                                            ? Color(nsColor: .controlAccentColor)
                                            : Color(nsColor: .controlAccentColor).opacity(0.72)
                                    )
                                    .frame(width: barWidth, height: height)
                                if Calendar.current.isDateInToday(point.dayStart) {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(Color.yellow.opacity(0.95))
                                        .frame(width: barWidth, height: min(4, height))
                                        .frame(height: height, alignment: .top)
                                }
                            }
                            .frame(width: slotWidth, height: maxBarHeight, alignment: .bottom)
                            .background(alignment: .bottom) {
                                if point.id == selectedDayID {
                                    Capsule(style: .continuous)
                                        .fill(Color.primary.opacity(0.08))
                                        .frame(width: barWidth + 10, height: 4)
                                        .offset(y: 8)
                                }
                            }
                            Text(dayLabel(point.dayStart))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: slotWidth)
                        }
                    }
                }
                MouseLocationReader { location in
                    updateHover(location: location, width: width)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
        }
        .frame(height: chartHeight, alignment: .bottomLeading)
    }

    private func barHeight(for value: Double) -> CGFloat {
        guard maxCost > 0 else { return minBarHeight }
        let ratio = max(0, min(1, value / maxCost))
        return minBarHeight + CGFloat(ratio) * (maxBarHeight - minBarHeight)
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private func updateHover(location: CGPoint?, width: CGFloat) {
        guard let location else {
            onHoverDay?(nil)
            return
        }
        guard width > 0, !displaySeries.isEmpty else {
            onHoverDay?(nil)
            return
        }
        let slotWidth = width / CGFloat(displaySeries.count)
        guard slotWidth > 0 else {
            onHoverDay?(nil)
            return
        }
        let raw = Int(floor(location.x / slotWidth))
        let index = max(0, min(displaySeries.count - 1, raw))
        guard displaySeries.indices.contains(index) else {
            onHoverDay?(nil)
            return
        }
        onHoverDay?(displaySeries[index].dayStart)
    }
}

@MainActor
private struct MouseLocationReader: NSViewRepresentable {
    let onMoved: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMoved = onMoved
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMoved = onMoved
    }

    final class TrackingView: NSView {
        var onMoved: ((CGPoint?) -> Void)?
        private var trackingArea: NSTrackingArea?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.window?.acceptsMouseMovedEvents = true
            updateTrackingAreas()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let options: NSTrackingArea.Options = [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ]
            let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            onMoved?(convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            onMoved?(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            onMoved?(nil)
        }
    }
}

private struct UtilizationSection: View {
    let usage: UsageSnapshot
    let accounts: [UsageAccountSnapshot]
    let progressMode: UtilizationProgressMode
    let activeAccountID: String?

    private var accountSections: [UsageAccountSnapshot] {
        if !accounts.isEmpty {
            return accounts
        }
        let fallback = UsageAccountSnapshot(
            id: usage.accountEmail ?? "primary",
            accountID: nil,
            email: usage.accountEmail,
            name: usage.accountName,
            note: nil,
            planType: usage.planType,
            source: usage.source,
            sessionUsedRatio: usage.sessionUsedRatio,
            weeklyUsedRatio: usage.weeklyUsedRatio,
            sessionResetAt: usage.sessionResetAt,
            weeklyResetAt: usage.weeklyResetAt,
            updatedAt: usage.updatedAt,
            expiresAt: nil,
            isCurrentCodexAccount: true,
            isCredentialExpired: false
        )
        return [fallback]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Subscription Utilization")
                .font(.headline)

            let sections = accountSections
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    Divider().opacity(0.5)
                }
                if sections.count > 1 {
                    accountHeader(account)
                }
                utilizationLane(
                    title: "Session",
                    usedRatio: account.sessionUsedRatio,
                    resetAt: account.sessionResetAt,
                    defaultWindowSeconds: 5 * 60 * 60
                )
                utilizationLane(
                    title: "Weekly",
                    usedRatio: account.weeklyUsedRatio,
                    resetAt: account.weeklyResetAt,
                    defaultWindowSeconds: 7 * 24 * 60 * 60
                )
            }
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func accountHeader(_ account: UsageAccountSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(accountHeaderLabel(for: account))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if account.isCurrentCodexAccount {
                Text("Active")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            if account.isCredentialExpired {
                Text("Expired")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.red)
            }
            Spacer()
            if let plan = account.planType, !plan.isEmpty {
                Text(plan.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func accountHeaderLabel(for account: UsageAccountSnapshot) -> String {
        let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = account.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (email?.isEmpty == false ? email : nil, nickname?.isEmpty == false ? nickname : nil) {
        case let (email?, nickname?):
            return "\(email) (\(nickname))"
        case let (email?, nil):
            return email
        case let (nil, nickname?):
            return nickname
        default:
            return account.displayName
        }
    }

    @ViewBuilder
    private func utilizationLane(
        title: String,
        usedRatio: Double?,
        resetAt: Date?,
        defaultWindowSeconds: TimeInterval
    ) -> some View {
        let detail = paceDetail(usedRatio: usedRatio, resetAt: resetAt, defaultWindowSeconds: defaultWindowSeconds)
        let value = displayRatio(forUsedRatio: usedRatio)
        let expected = displayRatio(forUsedRatio: detail?.expectedUsedRatio)
        let markerUsedRatios: [Double] = [0.5, 0.8]
        let markers = markerUsedRatios.compactMap { displayRatio(forUsedRatio: $0) }
        let percentLabel = ratioLabel(forUsedRatio: usedRatio)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let percentLabel {
                    Text(percentLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let value {
                UtilizationProgressBar(
                    value: value,
                    expectedValue: expected,
                    markers: markers,
                    deficit: detail?.isDeficit ?? false,
                    showPaceMarker: (detail?.isOnTrack == false)
                )
            } else {
                ProgressView(value: 0)
                    .opacity(0.35)
            }

            if let detail {
                HStack {
                    Text(detail.leftLabel)
                        .font(.caption2.weight(.medium))
                    Spacer()
                    if let right = detail.rightLabel {
                        Text(right)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            HStack {
                if let resetAt, usedRatio != nil {
                    Text("Resets \(resetAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Reset unavailable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func ratioLabel(forUsedRatio ratio: Double?) -> String? {
        guard let ratio else { return nil }
        let used = min(1, max(0, ratio))
        let value = progressMode == .used ? used : (1 - used)
        let percent = Int((value * 100).rounded())
        let mode = progressMode == .used
            ? NSLocalizedString("Used", bundle: .module, comment: "")
            : NSLocalizedString("Remaining", bundle: .module, comment: "")
        return "\(percent)% \(mode)"
    }

    private func displayRatio(forUsedRatio ratio: Double?) -> Double? {
        guard let ratio else { return nil }
        let used = min(1, max(0, ratio))
        return progressMode == .used ? used : (1 - used)
    }

    private func paceDetail(
        usedRatio: Double?,
        resetAt: Date?,
        defaultWindowSeconds: TimeInterval
    ) -> UtilizationPaceDetail? {
        guard let usedRatio, let resetAt else { return nil }
        let now = Date()
        let remainingToReset = resetAt.timeIntervalSince(now)
        guard remainingToReset > 0, remainingToReset <= defaultWindowSeconds else { return nil }

        let actual = min(1, max(0, usedRatio))
        let elapsed = max(0, defaultWindowSeconds - remainingToReset)
        let expected = min(1, max(0, elapsed / defaultWindowSeconds))
        if elapsed == 0, actual > 0 { return nil }

        let delta = actual - expected
        let absDeltaPercent = Int((abs(delta) * 100).rounded())
        let isOnTrack = abs(delta) <= 0.02
        let leftLabel: String
        if isOnTrack {
            leftLabel = NSLocalizedString("On pace", bundle: .module, comment: "")
        } else if delta > 0 {
            leftLabel = String.localizedStringWithFormat(
                NSLocalizedString("%d%% in deficit", bundle: .module, comment: ""),
                absDeltaPercent
            )
        } else {
            leftLabel = String.localizedStringWithFormat(
                NSLocalizedString("%d%% in reserve", bundle: .module, comment: ""),
                absDeltaPercent
            )
        }

        let rightLabel: String
        if elapsed <= 0 || actual <= 0 {
            rightLabel = NSLocalizedString("Lasts until reset", bundle: .module, comment: "")
        } else {
            let rate = actual / elapsed
            if rate <= 0 {
                rightLabel = NSLocalizedString("Lasts until reset", bundle: .module, comment: "")
            } else {
                let eta = max(0, (1 - actual) / rate)
                if eta >= remainingToReset {
                    rightLabel = NSLocalizedString("Lasts until reset", bundle: .module, comment: "")
                } else {
                    rightLabel = String.localizedStringWithFormat(
                        NSLocalizedString("Runs out in %@", bundle: .module, comment: ""),
                        formatDuration(eta)
                    )
                }
            }
        }

        return UtilizationPaceDetail(
            expectedUsedRatio: expected,
            leftLabel: leftLabel,
            rightLabel: rightLabel,
            isDeficit: delta > 0,
            isOnTrack: isOnTrack
        )
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        if interval <= 1 {
            return "now"
        }
        let total = Int(interval.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(1, minutes))m"
    }
}

private struct UtilizationPaceDetail {
    let expectedUsedRatio: Double
    let leftLabel: String
    let rightLabel: String?
    let isDeficit: Bool
    let isOnTrack: Bool
}

private struct UtilizationProgressBar: View {
    let value: Double
    let expectedValue: Double?
    let markers: [Double]
    let deficit: Bool
    let showPaceMarker: Bool
    private let accentFill = Color(nsColor: .controlAccentColor)

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let clampedValue = min(1, max(0, value))
            let fillWidth = width * clampedValue
            let expected = min(1, max(0, expectedValue ?? clampedValue))
            let markerColor = Color.primary.opacity(0.68)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.2))
                Capsule(style: .continuous)
                    .fill(accentFill.opacity(0.9))
                    .frame(width: max(2, fillWidth))
                ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                    Rectangle()
                        .fill(markerColor)
                        .frame(width: 1, height: 6)
                        .position(x: width * min(1, max(0, marker)), y: 3)
                }
                if showPaceMarker {
                    Rectangle()
                        .fill(deficit ? Color.red.opacity(0.9) : Color.green.opacity(0.9))
                        .frame(width: 2, height: 6)
                        .position(x: width * expected, y: 3)
                }
            }
        }
        .frame(height: 6)
    }
}

private struct ProjectMenuGroup: Identifiable {
    let id: String
    let projectName: String
    let projectPath: String?
    let latest: Date
    let sessions: [CodexSession]

    var isChatsProject: Bool {
        projectPath == nil || projectPath?.isEmpty == true
    }
}

@MainActor
final class ManagerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ManagerWindowController()

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(with store: SessionStore) {
        if window == nil {
            let rootView = MainWindowView().environmentObject(store)
            let hosting = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Session Manager"
            window.setContentSize(NSSize(width: 1180, height: 700))
            window.minSize = NSSize(width: 980, height: 620)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.isReleasedWhenClosed = false
            window.level = .normal
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.toolbarStyle = .unifiedCompact
            window.backgroundColor = .clear
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.delegate = self
            self.window = window
        }

        if let window {
            WindowPositioner.centerOnActiveScreen(window)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.orderOut(nil)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private let contentSize = NSSize(width: 820, height: 560)
    private var settingsHostingController: NSHostingController<SettingsWindowView>?

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(
        currentPath: String,
        currentProgressMode: UtilizationProgressMode,
        showMenuBarPercentage: Bool,
        refreshInterval: RefreshInterval,
        launchAtLogin: Bool,
        celebrateSessionReset: Bool,
        celebrateWeeklyReset: Bool,
        onSave: @escaping (String, UtilizationProgressMode, Bool, RefreshInterval, Bool) -> Void,
        onCelebrationChanged: @escaping (Bool, Bool) -> Void = { _, _ in },
        onAccountsChanged: @escaping () -> Void = {}
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.dismissTransientMenuWindows()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.showNow(
                    currentPath: currentPath,
                    currentProgressMode: currentProgressMode,
                    showMenuBarPercentage: showMenuBarPercentage,
                    refreshInterval: refreshInterval,
                    launchAtLogin: launchAtLogin,
                    celebrateSessionReset: celebrateSessionReset,
                    celebrateWeeklyReset: celebrateWeeklyReset,
                    onSave: onSave,
                    onCelebrationChanged: onCelebrationChanged,
                    onAccountsChanged: onAccountsChanged
                )
            }
        }
    }

    private func dismissTransientMenuWindows() {
        for candidate in NSApplication.shared.windows {
            guard candidate !== window else { continue }
            guard candidate.isVisible else { continue }
            guard candidate.title.isEmpty else { continue }
            candidate.orderOut(nil)
        }
    }

    private func showNow(
        currentPath: String,
        currentProgressMode: UtilizationProgressMode,
        showMenuBarPercentage: Bool,
        refreshInterval: RefreshInterval,
        launchAtLogin: Bool,
        celebrateSessionReset: Bool,
        celebrateWeeklyReset: Bool,
        onSave: @escaping (String, UtilizationProgressMode, Bool, RefreshInterval, Bool) -> Void,
        onCelebrationChanged: @escaping (Bool, Bool) -> Void,
        onAccountsChanged: @escaping () -> Void
    ) {
        let settingsView = SettingsWindowView(
            currentPath: currentPath,
            currentProgressMode: currentProgressMode,
            showMenuBarPercentage: showMenuBarPercentage,
            refreshInterval: refreshInterval,
            launchAtLogin: launchAtLogin,
            celebrateSessionReset: celebrateSessionReset,
            celebrateWeeklyReset: celebrateWeeklyReset,
            onSave: onSave,
            onCelebrationChanged: onCelebrationChanged,
            onAccountsChanged: onAccountsChanged
        )
        let hostingController: NSHostingController<SettingsWindowView>
        if let existing = settingsHostingController {
            existing.rootView = settingsView
            hostingController = existing
        } else {
            hostingController = NSHostingController(rootView: settingsView)
            settingsHostingController = hostingController
        }

        if window == nil {
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Settings"
            window.styleMask.insert(.fullSizeContentView)
            window.isReleasedWhenClosed = false
            window.level = .normal
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            window.toolbarStyle = .unifiedCompact
            window.backgroundColor = .clear
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.setContentSize(contentSize)
            window.minSize = NSSize(width: 760, height: 500)
            self.window = window
        } else {
            window?.contentViewController = hostingController
        }

        window?.setContentSize(contentSize)
        window?.minSize = NSSize(width: 760, height: 500)
        if let window {
            WindowPositioner.centerOnActiveScreen(window)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case accounts
    case about

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .general:
            return "General"
        case .accounts:
            return "Accounts"
        case .about:
            return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general:
            return "gearshape"
        case .accounts:
            return "person.crop.circle.badge.plus"
        case .about:
            return "info.circle"
        }
    }
}

private struct SettingsWindowView: View {
    @State private var selectedPane: SettingsPane = .general
    @State private var currentPath: String
    @State private var progressMode: UtilizationProgressMode
    @State private var showMenuBarPercentage: Bool
    @State private var refreshInterval: RefreshInterval
    @State private var launchAtLogin: Bool
    @State private var updateAlert: UpdateAlert?
    @State private var isCheckingUpdates = false
    @State private var importedAccounts: [ImportedCodexAccountSummary] = AccountCredentialStore.loadSummaries()
    @State private var accountAlert: UpdateAlert?
    @State private var celebrateSessionReset: Bool
    @State private var celebrateWeeklyReset: Bool
    @AppStorage("accountsSortOption") private var accountsSortRaw: String = AccountsSortOption.importedNewest.rawValue
    @AppStorage("accountsManualOrder") private var accountsManualOrderRaw: String = ""
    @AppStorage("accountsPinActive") private var accountsPinActive: Bool = false
    let onSave: (String, UtilizationProgressMode, Bool, RefreshInterval, Bool) -> Void
    let onCelebrationChanged: (Bool, Bool) -> Void
    let onAccountsChanged: () -> Void

    init(
        currentPath: String,
        currentProgressMode: UtilizationProgressMode,
        showMenuBarPercentage: Bool,
        refreshInterval: RefreshInterval,
        launchAtLogin: Bool,
        celebrateSessionReset: Bool = true,
        celebrateWeeklyReset: Bool = true,
        onSave: @escaping (String, UtilizationProgressMode, Bool, RefreshInterval, Bool) -> Void,
        onCelebrationChanged: @escaping (Bool, Bool) -> Void = { _, _ in },
        onAccountsChanged: @escaping () -> Void = {}
    ) {
        _currentPath = State(initialValue: currentPath)
        _progressMode = State(initialValue: currentProgressMode)
        _showMenuBarPercentage = State(initialValue: showMenuBarPercentage)
        _refreshInterval = State(initialValue: refreshInterval)
        _launchAtLogin = State(initialValue: launchAtLogin)
        _celebrateSessionReset = State(initialValue: celebrateSessionReset)
        _celebrateWeeklyReset = State(initialValue: celebrateWeeklyReset)
        self.onSave = onSave
        self.onCelebrationChanged = onCelebrationChanged
        self.onAccountsChanged = onAccountsChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 220)
                Divider()
                contentPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .background(settingsWindowBackground)
        .alert(item: $updateAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(item: $accountAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(nsImage: codexStackLogoImage(progressMode: progressMode))
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(localized("Settings"))
                    .font(.title2.weight(.semibold))
                Text(localized("Configure codexStack and Codex session sources."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("codexStack")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SettingsPane.allCases) { pane in
                Button {
                    selectedPane = pane
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: pane.symbolName)
                            .frame(width: 18)
                        Text(localized(pane.titleKey))
                        Spacer()
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selectedPane == pane ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background {
                        if selectedPane == pane {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.accentColor.opacity(0.16))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .background(settingsSidebarBackground)
    }

    @ViewBuilder
    private var contentPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(localized(selectedPane.titleKey))
                    .font(.title.weight(.semibold))
                    .padding(.bottom, 2)
                switch selectedPane {
                case .general:
                    generalPane
                case .accounts:
                    accountsPane
                case .about:
                    aboutPane
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollContentBackground(.hidden)
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("Codex")
            settingsCard {
                SettingsLine(title: localized("Codex Directory"), subtitle: localized("Used for session scan, archive, and index reconciliation.")) {
                    VStack(alignment: .trailing, spacing: 8) {
                        TextField("", text: $currentPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                        HStack(spacing: 8) {
                            Button(localized("Browse..."), action: chooseDirectory)
                            Button(localized("Save"), action: savePath)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                }
                SettingsDivider()
                SettingsLine(title: localized("Launch at Login"), subtitle: localized("Open codexStack automatically when you sign in.")) {
                    SettingsSwitch(isOn: $launchAtLogin) {
                        updateLaunchAtLogin()
                    }
                }
            }

            sectionTitle("Menu Bar")
            settingsCard {
                SettingsLine(title: localized("Progress Bar"), subtitle: localized("Controls whether usage bars show used or remaining quota.")) {
                    Picker("", selection: $progressMode) {
                        ForEach(UtilizationProgressMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .onChange(of: progressMode) { _ in applyNonPathSettings() }
                }
                SettingsDivider()
                SettingsLine(title: localized("Show percentage text"), subtitle: localized("Display the quota percentage next to the menu bar icon.")) {
                    SettingsSwitch(isOn: $showMenuBarPercentage) {
                        applyNonPathSettings()
                    }
                }
                SettingsDivider()
                SettingsLine(title: localized("Auto refresh"), subtitle: localized("Refresh usage and sessions in the background at this interval.")) {
                    Picker("", selection: $refreshInterval) {
                        ForEach(RefreshInterval.allCases) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                    .frame(width: 180)
                    .onChange(of: refreshInterval) { _ in applyNonPathSettings() }
                }
            }

            sectionTitle("Celebrations")
            settingsCard {
                SettingsLine(
                    title: localized("5h Window Reset"),
                    subtitle: localized("Play a full-screen confetti animation when the session window resets.")
                ) {
                    SettingsSwitch(isOn: $celebrateSessionReset) {
                        onCelebrationChanged(celebrateSessionReset, celebrateWeeklyReset)
                    }
                }
                SettingsDivider()
                SettingsLine(
                    title: localized("Weekly Reset"),
                    subtitle: localized("Play a full-screen confetti animation when the weekly quota resets.")
                ) {
                    SettingsSwitch(isOn: $celebrateWeeklyReset) {
                        onCelebrationChanged(celebrateSessionReset, celebrateWeeklyReset)
                    }
                }
                SettingsDivider()
                SettingsLine(
                    title: localized("Preview"),
                    subtitle: localized("Test the animation on the active screen.")
                ) {
                    HStack(spacing: 8) {
                        Button(localized("5h")) {
                            ResetCelebrationController.shared.present(kind: .session)
                        }
                        Button(localized("Weekly")) {
                            ResetCelebrationController.shared.present(kind: .weekly)
                        }
                    }
                }
            }
        }
    }

    private var accountsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("Imported Accounts")
            settingsCard {
                SettingsLine(
                    title: localized("Add Account"),
                    subtitle: localized("Import a Codex auth.json or cliproxyapi OAuth JSON. Duplicates are replaced by the most recently imported credential.")
                ) {
                    Button(localized("Import JSON..."), action: importAccountFile)
                }
                if !importedAccounts.isEmpty {
                    SettingsDivider()
                    SettingsLine(
                        title: localized("Sort"),
                        subtitle: localized("Choose how imported accounts are ordered in this list.")
                    ) {
                        Picker("", selection: accountsSortBinding) {
                            ForEach(AccountsSortOption.allCases) { option in
                                Text(localized(option.label)).tag(option)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    SettingsDivider()
                    SettingsLine(
                        title: localized("Pin Selected Account"),
                        subtitle: localized("Always show the selected account first in the menu bar utilization section.")
                    ) {
                        SettingsSwitch(isOn: $accountsPinActive) {
                            onAccountsChanged()
                        }
                    }
                    SettingsDivider()
                    VStack(spacing: 0) {
                        let rows = sortedImportedAccounts
                        let isManual = accountsSortOption == .manual
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, account in
                            if index > 0 {
                                ZStack {
                                    Divider()
                                        .padding(.horizontal, 16)
                                    if isManual {
                                        AccountInsertionLine { droppedID in
                                            moveAccount(draggedID: droppedID, before: account.id)
                                        }
                                    }
                                }
                            } else if isManual {
                                AccountInsertionLine { droppedID in
                                    moveAccount(draggedID: droppedID, before: account.id)
                                }
                            }
                            accountRow(account, isManual: isManual)
                        }
                        if isManual, !rows.isEmpty {
                            AccountInsertionLine(minHeight: 12) { droppedID in
                                moveAccount(draggedID: droppedID, before: nil)
                            }
                        }
                    }
                }
            }

            Text(localized("Imported credentials are stored locally and used only to query ChatGPT usage windows."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 8) {
                Image(nsImage: codexStackLogoImage(progressMode: progressMode))
                    .resizable()
                    .frame(width: 70, height: 70)
                Text("codexStack")
                    .font(.title2.weight(.semibold))
                Text(appVersionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)

            sectionTitle("Application")
            settingsCard {
                SettingsLine(title: localized("Version")) {
                    Text(appVersionText)
                        .foregroundStyle(.secondary)
                }
                SettingsDivider()
                SettingsLine(title: localized("Repository"), subtitle: localized("GitHub Releases")) {
                    Button(localized("Open GitHub"), action: openRepository)
                }
                SettingsDivider()
                SettingsLine(title: localized("Updates"), subtitle: localized("Check the latest version from GitHub Releases.")) {
                    Button(updateButtonTitle, action: checkForUpdates)
                        .disabled(isCheckingUpdates)
                }
                SettingsDivider()
                Text(localized("Manual update checks use the latest GitHub Release. Automatic updates can be added later with Sparkle."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
            }
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(settingsCardTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }

    private var settingsWindowBackground: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Color(nsColor: .windowBackgroundColor).opacity(0.28)
        }
    }

    private var settingsSidebarBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color(nsColor: .controlBackgroundColor).opacity(0.18)
        }
    }

    private var settingsCardTint: some ShapeStyle {
        Color(nsColor: .controlBackgroundColor).opacity(0.34)
    }

    private func sectionTitle(_ key: String) -> some View {
        Text(localized(key))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.prompt = localized("Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            currentPath = url.path
        }
    }

    private func savePath() {
        onSave(currentPath, progressMode, showMenuBarPercentage, refreshInterval, launchAtLogin)
    }

    @ViewBuilder
    private func accountRow(_ account: ImportedCodexAccountSummary, isManual: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if isManual {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .padding(.top, 2)
                    .help(localized("Drag to reorder"))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName)
                    .font(.system(size: 13, weight: .medium))
                if let email = account.email, !email.isEmpty, email != account.displayName {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(accountStatusLine(for: account))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(localized("Remove"), role: .destructive) {
                removeAccount(id: account.id)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .modifier(AccountDragModifier(enabled: isManual, accountID: account.id))
    }

    private var accountsSortOption: AccountsSortOption {
        AccountsSortOption(rawValue: accountsSortRaw) ?? .importedNewest
    }

    private var accountsSortBinding: Binding<AccountsSortOption> {
        Binding(
            get: { accountsSortOption },
            set: { newValue in
                if newValue == .manual && manualOrderIDs.isEmpty {
                    persistManualOrder(currentSortedIDs())
                }
                accountsSortRaw = newValue.rawValue
                onAccountsChanged()
            }
        )
    }

    private var manualOrderIDs: [String] {
        accountsManualOrderRaw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func persistManualOrder(_ ids: [String]) {
        accountsManualOrderRaw = ids.joined(separator: "\n")
    }

    private func currentSortedIDs() -> [String] {
        sortedImportedAccounts.map(\.id)
    }

    private var sortedImportedAccounts: [ImportedCodexAccountSummary] {
        accountsSortOption.sort(importedAccounts, manualOrder: manualOrderIDs)
    }

    private func moveAccount(draggedID: String, before targetID: String?) {
        guard draggedID != targetID else { return }
        var order = sortedImportedAccounts.map(\.id)
        guard let fromIdx = order.firstIndex(of: draggedID) else { return }
        let item = order.remove(at: fromIdx)
        if let targetID, let toIdx = order.firstIndex(of: targetID) {
            order.insert(item, at: toIdx)
        } else {
            order.append(item)
        }
        persistManualOrder(order)
        if accountsSortOption != .manual {
            accountsSortRaw = AccountsSortOption.manual.rawValue
        }
        onAccountsChanged()
    }

    private func appendNewAccountsToManualOrder() {
        let existing = Set(manualOrderIDs)
        let knownIDs = Set(importedAccounts.map(\.id))
        var order = manualOrderIDs.filter(knownIDs.contains)
        for account in importedAccounts where !existing.contains(account.id) {
            order.append(account.id)
        }
        persistManualOrder(order)
    }

    private func importAccountFile() {
        let panel = NSOpenPanel()
        panel.prompt = localized("Import")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK else { return }

        var failures: [String] = []
        for url in panel.urls {
            do {
                _ = try AccountCredentialStore.importAccount(from: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        importedAccounts = AccountCredentialStore.loadSummaries()
        appendNewAccountsToManualOrder()
        onAccountsChanged()
        if !failures.isEmpty {
            accountAlert = UpdateAlert(
                title: localized("Some accounts could not be imported"),
                message: failures.joined(separator: "\n")
            )
        }
    }

    private func removeAccount(id: String) {
        do {
            try AccountCredentialStore.removeAccount(id: id)
            importedAccounts = AccountCredentialStore.loadSummaries()
            persistManualOrder(manualOrderIDs.filter { $0 != id })
            onAccountsChanged()
        } catch {
            accountAlert = UpdateAlert(
                title: localized("Unable to Remove Account"),
                message: error.localizedDescription
            )
        }
    }

    private func accountStatusLine(for account: ImportedCodexAccountSummary) -> String {
        var parts: [String] = []
        if let plan = account.type, !plan.isEmpty {
            parts.append(plan.uppercased())
        }
        if let expiresAt = account.expiresAt {
            if expiresAt <= Date() {
                parts.append(localized("Expired"))
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                parts.append(String.localizedStringWithFormat(
                    NSLocalizedString("Expires %@", bundle: .module, comment: ""),
                    formatter.string(from: expiresAt)
                ))
            }
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        parts.append(String.localizedStringWithFormat(
            NSLocalizedString("Imported %@", bundle: .module, comment: ""),
            formatter.string(from: account.importedAt)
        ))
        return parts.joined(separator: " · ")
    }

    private func applyNonPathSettings() {
        onSave(currentPath, progressMode, showMenuBarPercentage, refreshInterval, launchAtLogin)
    }

    private func updateLaunchAtLogin() {
        do {
            try LaunchAtLoginController.setEnabled(launchAtLogin)
            applyNonPathSettings()
        } catch {
            launchAtLogin.toggle()
            updateAlert = UpdateAlert(
                title: localized("Unable to Update Login Item"),
                message: error.localizedDescription
            )
        }
    }

    private func openRepository() {
        guard let url = URL(string: "https://github.com/ocd0711/CodexStack") else { return }
        NSWorkspace.shared.open(url)
    }

    private func checkForUpdates() {
        isCheckingUpdates = true
        Task {
            defer { isCheckingUpdates = false }
            do {
                let release = try await GitHubReleaseChecker.fetchLatest()
                if compareVersions(release.version, currentVersion) == .orderedDescending {
                    guard let asset = release.macOSZipAsset else {
                        updateAlert = UpdateAlert(
                            title: localized("No macOS update package found."),
                            message: localized("Latest GitHub Release does not contain a macOS zip package.")
                        )
                        if let url = URL(string: release.htmlURL) {
                            NSWorkspace.shared.open(url)
                        }
                        return
                    }

                    let localURL = try await GitHubReleaseChecker.download(asset: asset)
                    NSWorkspace.shared.open(localURL)
                    NSWorkspace.shared.activateFileViewerSelecting([localURL])
                    updateAlert = UpdateAlert(
                        title: localized("Update Downloaded"),
                        message: localized("The update archive was downloaded and opened. Quit codexStack and replace the app to finish updating.")
                    )
                } else {
                    updateAlert = UpdateAlert(
                        title: localized("codexStack is up to date."),
                        message: String(format: localized("Current version: %@"), currentVersion)
                    )
                }
            } catch {
                updateAlert = UpdateAlert(
                    title: localized("Unable to Check for Updates"),
                    message: localized("codexStack could not reach GitHub Releases. Please try again later.")
                )
            }
        }
    }

    private var updateButtonTitle: String {
        isCheckingUpdates ? localized("Downloading...") : localized("Check for Updates")
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return String(format: localized("Version %@ (%@)"), version, build)
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let lval = index < left.count ? left[index] : 0
            let rval = index < right.count ? right[index] : 0
            if lval > rval { return .orderedDescending }
            if lval < rval { return .orderedAscending }
        }
        return .orderedSame
    }

    private func versionComponents(_ text: String) -> [Int] {
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let parts = cleaned.split(separator: ".").map { part -> Int in
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
        return parts.isEmpty ? [0] : parts
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }
}

private struct SettingsLine<Accessory: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let accessory: () -> Accessory

    init(title: String, subtitle: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 24)
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 16)
    }
}

private struct SettingsSwitch: View {
    @Binding var isOn: Bool
    let onChange: () -> Void

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .onChange(of: isOn) { _ in onChange() }
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule(style: .continuous))
            .background(
                Color(nsColor: .windowBackgroundColor).opacity(0.28),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            }
        .accessibilityLabel("Show percentage text")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct UpdateAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct AccountDragModifier: ViewModifier {
    let enabled: Bool
    let accountID: String

    func body(content: Content) -> some View {
        if enabled {
            content.draggable(accountID)
        } else {
            content
        }
    }
}

private struct AccountInsertionLine: View {
    var minHeight: CGFloat = 6
    let onDrop: (String) -> Void
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            Color.clear
            if isTargeted {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 3)
                    .padding(.horizontal, 14)
                    .transition(.opacity)
            }
        }
        .frame(height: minHeight)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let droppedID = items.first else { return false }
            onDrop(droppedID)
            return true
        } isTargeted: { active in
            withAnimation(.easeInOut(duration: 0.08)) { isTargeted = active }
        }
    }
}

private enum AccountsSortOption: String, CaseIterable, Identifiable {
    case manual
    case importedNewest
    case importedOldest
    case nameAscending
    case expiresSoonest
    case expiresLatest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .importedNewest: return "Imported · Newest"
        case .importedOldest: return "Imported · Oldest"
        case .nameAscending: return "Name (A → Z)"
        case .expiresSoonest: return "Expires · Soonest"
        case .expiresLatest: return "Expires · Latest"
        }
    }

    func sort(
        _ accounts: [ImportedCodexAccountSummary],
        manualOrder: [String] = []
    ) -> [ImportedCodexAccountSummary] {
        switch self {
        case .manual:
            let position = Dictionary(uniqueKeysWithValues: manualOrder.enumerated().map { ($1, $0) })
            return accounts.sorted { lhs, rhs in
                let lhsIdx = position[lhs.id] ?? Int.max
                let rhsIdx = position[rhs.id] ?? Int.max
                if lhsIdx != rhsIdx { return lhsIdx < rhsIdx }
                return (lhs.lastRefreshAt ?? lhs.importedAt) > (rhs.lastRefreshAt ?? rhs.importedAt)
            }
        case .importedNewest:
            return accounts.sorted { lhs, rhs in
                (lhs.lastRefreshAt ?? lhs.importedAt) > (rhs.lastRefreshAt ?? rhs.importedAt)
            }
        case .importedOldest:
            return accounts.sorted { lhs, rhs in
                (lhs.lastRefreshAt ?? lhs.importedAt) < (rhs.lastRefreshAt ?? rhs.importedAt)
            }
        case .nameAscending:
            return accounts.sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        case .expiresSoonest:
            return accounts.sorted { lhs, rhs in
                (lhs.expiresAt ?? .distantFuture) < (rhs.expiresAt ?? .distantFuture)
            }
        case .expiresLatest:
            return accounts.sorted { lhs, rhs in
                (lhs.expiresAt ?? .distantPast) > (rhs.expiresAt ?? .distantPast)
            }
        }
    }

    func sort(
        _ accounts: [UsageAccountSnapshot],
        manualOrder: [String] = []
    ) -> [UsageAccountSnapshot] {
        switch self {
        case .manual:
            let position = Dictionary(uniqueKeysWithValues: manualOrder.enumerated().map { ($1, $0) })
            return accounts.sorted { lhs, rhs in
                let lhsIdx = position[lhs.id] ?? Int.max
                let rhsIdx = position[rhs.id] ?? Int.max
                if lhsIdx != rhsIdx { return lhsIdx < rhsIdx }
                return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
            }
        case .importedNewest:
            return accounts.sorted { lhs, rhs in
                (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
            }
        case .importedOldest:
            return accounts.sorted { lhs, rhs in
                (lhs.updatedAt ?? .distantPast) < (rhs.updatedAt ?? .distantPast)
            }
        case .nameAscending:
            return accounts.sorted { lhs, rhs in
                let lhsName = lhs.name ?? lhs.email ?? lhs.id
                let rhsName = rhs.name ?? rhs.email ?? rhs.id
                return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
            }
        case .expiresSoonest:
            return accounts.sorted { lhs, rhs in
                (lhs.expiresAt ?? .distantFuture) < (rhs.expiresAt ?? .distantFuture)
            }
        case .expiresLatest:
            return accounts.sorted { lhs, rhs in
                (lhs.expiresAt ?? .distantPast) > (rhs.expiresAt ?? .distantPast)
            }
        }
    }
}

@MainActor
private enum WindowPositioner {
    static func centerOnActiveScreen(_ window: NSWindow) {
        let target = activeScreen() ?? window.screen ?? NSScreen.main
        guard let target else { return }
        let visible = target.visibleFrame
        var frame = window.frame
        frame.origin.x = visible.origin.x + (visible.width - frame.width) / 2
        frame.origin.y = visible.origin.y + (visible.height - frame.height) / 2
        window.setFrame(frame, display: true)
    }

    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return hit
        }
        return NSScreen.screens.first { $0.frame.contains(NSApp.keyWindow?.frame.origin ?? mouse) }
    }
}

private func codexStackLogoImage(progressMode: UtilizationProgressMode) -> NSImage {
    let candidates = [
        Bundle.module.url(forResource: "codexStack-logo", withExtension: "png"),
        Bundle.module.url(forResource: "codexStack-logo", withExtension: "png", subdirectory: "Assets"),
    ]
    for url in candidates.compactMap({ $0 }) {
        if let image = NSImage(contentsOf: url) {
            return image
        }
    }
    return StatusIconRenderer.makeIcon(
        sessionUsedRatio: 0.36,
        weeklyUsedRatio: 0.72,
        progressMode: progressMode
    )
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let assets: [GitHubReleaseAsset]

    var version: String {
        tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }

    var macOSZipAsset: GitHubReleaseAsset? {
        assets.first { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix(".zip") && name.contains("macos")
        } ?? assets.first { asset in
            asset.name.lowercased().hasSuffix(".zip")
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private enum GitHubReleaseChecker {
    static func fetchLatest() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/ocd0711/CodexStack/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("codexStack", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    static func download(asset: GitHubReleaseAsset) async throws -> URL {
        guard let url = URL(string: asset.browserDownloadURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("codexStack", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        let downloadsDirectory = try FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let destinationURL = uniqueDownloadURL(
            in: downloadsDirectory,
            preferredName: asset.name.isEmpty ? "codexStack-update.zip" : asset.name
        )
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private static func uniqueDownloadURL(in directory: URL, preferredName: String) -> URL {
        let baseURL = directory.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let fileExtension = baseURL.pathExtension
        let baseName = baseURL.deletingPathExtension().lastPathComponent
        for index in 1...999 {
            let candidateName = fileExtension.isEmpty
                ? "\(baseName)-\(index)"
                : "\(baseName)-\(index).\(fileExtension)"
            let candidateURL = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }
        return directory.appendingPathComponent(UUID().uuidString + "-" + preferredName)
    }
}

@MainActor
enum DialogPresenter {
    static func confirmDestructive(title: String, message: String, buttonTitle: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: buttonTitle)
        alert.addButton(withTitle: NSLocalizedString("Cancel", bundle: .module, comment: ""))
        NSApplication.shared.activate(ignoringOtherApps: true)
        centerAlertOnActiveScreen(alert)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func promptRename(initialTitle: String) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("Rename Conversation", bundle: .module, comment: "")
        alert.informativeText = NSLocalizedString("Conversation title", bundle: .module, comment: "")
        alert.addButton(withTitle: NSLocalizedString("Save", bundle: .module, comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", bundle: .module, comment: ""))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = initialTitle
        field.placeholderString = NSLocalizedString("Conversation title", bundle: .module, comment: "")
        alert.accessoryView = field

        NSApplication.shared.activate(ignoringOtherApps: true)
        centerAlertOnActiveScreen(alert)
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return nil }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func promptMoveProject(targets: [ProjectMoveTarget]) -> ProjectMoveTarget? {
        guard !targets.isEmpty else { return nil }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("Move to Project", bundle: .module, comment: "")
        alert.informativeText = NSLocalizedString("Choose destination project", bundle: .module, comment: "")
        alert.addButton(withTitle: NSLocalizedString("Move", bundle: .module, comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", bundle: .module, comment: ""))

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28), pullsDown: false)
        for target in targets {
            popup.addItem(withTitle: projectTargetLabel(target))
        }
        popup.selectItem(at: 0)
        alert.accessoryView = popup

        NSApplication.shared.activate(ignoringOtherApps: true)
        centerAlertOnActiveScreen(alert)
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        guard targets.indices.contains(index) else { return nil }
        return targets[index]
    }

    private static func projectTargetLabel(_ target: ProjectMoveTarget) -> String {
        guard let path = target.path else { return target.name }
        return "\(target.name)  \(path)"
    }

    private static func centerAlertOnActiveScreen(_ alert: NSAlert) {
        guard let screen = NSApplication.shared.keyWindow?.screen
            ?? NSApplication.shared.mainWindow?.screen
            ?? NSScreen.main else {
            return
        }
        let alertWindow = alert.window
        let frame = alertWindow.frame
        let visibleFrame = screen.visibleFrame
        alertWindow.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - frame.width / 2,
                y: visibleFrame.midY - frame.height / 2
            )
        )
    }
}
