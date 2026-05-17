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
            MenuBarContent(
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
        .menuBarExtraStyle(.menu)
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

private struct MenuBarContent: View {
    @EnvironmentObject private var store: SessionStore
    let onOpenSettings: () -> Void

    private let maxProjectsInMenu = 12
    private let maxSessionsPerProject = 12

    var body: some View {
        Button("Open Manager") {
            ManagerWindowController.shared.show(with: store)
        }

        Button("Refresh Sessions") {
            store.refresh()
        }

        Button("Settings...") {
            onOpenSettings()
        }

        Divider()

        if store.sessions.isEmpty {
            Text("No sessions found")
                .foregroundStyle(.secondary)
        } else {
            ForEach(groupedProjects()) { project in
                Menu(project.title) {
                    Button("Move Entire Project to Trash", role: .destructive) {
                        store.trashProject(named: project.projectName)
                    }
                    Divider()

                    ForEach(project.sessions.prefix(maxSessionsPerProject)) { session in
                        Menu(shortTitle(for: session.title)) {
                            Text(session.id)
                            Text(session.isArchived ? "Archived" : "Active")
                            Divider()
                            if session.isArchived {
                                Button("Unarchive") {
                                    store.selectedIDs = [session.id]
                                    store.unarchiveSelected()
                                }
                            } else {
                                Button("Archive") {
                                    store.selectedIDs = [session.id]
                                    store.archiveSelected()
                                }
                            }
                            Button("Move to Trash", role: .destructive) {
                                store.selectedIDs = [session.id]
                                store.trashSelected()
                            }
                        }
                    }

                    if project.sessions.count > maxSessionsPerProject {
                        Divider()
                        Text("... \(project.sessions.count - maxSessionsPerProject) more")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        Divider()
        Button("Quit ConvStack") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
        .onAppear {
            if store.sessions.isEmpty {
                store.refresh()
            }
        }
    }

    private func shortTitle(for title: String) -> String {
        if title.count <= 48 { return title }
        let end = title.index(title.startIndex, offsetBy: 45)
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
