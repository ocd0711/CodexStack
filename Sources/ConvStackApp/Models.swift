import Foundation

enum SessionScope: String, CaseIterable, Identifiable {
    case active = "Active"
    case archived = "Archived"
    case all = "All"

    var id: String { rawValue }
}

enum SessionMessageRole: String, Hashable {
    case user = "User"
    case assistant = "Assistant"
    case system = "System"
}

struct SessionMessage: Identifiable, Hashable {
    let id = UUID()
    let role: SessionMessageRole
    let text: String
    let timestamp: Date?
}

struct CodexSession: Identifiable, Hashable {
    let id: String
    let title: String
    let updatedAt: Date
    let fileURL: URL
    let isArchived: Bool
    let sizeInBytes: Int64
    let projectPath: String?

    var projectName: String {
        guard let projectPath, !projectPath.isEmpty else { return "Unknown" }
        if isChatWorkspace(projectPath) {
            return "Chats"
        }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
    }

    private func isChatWorkspace(_ path: String) -> Bool {
        let normalized = path.lowercased()
        let codexDocsPrefix = "/users/\(NSUserName().lowercased())/documents/codex/"
        if normalized.hasPrefix(codexDocsPrefix) {
            return true
        }
        return normalized.contains("/documents/codex/")
    }
}
