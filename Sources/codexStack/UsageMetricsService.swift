import Foundation

struct UsageMetricsService {
    private let fileManager = FileManager.default
    private let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let pricingByModel: [String: CodexModelPricing] = [
        "gpt-5": .init(inputPerToken: 1.25e-6, cachedInputPerToken: 1.25e-7, outputPerToken: 1e-5),
        "gpt-5-codex": .init(inputPerToken: 1.25e-6, cachedInputPerToken: 1.25e-7, outputPerToken: 1e-5),
        "gpt-5-mini": .init(inputPerToken: 2.5e-7, cachedInputPerToken: 2.5e-8, outputPerToken: 2e-6),
        "gpt-5-nano": .init(inputPerToken: 5e-8, cachedInputPerToken: 5e-9, outputPerToken: 4e-7),
        "gpt-5-pro": .init(inputPerToken: 1.5e-5, cachedInputPerToken: 1.5e-5, outputPerToken: 1.2e-4),
        "gpt-5.1": .init(inputPerToken: 1.25e-6, cachedInputPerToken: 1.25e-7, outputPerToken: 1e-5),
        "gpt-5.1-codex": .init(inputPerToken: 1.25e-6, cachedInputPerToken: 1.25e-7, outputPerToken: 1e-5),
        "gpt-5.1-codex-max": .init(inputPerToken: 1.25e-6, cachedInputPerToken: 1.25e-7, outputPerToken: 1e-5),
        "gpt-5.1-codex-mini": .init(inputPerToken: 2.5e-7, cachedInputPerToken: 2.5e-8, outputPerToken: 2e-6),
        "gpt-5.2": .init(inputPerToken: 1.75e-6, cachedInputPerToken: 1.75e-7, outputPerToken: 1.4e-5),
        "gpt-5.2-codex": .init(inputPerToken: 1.75e-6, cachedInputPerToken: 1.75e-7, outputPerToken: 1.4e-5),
        "gpt-5.2-pro": .init(inputPerToken: 2.1e-5, cachedInputPerToken: 2.1e-5, outputPerToken: 1.68e-4),
        "gpt-5.3-codex": .init(inputPerToken: 1.75e-6, cachedInputPerToken: 1.75e-7, outputPerToken: 1.4e-5),
        "gpt-5.4": .init(
            inputPerToken: 2.5e-6,
            cachedInputPerToken: 2.5e-7,
            outputPerToken: 1.5e-5,
            longContextThreshold: 272_000,
            inputPerTokenAboveThreshold: 5e-6,
            cachedInputPerTokenAboveThreshold: 5e-7,
            outputPerTokenAboveThreshold: 2.25e-5
        ),
        "gpt-5.4-mini": .init(inputPerToken: 7.5e-7, cachedInputPerToken: 7.5e-8, outputPerToken: 4.5e-6),
        "gpt-5.4-nano": .init(inputPerToken: 2e-7, cachedInputPerToken: 2e-8, outputPerToken: 1.25e-6),
        "gpt-5.4-pro": .init(inputPerToken: 3e-5, cachedInputPerToken: 3e-5, outputPerToken: 1.8e-4),
        "gpt-5.5": .init(
            inputPerToken: 5e-6,
            cachedInputPerToken: 5e-7,
            outputPerToken: 3e-5,
            longContextThreshold: 272_000,
            inputPerTokenAboveThreshold: 1e-5,
            cachedInputPerTokenAboveThreshold: 1e-6,
            outputPerTokenAboveThreshold: 4.5e-5
        ),
        "gpt-5.5-pro": .init(inputPerToken: 3e-5, cachedInputPerToken: 3e-5, outputPerToken: 1.8e-4)
    ]

