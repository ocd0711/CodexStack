import AppKit
import SwiftUI

@main
struct CodexStackApp: App {
    private static let codexRootPathDefaultsKey = "codexRootPath"
    private static let utilizationProgressModeDefaultsKey = "utilizationProgressMode"
    private static let showMenuBarPercentageDefaultsKey = "showMenuBarPercentage"
    @NSApplicationDelegateAdaptor(CodexStackAppDelegate.self) private var appDelegate
    @StateObject private var store: SessionStore
    @State private var showMenuBarPercentage: Bool

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.codexRootPathDefaultsKey)
            ?? SessionStore.defaultCodexRootPath()
        let savedModeRaw = UserDefaults.standard.string(forKey: Self.utilizationProgressModeDefaultsKey)
        let savedMode = UtilizationProgressMode(rawValue: savedModeRaw ?? "") ?? .remaining
        let showPercentage = UserDefaults.standard.object(forKey: Self.showMenuBarPercentageDefaultsKey) as? Bool ?? true
        _store = StateObject(
            wrappedValue: SessionStore(
                codexRootPath: saved,
                utilizationProgressMode: savedMode
            )
        )
        _showMenuBarPercentage = State(initialValue: showPercentage)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(
                onOpenSettings: {
                    SettingsWindowController.shared.show(
                        currentPath: store.codexRootPath,
                        currentProgressMode: store.utilizationProgressMode,
                        showMenuBarPercentage: showMenuBarPercentage
                    ) { newPath, progressMode, showPercentage in
                        let expanded = NSString(string: newPath).expandingTildeInPath
                        UserDefaults.standard.set(expanded, forKey: Self.codexRootPathDefaultsKey)
                        UserDefaults.standard.set(
                            progressMode.rawValue,
                            forKey: Self.utilizationProgressModeDefaultsKey
                        )
                        UserDefaults.standard.set(showPercentage, forKey: Self.showMenuBarPercentageDefaultsKey)
                        if expanded != store.codexRootPath {
                            store.updateCodexRootPath(expanded)
                        }
                        store.updateUtilizationProgressMode(progressMode)
                        showMenuBarPercentage = showPercentage
                    }
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

    var body: some View {
        VStack(spacing: 10) {
            header
            UtilizationSection(usage: store.usage, progressMode: store.utilizationProgressMode)
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
                Text(accountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                if store.sessions.isEmpty {
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

            if store.sessions.isEmpty {
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
                                    Menu {
                                        Button("Remove Project...", role: .destructive) {
                                            confirmProjectDeletion(projectName: project.projectName)
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                    }
                                    .buttonStyle(.plain)
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
                                            Button("Delete Conversation...", role: .destructive) {
                                                confirmSessionDeletion(session: session)
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis")
                                        }
                                        .buttonStyle(.plain)
                                    }
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
        let grouped = Dictionary(grouping: recent, by: \.projectName)
        let groups = grouped.map { key, value in
            ProjectMenuGroup(
                id: key,
                projectName: key,
                latest: value.first?.updatedAt ?? .distantPast,
                sessions: value
            )
        }
        return groups.sorted { $0.latest > $1.latest }
    }

    private var accountLabel: String {
        if let name = store.usage.accountName, !name.isEmpty {
            return name
        }
        if let email = store.usage.accountEmail, !email.isEmpty {
            return email
        }
        return "Account unavailable"
    }

    private var planLabel: String {
        guard let plan = store.usage.planType, !plan.isEmpty else {
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

    private func confirmProjectDeletion(projectName: String) {
        let message = String.localizedStringWithFormat(
            NSLocalizedString("Project: %@", bundle: .module, comment: ""),
            projectName
        )
        if DialogPresenter.confirmDestructive(
            title: NSLocalizedString("Delete all conversations in this project?", bundle: .module, comment: ""),
            message: message,
            buttonTitle: NSLocalizedString("Delete Project", bundle: .module, comment: "")
        ) {
            store.trashProject(named: projectName)
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
    let progressMode: UtilizationProgressMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Subscription Utilization")
                .font(.headline)

            utilizationLane(
                title: "Session",
                usedRatio: usage.sessionUsedRatio,
                resetAt: usage.sessionResetAt,
                defaultWindowSeconds: 5 * 60 * 60
            )
            utilizationLane(
                title: "Weekly",
                usedRatio: usage.weeklyUsedRatio,
                resetAt: usage.weeklyResetAt,
                defaultWindowSeconds: 7 * 24 * 60 * 60
            )
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
    let latest: Date
    let sessions: [CodexSession]
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
    private let contentSize = NSSize(width: 760, height: 620)
    private var settingsViewController: SettingsViewController?

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
        onSave: @escaping (String, UtilizationProgressMode, Bool) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.dismissTransientMenuWindows()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.showNow(
                    currentPath: currentPath,
                    currentProgressMode: currentProgressMode,
                    showMenuBarPercentage: showMenuBarPercentage,
                    onSave: onSave
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
        onSave: @escaping (String, UtilizationProgressMode, Bool) -> Void
    ) {
        let viewController: SettingsViewController
        if let existing = settingsViewController {
            existing.configure(
                currentPath: currentPath,
                currentProgressMode: currentProgressMode,
                showMenuBarPercentage: showMenuBarPercentage,
                onSave: onSave
            )
            viewController = existing
        } else {
            viewController = SettingsViewController(
                currentPath: currentPath,
                currentProgressMode: currentProgressMode,
                showMenuBarPercentage: showMenuBarPercentage,
                onSave: onSave
            )
            settingsViewController = viewController
        }

        if window == nil {
            let window = NSWindow(contentViewController: viewController)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.level = .normal
            window.isMovableByWindowBackground = true
            window.toolbarStyle = .unified
            window.backgroundColor = .windowBackgroundColor
            window.setContentSize(contentSize)
            window.minSize = NSSize(width: 700, height: 560)
            self.window = window
        } else {
            window?.contentViewController = viewController
        }

        window?.setContentSize(contentSize)
        window?.minSize = NSSize(width: 700, height: 560)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class SettingsViewController: NSViewController {
    private let pathField = NSTextField()
    private let pathSaveButton = NSButton()
    private let progressControl = NSSegmentedControl(
        labels: UtilizationProgressMode.allCases.map(\.label),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let showPercentageCheckbox = NSButton()
    private var currentPath: String
    private var progressMode: UtilizationProgressMode
    private var showMenuBarPercentage: Bool
    private var onSave: (String, UtilizationProgressMode, Bool) -> Void

    init(
        currentPath: String,
        currentProgressMode: UtilizationProgressMode,
        showMenuBarPercentage: Bool,
        onSave: @escaping (String, UtilizationProgressMode, Bool) -> Void
    ) {
        self.currentPath = currentPath
        self.progressMode = currentProgressMode
        self.showMenuBarPercentage = showMenuBarPercentage
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        configure(
            currentPath: currentPath,
            currentProgressMode: currentProgressMode,
            showMenuBarPercentage: showMenuBarPercentage,
            onSave: onSave
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        currentPath: String,
        currentProgressMode: UtilizationProgressMode,
        showMenuBarPercentage: Bool,
        onSave: @escaping (String, UtilizationProgressMode, Bool) -> Void
    ) {
        self.currentPath = currentPath
        self.showMenuBarPercentage = showMenuBarPercentage
        if isViewLoaded {
            pathField.stringValue = currentPath
            progressControl.selectedSegment = UtilizationProgressMode.allCases.firstIndex(of: currentProgressMode) ?? 0
            showPercentageCheckbox.state = showMenuBarPercentage ? .on : .off
        }
        progressMode = currentProgressMode
        self.onSave = onSave
    }

    override func loadView() {
        let effectView = NSVisualEffectView()
        effectView.material = .contentBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false
        view = effectView

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(rootStack)

        let topBar = makeSettingsHeader()
        let divider = makeDivider()
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let contentWrap = NSView()
        contentWrap.translatesAutoresizingMaskIntoConstraints = false
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentWrap.addSubview(contentStack)
        scrollView.documentView = contentWrap

        let systemSection = makeSectionTitle(localized("SYSTEM"))
        let (systemCard, systemCardStack) = makeSettingsCard()
        let directoryRow = makeSettingsRow(
            title: localized("Codex Directory"),
            subtitle: localized("Used for session scan, archive, and index reconciliation.")
        )

        let pathRow = NSStackView()
        pathRow.orientation = .horizontal
        pathRow.alignment = .centerY
        pathRow.spacing = 8
        pathRow.translatesAutoresizingMaskIntoConstraints = false

        pathField.placeholderString = SessionStore.defaultCodexRootPath()
        pathField.bezelStyle = .roundedBezel
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.font = .systemFont(ofSize: 13)

        let browseButton = NSButton(title: localized("Browse..."), target: self, action: #selector(chooseDirectory))
        browseButton.bezelStyle = .rounded
        pathSaveButton.title = localized("Save")
        pathSaveButton.target = self
        pathSaveButton.action = #selector(savePath)
        pathSaveButton.bezelStyle = .rounded

        pathRow.addArrangedSubview(pathField)
        pathRow.addArrangedSubview(browseButton)
        pathRow.addArrangedSubview(pathSaveButton)
        directoryRow.addArrangedSubview(pathRow)
        systemCardStack.addArrangedSubview(directoryRow)

        let displaySection = makeSectionTitle(localized("DISPLAY"))
        let (displayCard, displayCardStack) = makeSettingsCard()
        let progressRow = makeSettingsRow(
            title: localized("Progress Bar"),
            subtitle: localized("Controls whether usage bars show used or remaining quota.")
        )

        progressControl.target = self
        progressControl.action = #selector(progressModeChanged)
        progressControl.segmentStyle = .rounded
        progressControl.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<progressControl.segmentCount {
            progressControl.setWidth(116, forSegment: index)
        }
        progressRow.addArrangedSubview(progressControl)

        showPercentageCheckbox.setButtonType(.switch)
        showPercentageCheckbox.title = localized("Show percentage text")
        showPercentageCheckbox.target = self
        showPercentageCheckbox.action = #selector(showPercentageChanged)
        showPercentageCheckbox.state = showMenuBarPercentage ? .on : .off
        showPercentageCheckbox.font = .systemFont(ofSize: 15, weight: .medium)
        let percentageRow = makeSettingsRow(
            title: "",
            subtitle: localized("Display the quota percentage next to the menu bar icon.")
        )
        percentageRow.insertArrangedSubview(showPercentageCheckbox, at: 0)
        displayCardStack.addArrangedSubview(progressRow)
        displayCardStack.addArrangedSubview(makeSeparator())
        displayCardStack.addArrangedSubview(percentageRow)

        let automationSection = makeSectionTitle(localized("AUTOMATION"))
        let (automationCard, automationCardStack) = makeSettingsCard()
        let refreshInfo = makeMutedText(localized("Usage and sessions refresh automatically when the menu opens or after mutations."))
        automationCardStack.addArrangedSubview(refreshInfo)

        contentStack.addArrangedSubview(systemSection)
        contentStack.addArrangedSubview(systemCard)
        contentStack.addArrangedSubview(displaySection)
        contentStack.addArrangedSubview(displayCard)
        contentStack.addArrangedSubview(automationSection)
        contentStack.addArrangedSubview(automationCard)
        rootStack.addArrangedSubview(topBar)
        rootStack.addArrangedSubview(divider)
        rootStack.addArrangedSubview(scrollView)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: effectView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            topBar.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 112),
            divider.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            scrollView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            contentWrap.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: contentWrap.leadingAnchor, constant: 78),
            contentStack.trailingAnchor.constraint(equalTo: contentWrap.trailingAnchor, constant: -78),
            contentStack.topAnchor.constraint(equalTo: contentWrap.topAnchor, constant: 28),
            contentStack.bottomAnchor.constraint(equalTo: contentWrap.bottomAnchor, constant: -32),
            systemSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            systemCard.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            directoryRow.widthAnchor.constraint(equalTo: systemCardStack.widthAnchor),
            displaySection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            displayCard.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            progressRow.widthAnchor.constraint(equalTo: displayCardStack.widthAnchor),
            percentageRow.widthAnchor.constraint(equalTo: displayCardStack.widthAnchor),
            automationSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            automationCard.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            refreshInfo.widthAnchor.constraint(equalTo: automationCardStack.widthAnchor),
            pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            pathField.heightAnchor.constraint(equalToConstant: 28),
            progressControl.heightAnchor.constraint(equalToConstant: 28),
        ])

        configure(
            currentPath: currentPath,
            currentProgressMode: progressMode,
            showMenuBarPercentage: showMenuBarPercentage,
            onSave: onSave
        )
    }

    private func makeSettingsHeader() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        let logoView = NSImageView(image: projectLogoImage())
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.translatesAutoresizingMaskIntoConstraints = false

        let logoPlate = NSVisualEffectView()
        logoPlate.material = .popover
        logoPlate.blendingMode = .withinWindow
        logoPlate.state = .active
        logoPlate.wantsLayer = true
        logoPlate.layer?.cornerRadius = 18
        logoPlate.translatesAutoresizingMaskIntoConstraints = false
        logoPlate.addSubview(logoView)

        let titleStack = makeVerticalStack(spacing: 4)
        titleStack.addArrangedSubview(makeLabel("codexStack", font: .systemFont(ofSize: 24, weight: .semibold)))
        titleStack.addArrangedSubview(makeLabel(
            localized("Configure codexStack and Codex session sources."),
            font: .systemFont(ofSize: 13),
            color: .secondaryLabelColor
        ))

        row.addArrangedSubview(logoPlate)
        row.addArrangedSubview(titleStack)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 78),
            row.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -78),
            row.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            logoPlate.widthAnchor.constraint(equalToConstant: 58),
            logoPlate.heightAnchor.constraint(equalToConstant: 58),
            logoView.centerXAnchor.constraint(equalTo: logoPlate.centerXAnchor),
            logoView.centerYAnchor.constraint(equalTo: logoPlate.centerYAnchor),
            logoView.widthAnchor.constraint(equalToConstant: 42),
            logoView.heightAnchor.constraint(equalToConstant: 42),
        ])
        return container
    }

    private func projectLogoImage() -> NSImage {
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

    private func makeDivider() -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        return divider
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let label = makeLabel(text, font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func makeSettingsRow(title: String, subtitle: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        if !title.isEmpty {
            row.addArrangedSubview(makeLabel(title, font: .systemFont(ofSize: 16, weight: .regular)))
        }
        if !subtitle.isEmpty {
            row.addArrangedSubview(makeMutedText(subtitle))
        }
        return row
    }

    private func makeSettingsCard() -> (NSVisualEffectView, NSStackView) {
        let card = NSVisualEffectView()
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = makeVerticalStack(spacing: 14)
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])

        return (card, stack)
    }

    private func makeMutedText(_ text: String) -> NSTextField {
        makeLabel(text, font: .systemFont(ofSize: 13), color: .tertiaryLabelColor)
    }

    private func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 1),
        ])
        return box
    }

    private func makeVerticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeLabel(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }

    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let window = view.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.pathField.stringValue = url.path
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            pathField.stringValue = url.path
        }
    }

    @objc private func progressModeChanged() {
        let index = progressControl.selectedSegment
        guard UtilizationProgressMode.allCases.indices.contains(index) else { return }
        progressMode = UtilizationProgressMode.allCases[index]
        applyNonPathSettings()
    }

    @objc private func showPercentageChanged() {
        showMenuBarPercentage = showPercentageCheckbox.state == .on
        applyNonPathSettings()
    }

    @objc private func savePath() {
        currentPath = pathField.stringValue
        onSave(currentPath, progressMode, showMenuBarPercentage)
    }

    private func applyNonPathSettings() {
        onSave(currentPath, progressMode, showMenuBarPercentage)
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
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return nil }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
