import Foundation

enum SessionScope: String, CaseIterable, Identifiable, Sendable {
    case active = "Active"
    case archived = "Archived"
    case all = "All"

    var id: String { rawValue }
}

enum SessionMessageRole: String, Hashable, Sendable {
    case user = "User"
    case assistant = "Assistant"
    case system = "System"
}

struct UsageSnapshot: Sendable {
    var updatedAt: Date?
    var accountEmail: String?
    var accountName: String?
    var planType: String?
    var source: UsageSource
    var sessionUsedRatio: Double?
    var weeklyUsedRatio: Double?
    var sessionResetAt: Date?
    var weeklyResetAt: Date?
    var todayTokens: Int64
    var last30DaysTokens: Int64
    var todayCostUSD: Double
    var last30DaysCostUSD: Double
    var dailyCostSeries: [UsageDailyCost]

    static let empty = UsageSnapshot(
        updatedAt: nil,
        accountEmail: nil,
        accountName: nil,
        planType: nil,
        source: .unavailable,
        sessionUsedRatio: nil,
        weeklyUsedRatio: nil,
        sessionResetAt: nil,
        weeklyResetAt: nil,
        todayTokens: 0,
        last30DaysTokens: 0,
        todayCostUSD: 0,
        last30DaysCostUSD: 0,
        dailyCostSeries: []
    )
}

struct UsageDailyCost: Identifiable, Sendable {
    let dayStart: Date
    let tokens: Int64
    let costUSD: Double
    let modelBreakdowns: [UsageDailyModelBreakdown]

    var id: TimeInterval { dayStart.timeIntervalSince1970 }
}

struct UsageDailyModelBreakdown: Identifiable, Sendable {
    let modelName: String
    let tokens: Int64
    let costUSD: Double

    var id: String { modelName }
}

enum UsageSource: String, Sendable {
    case live
    case cached
    case unavailable

    var label: String {
        switch self {
        case .live:
            return "Live"
        case .cached:
            return "Cached"
        case .unavailable:
            return "Unavailable"
        }
    }
}

enum UtilizationProgressMode: String, CaseIterable, Identifiable, Sendable {
    case used
    case remaining

    var id: String { rawValue }

    var label: String {
        switch self {
        case .used:
            return NSLocalizedString("Used", bundle: .module, comment: "")
        case .remaining:
            return NSLocalizedString("Remaining", bundle: .module, comment: "")
        }
    }
}

enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case seconds30 = 30
    case minute1 = 60
    case minute5 = 300
    case minute15 = 900

    var id: Int { rawValue }

    var seconds: TimeInterval? {
        rawValue > 0 ? TimeInterval(rawValue) : nil
    }

    var label: String {
        switch self {
        case .off:
            return NSLocalizedString("Off", bundle: .module, comment: "")
        case .seconds30:
            return NSLocalizedString("Every 30 seconds", bundle: .module, comment: "")
        case .minute1:
            return NSLocalizedString("Every 1 minute", bundle: .module, comment: "")
        case .minute5:
            return NSLocalizedString("Every 5 minutes", bundle: .module, comment: "")
        case .minute15:
            return NSLocalizedString("Every 15 minutes", bundle: .module, comment: "")
        }
    }
}

struct SessionMessage: Identifiable, Hashable, Sendable {
    let id = UUID()
    let role: SessionMessageRole
    let text: String
    let timestamp: Date?
}

struct CodexSession: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let updatedAt: Date
    let fileURL: URL
    let isArchived: Bool
    let sizeInBytes: Int64
    let projectPath: String?

    var projectID: String {
        guard let projectPath, !projectPath.isEmpty else { return "chats" }
        return projectPath
    }

    var isChatsProject: Bool {
        projectPath == nil || projectPath?.isEmpty == true
    }

    var projectName: String {
        guard let projectPath, !projectPath.isEmpty else { return "Chats" }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
    }
}

struct CodexProject: Identifiable, Hashable, Sendable {
    let path: String

    var id: String { path }

    var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

struct ProjectMoveTarget: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String?

    static let chats = ProjectMoveTarget(name: "Chats", path: nil)

    init(name: String, path: String?) {
        self.name = name
        self.path = path
        self.id = path ?? "chats"
    }
}