    func loadUsageSnapshot(codexRoot: URL) -> UsageSnapshot {
        let liveUsage = loadUsageFromOAuthAPI(codexRoot: codexRoot)
        let cachedUsage = loadUsageFromRegistry(codexRoot: codexRoot)
        let selectedUsage = mergedUsage(live: liveUsage, cached: cachedUsage)

        let now = Date()
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let todayStart = Calendar.current.startOfDay(for: now)

        let roots = [codexRoot.appending(path: "sessions"), codexRoot.appending(path: "archived_sessions")]
        let files = collectSessionFiles(roots: roots)

        var todayTokens: Int64 = 0
        var last30Tokens: Int64 = 0
        var todayCost: Double = 0
        var last30Cost: Double = 0
        var latestTimestamp = selectedUsage?.updatedAt
        var dailyBuckets: [Date: DayBucket] = [:]

        for fileURL in files {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            var currentModel = "gpt-5.5"
            var previousTotals: CodexTotals?
            var rawTotalsBaseline: CodexTotals?
            var sawDivergentTotals = false

            content.enumerateLines { line, _ in
                guard let data = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return
                }

                if let model = parseModelFromTurnContext(root), !model.isEmpty {
                    currentModel = model
                }

                guard let timestamp = parseTimestamp(root),
                      let event = parseTokenEvent(root) else {
                    return
                }
                let eventModel = normalizeModelName(event.model ?? currentModel)

                latestTimestamp = maxDate(latestTimestamp, timestamp)

                let deltas: CodexTotals
                if let last = event.lastTotals {
                    deltas = last
                    let counted = (previousTotals ?? .zero).adding(last)
                    previousTotals = counted
                    if let total = event.totalTotals {
                        rawTotalsBaseline = total
                        if total != counted {
                            sawDivergentTotals = true
                        }
                    } else {
                        rawTotalsBaseline = counted
                    }
                } else if let total = event.totalTotals {
                    if sawDivergentTotals {
                        deltas = divergentTotalDelta(
                            rawBaseline: rawTotalsBaseline,
                            countedBaseline: previousTotals,
                            current: total
                        )
                    } else {
                        deltas = totalDelta(from: rawTotalsBaseline, to: total)
                    }
                    previousTotals = (previousTotals ?? .zero).adding(deltas)
                    rawTotalsBaseline = total
                    if rawTotalsBaseline != previousTotals {
                        sawDivergentTotals = true
                    }
                } else {
                    return
                }

                let deltaInput = max(0, deltas.input)
                let deltaCachedInput = min(deltaInput, max(0, deltas.cachedInput))
                let deltaOutput = max(0, deltas.output)
                let deltaTotal = deltaInput + deltaOutput

                guard deltaTotal > 0 else { return }
                guard timestamp >= thirtyDaysAgo else { return }

                last30Tokens += Int64(deltaTotal)
                let eventCost = estimateCost(
                    model: eventModel,
                    deltaInput: deltaInput,
                    deltaCachedInput: deltaCachedInput,
                    deltaOutput: deltaOutput
                )
                last30Cost += eventCost

                let day = Calendar.current.startOfDay(for: timestamp)
                var bucket = dailyBuckets[day] ?? DayBucket.empty
                bucket.tokens += Int64(deltaTotal)
                bucket.cost += eventCost
                var modelBucket = bucket.models[eventModel] ?? ModelBucket.empty
                modelBucket.tokens += Int64(deltaTotal)
                modelBucket.cost += eventCost
                bucket.models[eventModel] = modelBucket
                dailyBuckets[day] = bucket

                if timestamp >= todayStart {
                    todayTokens += Int64(deltaTotal)
                    todayCost += eventCost
                }
            }
        }

        let dailySeries = recentSevenDaySeries(from: dailyBuckets, todayStart: todayStart)

