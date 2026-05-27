import Foundation

struct UsageMetricsService {
    private let fileManager = FileManager.default
    private let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackPricingByModel: [String: CodexModelPricing] = [
        "gpt-5": .init(inputPerToken: 1.25e-6, cachedInputPerToken: 1.25e-7, outputPerToken: 1e-5),
        "gpt-5-mini": .init(inputPerToken: 2.5e-7, cachedInputPerToken: 2.5e-8, outputPerToken: 2e-6),
        "gpt-5-pro": .init(inputPerToken: 1.5e-5, cachedInputPerToken: 1.5e-5, outputPerToken: 1.2e-4),
        "gpt-5.5": .init(
            inputPerToken: 5e-6,
            cachedInputPerToken: 5e-7,
            outputPerToken: 3e-5,
            longContextThreshold: 272_000,
            inputPerTokenAboveThreshold: 1e-5,
            cachedInputPerTokenAboveThreshold: 1e-6,
            outputPerTokenAboveThreshold: 4.5e-5
        ),
        "o1-preview": .init(inputPerToken: 1.5e-5, cachedInputPerToken: 1.5e-5, outputPerToken: 6e-5),
        "o1-mini": .init(inputPerToken: 1.1e-6, cachedInputPerToken: 1.1e-7, outputPerToken: 4.4e-6)
    ]
    
    private let pricingByModel: [String: CodexModelPricing]
    private let cacheURL: URL
    
    init() {
        self.pricingByModel = Self.fallbackPricingByModel.merging(ModelPricingSyncService.shared.syncedPrices) { (_, new) in new }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("codexStack")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.cacheURL = appDir.appendingPathComponent("usage_cache.json")
    }

    func loadUsageSnapshot(codexRoot: URL, preferredAccountID: String? = nil) -> UsageSnapshot {
        let liveProfiles = loadAccountUsageProfiles(codexRoot: codexRoot)
        let cachedUsage = loadUsageFromRegistry(codexRoot: codexRoot)
        let allProfiles = liveProfiles + (cachedUsage.map { [$0] } ?? [])
        let mergedProfiles = dedupedAccountProfiles(allProfiles)
        let accountSnapshots = mergedProfiles.map(makeAccountSnapshot(from:))

        let preferred = accountSnapshots.first { $0.id == preferredAccountID }
            ?? accountSnapshots.first { $0.sessionUsedRatio != nil || $0.weeklyUsedRatio != nil }
            ?? accountSnapshots.first

        let orderedAccountSnapshots: [UsageAccountSnapshot]
        if let preferred {
            var rest = accountSnapshots.filter { $0.id != preferred.id }
            rest.insert(preferred, at: 0)
            orderedAccountSnapshots = rest
        } else {
            orderedAccountSnapshots = accountSnapshots
        }

        let selectedUsage = preferred

        let now = Date()
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let todayStart = Calendar.current.startOfDay(for: now)

        let roots = [codexRoot.appending(path: "sessions"), codexRoot.appending(path: "archived_sessions")]
        let files = collectSessionFiles(roots: roots)
        
        // Build metadata index to handle forked sessions
        let sessionIndex = buildSessionIndex(files: files)
        
        // Load persistent cache
        var usageCache = loadCache()
        var sessionTotals: [String: CodexTotals] = [:]

        var todayTokens: Int64 = 0
        var last30Tokens: Int64 = 0
        var todayCost: Double = 0
        var last30Cost: Double = 0
        var latestTimestamp = selectedUsage?.updatedAt
        var dailyBuckets: [Date: DayBucket] = [:]

        for fileURL in files {
            let sessionID = extractSessionID(from: fileURL.lastPathComponent) ?? UUID().uuidString
            let fileAttr = try? fileManager.attributesOfItem(atPath: fileURL.path)
            let fileSize = (fileAttr?[.size] as? Int64) ?? 0
            let modDate = (fileAttr?[.modificationDate] as? Date) ?? .distantPast
            
            let metrics: SessionMetrics
            if let cached = usageCache.sessions[sessionID], 
               cached.fileSize == fileSize, 
               cached.modificationDate == modDate {
                metrics = cached.metrics
            } else {
                metrics = scanSessionFile(
                    fileURL, 
                    sessionIndex: sessionIndex, 
                    sessionTotals: &sessionTotals,
                    thirtyDaysAgo: thirtyDaysAgo
                )
                usageCache.sessions[sessionID] = CachedSessionMetrics(
                    metrics: metrics,
                    fileSize: fileSize,
                    modificationDate: modDate
                )
            }
            
            // Accumulate global usage
            if let lastTS = metrics.lastTimestamp {
                latestTimestamp = maxDate(latestTimestamp, lastTS)
            }
            
            for (day, bucket) in metrics.dailyBuckets {
                if day >= thirtyDaysAgo {
                    last30Tokens += bucket.tokens
                    last30Cost += bucket.cost
                    
                    if day >= todayStart {
                        todayTokens += bucket.tokens
                        todayCost += bucket.cost
                    }
                    
                    var globalBucket = dailyBuckets[day] ?? DayBucket.empty
                    globalBucket.tokens += bucket.tokens
                    globalBucket.cost += bucket.cost
                    for (model, mBucket) in bucket.models {
                        var globalModelBucket = globalBucket.models[model] ?? ModelBucket.empty
                        globalModelBucket.tokens += mBucket.tokens
                        globalModelBucket.cost += mBucket.cost
                        globalBucket.models[model] = globalModelBucket
                    }
                    dailyBuckets[day] = globalBucket
                }
            }
        }
        
        saveCache(usageCache)

        let dailySeries = recentSevenDaySeries(from: dailyBuckets, todayStart: todayStart)

        return UsageSnapshot(
            updatedAt: latestTimestamp,
            accountEmail: selectedUsage?.email,
            accountName: selectedUsage?.name,
            planType: selectedUsage?.planType,
            source: selectedUsage?.source ?? .unavailable,
            sessionUsedRatio: selectedUsage?.sessionUsedRatio,
            weeklyUsedRatio: selectedUsage?.weeklyUsedRatio,
            sessionResetAt: selectedUsage?.sessionResetAt,
            weeklyResetAt: selectedUsage?.weeklyResetAt,
            todayTokens: todayTokens,
            last30DaysTokens: last30Tokens,
            todayCostUSD: todayCost,
            last30DaysCostUSD: last30Cost,
            dailyCostSeries: dailySeries,
            accounts: orderedAccountSnapshots
        )
    }
    
