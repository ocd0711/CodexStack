import Foundation

struct UsageMetricsService {
    private let fileManager = FileManager.default
    private let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // Estimated token budgets for utilization bars.
    private let sessionTokenBudget: Double = 18_000_000
    private let weeklyTokenBudget: Double = 120_000_000

    // Approximate model pricing (USD per 1M tokens).
    private let pricingByModel: [String: (input: Double, cachedInput: Double, output: Double)] = [
        "gpt-5.5": (input: 1.25, cachedInput: 0.125, output: 10.0),
        "gpt-5.4": (input: 1.25, cachedInput: 0.125, output: 10.0),
        "gpt-5.3-codex": (input: 1.25, cachedInput: 0.125, output: 10.0),
        "gpt-5.2": (input: 1.25, cachedInput: 0.125, output: 10.0)
    ]

    func loadUsageSnapshot(codexRoot: URL) -> UsageSnapshot {
        let now = Date()
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let sessionWindowStart = now.addingTimeInterval(-5 * 60 * 60)
        let weekWindowStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let todayStart = Calendar.current.startOfDay(for: now)

        let roots = [codexRoot.appending(path: "sessions"), codexRoot.appending(path: "archived_sessions")]
        let files = collectSessionFiles(roots: roots)
        if files.isEmpty {
            return .empty
        }

        var todayTokens: Int64 = 0
        var last30Tokens: Int64 = 0
        var sessionTokens: Int64 = 0
        var weeklyTokens: Int64 = 0
        var todayCost: Double = 0
        var last30Cost: Double = 0
        var latestTimestamp: Date?

        for fileURL in files {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            var currentModel = "gpt-5.5"
            var prevInput = 0
            var prevCachedInput = 0
            var prevOutput = 0
            var prevTotal = 0

            content.enumerateLines { line, _ in
                guard let data = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return
                }

                if let model = parseModelFromTurnContext(root), !model.isEmpty {
                    currentModel = model
                }

                guard let timestamp = parseTimestamp(root),
                      let usage = parseTotalUsage(root) else {
                    return
                }

                latestTimestamp = maxDate(latestTimestamp, timestamp)

                let deltaInput = max(0, usage.input - prevInput)
                let deltaCachedInput = max(0, usage.cachedInput - prevCachedInput)
                let deltaOutput = max(0, usage.output - prevOutput)
                let deltaTotal = max(0, usage.total - prevTotal)

                prevInput = usage.input
                prevCachedInput = usage.cachedInput
                prevOutput = usage.output
                prevTotal = usage.total

                guard deltaTotal > 0 else { return }
                guard timestamp >= thirtyDaysAgo else { return }

                last30Tokens += Int64(deltaTotal)
                let eventCost = estimateCost(
                    model: currentModel,
                    deltaInput: deltaInput,
                    deltaCachedInput: deltaCachedInput,
                    deltaOutput: deltaOutput
                )
                last30Cost += eventCost

                if timestamp >= todayStart {
                    todayTokens += Int64(deltaTotal)
                    todayCost += eventCost
                }
                if timestamp >= sessionWindowStart {
                    sessionTokens += Int64(deltaTotal)
                }
                if timestamp >= weekWindowStart {
                    weeklyTokens += Int64(deltaTotal)
                }
            }
        }

        let sessionRatio = min(1, max(0, Double(sessionTokens) / sessionTokenBudget))
        let weeklyRatio = min(1, max(0, Double(weeklyTokens) / weeklyTokenBudget))
        let sessionReset = Calendar.current.date(byAdding: .hour, value: 5, to: now)
        let weeklyReset = Calendar.current.date(byAdding: .day, value: 7, to: now)

        return UsageSnapshot(
            updatedAt: latestTimestamp,
            sessionUsedRatio: sessionRatio,
            weeklyUsedRatio: weeklyRatio,
            sessionResetAt: sessionReset,
            weeklyResetAt: weeklyReset,
            todayTokens: todayTokens,
            last30DaysTokens: last30Tokens,
            todayCostUSD: todayCost,
            last30DaysCostUSD: last30Cost
        )
    }

    private func collectSessionFiles(roots: [URL]) -> [URL] {
        var files: [URL] = []
        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "jsonl" {
                    files.append(fileURL)
                }
            }
        }
        return files
    }

    private func parseModelFromTurnContext(_ root: [String: Any]) -> String? {
        guard (root["type"] as? String) == "turn_context",
              let payload = root["payload"] as? [String: Any],
              let model = payload["model"] as? String else {
            return nil
        }
        return model
    }

    private func parseTotalUsage(_ root: [String: Any]) -> (input: Int, cachedInput: Int, output: Int, total: Int)? {
        guard (root["type"] as? String) == "event_msg",
              let payload = root["payload"] as? [String: Any],
              (payload["type"] as? String) == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else {
            return nil
        }

        let input = total["input_tokens"] as? Int ?? 0
        let cached = total["cached_input_tokens"] as? Int ?? 0
        let output = total["output_tokens"] as? Int ?? 0
        let all = total["total_tokens"] as? Int ?? (input + output)
        return (input, cached, output, all)
    }

    private func parseTimestamp(_ root: [String: Any]) -> Date? {
        guard let ts = root["timestamp"] as? String else { return nil }
        if let date = fractionalFormatter.date(from: ts) {
            return date
        }
        return ISO8601DateFormatter().date(from: ts)
    }

    private func estimateCost(model: String, deltaInput: Int, deltaCachedInput: Int, deltaOutput: Int) -> Double {
        let pricing = pricingByModel[model] ?? pricingByModel["gpt-5.5"]!
        let inCost = Double(deltaInput) / 1_000_000 * pricing.input
        let cachedCost = Double(deltaCachedInput) / 1_000_000 * pricing.cachedInput
        let outCost = Double(deltaOutput) / 1_000_000 * pricing.output
        return inCost + cachedCost + outCost
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return lhs > rhs ? lhs : rhs
    }
}
