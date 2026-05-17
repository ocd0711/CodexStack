import AppKit
import SwiftUI

@main
struct ConvStackApp: App {
    private static let codexRootPathDefaultsKey = "codexRootPath"
    @NSApplicationDelegateAdaptor(ConvStackAppDelegate.self) private var appDelegate
    @StateObject private var store: SessionStore

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.codexRootPathDefaultsKey)
            ?? SessionStore.defaultCodexRootPath()
        _store = StateObject(wrappedValue: SessionStore(codexRootPath: saved))
    }

    var body: some Scene {
        MenuBarExtra("ConvStack", systemImage: "square.stack.3d.up") {
            MenuBarPanel(
                onOpenSettings: {
                    SettingsWindowController.shared.show(currentPath: store.codexRootPath) { newPath in
                        let expanded = NSString(string: newPath).expandingTildeInPath
                        UserDefaults.standard.set(expanded, forKey: Self.codexRootPathDefaultsKey)
                        store.updateCodexRootPath(expanded)
                    }
                }
            )
            .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

final class ConvStackAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private struct MenuBarPanel: View {
    @EnvironmentObject private var store: SessionStore
    let onOpenSettings: () -> Void

    private let maxProjectsInMenu = 8
    private let maxSessionsPerProject = 5

    var body: some View {
        VStack(spacing: 10) {
            header
            UtilizationSection(usage: store.usage)
            costSection
            projectsSection
            actionsRow
        }
        .padding(12)
        .frame(width: 430)
        .background(.regularMaterial)
        .onAppear {
            if store.sessions.isEmpty {
                store.refresh()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex")
                    .font(.title3.weight(.semibold))
                if let updatedAt = store.usage.updatedAt {
                    Text("Updated \(updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("Subscription")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var costSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cost")
                .font(.headline)
            HStack {
                Text("Today")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(formatUSD(store.usage.todayCostUSD)) · \(formatTokens(store.usage.todayTokens))")
            }
            HStack {
                Text("Last 30 days")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(formatUSD(store.usage.last30DaysCostUSD)) · \(formatTokens(store.usage.last30DaysTokens))")
            }
            Text("Estimated from local Codex logs.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Projects")
                    .font(.headline)
                Spacer()
                Text("\(store.sessions.count) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.sessions.isEmpty {
                Text("No sessions found")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(groupedProjects()) { project in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(project.title)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Button(role: .destructive) {
                                        store.trashProject(named: project.projectName)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.plain)
                                }

                                ForEach(project.sessions.prefix(maxSessionsPerProject)) { session in
                                    HStack {
                                        Text(shortTitle(for: session.title))
                                            .font(.caption)
                                            .lineLimit(1)
                                        Spacer()
                                        Button(session.isArchived ? "Unarchive" : "Archive") {
                                            store.selectedIDs = [session.id]
                                            if session.isArchived {
                                                store.unarchiveSelected()
                                            } else {
                                                store.archiveSelected()
                                            }
                                        }
                                        .font(.caption2)
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var actionsRow: some View {
        HStack {
            Button("Open Manager") {
                ManagerWindowController.shared.show(with: store)
            }
            Button("Refresh") {
                store.refresh()
            }
            Button("Settings...") {
                onOpenSettings()
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .buttonStyle(.bordered)
    }

    private func shortTitle(for title: String) -> String {
        if title.count <= 52 { return title }
        let end = title.index(title.startIndex, offsetBy: 49)
        return "\(title[..<end])..."
    }

    private func groupedProjects() -> [ProjectMenuGroup] {
        let recent = store.sessions.sorted { $0.updatedAt > $1.updatedAt }
        let grouped = Dictionary(grouping: recent, by: \.projectName)
        let groups = grouped.map { key, value in
            ProjectMenuGroup(
                id: key,
                title: "\(key) (\(value.count))",
                projectName: key,
                latest: value.first?.updatedAt ?? .distantPast,
                sessions: value
            )
        }
        return groups.sorted { $0.latest > $1.latest }.prefix(maxProjectsInMenu).map { $0 }
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
}

private struct UtilizationSection: View {
    let usage: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subscription Utilization")
                .font(.headline)

            utilizationRow(
                title: "Session",
                usedRatio: usage.sessionUsedRatio,
                resetAt: usage.sessionResetAt
            )
            utilizationRow(
                title: "Weekly",
                usedRatio: usage.weeklyUsedRatio,
                resetAt: usage.weeklyResetAt
            )
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func utilizationRow(title: String, usedRatio: Double, resetAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int((1 - usedRatio) * 100))% left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, max(0, usedRatio)))
            if let resetAt {
                Text("Resets \(resetAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Reset unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProjectMenuGroup: Identifiable {
    let id: String
    let title: String
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
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.level = .normal
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

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(currentPath: String, onSave: @escaping (String) -> Void) {
        let rootView = SettingsView(currentPath: currentPath, onSave: onSave)
        let hosting = NSHostingController(rootView: rootView)

        if window == nil {
            let window = NSWindow(contentViewController: hosting)
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.level = .normal
            window.setContentSize(NSSize(width: 620, height: 210))
            window.minSize = NSSize(width: 560, height: 200)
            self.window = window
        } else {
            window?.contentViewController = hosting
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @State private var path: String
    let onSave: (String) -> Void

    init(currentPath: String, onSave: @escaping (String) -> Void) {
        self._path = State(initialValue: currentPath)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Codex Directory")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("~/.codex", text: $path)
                    .textFieldStyle(.roundedBorder)
                Button("Browse...") {
                    chooseDirectory()
                }
            }

            Text("Used for session scan, archive, and index reconciliation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Reset Default") {
                    path = SessionStore.defaultCodexRootPath()
                }
                Spacer()
                Button("Cancel") {
                    closeSettingsWindow()
                }
                Button("Save") {
                    onSave(path)
                    closeSettingsWindow()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    private func closeSettingsWindow() {
        NSApplication.shared.keyWindow?.close()
    }
}