    // MARK: - Optimization Helpers

    private func scanSessionFile(
        _ fileURL: URL, 
        sessionIndex: [String: URL], 
        sessionTotals: inout [String: CodexTotals],
        thirtyDaysAgo: Date
    ) -> SessionMetrics {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return .empty }

        var currentModel = "gpt-5.5"
        var previousTotals: CodexTotals?
        var rawTotalsBaseline: CodexTotals?
        var sawDivergentTotals = false
        var inheritedTotals: CodexTotals?
        var remainingInheritedTotals: CodexTotals?
        
        var metrics = SessionMetrics.empty

        if let metadata = parseSessionMetadata(from: content) {
            if let forkedFromId = metadata.forkedFromId, let forkedAt = metadata.forkTimestamp {
                let forkPoint = resolveInheritedTotals(
                    forkedFromId: forkedFromId,
                    forkedAt: forkedAt,
                    index: sessionIndex,
                    totalsCache: &sessionTotals
                )
                inheritedTotals = forkPoint
                remainingInheritedTotals = forkPoint
            }
        }

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

            metrics.lastTimestamp = maxDate(metrics.lastTimestamp, timestamp)

            let deltas: CodexTotals
            if let last = event.lastTotals {
                let adjustedLast = adjustForInheritance(rawDelta: last, remaining: &remainingInheritedTotals)
                deltas = adjustedLast
                
                let counted = (previousTotals ?? .zero).adding(adjustedLast)
                previousTotals = counted
                
                if let total = event.totalTotals {
                    let currentTotal: CodexTotals
                    if let inheritance = inheritedTotals {
                        currentTotal = CodexTotals(
                            input: max(0, total.input - inheritance.input),
                            cachedInput: max(0, total.cachedInput - inheritance.cachedInput),
                            output: max(0, total.output - inheritance.output)
                        )
                    } else {
                        currentTotal = total
                    }
                    rawTotalsBaseline = currentTotal
                    if currentTotal != counted {
                        sawDivergentTotals = true
                    }
                } else {
                    rawTotalsBaseline = counted
                }
            } else if let total = event.totalTotals {
                let currentTotal: CodexTotals
                if let inheritance = inheritedTotals {
                    currentTotal = CodexTotals(
                        input: max(0, total.input - inheritance.input),
                        cachedInput: max(0, total.cachedInput - inheritance.cachedInput),
                        output: max(0, total.output - inheritance.output)
                    )
                } else {
                    currentTotal = total
                }
                
                if sawDivergentTotals {
                    deltas = divergentTotalDelta(
                        rawBaseline: rawTotalsBaseline,
                        countedBaseline: previousTotals,
                        current: currentTotal
                    )
                } else {
                    deltas = totalDelta(from: rawTotalsBaseline, to: currentTotal)
                }
                previousTotals = (previousTotals ?? .zero).adding(deltas)
                rawTotalsBaseline = currentTotal
                if rawTotalsBaseline != previousTotals {
                    sawDivergentTotals = true
                }
                remainingInheritedTotals = nil 
            } else {
                return
            }