        return UsageSnapshot(
            updatedAt: latestTimestamp,
            accountEmail: selectedUsage?.accountEmail,
            accountName: selectedUsage?.accountName,
            planType: selectedUsage?.planType,
            source: selectedUsage?.source ?? .unavailable,
            sessionUsedRatio: selectedUsage?.primaryUsedRatio,
            weeklyUsedRatio: selectedUsage?.secondaryUsedRatio,
            sessionResetAt: selectedUsage?.primaryResetAt,
            weeklyResetAt: selectedUsage?.secondaryResetAt,
            todayTokens: todayTokens,
            last30DaysTokens: last30Tokens,
            todayCostUSD: todayCost,
            last30DaysCostUSD: last30Cost,
            dailyCostSeries: dailySeries
        )
    }

    private func recentSevenDaySeries(
        from buckets: [Date: DayBucket],
        todayStart: Date
    ) -> [UsageDailyCost] {
        var series: [UsageDailyCost] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            let bucket = buckets[day] ?? .empty
            let breakdowns = bucket.models.map { key, value in
                UsageDailyModelBreakdown(modelName: key, tokens: value.tokens, costUSD: value.cost)
            }
            .sorted {
                if $0.costUSD != $1.costUSD { return $0.costUSD > $1.costUSD }
                return $0.tokens > $1.tokens
            }
            series.append(
                UsageDailyCost(
                    dayStart: day,
                    tokens: bucket.tokens,
                    costUSD: bucket.cost,
                    modelBreakdowns: breakdowns
                )
            )
        }
        return series
    }

    private func mergedUsage(live: AccountUsageProfile?, cached: AccountUsageProfile?) -> AccountUsageProfile? {
        guard live != nil || cached != nil else { return nil }

        let liveHasUsageWindows = live?.primaryUsedRatio != nil || live?.secondaryUsedRatio != nil
        let source: UsageSource = liveHasUsageWindows ? .live : (cached != nil ? .cached : .unavailable)

        return AccountUsageProfile(
            source: source,
            accountEmail: live?.accountEmail ?? cached?.accountEmail,
            accountName: live?.accountName ?? cached?.accountName,
            planType: live?.planType ?? cached?.planType,
            primaryUsedRatio: live?.primaryUsedRatio ?? cached?.primaryUsedRatio,
            secondaryUsedRatio: live?.secondaryUsedRatio ?? cached?.secondaryUsedRatio,
            primaryResetAt: live?.primaryResetAt ?? cached?.primaryResetAt,
            secondaryResetAt: live?.secondaryResetAt ?? cached?.secondaryResetAt,
            updatedAt: source == .live ? (live?.updatedAt ?? Date()) : cached?.updatedAt
        )
    }

    private func loadUsageFromOAuthAPI(codexRoot: URL) -> AccountUsageProfile? {
        guard let credentials = loadOAuthCredentials(codexRoot: codexRoot) else { return nil }
        guard let usageURL = resolveUsageURL(codexRoot: codexRoot) else { return nil }
        guard let response = fetchCodexUsage(usageURL: usageURL, credentials: credentials) else { return nil }

        let jwtPayload = credentials.idToken.flatMap(parseJWT)
        let authProfile = jwtPayload?["https://api.openai.com/profile"] as? [String: Any]
        let authDetails = jwtPayload?["https://api.openai.com/auth"] as? [String: Any]

        let primaryWindow = response.rateLimit?.primaryWindow
        let secondaryWindow = response.rateLimit?.secondaryWindow

        let profile = AccountUsageProfile(
            source: .live,
            accountEmail: normalizedString(
                authProfile?["email"] as? String
                    ?? jwtPayload?["email"] as? String
            ),
            accountName: nil,
            planType: normalizedString(
                response.planType
                    ?? authDetails?["chatgpt_plan_type"] as? String
                    ?? jwtPayload?["chatgpt_plan_type"] as? String
            ),
            primaryUsedRatio: primaryWindow.map { clampPercent(Double($0.usedPercent)) / 100 },
            secondaryUsedRatio: secondaryWindow.map { clampPercent(Double($0.usedPercent)) / 100 },
            primaryResetAt: primaryWindow.map { Date(timeIntervalSince1970: TimeInterval($0.resetAt)) },
            secondaryResetAt: secondaryWindow.map { Date(timeIntervalSince1970: TimeInterval($0.resetAt)) },
            updatedAt: Date()
        )

        if profile.accountEmail == nil &&
            profile.planType == nil &&
            profile.primaryUsedRatio == nil &&
            profile.secondaryUsedRatio == nil {
            return nil
        }
        return profile
    }

    private func resolveUsageURL(codexRoot: URL) -> URL? {
        let configURL = codexRoot.appending(path: "config.toml")
        let configContents = try? String(contentsOf: configURL, encoding: .utf8)
        let base = parseChatGPTBaseURL(from: configContents) ?? "https://chatgpt.com/backend-api/"
        let normalized = normalizeChatGPTBaseURL(base)
        let path = normalized.contains("/backend-api") ? "/wham/usage" : "/api/codex/usage"
        return URL(string: normalized + path)
    }

    private func normalizeChatGPTBaseURL(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            trimmed = "https://chatgpt.com/backend-api/"
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if (trimmed.hasPrefix("https://chatgpt.com") || trimmed.hasPrefix("https://chat.openai.com")) &&
            !trimmed.contains("/backend-api") {
            trimmed += "/backend-api"
        }
        return trimmed
    }

    private func parseChatGPTBaseURL(from configContents: String?) -> String? {
        guard let configContents else { return nil }
        for rawLine in configContents.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first
            let trimmed = line?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "chatgpt_base_url" else { continue }

            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func fetchCodexUsage(usageURL: URL, credentials: OAuthCredentials) -> CodexUsageAPIResponse? {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.5
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codexStack", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let accountId = credentials.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 2.5
        let session = URLSession(configuration: config)

        let semaphore = DispatchSemaphore(value: 0)
        var decoded: CodexUsageAPIResponse?
        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let data else {
                return
            }
            decoded = try? JSONDecoder().decode(CodexUsageAPIResponse.self, from: data)
        }
        task.resume()

        let waitResult = semaphore.wait(timeout: .now() + 2.8)
        if waitResult == .timedOut {
            task.cancel()
            return nil
        }
        return decoded
    }

    private func loadOAuthCredentials(codexRoot: URL) -> OAuthCredentials? {
        let authURL = codexRoot.appending(path: "auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let apiKey = normalizedString(root["OPENAI_API_KEY"] as? String) {
            return OAuthCredentials(accessToken: apiKey, idToken: nil, accountId: nil)
        }

        guard let tokens = root["tokens"] as? [String: Any],
              let accessToken = normalizedString(
                  tokens["access_token"] as? String
                      ?? tokens["accessToken"] as? String
              ) else {
            return nil
        }

        return OAuthCredentials(
            accessToken: accessToken,
            idToken: normalizedString(tokens["id_token"] as? String ?? tokens["idToken"] as? String),
            accountId: normalizedString(tokens["account_id"] as? String ?? tokens["accountId"] as? String)
        )
    }

    private func loadUsageFromRegistry(codexRoot: URL) -> AccountUsageProfile? {
        let registryURL = codexRoot.appending(path: "accounts").appending(path: "registry.json")
        guard let data = try? Data(contentsOf: registryURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let activeKey = root["active_account_key"] as? String
        guard let accounts = root["accounts"] as? [[String: Any]], !accounts.isEmpty else {
            return nil
        }

        let active = accounts.first { ($0["account_key"] as? String) == activeKey } ?? accounts.first
        guard let active else { return nil }

        let usage = active["last_usage"] as? [String: Any]
        let primary = usage?["primary"] as? [String: Any]
        let secondary = usage?["secondary"] as? [String: Any]

        let primaryUsed = doubleValue(forKeys: ["used_percent", "usedPercent"], in: primary)
        let secondaryUsed = doubleValue(forKeys: ["used_percent", "usedPercent"], in: secondary)

        return AccountUsageProfile(
            source: .cached,
            accountEmail: stringValue(forKeys: ["email"], in: active),
            accountName: stringValue(forKeys: ["account_name", "accountName", "alias"], in: active),
            planType: stringValue(forKeys: ["plan"], in: active)
                ?? stringValue(forKeys: ["plan_type", "planType"], in: usage),
            primaryUsedRatio: primaryUsed.map { clampPercent($0) / 100 },
            secondaryUsedRatio: secondaryUsed.map { clampPercent($0) / 100 },
            primaryResetAt: unixDate(primary?["resets_at"] ?? primary?["resetsAt"]),
            secondaryResetAt: unixDate(secondary?["resets_at"] ?? secondary?["resetsAt"]),
            updatedAt: unixDate(active["last_usage_at"] ?? active["lastUsageAt"])
        )
    }

    private func parseJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var padded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 {
            padded.append("=")
        }

        guard let data = Data(base64Encoded: padded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func collectSessionFiles(roots: [URL]) -> [URL] {
        var files: [URL] = []
        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                files.append(fileURL)
            }
        }
        return files
    }

    private func parseModelFromTurnContext(_ root: [String: Any]) -> String? {
        guard (root["type"] as? String) == "turn_context",
              let payload = root["payload"] as? [String: Any] else {
            return nil
        }
        if let model = payload["model"] as? String, !model.isEmpty {
            return model
        }
        if let info = payload["info"] as? [String: Any],
           let model = info["model"] as? String,
           !model.isEmpty {
            return model
        }
        return nil
    }

    private func parseTokenEvent(_ root: [String: Any]) -> TokenEvent? {
        guard (root["type"] as? String) == "event_msg",
              let payload = root["payload"] as? [String: Any],
              (payload["type"] as? String) == "token_count",
              let info = payload["info"] as? [String: Any] else {
            return nil
        }

        let model = normalizedString(
            (info["model"] as? String)
                ?? (info["model_name"] as? String)
                ?? (payload["model"] as? String)
                ?? (root["model"] as? String)
        )
        let total = parseCodexTotals(info["total_token_usage"])
        let last = parseCodexTotals(info["last_token_usage"])
        guard total != nil || last != nil else { return nil }
        return TokenEvent(model: model, totalTotals: total, lastTotals: last)
    }

    private func parseCodexTotals(_ value: Any?) -> CodexTotals? {
        guard let dict = value as? [String: Any] else { return nil }
        let input = max(0, intFromAny(dict["input_tokens"]) ?? 0)
        let cached = max(
            0,
            intFromAny(dict["cached_input_tokens"] ?? dict["cache_read_input_tokens"]) ?? 0
        )
        let output = max(0, intFromAny(dict["output_tokens"]) ?? 0)
        return CodexTotals(input: input, cachedInput: cached, output: output)
    }

    private func totalDelta(from baseline: CodexTotals?, to current: CodexTotals) -> CodexTotals {
        let baseline = baseline ?? .zero
        return CodexTotals(
            input: max(0, current.input - baseline.input),
            cachedInput: max(0, current.cachedInput - baseline.cachedInput),
            output: max(0, current.output - baseline.output)
        )
    }

    private func divergentTotalDelta(
        rawBaseline: CodexTotals?,
        countedBaseline: CodexTotals?,
        current: CodexTotals
    ) -> CodexTotals {
        let raw = rawBaseline ?? .zero
        let counted = countedBaseline ?? .zero

        func delta(rawValue: Int, countedValue: Int, currentValue: Int) -> Int {
            if currentValue >= rawValue {
                return max(0, currentValue - rawValue)
            }
            return max(0, currentValue - countedValue)
        }

        return CodexTotals(
            input: delta(rawValue: raw.input, countedValue: counted.input, currentValue: current.input),
            cachedInput: delta(
                rawValue: raw.cachedInput,
                countedValue: counted.cachedInput,
                currentValue: current.cachedInput
            ),
            output: delta(rawValue: raw.output, countedValue: counted.output, currentValue: current.output)
        )
    }

    private func normalizeModelName(_ value: String) -> String {
        var model = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.hasPrefix("openai/") {
            model = String(model.dropFirst("openai/".count))
        }
        if pricingByModel[model] != nil {
            return model
        }
        if let range = model.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(model[..<range.lowerBound])
            if pricingByModel[base] != nil {
                return base
            }
        }
        return model
    }

    private func parseTimestamp(_ root: [String: Any]) -> Date? {
        guard let ts = root["timestamp"] as? String else { return nil }
        if let date = fractionalFormatter.date(from: ts) {
            return date
        }
        return ISO8601DateFormatter().date(from: ts)
    }

    private func estimateCost(model: String, deltaInput: Int, deltaCachedInput: Int, deltaOutput: Int) -> Double {
        let normalized = normalizeModelName(model)
        let pricing = pricingByModel[normalized] ?? pricingByModel["gpt-5.5"]!
        let cached = min(max(0, deltaCachedInput), max(0, deltaInput))
        let nonCached = max(0, deltaInput - cached)

        let useAboveThreshold = pricing.longContextThreshold.map { max(0, deltaInput) > $0 } ?? false
        let inputRate = useAboveThreshold ? (pricing.inputPerTokenAboveThreshold ?? pricing.inputPerToken) : pricing.inputPerToken
        let cachedRate = useAboveThreshold
            ? (pricing.cachedInputPerTokenAboveThreshold ?? pricing.cachedInputPerToken)
            : pricing.cachedInputPerToken
        let outputRate = useAboveThreshold
            ? (pricing.outputPerTokenAboveThreshold ?? pricing.outputPerToken)
            : pricing.outputPerToken

        let inCost = Double(nonCached) * inputRate
        let cachedCost = Double(cached) * cachedRate
        let outCost = Double(max(0, deltaOutput)) * outputRate
        return inCost + cachedCost + outCost
    }

    private func stringValue(forKeys keys: [String], in dictionary: [String: Any]?) -> String? {
        guard let dictionary else { return nil }
        for key in keys {
            if let value = normalizedString(dictionary[key] as? String) {
                return value
            }
        }
        return nil
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func intFromAny(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String, let intValue = Int(value) { return intValue }
        return nil
    }

    private func doubleValue(forKeys keys: [String], in dictionary: [String: Any]?) -> Double? {
        guard let dictionary else { return nil }
        for key in keys {
            if let value = dictionary[key] as? Double { return value }
            if let value = dictionary[key] as? Int { return Double(value) }
            if let value = dictionary[key] as? NSNumber { return value.doubleValue }
            if let value = dictionary[key] as? String, let doubleValue = Double(value) {
                return doubleValue
            }
        }
        return nil
    }

    private func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private func unixDate(_ value: Any?) -> Date? {
        if let intValue = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(intValue))
        }
        if let doubleValue = value as? Double {
            return Date(timeIntervalSince1970: doubleValue)
        }
        if let stringValue = value as? String, let doubleValue = Double(stringValue) {
            return Date(timeIntervalSince1970: doubleValue)
        }
        return nil
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return lhs > rhs ? lhs : rhs
    }
}

