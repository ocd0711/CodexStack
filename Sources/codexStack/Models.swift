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

    var projectName: String {
        guard let projectPath, !projectPath.isEmpty else { return "Chats" }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
    }
}