            let deltaInput = max(0, deltas.input)
            let deltaCachedInput = min(deltaInput, max(0, deltas.cachedInput))
            let deltaOutput = max(0, deltas.output)
            let deltaTotal = deltaInput + deltaOutput

            guard deltaTotal > 0 else { return }
            metrics.tokens += Int64(deltaTotal)
            
            let eventCost = estimateCost(
                model: eventModel,
                deltaInput: deltaInput,
                deltaCachedInput: deltaCachedInput,
                deltaOutput: deltaOutput
            )
            metrics.cost += eventCost

            let day = Calendar.current.startOfDay(for: timestamp)
            var bucket = metrics.dailyBuckets[day] ?? DayBucket.empty
            bucket.tokens += Int64(deltaTotal)
            bucket.cost += eventCost
            var modelBucket = bucket.models[eventModel] ?? ModelBucket.empty
            modelBucket.tokens += Int64(deltaTotal)
            modelBucket.cost += eventCost
            bucket.models[eventModel] = modelBucket
            metrics.dailyBuckets[day] = bucket
        }
        
        // Cache final session totals for downstream inheritance
        if let sessionID = extractSessionID(from: fileURL.lastPathComponent), let final = previousTotals {
            sessionTotals[sessionID] = final
        }
        
        return metrics
    }

    private func adjustForInheritance(rawDelta: CodexTotals, remaining: inout CodexTotals?) -> CodexTotals {
        guard var rem = remaining else { return rawDelta }
        
        let adjusted = CodexTotals(
            input: max(0, rawDelta.input - rem.input),
            cachedInput: max(0, rawDelta.cachedInput - rem.cachedInput),
            output: max(0, rawDelta.output - rem.output)
        )
        
        rem = CodexTotals(
            input: max(0, rem.input - rawDelta.input),
            cachedInput: max(0, rem.cachedInput - rawDelta.cachedInput),
            output: max(0, rem.output - rawDelta.output)
        )
        
        remaining = (rem.input == 0 && rem.cachedInput == 0 && rem.output == 0) ? nil : rem
        return adjusted
    }

    private struct SessionFileMetadata {
        let sessionId: String?
        let forkedFromId: String?
        let forkTimestamp: String?
    }

    private func buildSessionIndex(files: [URL]) -> [String: URL] {
        var index: [String: URL] = [:]
        for fileURL in files {
            let fileName = fileURL.lastPathComponent
            if let id = extractSessionID(from: fileName) {
                index[id] = fileURL
            }
        }
        return index
    }

    private func extractSessionID(from fileName: String) -> String? {
        let idRegex = try! NSRegularExpression(
            pattern: #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$"#,
            options: [.caseInsensitive]
        )
        let nsRange = NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
        guard let match = idRegex.firstMatch(in: fileName, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: fileName) else {
            return nil
        }
        return String(fileName[range])
    }

    private func parseSessionMetadata(from content: String) -> SessionFileMetadata? {
        var sessionId: String?
        var forkedFromId: String?
        var forkTimestamp: String?
        
        content.enumerateLines { line, stop in
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["type"] as? String) == "session_meta" else {
                return
            }
            
            let payload = root["payload"] as? [String: Any]
            sessionId = payload?["session_id"] as? String ?? root["session_id"] as? String
            forkedFromId = payload?["forked_from_id"] as? String ?? payload?["parent_session_id"] as? String
            forkTimestamp = payload?["timestamp"] as? String ?? root["timestamp"] as? String
            stop = true
        }
        
        return SessionFileMetadata(sessionId: sessionId, forkedFromId: forkedFromId, forkTimestamp: forkTimestamp)
    }

    private func resolveInheritedTotals(
        forkedFromId: String, 
        forkedAt: String, 
        index: [String: URL],
        totalsCache: inout [String: CodexTotals]
    ) -> CodexTotals? {
        if let cached = totalsCache[forkedFromId] {
            return cached
        }
        
        guard let parentURL = index[forkedFromId],
              let content = try? String(contentsOf: parentURL, encoding: .utf8) else {
            return nil
        }
        
        var bestTotals: CodexTotals?
        content.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = root["timestamp"] as? String,
                  timestamp <= forkedAt,
                  (root["type"] as? String) == "event_msg",
                  let payload = root["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let totalUsage = info["total_token_usage"] else {
                return
            }
            
            if let totals = parseCodexTotals(totalUsage) {
                bestTotals = totals
            }
        }
        if let final = bestTotals {
            totalsCache[forkedFromId] = final
        }
        return bestTotals
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

    private func loadAccountUsageProfiles(codexRoot: URL) -> [AccountUsageProfile] {
        guard let usageURL = resolveUsageURL(codexRoot: codexRoot) else { return [] }
        let credentials = loadOAuthCredentials(codexRoot: codexRoot) + loadImportedOAuthCredentials()
        return credentials.compactMap { loadUsageProfile(usageURL: usageURL, credentials: $0, codexRoot: codexRoot) }
    }

    private func loadUsageProfile(usageURL: URL, credentials: OAuthCredentials, codexRoot: URL) -> AccountUsageProfile? {
        guard !credentials.disabled else { return nil }
        var credentials = refreshedCredentialsIfNeeded(credentials, codexRoot: codexRoot)
        var fetchResult = fetchCodexUsage(usageURL: usageURL, credentials: credentials)
        if fetchResult.1,
           credentials.isCurrentCodexAccount,
           let refreshToken = credentials.refreshToken,
           !refreshToken.isEmpty,
           let refreshed = refreshOAuthCredentials(credentials, refreshToken: refreshToken) {
            persistRefreshedCredentials(refreshed, original: credentials, codexRoot: codexRoot)
            credentials = refreshed
            fetchResult = fetchCodexUsage(usageURL: usageURL, credentials: credentials)
        }
        let response = fetchResult.0
        let isUnauthorized = fetchResult.1

        let jwtPayload = credentials.idToken.flatMap(parseJWT)
        let accessPayload = parseJWT(credentials.accessToken)
        let authProfile = jwtPayload?["https://api.openai.com/profile"] as? [String: Any]
            ?? accessPayload?["https://api.openai.com/profile"] as? [String: Any]
        let authDetails = jwtPayload?["https://api.openai.com/auth"] as? [String: Any]
            ?? accessPayload?["https://api.openai.com/auth"] as? [String: Any]

        let primaryWindow = response?.rateLimit?.primaryWindow
        let secondaryWindow = response?.rateLimit?.secondaryWindow
        let accountID = credentials.accountId
            ?? normalizedString(authDetails?["chatgpt_account_id"] as? String)
        let email = normalizedString(
            credentials.email
                ?? authProfile?["email"] as? String
                ?? jwtPayload?["email"] as? String
                ?? accessPayload?["email"] as? String
        )

        let profile = AccountUsageProfile(
            id: accountID ?? email ?? credentials.id,
            accountID: accountID,
            source: response == nil ? .unavailable : .live,
            accountEmail: email,
            accountName: nil,
            note: credentials.note,
            planType: normalizedString(
                response?.planType
                    ?? authDetails?["chatgpt_plan_type"] as? String
                    ?? jwtPayload?["chatgpt_plan_type"] as? String
                    ?? accessPayload?["chatgpt_plan_type"] as? String
            ),
            primaryUsedRatio: primaryWindow.map { clampPercent(Double($0.usedPercent)) / 100 },
            secondaryUsedRatio: secondaryWindow.map { clampPercent(Double($0.usedPercent)) / 100 },
            primaryResetAt: primaryWindow.map { Date(timeIntervalSince1970: TimeInterval($0.resetAt)) },
            secondaryResetAt: secondaryWindow.map { Date(timeIntervalSince1970: TimeInterval($0.resetAt)) },
            updatedAt: response == nil ? credentials.lastRefreshAt : Date(),
            expiresAt: credentials.expiresAt,
            importedAt: credentials.importedAt,
            isCurrentCodexAccount: credentials.isCurrentCodexAccount,
            isCredentialExpired: isUnauthorized
        )

        if profile.accountEmail == nil &&
            profile.accountID == nil &&
            profile.note == nil &&
            profile.planType == nil &&
            profile.primaryUsedRatio == nil &&
            profile.secondaryUsedRatio == nil {
            return nil
        }
        return profile
    }

    private func refreshedCredentialsIfNeeded(_ credentials: OAuthCredentials, codexRoot: URL) -> OAuthCredentials {
        guard credentials.isCurrentCodexAccount,
              credentials.isExpired,
              let refreshToken = credentials.refreshToken,
              !refreshToken.isEmpty,
              let refreshed = refreshOAuthCredentials(credentials, refreshToken: refreshToken) else {
            return credentials
        }
        persistRefreshedCredentials(refreshed, original: credentials, codexRoot: codexRoot)
        return refreshed
    }

    private func refreshOAuthCredentials(_ credentials: OAuthCredentials, refreshToken: String) -> OAuthCredentials? {
        let tokenURL = URL(string: "https://auth.openai.com/oauth/token")
        guard let tokenURL else { return nil }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formURLEncodedBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID(for: credentials)
        ])

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 6
        let session = URLSession(configuration: config)
        let semaphore = DispatchSemaphore(value: 0)
        var tokenResponse: OAuthRefreshResponse?

        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let data else {
                return
            }
            tokenResponse = try? JSONDecoder().decode(OAuthRefreshResponse.self, from: data)
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 6.5) == .timedOut {
            task.cancel()
            return nil
        }

        guard let tokenResponse else { return nil }
        let accessToken = tokenResponse.accessToken
        let idToken = tokenResponse.idToken ?? credentials.idToken
        let newRefreshToken = tokenResponse.refreshToken ?? refreshToken
        let accessPayload = parseJWT(accessToken)
        let idPayload = idToken.flatMap(parseJWT)
        let authDetails = (idPayload?["https://api.openai.com/auth"] as? [String: Any])
            ?? (accessPayload?["https://api.openai.com/auth"] as? [String: Any])
        let profile = (idPayload?["https://api.openai.com/profile"] as? [String: Any])
            ?? (accessPayload?["https://api.openai.com/profile"] as? [String: Any])
        let expiresAt = tokenResponse.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
            ?? jwtExpiration(accessPayload)
            ?? jwtExpiration(idPayload)

        return OAuthCredentials(
            id: normalizedString(authDetails?["chatgpt_account_id"] as? String)
                ?? normalizedString(profile?["email"] as? String)
                ?? credentials.id,
            accessToken: accessToken,
            idToken: idToken,
            refreshToken: newRefreshToken,
            accountId: normalizedString(authDetails?["chatgpt_account_id"] as? String) ?? credentials.accountId,
            email: credentials.email
                ?? normalizedString(profile?["email"] as? String)
                ?? normalizedString(idPayload?["email"] as? String)
                ?? normalizedString(accessPayload?["email"] as? String),
            note: credentials.note,
            expiresAt: expiresAt,
            lastRefreshAt: Date(),
            importedAt: credentials.importedAt,
            disabled: credentials.disabled,
            isCurrentCodexAccount: credentials.isCurrentCodexAccount
        )
    }

    private func persistRefreshedCredentials(_ refreshed: OAuthCredentials, original: OAuthCredentials, codexRoot: URL) {
        if original.isCurrentCodexAccount {
            persistCurrentAuth(refreshed, codexRoot: codexRoot)
        } else {
            try? AccountCredentialStore.updateTokens(
                id: original.id,
                accessToken: refreshed.accessToken,
                idToken: refreshed.idToken,
                refreshToken: refreshed.refreshToken,
                expiresAt: refreshed.expiresAt,
                lastRefreshAt: refreshed.lastRefreshAt ?? Date()
            )
        }
    }

    private func dedupedAccountProfiles(_ profiles: [AccountUsageProfile]) -> [AccountUsageProfile] {
        var groups: [(keys: Set<String>, profile: AccountUsageProfile)] = []

        for profile in profiles {
            let incomingKeys = identityKeys(for: profile)
            if let idx = groups.firstIndex(where: { !$0.keys.intersection(incomingKeys).isEmpty }) {
                let merged = mergeProfiles(groups[idx].profile, profile)
                let combinedKeys = groups[idx].keys.union(incomingKeys).union(identityKeys(for: merged))
                groups[idx] = (combinedKeys, merged)
            } else {
                groups.append((incomingKeys, profile))
            }
        }

        return groups.map(\.profile).sorted { lhs, rhs in
            if lhs.isCurrentCodexAccount != rhs.isCurrentCodexAccount {
                return lhs.isCurrentCodexAccount
            }
            return profileSortDate(lhs) > profileSortDate(rhs)
        }
    }

    private func identityKeys(for profile: AccountUsageProfile) -> Set<String> {
        var keys: Set<String> = []
        if let id = profile.accountID, !id.isEmpty {
            keys.insert("acct:" + id)
        }
        if let email = profile.accountEmail, !email.isEmpty {
            keys.insert("email:" + email.lowercased())
        }
        if keys.isEmpty {
            keys.insert("self:" + profile.id)
        }
        return keys
    }

    private func mergeProfiles(_ existing: AccountUsageProfile, _ incoming: AccountUsageProfile) -> AccountUsageProfile {
        let winner: AccountUsageProfile
        let loser: AccountUsageProfile
        if existing.isCredentialExpired != incoming.isCredentialExpired {
            winner = existing.isCredentialExpired ? incoming : existing
            loser = existing.isCredentialExpired ? existing : incoming
        } else {
            let existingHasUsage = existing.primaryUsedRatio != nil || existing.secondaryUsedRatio != nil
            let incomingHasUsage = incoming.primaryUsedRatio != nil || incoming.secondaryUsedRatio != nil
            if existingHasUsage != incomingHasUsage {
                winner = existingHasUsage ? existing : incoming
                loser = existingHasUsage ? incoming : existing
            } else if profileSortDate(existing) >= profileSortDate(incoming) {
                winner = existing
                loser = incoming
            } else {
                winner = incoming
                loser = existing
            }
        }

        let preferLiveSource = winner.source == .live || loser.source == .live
        let mergedSource: UsageSource = preferLiveSource
            ? .live
            : (winner.source != .unavailable ? winner.source : loser.source)

        let updatedAt: Date? = {
            switch (winner.updatedAt, loser.updatedAt) {
            case let (a?, b?): return a > b ? a : b
            case let (a?, nil): return a
            case let (nil, b?): return b
            default: return nil
            }
        }()
        
        let isExpired: Bool
        if existing.source == .cached {
            isExpired = incoming.isCredentialExpired
        } else if incoming.source == .cached {
            isExpired = existing.isCredentialExpired
        } else {
            isExpired = existing.isCredentialExpired && incoming.isCredentialExpired
        }

        return AccountUsageProfile(
            id: winner.accountID ?? loser.accountID ?? winner.accountEmail ?? loser.accountEmail ?? winner.id,
            accountID: winner.accountID ?? loser.accountID,
            source: mergedSource,
            accountEmail: winner.accountEmail ?? loser.accountEmail,
            accountName: winner.accountName ?? loser.accountName,
            note: winner.note ?? loser.note,
            planType: winner.planType ?? loser.planType,
            primaryUsedRatio: winner.primaryUsedRatio ?? loser.primaryUsedRatio,
            secondaryUsedRatio: winner.secondaryUsedRatio ?? loser.secondaryUsedRatio,
            primaryResetAt: winner.primaryResetAt ?? loser.primaryResetAt,
            secondaryResetAt: winner.secondaryResetAt ?? loser.secondaryResetAt,
            updatedAt: updatedAt,
            expiresAt: winner.expiresAt ?? loser.expiresAt,
            importedAt: winner.importedAt ?? loser.importedAt,
            isCurrentCodexAccount: winner.isCurrentCodexAccount || loser.isCurrentCodexAccount,
            isCredentialExpired: isExpired
        )
    }

    private func profileSortDate(_ profile: AccountUsageProfile) -> Date {
        profile.updatedAt ?? profile.importedAt ?? profile.expiresAt ?? .distantPast
    }

    private func makeAccountSnapshot(from profile: AccountUsageProfile) -> UsageAccountSnapshot {
        UsageAccountSnapshot(
            id: profile.accountID ?? profile.accountEmail ?? profile.id,
            accountID: profile.accountID,
            email: profile.accountEmail,
            name: profile.accountName,
            note: profile.note,
            planType: profile.planType,
            source: profile.source,
            sessionUsedRatio: profile.isCredentialExpired ? nil : profile.primaryUsedRatio,
            weeklyUsedRatio: profile.isCredentialExpired ? nil : profile.secondaryUsedRatio,
            sessionResetAt: profile.primaryResetAt,
            weeklyResetAt: profile.secondaryResetAt,
            updatedAt: profile.updatedAt,
            expiresAt: profile.expiresAt,
            isCurrentCodexAccount: profile.isCurrentCodexAccount,
            isCredentialExpired: profile.isCredentialExpired
        )
    }

    private func resolveUsageURL(codexRoot: URL) -> URL? {
        URL(string: "https://chatgpt.com/backend-api/wham/usage")
    }

    private func fetchCodexUsage(usageURL: URL, credentials: OAuthCredentials) -> (CodexUsageAPIResponse?, Bool) {
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
        var isUnauthorized = false
        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 || http.statusCode == 403 {
                isUnauthorized = true
                return
            }
            guard (200...299).contains(http.statusCode), let data else {
                return
            }
            decoded = try? JSONDecoder().decode(CodexUsageAPIResponse.self, from: data)
        }
        task.resume()

        let waitResult = semaphore.wait(timeout: .now() + 2.8)
        if waitResult == .timedOut {
            task.cancel()
            return (nil, false)
        }
        return (decoded, isUnauthorized)
    }

    private func formURLEncodedBody(_ values: [String: String]) -> Data {
        let body = values
            .map { key, value in
                "\(formEscape(key))=\(formEscape(value))"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func oauthClientID(for credentials: OAuthCredentials) -> String {
        let payloads = [parseJWT(credentials.accessToken), credentials.idToken.flatMap(parseJWT)]
        for payload in payloads {
            if let clientID = normalizedString(payload?["client_id"] as? String) {
                return clientID
            }
        }
        return "app_EMoamEEZ73f0CkXaXp7hrann"
    }

    private func persistCurrentAuth(_ credentials: OAuthCredentials, codexRoot: URL) {
        let authURL = codexRoot.appending(path: "auth.json")
        guard let data = try? Data(contentsOf: authURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        var tokens = (root["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = credentials.accessToken
        if let idToken = credentials.idToken {
            tokens["id_token"] = idToken
        }
        if let refreshToken = credentials.refreshToken {
            tokens["refresh_token"] = refreshToken
        }
        root["tokens"] = tokens

        if let encoded = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? encoded.write(to: authURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: authURL.path
            )
        }
    }

    private func loadOAuthCredentials(codexRoot: URL) -> [OAuthCredentials] {
        let authURL = codexRoot.appending(path: "auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if let apiKey = normalizedString(root["OPENAI_API_KEY"] as? String) {
            return [
                OAuthCredentials(
                    id: "codex-api-key",
                    accessToken: apiKey,
                    idToken: nil,
                    refreshToken: nil,
                    accountId: nil,
                    email: nil,
                    note: "Codex auth.json",
                    expiresAt: nil,
                    lastRefreshAt: nil,
                    importedAt: nil,
                    disabled: false,
                    isCurrentCodexAccount: true
                )
            ]
        }

        guard let tokens = root["tokens"] as? [String: Any],
              let accessToken = normalizedString(
                  tokens["access_token"] as? String
                      ?? tokens["accessToken"] as? String
              ) else {
            return []
        }

        let idToken = normalizedString(tokens["id_token"] as? String ?? tokens["idToken"] as? String)
        let accessPayload = parseJWT(accessToken)
        let idPayload = idToken.flatMap(parseJWT)
        let authDetails = (idPayload?["https://api.openai.com/auth"] as? [String: Any])
            ?? (accessPayload?["https://api.openai.com/auth"] as? [String: Any])
        let profile = (idPayload?["https://api.openai.com/profile"] as? [String: Any])
            ?? (accessPayload?["https://api.openai.com/profile"] as? [String: Any])
        let accountID = normalizedString(authDetails?["chatgpt_account_id"] as? String)
            ?? normalizedString(tokens["account_id"] as? String ?? tokens["accountId"] as? String)
        let email = normalizedString(profile?["email"] as? String)
            ?? normalizedString(idPayload?["email"] as? String)
            ?? normalizedString(accessPayload?["email"] as? String)

        return [
            OAuthCredentials(
                id: accountID ?? email ?? "codex-auth-json",
                accessToken: accessToken,
                idToken: idToken,
                refreshToken: normalizedString(tokens["refresh_token"] as? String ?? tokens["refreshToken"] as? String),
                accountId: accountID,
                email: email,
                note: "Codex auth.json",
                expiresAt: jwtExpiration(accessPayload) ?? jwtExpiration(idPayload),
                lastRefreshAt: nil,
                importedAt: nil,
                disabled: false,
                isCurrentCodexAccount: true
            )
        ]
    }

    private func loadImportedOAuthCredentials() -> [OAuthCredentials] {
        AccountCredentialStore.loadAccounts().map { account in
            let account = AccountCredentialStore.refreshFromSource(account)
            return OAuthCredentials(
                id: account.id,
                accessToken: account.accessToken,
                idToken: account.idToken,
                refreshToken: account.refreshToken,
                accountId: account.accountID,
                email: account.email,
                note: account.note,
                expiresAt: account.expiresAt,
                lastRefreshAt: account.lastRefreshAt,
                importedAt: account.importedAt,
                disabled: false,
                isCurrentCodexAccount: false
            )
        }
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

    private func jwtExpiration(_ payload: [String: Any]?) -> Date? {
        guard let payload else { return nil }
        if let value = payload["exp"] as? TimeInterval {
            return Date(timeIntervalSince1970: value)
        }
        if let value = payload["exp"] as? NSNumber {
            return Date(timeIntervalSince1970: value.doubleValue)
        }
        return nil
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
        // Legacy format: only total_tokens is recorded without input/output breakdown.
        // Approximate as 70% input / 30% output for cost estimation.
        if input == 0 && output == 0, let total = intFromAny(dict["total_tokens"]), total > 0 {
            return CodexTotals(input: total * 7 / 10, cachedInput: 0, output: total * 3 / 10)
        }
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
        if model.hasPrefix("anthropic.") {
            model = String(model.dropFirst("anthropic.".count))
        }
        
        if pricingByModel[model] != nil {
            return model
        }
        
        // Remove date suffix like -20240513 or -2024-05-13
        if let range = model.range(of: #"-\d{4}-?\d{2}-?\d{2}$"#, options: .regularExpression) {
            let base = String(model[..<range.lowerBound])
            if pricingByModel[base] != nil {
                return base
            }
        }
        
        // Handle @ suffix
        if let atIndex = model.firstIndex(of: "@") {
            let base = String(model[..<atIndex])
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
    
    // MARK: - Persistence & Caching
    
    private func loadCache() -> UsageCache {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(UsageCache.self, from: data) else {
            return UsageCache(sessions: [:])
        }
        return cache
    }
    
    private func saveCache(_ cache: UsageCache) {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL)
        }
    }
}

// MARK: - Supporting Types

struct CodexModelPricing: Codable {
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

private struct CodexTotals: Codable, Equatable {
    var input: Int
    var cachedInput: Int
    var output: Int

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

private struct ModelBucket: Codable {
    var tokens: Int64
    var cost: Double

    static let empty = ModelBucket(tokens: 0, cost: 0)
}

private struct DayBucket: Codable {
    var tokens: Int64
    var cost: Double
    var models: [String: ModelBucket]

    static let empty = DayBucket(tokens: 0, cost: 0, models: [:])
}

private struct SessionMetrics: Codable {
    var tokens: Int64
    var cost: Double
    var dailyBuckets: [Date: DayBucket]
    var lastTimestamp: Date?
    
    static let empty = SessionMetrics(tokens: 0, cost: 0, dailyBuckets: [:], lastTimestamp: nil)
}

private struct CachedSessionMetrics: Codable {
    let metrics: SessionMetrics
    let fileSize: Int64
    let modificationDate: Date
}

private struct UsageCache: Codable {
    var sessions: [String: CachedSessionMetrics]
}

private struct AccountUsageProfile {
    let id: String
    let accountID: String?
    let source: UsageSource
    let accountEmail: String?
    let accountName: String?
    let note: String?
    let planType: String?
    let primaryUsedRatio: Double?
    let secondaryUsedRatio: Double?
    let primaryResetAt: Date?
    let secondaryResetAt: Date?
    let updatedAt: Date?
    let expiresAt: Date?
    let importedAt: Date?
    let isCurrentCodexAccount: Bool
    let isCredentialExpired: Bool

    init(
        id: String = UUID().uuidString,
        accountID: String? = nil,
        source: UsageSource,
        accountEmail: String?,
        accountName: String?,
        note: String? = nil,
        planType: String?,
        primaryUsedRatio: Double?,
        secondaryUsedRatio: Double?,
        primaryResetAt: Date?,
        secondaryResetAt: Date?,
        updatedAt: Date?,
        expiresAt: Date? = nil,
        importedAt: Date? = nil,
        isCurrentCodexAccount: Bool = false,
        isCredentialExpired: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.source = source
        self.accountEmail = accountEmail
        self.accountName = accountName
        self.note = note
        self.planType = planType
        self.primaryUsedRatio = primaryUsedRatio
        self.secondaryUsedRatio = secondaryUsedRatio
        self.primaryResetAt = primaryResetAt
        self.secondaryResetAt = secondaryResetAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.importedAt = importedAt
        self.isCurrentCodexAccount = isCurrentCodexAccount
        self.isCredentialExpired = isCredentialExpired
    }
}

private struct OAuthCredentials {
    let id: String
    let accessToken: String
    let idToken: String?
    let refreshToken: String?
    let accountId: String?
    let email: String?
    let note: String?
    let expiresAt: Date?
    let lastRefreshAt: Date?
    let importedAt: Date?
    let disabled: Bool
    let isCurrentCodexAccount: Bool

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
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

private struct OAuthRefreshResponse: Decodable {
    let accessToken: String
    let idToken: String?
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
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
