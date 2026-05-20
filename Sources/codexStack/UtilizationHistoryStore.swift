import Foundation

enum UtilizationSeriesName: String, Codable, Hashable {
    case session
    case weekly

    var windowMinutes: Int {
        switch self {
        case .session: return 300
        case .weekly: return 10080
        }
    }

    var title: String {
        switch self {
        case .session: return "Session"
        case .weekly: return "Weekly"
        }
    }
}

struct UtilizationHistoryEntry: Codable, Equatable {
    let capturedAt: Date
    let usedPercent: Double
    let resetsAt: Date?
}

struct UtilizationSeriesHistory: Codable, Equatable {
    let name: UtilizationSeriesName
    let entries: [UtilizationHistoryEntry]

    var windowMinutes: Int { name.windowMinutes }

    init(name: UtilizationSeriesName, entries: [UtilizationHistoryEntry]) {
        self.name = name
        self.entries = entries.sorted { $0.capturedAt < $1.capturedAt }
    }
}

struct UtilizationHistoryStore {
    private static let maxEntriesPerSeries = 600

    private let fileURL: URL?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        self.fileURL = appSupport?
            .appendingPathComponent("codexStack")
            .appendingPathComponent("utilization_history.json")
    }

    func load() -> [String: [UtilizationSeriesHistory]] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: [UtilizationSeriesHistory]].self, from: data)) ?? [:]
    }

    func save(_ histories: [String: [UtilizationSeriesHistory]]) {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(histories) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    static func record(
        accounts: [UsageAccountSnapshot],
        into histories: inout [String: [UtilizationSeriesHistory]]
    ) {
        let now = Date()
        for account in accounts {
            let key = account.id
            var seriesMap: [UtilizationSeriesName: UtilizationSeriesHistory] = [:]
            for s in histories[key] ?? [] {
                seriesMap[s.name] = s
            }
            appendEntry(
                to: &seriesMap, name: .session,
                ratio: account.sessionUsedRatio, resetsAt: account.sessionResetAt, at: now)
            appendEntry(
                to: &seriesMap, name: .weekly,
                ratio: account.weeklyUsedRatio, resetsAt: account.weeklyResetAt, at: now)
            let updated = Array(seriesMap.values).filter { !$0.entries.isEmpty }
            if !updated.isEmpty {
                histories[key] = updated
            }
        }
    }

    private static func appendEntry(
        to seriesMap: inout [UtilizationSeriesName: UtilizationSeriesHistory],
        name: UtilizationSeriesName,
        ratio: Double?,
        resetsAt: Date?,
        at now: Date
    ) {
        guard let ratio else { return }
        let percent = max(0, min(100, ratio * 100))
        let newEntry = UtilizationHistoryEntry(capturedAt: now, usedPercent: percent, resetsAt: resetsAt)
        let existing = seriesMap[name]?.entries ?? []
        let trimmed = Array((existing + [newEntry]).suffix(maxEntriesPerSeries))
        seriesMap[name] = UtilizationSeriesHistory(name: name, entries: trimmed)
    }
}