private struct CodexModelPricing {
    let inputPerToken: Double
    let cachedInputPerToken: Double
    let outputPerToken: Double
    let longContextThreshold: Int?
    let inputPerTokenAboveThreshold: Double?
    let cachedInputPerTokenAboveThreshold: Double?
    let outputPerTokenAboveThreshold: Double?

    init(
        inputPerToken: Double,
        cachedInputPerToken: Double,
        outputPerToken: Double,
        longContextThreshold: Int? = nil,
        inputPerTokenAboveThreshold: Double? = nil,
        cachedInputPerTokenAboveThreshold: Double? = nil,
        outputPerTokenAboveThreshold: Double? = nil
    ) {
        self.inputPerToken = inputPerToken
        self.cachedInputPerToken = cachedInputPerToken
        self.outputPerToken = outputPerToken
        self.longContextThreshold = longContextThreshold
        self.inputPerTokenAboveThreshold = inputPerTokenAboveThreshold
        self.cachedInputPerTokenAboveThreshold = cachedInputPerTokenAboveThreshold
        self.outputPerTokenAboveThreshold = outputPerTokenAboveThreshold
    }
}

private struct CodexTotals: Equatable {
    let input: Int
    let cachedInput: Int
    let output: Int

    static let zero = CodexTotals(input: 0, cachedInput: 0, output: 0)

