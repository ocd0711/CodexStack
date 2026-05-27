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
    @State private var cachedStatusBarIcon: NSImage = NSImage()

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
        let celebrateWeekly = (UserDefaults.standard.object(forKey: SessionStore.celebrateWeeklyResetDefaultsKey) as? Bool) ?? true
        let autoSwitchEnabled = UserDefaults.standard.object(forKey: SessionStore.autoSwitchEnabledDefaultsKey) as? Bool ?? false
        let autoSwitchSessionThreshold = UserDefaults.standard.object(forKey: SessionStore.autoSwitchSessionThresholdDefaultsKey) as? Double ?? 90.0
        let autoSwitchWeeklyThreshold = UserDefaults.standard.object(forKey: SessionStore.autoSwitchWeeklyThresholdDefaultsKey) as? Double ?? 90.0
        let autoSwitchNotificationEnabled = UserDefaults.standard.object(forKey: SessionStore.autoSwitchNotificationEnabledDefaultsKey) as? Bool ?? true
        let store = SessionStore(
            codexRootPath: saved,
            utilizationProgressMode: savedMode,
            refreshInterval: savedRefreshInterval,
            preferredAccountID: preferredAccountID,
            autoSwitchEnabled: autoSwitchEnabled,
            autoSwitchSessionThreshold: autoSwitchSessionThreshold,
            autoSwitchWeeklyThreshold: autoSwitchWeeklyThreshold,
            autoSwitchNotificationEnabled: autoSwitchNotificationEnabled,
            celebrateWeeklyReset: celebrateWeekly
        )
        store.onResetCelebration = { kind in
            ResetCelebrationController.shared.present(kind: kind)
        }
        _store = StateObject(wrappedValue: store)
        _showMenuBarPercentage = State(initialValue: showPercentage)
        _launchAtLogin = State(initialValue: launchAtLoginEnabled)
        ModelPricingSyncService.shared.syncIfNeeded()
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
                        celebrateWeeklyReset: store.celebrateWeeklyReset,
                        autoSwitchEnabled: store.autoSwitchEnabled,
                        autoSwitchSessionThreshold: store.autoSwitchSessionThreshold,
                        autoSwitchWeeklyThreshold: store.autoSwitchWeeklyThreshold,
                        autoSwitchNotificationEnabled: store.autoSwitchNotificationEnabled,
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
                        onCelebrationChanged: { weeklyOn in
                            store.setCelebrateWeeklyReset(weeklyOn)
                        },
                        onAccountsChanged: {
                            store.refresh()
                        },
                        onAutoSwitchChanged: { enabled, sessionThreshold, weeklyThreshold, notifEnabled in
                            UserDefaults.standard.set(enabled, forKey: SessionStore.autoSwitchEnabledDefaultsKey)
                            UserDefaults.standard.set(sessionThreshold, forKey: SessionStore.autoSwitchSessionThresholdDefaultsKey)
                            UserDefaults.standard.set(weeklyThreshold, forKey: SessionStore.autoSwitchWeeklyThresholdDefaultsKey)
                            UserDefaults.standard.set(notifEnabled, forKey: SessionStore.autoSwitchNotificationEnabledDefaultsKey)
                            store.autoSwitchEnabled = enabled
                            store.autoSwitchSessionThreshold = sessionThreshold
                            store.autoSwitchWeeklyThreshold = weeklyThreshold
                            store.autoSwitchNotificationEnabled = notifEnabled
                        }
                    )
                }
            )
            .environmentObject(store)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: cachedStatusBarIcon)
                    .resizable()
                    .frame(width: 18, height: 18)
                if showMenuBarPercentage, let percent = menuBarPercent {
                    Text("\(percent)%")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
            }
            .accessibilityLabel(menuBarTitle)
            .onAppear { cachedStatusBarIcon = computeStatusBarIcon() }
            .onChange(of: iconCacheKey) { _ in
                if !store.isRefreshing { cachedStatusBarIcon = computeStatusBarIcon() }
            }
            .task(id: store.isRefreshing) {
                guard store.isRefreshing else {
                    cachedStatusBarIcon = computeStatusBarIcon()
                    return
                }
                var blinkPhase = 0.0
                let nsPerFrame: UInt64 = 1_000_000_000 / 30
                let key = iconCacheKey
                while !Task.isCancelled {
                    // Blink cycle: close (0–0.15), hold (0.15–0.20), open (0.20–0.35), pause (0.35–1.0)
                    let blink: Double
                    if blinkPhase < 0.15 {
                        blink = blinkPhase / 0.15
                    } else if blinkPhase < 0.20 {
                        blink = 1.0
                    } else if blinkPhase < 0.35 {
                        blink = 1.0 - (blinkPhase - 0.20) / 0.15
                    } else {
                        blink = 0.0
                    }
                    cachedStatusBarIcon = StatusIconRenderer.makeIcon(
                        sessionUsedRatio: key.session,
                        weeklyUsedRatio: key.weekly,
                        progressMode: key.mode,
                        blinkAmount: blink
                    )
                    blinkPhase += 1.0 / 36.0  // 1.2-second cycle at 30fps
                    if blinkPhase >= 1.0 { blinkPhase -= 1.0 }
                    try? await Task.sleep(nanoseconds: nsPerFrame)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var iconCacheKey: IconCacheKey {
        let activeAccount = store.usage.accounts.first
        return IconCacheKey(
            session: activeAccount?.sessionUsedRatio ?? store.usage.sessionUsedRatio,
            weekly: activeAccount?.weeklyUsedRatio ?? store.usage.weeklyUsedRatio,
            mode: store.utilizationProgressMode
        )
    }

    private func computeStatusBarIcon() -> NSImage {
        let key = iconCacheKey
        return StatusIconRenderer.makeIcon(
            sessionUsedRatio: key.session,
            weeklyUsedRatio: key.weekly,
            progressMode: key.mode
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
        let activeAccount = store.usage.accounts.first
        let ratio = activeAccount?.weeklyUsedRatio ?? activeAccount?.sessionUsedRatio
            ?? store.usage.weeklyUsedRatio ?? store.usage.sessionUsedRatio
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

private enum PricingSyncInterval: Int, CaseIterable, Identifiable {
    case never = 0
    case daily = 86400
    case weekly = 604800

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .never: return "Never"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }
}

private enum MenuDrilldownPane {
    case none
    case cost
    case projects
    case utilization
}

private struct MenuBarPanel: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    let onOpenSettings: () -> Void
    @State private var activePane: MenuDrilldownPane = .none
    @State private var hoveredCostDayID: TimeInterval?
    @State private var hoverCostCard = false
    @State private var hoverProjectsCard = false
    @State private var hoverUtilCard = false
    @State private var hoverDetailPane = false
    @State private var closePaneTask: Task<Void, Never>?
    @State private var lockScreenError: String?
    @State private var isKeepingAwake = PowerManagementService.isKeepingAwake
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
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                header
                utilizationCard
                embeddedCostSection
                projectsSummaryCard
            }
            .padding(12)
            Divider()
            actionsRow
                .padding(.vertical, 4)
        }
        .frame(minWidth: 360, idealWidth: 390, maxWidth: 420)
        .animation(.easeInOut(duration: 0.12), value: activePane)
        .alert("Unable to Lock Screen", isPresented: Binding(
            get: { lockScreenError != nil },
            set: { if !$0 { lockScreenError = nil } }
        ), actions: {
            Button("OK") {
                lockScreenError = nil
            }
        }, message: {
            Text(lockScreenError ?? "")
        })
        .onDisappear {
            cancelClosePaneTask()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Codex")
                        .font(.title3.weight(.semibold))
                    if let activeProvider = store.activeProvider {
                        Text(activeProvider)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.8), in: Capsule())
                    }
                }
                accountSwitcher
                if let updatedAt = store.usage.updatedAt {
                    Text(
                        String(
                            format: NSLocalizedString("%@ · Updated %@", bundle: .module, comment: ""),
                            store.usage.source.label,
                            updatedAt.formatted(.relative(presentation: .named))
                        )
                    )
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
        Menu {
            if accounts.count > 1 {
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
                Divider()
            }
            Button {
                do {
                    if let activeID = activeAccountID {
                        try store.syncToAuthJSON(accountID: activeID)
                    }
                } catch {
                    NSSound.beep()
                }
            } label: {
                Label("Sync to auth.json", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                let syncService = ProviderSyncService(codexRoot: URL(fileURLWithPath: store.codexRootPath, isDirectory: true))
                if let count = try? syncService.sync() {
                    print("Synced \(count) sessions")
                } else {
                    NSSound.beep()
                }
            } label: {
                Label("Sync Sessions Metadata", systemImage: "doc.badge.gearshape")
            }
            Menu {
                Button {
                    do {
                        try store.applyConfigProvider(nil as String?)
                    } catch {
                        NSSound.beep()
                    }
                } label: {
                    if store.activeProvider == nil {
                        Label("Official Login", systemImage: "checkmark")
                    } else {
                        Text("Official Login")
                    }
                }
                Divider()
                if store.availableProviders.isEmpty {
                    Text("No custom providers found")
                } else {
                    ForEach(store.availableProviders, id: \.self) { provider in
                        Button {
                            do {
                                try store.applyConfigProvider(provider)
                            } catch {
                                NSSound.beep()
                            }
                        } label: {
                            if store.activeProvider == provider {
                                Label(provider, systemImage: "checkmark")
                            } else {
                                Text(provider)
                            }
                        }
                    }
                }
            } label: {
                Label("Provider Mode", systemImage: "network")
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

    private var embeddedCostSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: Hero metrics
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Text(formatUSD(store.usage.todayCostUSD))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text("30d cost")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Text(formatUSD(store.usage.last30DaysCostUSD))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // MARK: Token stats
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text("30d tokens")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(formatTokens(store.usage.last30DaysTokens))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    Text("Latest tokens")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(formatTokens(store.usage.todayTokens))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 14)

            // MARK: Chart
            CostBarsView(
                dailySeries: store.usage.dailyCostSeries,
                selectedDayID: nil,
                barTint: .accentColor,
                highlightMaxDay: true,
                onHoverDay: { _ in }
            )
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // MARK: Footer
            HStack(spacing: 4) {
                let topModel = findTopModel(in: store.usage)
                Text("Top model:")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(topModel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Estimated from local logs")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .background(
            hoverCostCard ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    private func findTopModel(in usage: UsageSnapshot) -> String {
        var counts: [String: Int64] = [:]
        for day in usage.dailyCostSeries {
            for breakdown in day.modelBreakdowns {
                counts[breakdown.modelName, default: 0] += breakdown.tokens
            }
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? "gpt-5.5"
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
            .background(
                hoverProjectsCard ? Color.accentColor.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily Breakdown")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(
                    String.localizedStringWithFormat(
                        NSLocalizedString("30d total: %@", bundle: .module, comment: ""),
                        formatUSD(store.usage.last30DaysCostUSD)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            CostBarsView(
                dailySeries: store.usage.dailyCostSeries,
                selectedDayID: selectedCostDay?.id,
                barTint: Color(nsColor: NSColor.controlAccentColor.withSystemEffect(.deepPressed)),
                highlightMaxDay: false,
                onHoverDay: { day in
                    hoveredCostDayID = day?.timeIntervalSince1970
                }
            )

            if let selectedCostDay {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(selectedCostDay.dayStart.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(formatUSD(selectedCostDay.costUSD)) · \(formatTokens(selectedCostDay.tokens)) tokens")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    
                    if selectedCostDay.modelBreakdowns.isEmpty {
                        Text(NSLocalizedString("No per-model breakdown", bundle: .module, comment: ""))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(height: 20, alignment: .leading)
                    } else {
                        let visibleRows = Array(selectedCostDay.modelBreakdowns.prefix(5))
                        ForEach(visibleRows) { item in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(Color(nsColor: .controlAccentColor).opacity(0.7))
                                    .frame(width: 3, height: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.modelName)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Text("\(formatUSD(item.costUSD)) · \(formatTokens(item.tokens)) tokens")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                }
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                }
            } else {
                HStack {
                    Image(systemName: "hand.point.up.left")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("Hover a bar to see details")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
            }
        }
        .padding(14)
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
        HStack(spacing: 0) {
            actionButton("Open", icon: "sidebar.left") {
                ManagerWindowController.shared.show(with: store)
                dismiss()
            }
            actionButton("Refresh", icon: "arrow.clockwise") {
                store.refresh()
            }
            .disabled(store.isBusy)
            actionButton("Sync", icon: "arrow.triangle.2.circlepath") {
                Task { await ModelPricingSyncService.shared.syncPrices() }
            }
            .disabled(store.isBusy)
            if isKeepingAwake {
                actionButton("Stop Awake", icon: "stop.circle", help: "Stop keeping macOS awake in the background.") {
                    stopKeepingAwake()
                }
            } else {
                actionButton("Lock", icon: "lock", help: "Lock macOS and keep Codex sessions awake in the background.") {
                    lockScreenKeepingAwake()
                }
            }
            actionButton("Settings", icon: "gearshape") {
                activePane = .none
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onOpenSettings() }
                dismiss()
            }
            Spacer()
            actionButton("Quit", icon: "power", destructive: true) {
                NSApplication.shared.terminate(nil)
            }
        }
        .disabled(store.isMutating)
        .onAppear {
            isKeepingAwake = PowerManagementService.isKeepingAwake
        }
    }

    private func actionButton(
        _ label: String,
        icon: String,
        destructive: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(NSLocalizedString(label, bundle: .module, comment: ""))
                    .font(.system(size: 10))
            }
            .foregroundStyle(destructive ? .red : .primary)
            .frame(minWidth: 46, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString(help ?? label, bundle: .module, comment: ""))
    }

    private func lockScreenKeepingAwake() {
        do {
            try PowerManagementService.lockScreenKeepingAwake()
            isKeepingAwake = PowerManagementService.isKeepingAwake
            dismiss()
        } catch {
            lockScreenError = error.localizedDescription
        }
    }

    private func stopKeepingAwake() {
        PowerManagementService.stopKeepingAwake()
        isKeepingAwake = false
    }

    private var recentProjectLabels: [String] {
        let groups = groupedProjects()
        let labels = groups.prefix(8).map { "\($0.projectName) · \($0.sessions.count)" }
        if groups.count > 8 {
            return labels + ["... \((groups.count - 8)) more"]
        }
        return labels
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
        return groups.sorted {
            if $0.latest != $1.latest {
                return $0.latest > $1.latest
            }
            return $0.projectName.localizedStandardCompare($1.projectName) == .orderedAscending
        }
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
        if value >= 1_000_000_000 {
            let formatted = String(format: "%.1fB", Double(value) / 1_000_000_000)
            return formatted.replacingOccurrences(of: ".0B", with: "B")
        }
        if value >= 1_000_000 {
            let formatted = String(format: "%.1fM", Double(value) / 1_000_000)
            return formatted.replacingOccurrences(of: ".0M", with: "M")
        }
        if value >= 1_000 {
            let formatted = String(format: "%.1fK", Double(value) / 1_000)
            return formatted.replacingOccurrences(of: ".0K", with: "K")
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
                if !hoverCostCard && !hoverProjectsCard && !hoverUtilCard && !hoverDetailPane {
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

    private var isUtilPopoverPresented: Binding<Bool> {
        Binding(
            get: { activePane == .utilization },
            set: { isPresented in
                if !isPresented, activePane == .utilization {
                    hoverDetailPane = false
                    activePane = .none
                }
            }
        )
    }

    private var activeAccountsForInline: [UsageAccountSnapshot] {
        guard !sortedAccounts.isEmpty else { return [] }
        if let activeID = activeAccountID,
           let active = sortedAccounts.first(where: { $0.id == activeID }) {
            return [active]
        }
        return [sortedAccounts[0]]
    }

    private var utilizationCard: some View {
        UtilizationSection(
            usage: store.usage,
            accounts: activeAccountsForInline,
            progressMode: store.utilizationProgressMode,
            activeAccountID: activeAccountID,
            utilizationHistories: store.utilizationHistories
        )
        .background(
            hoverUtilCard ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .popover(isPresented: isUtilPopoverPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
            UtilizationSection(
                usage: store.usage,
                accounts: sortedAccounts,
                progressMode: store.utilizationProgressMode,
                activeAccountID: activeAccountID,
                utilizationHistories: store.utilizationHistories,
                showHistoryToggle: true
            )
            .frame(width: 320)
            .onHover { hovering in
                hoverDetailPane = hovering
                if hovering { cancelClosePaneTask() } else { scheduleClosePaneIfNeeded() }
            }
        }
        .onHover { hovering in
            hoverUtilCard = hovering
            if hovering {
                cancelClosePaneTask()
                activePane = .utilization
            } else {
                scheduleClosePaneIfNeeded()
            }
        }
    }
}

private struct CostBarsView: View {
    let dailySeries: [UsageDailyCost]
    var selectedDayID: TimeInterval? = nil
    var barTint: Color = Color(nsColor: .controlAccentColor)
    var highlightMaxDay: Bool = false
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

    private var maxDayID: TimeInterval? {
        guard highlightMaxDay, maxCost > 0 else { return nil }
        return displaySeries.first(where: { $0.costUSD == maxCost })?.id
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
                            let isMax = point.id == maxDayID
                            let isSelected = point.id == selectedDayID
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(
                                        isSelected
                                            ? barTint
                                            : isMax
                                                ? barTint
                                                : barTint.opacity(0.55)
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
                                if isSelected {
                                    Capsule(style: .continuous)
                                        .fill(Color.primary.opacity(0.08))
                                        .frame(width: barWidth + 10, height: 4)
                                        .offset(y: 8)
                                }
                            }
                            Text(dayLabel(point.dayStart))
                                .font(.caption2)
                                .foregroundStyle(isMax && highlightMaxDay ? .primary : .secondary)
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
private struct UtilizationSection: View {
    let usage: UsageSnapshot
    let accounts: [UsageAccountSnapshot]
    let progressMode: UtilizationProgressMode
    let activeAccountID: String?
    let utilizationHistories: [String: [UtilizationSeriesHistory]]
    var showHistoryToggle: Bool = false

    @State private var showHistory: Bool = UserDefaults.standard.bool(forKey: "utilization.showHistory")

    private var activeAccountHistories: [UtilizationSeriesHistory] {
        let key = activeAccountID ?? accountSections.first?.id ?? ""
        return utilizationHistories[key] ?? []
    }

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
            HStack {
                Text("Subscription Utilization")
                    .font(.headline)
                Spacer()
                if showHistoryToggle {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showHistory.toggle() }
                        UserDefaults.standard.set(showHistory, forKey: "utilization.showHistory")
                    } label: {
                        Image(systemName: showHistory ? "chart.bar.fill" : "chart.bar")
                            .font(.system(size: 13))
                            .foregroundStyle(showHistory ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Utilization History")
                }
            }

            let sections = accountSections
            if sections.count > 2 {
                ScrollView(.vertical) {
                    accountSectionsList(sections)
                }
                .frame(maxHeight: 280)
            } else {
                accountSectionsList(sections)
            }

            if showHistoryToggle && showHistory {
                Divider().opacity(0.5)
                UtilizationHistoryChartView(histories: activeAccountHistories)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private func accountSectionsList(_ sections: [UsageAccountSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
            window.toolbarStyle = .unified
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
    private let contentSize = NSSize(width: 960, height: 620)
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
        celebrateWeeklyReset: Bool,
        autoSwitchEnabled: Bool,
        autoSwitchSessionThreshold: Double,
        autoSwitchWeeklyThreshold: Double,
        autoSwitchNotificationEnabled: Bool,
        onSave: @escaping (String, UtilizationProgressMode, Bool, RefreshInterval, Bool) -> Void,
        onCelebrationChanged: @escaping (Bool) -> Void = { _ in },
        onAccountsChanged: @escaping () -> Void = {},
        onAutoSwitchChanged: @escaping (Bool, Double, Double, Bool) -> Void = { _, _, _, _ in }
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
                    celebrateWeeklyReset: celebrateWeeklyReset,
                    autoSwitchEnabled: autoSwitchEnabled,
                    autoSwitchSessionThreshold: autoSwitchSessionThreshold,
                    autoSwitchWeeklyThreshold: autoSwitchWeeklyThreshold,
                    autoSwitchNotificationEnabled: autoSwitchNotificationEnabled,
                    onSave: onSave,
                    onCelebrationChanged: onCelebrationChanged,
                    onAccountsChanged: onAccountsChanged,
                    onAutoSwitchChanged: onAutoSwitchChanged
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
        celebrateWeeklyReset: Bool,
        autoSwitchEnabled: Bool,
        autoSwitchSessionThreshold: Double,
        autoSwitchWeeklyThreshold: Double,
        autoSwitchNotificationEnabled: Bool,
        onSave: @escaping (String, UtilizationProgressMode, Bool, RefreshInterval, Bool) -> Void,
        onCelebrationChanged: @escaping (Bool) -> Void,
        onAccountsChanged: @escaping () -> Void,
        onAutoSwitchChanged: @escaping (Bool, Double, Double, Bool) -> Void
    ) {
        let settingsView = SettingsWindowView(
            currentPath: currentPath,
            currentProgressMode: currentProgressMode,
            showMenuBarPercentage: showMenuBarPercentage,
            refreshInterval: refreshInterval,
            launchAtLogin: launchAtLogin,
            celebrateWeeklyReset: celebrateWeeklyReset,
            autoSwitchEnabled: autoSwitchEnabled,
            autoSwitchSessionThreshold: autoSwitchSessionThreshold,
            autoSwitchWeeklyThreshold: autoSwitchWeeklyThreshold,
            autoSwitchNotificationEnabled: autoSwitchNotificationEnabled,
            onSave: onSave,
            onCelebrationChanged: onCelebrationChanged,
            onAccountsChanged: onAccountsChanged,
            onAutoSwitchChanged: onAutoSwitchChanged
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
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.isReleasedWhenClosed = false
            window.level = .normal
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.toolbarStyle = .unified
            let toolbar = NSToolbar(identifier: "SettingsToolbar")
            toolbar.showsBaselineSeparator = true
            window.toolbar = toolbar
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.minSize = NSSize(width: 860, height: 560)
            window.maxSize = NSSize(width: 1080, height: CGFloat.greatestFiniteMagnitude)
            window.setContentSize(contentSize)
            self.window = window
        } else {
            window?.contentViewController = hostingController
            window?.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window?.titleVisibility = .hidden
            window?.titlebarAppearsTransparent = true
            window?.isMovableByWindowBackground = true
            window?.toolbarStyle = .unified
            if window?.toolbar == nil {
                let toolbar = NSToolbar(identifier: "SettingsToolbar")
                toolbar.showsBaselineSeparator = true
                window?.toolbar = toolbar
            }
        }

        window?.minSize = NSSize(width: 860, height: 560)
        window?.maxSize = NSSize(width: 1080, height: CGFloat.greatestFiniteMagnitude)
        if let window {
            WindowPositioner.centerOnActiveScreen(window)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func bringToFront() {
        guard let window else { return }
        bringWindowToFront(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let window = self?.window else { return }
            self?.bringWindowToFront(window)
        }
    }

    private func bringWindowToFront(_ window: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }
}

private enum SettingsNavItem: String, Hashable {
    case codex, menuBar, power, celebrations
    case importedAccounts, autoSwitch
    case about

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .menuBar: return "Menu Bar"
        case .power: return "Power"
        case .celebrations: return "Celebrations"
        case .importedAccounts: return "Imported Accounts"
        case .autoSwitch: return "Auto-Switch"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .codex: return "folder"
        case .menuBar: return "menubar.rectangle"
        case .power: return "powerplug"
        case .celebrations: return "party.popper"
        case .importedAccounts: return "person.crop.circle.badge.plus"
        case .autoSwitch: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}

private enum PowerSystemSetupSetting {
    case freeze
}

@MainActor
private struct SettingsWindowView: View {
    @State private var selectedItem: SettingsNavItem? = .codex
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var currentPath: String
    @State private var progressMode: UtilizationProgressMode
    @State private var showMenuBarPercentage: Bool
    @State private var refreshInterval: RefreshInterval
    @State private var launchAtLogin: Bool
    @AppStorage("pricingSyncInterval") private var pricingSyncInterval: PricingSyncInterval = .weekly
    @State private var updateAlert: UpdateAlert?
    @State private var isCheckingUpdates = false
    @State private var isSyncingPrices = false
    @State private var importedAccounts: [ImportedCodexAccountSummary] = AccountCredentialStore.loadSummaries()
    @State private var accountAlert: UpdateAlert?
    @State private var celebrateWeeklyReset: Bool
    @State private var autoSwitchEnabled: Bool
    @State private var autoSwitchSessionThreshold: Double
    @State private var autoSwitchWeeklyThreshold: Double
    @State private var autoSwitchNotificationEnabled: Bool
    @State private var powerSnapshot: PowerManagementSnapshot?
    @State private var powerScope: PowerManagementScope = .current
    @State private var isRefreshingPowerSettings = false
    @State private var isApplyingPowerSettings = false
    @AppStorage("accountsSortOption") private var accountsSortRaw: String = AccountsSortOption.importedNewest.rawValue
    @AppStorage("accountsManualOrder") private var accountsManualOrderRaw: String = ""
    @AppStorage("accountsPinActive") private var accountsPinActive: Bool = false
    let onSave: (String, UtilizationProgressMode, Bool, RefreshInterval, Bool) -> Void
    let onCelebrationChanged: (Bool) -> Void
    let onAccountsChanged: () -> Void
    let onAutoSwitchChanged: (Bool, Double, Double, Bool) -> Void

    @State private var isOfficialLogin: Bool

    private func checkOfficialLogin() {
        let codexRoot = URL(fileURLWithPath: NSString(string: currentPath).expandingTildeInPath, isDirectory: true)
        let configURL = codexRoot.appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: configURL.path),
              let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            isOfficialLogin = true
            return
        }
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("model_provider") {
                isOfficialLogin = false
                return
            }
        }
        isOfficialLogin = true
    }

    init(
        currentPath: String,
        currentProgressMode: UtilizationProgressMode,
        showMenuBarPercentage: Bool,
        refreshInterval: RefreshInterval,
        launchAtLogin: Bool,
        celebrateWeeklyReset: Bool = true,
        autoSwitchEnabled: Bool = false,
        autoSwitchSessionThreshold: Double = 90.0,
        autoSwitchWeeklyThreshold: Double = 90.0,
        autoSwitchNotificationEnabled: Bool = true,
        onSave: @escaping (String, UtilizationProgressMode, Bool, RefreshInterval, Bool) -> Void,
        onCelebrationChanged: @escaping (Bool) -> Void = { _ in },
        onAccountsChanged: @escaping () -> Void = {},
        onAutoSwitchChanged: @escaping (Bool, Double, Double, Bool) -> Void = { _, _, _, _ in }
    ) {
        _currentPath = State(initialValue: currentPath)
        _progressMode = State(initialValue: currentProgressMode)
        _showMenuBarPercentage = State(initialValue: showMenuBarPercentage)
        _refreshInterval = State(initialValue: refreshInterval)
        _launchAtLogin = State(initialValue: launchAtLogin)
        _celebrateWeeklyReset = State(initialValue: celebrateWeeklyReset)
        _autoSwitchEnabled = State(initialValue: autoSwitchEnabled)
        _autoSwitchSessionThreshold = State(initialValue: autoSwitchSessionThreshold)
        _autoSwitchWeeklyThreshold = State(initialValue: autoSwitchWeeklyThreshold)
        _autoSwitchNotificationEnabled = State(initialValue: autoSwitchNotificationEnabled)
        self.onSave = onSave
        self.onCelebrationChanged = onCelebrationChanged
        self.onAccountsChanged = onAccountsChanged
        self.onAutoSwitchChanged = onAutoSwitchChanged

        let codexRoot = URL(fileURLWithPath: NSString(string: currentPath).expandingTildeInPath, isDirectory: true)
        let configURL = codexRoot.appendingPathComponent("config.toml")
        var official = true
        if let content = try? String(contentsOf: configURL, encoding: .utf8) {
            for line in content.split(whereSeparator: \.isNewline) {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("model_provider") {
                    official = false
                    break
                }
            }
        }
        _isOfficialLogin = State(initialValue: official)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selectedItem) {
                Section(localized("General")) {
                    Label(localized("Codex"), systemImage: SettingsNavItem.codex.symbolName)
                        .tag(SettingsNavItem.codex)
                    Label(localized("Menu Bar"), systemImage: SettingsNavItem.menuBar.symbolName)
                        .tag(SettingsNavItem.menuBar)
                    Label(localized("Power"), systemImage: SettingsNavItem.power.symbolName)
                        .tag(SettingsNavItem.power)
                    Label(localized("Celebrations"), systemImage: SettingsNavItem.celebrations.symbolName)
                        .tag(SettingsNavItem.celebrations)
                }
                Section(localized("Accounts")) {
                    Label(localized("Imported Accounts"), systemImage: SettingsNavItem.importedAccounts.symbolName)
                        .tag(SettingsNavItem.importedAccounts)
                    Label(localized("Auto-Switch"), systemImage: SettingsNavItem.autoSwitch.symbolName)
                        .tag(SettingsNavItem.autoSwitch)
                }
                Section(localized("Application")) {
                    Label(localized("About"), systemImage: SettingsNavItem.about.symbolName)
                        .tag(SettingsNavItem.about)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            let current = selectedItem ?? .codex
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(localized(current.title))
                        .font(.title.weight(.semibold))
                        .padding(.bottom, 2)
                    switch current {
                    case .codex: codexPane
                    case .menuBar: menuBarPane
                    case .power: powerPane
                    case .celebrations: celebrationsPane
                    case .importedAccounts: importedAccountsPane
                    case .autoSwitch: autoSwitchPane
                    case .about: aboutPane
                    }
                }
                .padding(.horizontal, 34)
                .padding(.top, 54)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(localized(current.title))
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            columnVisibility = columnVisibility == .all ? .detailOnly : .all
                        }
                    } label: {
                        Image(systemName: "sidebar.leading")
                    }
                    .help(localized("Toggle Sidebar"))
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CodexConfigProviderChanged"))) { _ in
            checkOfficialLogin()
        }
    }

    private var codexPane: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized("Codex Directory"))
                        .font(.callout.weight(.semibold))
                    Text(localized("Folder where codexStack reads Codex sessions."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    TextField("~/codex", text: $currentPath)
                        .textFieldStyle(.roundedBorder)
                    Button(localized("Browse..."), action: chooseDirectory)
                    Button(localized("Save"), action: savePath)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            SettingsDivider()
            SettingsLine(title: localized("Launch at Login"), subtitle: localized("Open codexStack automatically when you sign in.")) {
                SettingsSwitch(isOn: $launchAtLogin) {
                    updateLaunchAtLogin()
                }
            }
        }
    }

    private var menuBarPane: some View {
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
            SettingsDivider()
            SettingsLine(title: localized("Sync Model Prices"), subtitle: localized("Automatically download latest model prices from LiteLLM (BerriAI).")) {
                HStack(spacing: 8) {
                    Picker("", selection: $pricingSyncInterval) {
                        ForEach(PricingSyncInterval.allCases) { interval in
                            Text(localized(interval.label)).tag(interval)
                        }
                    }
                    .frame(width: 110)
                    .onChange(of: pricingSyncInterval) { newValue in
                        if newValue != .never {
                            ModelPricingSyncService.shared.syncIfNeeded()
                        }
                    }
                    Button(isSyncingPrices ? localized("Syncing...") : localized("Sync Now")) {
                        guard !isSyncingPrices else { return }
                        isSyncingPrices = true
                        Task {
                            await ModelPricingSyncService.shared.syncPrices()
                            isSyncingPrices = false
                        }
                    }
                    .disabled(isSyncingPrices)
                }
            }
        }
    }

    private var powerPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard {
                SettingsLine(
                    title: localized("Prevent Sleep Profile"),
                    subtitle: localized("Apply macOS power settings for long-running Codex sessions.")
                ) {
                    HStack(spacing: 8) {
                        Picker("", selection: $powerScope) {
                            ForEach(PowerManagementScope.allCases) { scope in
                                Text(localized(scope.label)).tag(scope)
                            }
                        }
                        .frame(width: 170)
                        .onChange(of: powerScope) { _ in refreshPowerSettings() }

                        Button {
                            refreshPowerSettings()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help(localized("Refresh"))
                        .disabled(isRefreshingPowerSettings || isApplyingPowerSettings)

                        Button {
                            applyRecommendedPowerSettings()
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .help(localized("Apply Recommended"))
                        .disabled(isRefreshingPowerSettings || isApplyingPowerSettings || isPowerProfileRecommended)

                        Button {
                            applyDisabledPowerSettings()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .help(localized("Turn Off Profile"))
                        .disabled(isRefreshingPowerSettings || isApplyingPowerSettings)
                    }
                }
                SettingsDivider()
                powerStatusRow(
                    title: "System sleep",
                    subtitle: "pmset sleep 0",
                    value: powerSnapshot?.sleepDisabled,
                    setRecommended: { applyPowerSetting(key: "sleep", value: 0) },
                    setDisabled: { applyPowerSetting(key: "sleep", value: 20) }
                )
                SettingsDivider()
                powerStatusRow(
                    title: "Display sleep",
                    subtitle: "pmset displaysleep 0",
                    value: powerSnapshot?.displaySleepDisabled,
                    setRecommended: { applyPowerSetting(key: "displaysleep", value: 0) },
                    setDisabled: { applyPowerSetting(key: "displaysleep", value: 10) }
                )
                SettingsDivider()
                powerStatusRow(
                    title: "Disk sleep",
                    subtitle: "pmset disksleep 0",
                    value: powerSnapshot?.diskSleepDisabled,
                    setRecommended: { applyPowerSetting(key: "disksleep", value: 0) },
                    setDisabled: { applyPowerSetting(key: "disksleep", value: 10) }
                )
                SettingsDivider()
                powerStatusRow(
                    title: "Wake on network",
                    subtitle: "pmset womp 1",
                    value: powerSnapshot?.wakeOnMagicPacketEnabled,
                    setRecommended: { applyPowerSetting(key: "womp", value: 1) },
                    setDisabled: { applyPowerSetting(key: "womp", value: 0) }
                )
                SettingsDivider()
                powerStatusRow(
                    title: "Power Nap",
                    subtitle: "pmset powernap 0",
                    value: powerSnapshot?.powerNapDisabled,
                    setRecommended: { applyPowerSetting(key: "powernap", value: 0) },
                    setDisabled: { applyPowerSetting(key: "powernap", value: 1) }
                )
                SettingsDivider()
                powerStatusRow(
                    title: "Restart after power failure",
                    subtitle: "pmset autorestart 1",
                    value: powerSnapshot?.autoRestartEnabled,
                    unavailable: powerSnapshot?.autoRestartAvailable == false,
                    setRecommended: { applyPowerSetting(key: "autorestart", value: 1) },
                    setDisabled: { applyPowerSetting(key: "autorestart", value: 0) }
                )
                SettingsDivider()
                powerStatusRow(
                    title: "Restart after freeze",
                    subtitle: "systemsetup -setrestartfreeze on",
                    value: powerSnapshot?.restartAfterFreezeEnabled,
                    requiresAdmin: powerSnapshot?.restartAfterFreezeRequiresAdmin == true,
                    setRecommended: { applyPowerSystemSetupSetting(.freeze, enabled: true) },
                    setDisabled: { applyPowerSystemSetupSetting(.freeze, enabled: false) }
                )
            }
            Text(localized("Applying recommended power settings requires administrator authorization."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .onAppear {
            if powerSnapshot == nil {
                refreshPowerSettings()
            }
        }
    }

    private var celebrationsPane: some View {
        settingsCard {
            SettingsLine(
                title: localized("Weekly Reset"),
                subtitle: localized("Play a full-screen confetti animation when the weekly quota resets.")
            ) {
                SettingsSwitch(isOn: $celebrateWeeklyReset) {
                    onCelebrationChanged(celebrateWeeklyReset)
                }
            }
            SettingsDivider()
            SettingsLine(
                title: localized("Preview"),
                subtitle: localized("Test the animation on the active screen.")
            ) {
                Button(localized("Test Animation")) {
                    ResetCelebrationController.shared.present(kind: .weekly)
                }
            }
        }
    }

    private var importedAccountsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
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
                                    Divider().padding(.horizontal, 16)
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

    private var autoSwitchPane: some View {
        settingsCard {
            if !isOfficialLogin {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(localized("Auto-Switch is disabled because a custom provider is active."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 16)
                .background(Color.yellow.opacity(0.1))
                SettingsDivider()
            }
            Group {
                SettingsLine(
                    title: localized("Auto-Switch Accounts"),
                    subtitle: localized("Automatically switch to the account with the lowest usage when the current account reaches a specified percentage limit.")
                ) {
                    SettingsSwitch(isOn: $autoSwitchEnabled) {
                        onAutoSwitchChanged(autoSwitchEnabled, autoSwitchSessionThreshold, autoSwitchWeeklyThreshold, autoSwitchNotificationEnabled)
                    }
                }
                if autoSwitchEnabled {
                    SettingsDivider()
                    SettingsLine(
                        title: localized("Session Limit Threshold"),
                        subtitle: localized("Switch when the current account's 5h session limit reaches this percentage.")
                    ) {
                        HStack {
                            Slider(value: $autoSwitchSessionThreshold, in: 1...100) { _ in
                                onAutoSwitchChanged(autoSwitchEnabled, autoSwitchSessionThreshold, autoSwitchWeeklyThreshold, autoSwitchNotificationEnabled)
                            }
                            .frame(width: 150)
                            Text("\(Int(autoSwitchSessionThreshold))%")
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    SettingsDivider()
                    SettingsLine(
                        title: localized("Weekly Limit Threshold"),
                        subtitle: localized("Switch when the current account's weekly limit reaches this percentage.")
                    ) {
                        HStack {
                            Slider(value: $autoSwitchWeeklyThreshold, in: 1...100) { _ in
                                onAutoSwitchChanged(autoSwitchEnabled, autoSwitchSessionThreshold, autoSwitchWeeklyThreshold, autoSwitchNotificationEnabled)
                            }
                            .frame(width: 150)
                            Text("\(Int(autoSwitchWeeklyThreshold))%")
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    SettingsDivider()
                    SettingsLine(
                        title: localized("Auto-Switch Notifications"),
                        subtitle: localized("Show a macOS notification when an automatic switch occurs.")
                    ) {
                        SettingsSwitch(isOn: $autoSwitchNotificationEnabled) {
                            onAutoSwitchChanged(autoSwitchEnabled, autoSwitchSessionThreshold, autoSwitchWeeklyThreshold, autoSwitchNotificationEnabled)
                        }
                    }
                }
            }
            .disabled(!isOfficialLogin)
            .opacity(isOfficialLogin ? 1.0 : 0.5)
        }
    }

    private func powerStatusRow(
        title: String,
        subtitle: String,
        value: Bool?,
        unavailable: Bool = false,
        requiresAdmin: Bool = false,
        setRecommended: @escaping () -> Void,
        setDisabled: @escaping () -> Void
    ) -> some View {
        SettingsLine(title: localized(title), subtitle: subtitle) {
            HStack(spacing: 8) {
                Circle()
                    .fill(powerStatusColor(value, unavailable: unavailable, requiresAdmin: requiresAdmin))
                    .frame(width: 8, height: 8)
                Text(powerStatusLabel(value, unavailable: unavailable, requiresAdmin: requiresAdmin))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(value == true ? Color.green : .secondary)
                    .frame(width: 92, alignment: .trailing)
                Menu {
                    Button(localized("Set Recommended")) {
                        setRecommended()
                    }
                    .disabled(value == true)
                    Button(localized("Turn Off")) {
                        setDisabled()
                    }
                    .disabled(value == false)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .frame(width: 42, height: 26)
                .help(localized("Power Actions"))
                .disabled(unavailable || isRefreshingPowerSettings || isApplyingPowerSettings)
            }
        }
    }

    private var isPowerProfileRecommended: Bool {
        guard let powerSnapshot, powerSnapshot.knownCount > 0 else {
            return false
        }
        return powerSnapshot.recommendedCount == powerSnapshot.knownCount
    }

    private func powerStatusColor(_ value: Bool?, unavailable: Bool, requiresAdmin: Bool) -> Color {
        if unavailable { return .secondary.opacity(0.45) }
        if requiresAdmin { return .blue }
        switch value {
        case true:
            return .green
        case false:
            return .secondary.opacity(0.45)
        case nil:
            return .orange
        }
    }

    private func powerStatusLabel(_ value: Bool?, unavailable: Bool, requiresAdmin: Bool) -> String {
        if unavailable { return localized("Unavailable") }
        if requiresAdmin { return localized("Needs Admin") }
        switch value {
        case true:
            return localized("Recommended")
        case false:
            return localized("Not Set")
        case nil:
            return localized("Unknown")
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
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(
                Color(nsColor: .windowBackgroundColor).opacity(0.82),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.035), radius: 10, x: 0, y: 3)
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
            savePath()
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
            Menu {
                Button(localized("Sync to Codex (auth.json)")) {
                    syncToAuthJSON(id: account.id)
                }
                Button(localized("Sync Sessions Metadata")) {
                    syncSessionsMetadata()
                }
                Button(localized("Export Configuration...")) {
                    exportAccount(id: account.id)
                }
                Button(localized("Remove"), role: .destructive) {
                    removeAccount(id: account.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32)
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

    private func exportAccount(id: String) {
        guard let account = AccountCredentialStore.loadAccounts().first(where: { $0.id == id }) else {
            accountAlert = UpdateAlert(
                title: localized("Export Failed"),
                message: localized("Account details could not be loaded.")
            )
            return
        }

        let panel = NSSavePanel()
        panel.prompt = localized("Export")
        let defaultName = account.email ?? account.accountID ?? "codex-account"
        panel.nameFieldStringValue = "\(defaultName).json"
        panel.allowedContentTypes = [.json]
        
        let formatButton = NSPopUpButton()
        formatButton.addItems(withTitles: [localized("Codex Format"), localized("cliproxyapi Format")])
        
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        let label = NSTextField(labelWithString: localized("Format:"))
        label.frame = NSRect(x: 0, y: 3, width: 60, height: 16)
        formatButton.frame = NSRect(x: 65, y: 0, width: 180, height: 24)
        accessoryView.addSubview(label)
        accessoryView.addSubview(formatButton)
        
        panel.accessoryView = accessoryView
        
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var dict: [String: Any] = [:]
        
        if formatButton.indexOfSelectedItem == 0 {
            // Codex Format
            var tokens: [String: Any] = ["access_token": account.accessToken]
            if let idToken = account.idToken { tokens["id_token"] = idToken }
            if let refreshToken = account.refreshToken { tokens["refresh_token"] = refreshToken }
            if let accountID = account.accountID { tokens["account_id"] = accountID }
            
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone.current
            
            dict["auth_mode"] = account.type == "codex" ? "chatgpt" : (account.type ?? "chatgpt")
            dict["OPENAI_API_KEY"] = NSNull()
            dict["tokens"] = tokens
            dict["last_refresh"] = formatter.string(from: Date())
        } else {
            // cliproxyapi Format
            dict["access_token"] = account.accessToken
            if let idToken = account.idToken { dict["id_token"] = idToken }
            if let refreshToken = account.refreshToken { dict["refresh_token"] = refreshToken }
            if let email = account.email { dict["email"] = email }
            if let note = account.note { dict["note"] = note }
            if let accountID = account.accountID { dict["account_id"] = accountID }
            dict["type"] = account.type ?? "codex"
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        } catch {
            accountAlert = UpdateAlert(
                title: localized("Export Failed"),
                message: error.localizedDescription
            )
        }
    }

    private func syncSessionsMetadata() {
        let codexRoot = URL(fileURLWithPath: NSString(string: currentPath).expandingTildeInPath, isDirectory: true)
        let syncService = ProviderSyncService(codexRoot: codexRoot)
        do {
            let count = try syncService.sync()
            accountAlert = UpdateAlert(
                title: localized("Sync Complete"),
                message: String(
                    format: localized("Synchronized %d session(s) metadata successfully. You may need to restart Codex for changes to take full effect."),
                    count
                )
            )
        } catch {
            accountAlert = UpdateAlert(
                title: localized("Sync Failed"),
                message: error.localizedDescription
            )
        }
    }

    private func syncToAuthJSON(id: String) {
        guard let account = AccountCredentialStore.loadAccounts().first(where: { $0.id == id }) else {
            accountAlert = UpdateAlert(
                title: localized("Sync Failed"),
                message: localized("Account details could not be loaded.")
            )
            return
        }

        let codexRoot = URL(fileURLWithPath: NSString(string: currentPath).expandingTildeInPath, isDirectory: true)
        let authURL = codexRoot.appending(path: "auth.json")
        
        var tokens: [String: Any] = ["access_token": account.accessToken]
        if let idToken = account.idToken { tokens["id_token"] = idToken }
        if let refreshToken = account.refreshToken { tokens["refresh_token"] = refreshToken }
        
        var dict: [String: Any] = [
            "type": account.type ?? "codex",
            "tokens": tokens
        ]
        if let email = account.email { dict["email"] = email }
        if let note = account.note { dict["note"] = note }
        if let accountID = account.accountID { dict["account_id"] = accountID }

        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: authURL)
            accountAlert = UpdateAlert(
                title: localized("Sync Successful"),
                message: localized("The credentials have been written to auth.json successfully.")
            )
        } catch {
            accountAlert = UpdateAlert(
                title: localized("Sync Failed"),
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

    private func refreshPowerSettings() {
        guard !isRefreshingPowerSettings else { return }
        isRefreshingPowerSettings = true
        let scope = powerScope
        Task {
            var snapshot = await Task.detached(priority: .userInitiated) {
                PowerManagementService.loadSnapshot(scope: scope)
            }.value
            if snapshot.restartAfterFreezeRequiresAdmin {
                snapshot = await MainActor.run {
                    PowerManagementService.loadSnapshotWithAuthorizedReads(scope: scope)
                }
                await MainActor.run {
                    SettingsWindowController.shared.bringToFront()
                }
            }
            await MainActor.run {
                powerSnapshot = snapshot
                isRefreshingPowerSettings = false
            }
        }
    }

    private func applyRecommendedPowerSettings() {
        guard !isApplyingPowerSettings else { return }
        isApplyingPowerSettings = true
        let scope = powerScope
        Task {
            do {
                try await MainActor.run {
                    try PowerManagementService.applyRecommendedSettings(scope: scope)
                    SettingsWindowController.shared.bringToFront()
                }
                let snapshot = await Task.detached(priority: .userInitiated) {
                    PowerManagementService.snapshotAfterApplyingRecommendedSettings(scope: scope)
                }.value
                await MainActor.run {
                    powerSnapshot = snapshot
                    isApplyingPowerSettings = false
                    updateAlert = UpdateAlert(
                        title: localized("Power Settings Updated"),
                        message: localized("Recommended sleep prevention settings have been applied.")
                    )
                }
            } catch {
                await MainActor.run {
                    isApplyingPowerSettings = false
                    updateAlert = UpdateAlert(
                        title: localized("Unable to Update Power Settings"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func applyDisabledPowerSettings() {
        guard !isApplyingPowerSettings else { return }
        isApplyingPowerSettings = true
        let scope = powerScope
        Task {
            do {
                try await MainActor.run {
                    try PowerManagementService.applyDisabledSettings(scope: scope)
                    SettingsWindowController.shared.bringToFront()
                }
                let snapshot = await Task.detached(priority: .userInitiated) {
                    var snapshot = PowerManagementService.loadSnapshot(scope: scope)
                    snapshot.restartAfterFreezeEnabled = false
                    snapshot.restartAfterFreezeRequiresAdmin = false
                    return snapshot
                }.value
                await MainActor.run {
                    powerSnapshot = snapshot
                    isApplyingPowerSettings = false
                    updateAlert = UpdateAlert(
                        title: localized("Power Settings Updated"),
                        message: localized("Prevent sleep profile has been turned off.")
                    )
                }
            } catch {
                await MainActor.run {
                    isApplyingPowerSettings = false
                    updateAlert = UpdateAlert(
                        title: localized("Unable to Update Power Settings"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func applyPowerSetting(key: String, value: Int) {
        guard !isApplyingPowerSettings else { return }
        isApplyingPowerSettings = true
        let scope = powerScope
        Task {
            do {
                try await MainActor.run {
                    try PowerManagementService.applyPMSetSetting(key: key, value: value, scope: scope)
                    SettingsWindowController.shared.bringToFront()
                }
                let snapshot = await Task.detached(priority: .userInitiated) {
                    PowerManagementService.loadSnapshot(scope: scope)
                }.value
                await MainActor.run {
                    powerSnapshot = snapshot
                    isApplyingPowerSettings = false
                }
            } catch {
                await MainActor.run {
                    isApplyingPowerSettings = false
                    updateAlert = UpdateAlert(
                        title: localized("Unable to Update Power Settings"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func applyPowerSystemSetupSetting(_ setting: PowerSystemSetupSetting, enabled: Bool) {
        guard !isApplyingPowerSettings else { return }
        isApplyingPowerSettings = true
        let scope = powerScope
        Task {
            do {
                try await MainActor.run {
                    switch setting {
                    case .freeze:
                        try PowerManagementService.applyRestartAfterFreeze(enabled: enabled)
                    }
                    SettingsWindowController.shared.bringToFront()
                }
                let snapshot = await Task.detached(priority: .userInitiated) {
                    var snapshot = PowerManagementService.loadSnapshot(scope: scope)
                    switch setting {
                    case .freeze:
                        snapshot.restartAfterFreezeEnabled = enabled
                        snapshot.restartAfterFreezeRequiresAdmin = false
                    }
                    return snapshot
                }.value
                await MainActor.run {
                    powerSnapshot = snapshot
                    isApplyingPowerSettings = false
                }
            } catch {
                await MainActor.run {
                    isApplyingPowerSettings = false
                    updateAlert = UpdateAlert(
                        title: localized("Unable to Update Power Settings"),
                        message: error.localizedDescription
                    )
                }
            }
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
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .allowsTightening(false)
                }
            }
            .frame(minWidth: 140, alignment: .leading)
            Spacer(minLength: 16)
            accessory()
                .padding(.top, 1)
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

private struct IconCacheKey: Equatable {
    let session: Double?
    let weekly: Double?
    let mode: UtilizationProgressMode
}