    func adding(_ rhs: CodexTotals) -> CodexTotals {
        CodexTotals(
            input: self.input + rhs.input,
            cachedInput: self.cachedInput + rhs.cachedInput,
            output: self.output + rhs.output
        )
    }
}

private struct TokenEvent {
    let model: String?
    let totalTotals: CodexTotals?
    let lastTotals: CodexTotals?
}

private struct ModelBucket {
    var tokens: Int64
    var cost: Double

    static let empty = ModelBucket(tokens: 0, cost: 0)
}

private struct DayBucket {
    var tokens: Int64
    var cost: Double
    var models: [String: ModelBucket]

    static let empty = DayBucket(tokens: 0, cost: 0, models: [:])
}

private struct AccountUsageProfile {
    let source: UsageSource
    let accountEmail: String?
    let accountName: String?
    let planType: String?
    let primaryUsedRatio: Double?
    let secondaryUsedRatio: Double?
    let primaryResetAt: Date?
    let secondaryResetAt: Date?
    let updatedAt: Date?
}

private struct OAuthCredentials {
    let accessToken: String
    let idToken: String?
    let accountId: String?
}

private struct CodexUsageAPIResponse: Decodable {
    let planType: String?
    let rateLimit: RateLimitDetails?
    let credits: CreditDetails?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }
}

private struct RateLimitDetails: Decodable {
    let primaryWindow: WindowSnapshot?
    let secondaryWindow: WindowSnapshot?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct WindowSnapshot: Decodable {
    let usedPercent: Int
    let resetAt: Int
    let limitWindowSeconds: Int

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }
}

private struct CreditDetails: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: Double?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = (try? container.decode(Bool.self, forKey: .hasCredits)) ?? false
        unlimited = (try? container.decode(Bool.self, forKey: .unlimited)) ?? false
        if let balance = try? container.decode(Double.self, forKey: .balance) {
            self.balance = balance
        } else if let balance = try? container.decode(String.self, forKey: .balance),
                  let parsed = Double(balance) {
            self.balance = parsed
        } else {
            self.balance = nil
        }
    }
}
