import Foundation

struct ImportedCodexAccount: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let accountID: String?
    let email: String?
    let note: String?
    let type: String?
    let accessToken: String
    let idToken: String?
    let refreshToken: String?
    let expiresAt: Date?
    let lastRefreshAt: Date?
    let importedAt: Date

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

struct ImportedCodexAccountSummary: Identifiable, Hashable, Sendable {
    let id: String
    let accountID: String?
    let email: String?
    let note: String?
    let type: String?
    let expiresAt: Date?
    let lastRefreshAt: Date?
    let importedAt: Date

    var displayName: String {
        if let note, !note.isEmpty { return note }
        if let email, !email.isEmpty { return email }
        if let accountID, !accountID.isEmpty { return accountID }
        return "Imported Account"
    }
}

enum AccountCredentialStore {
    private static let fileName = "imported-accounts.json"

    static func loadAccounts() -> [ImportedCodexAccount] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ImportedCodexAccount].self, from: data)) ?? []
    }

    static func loadSummaries() -> [ImportedCodexAccountSummary] {
        loadAccounts()
            .map { account in
                ImportedCodexAccountSummary(
                    id: account.id,
                    accountID: account.accountID,
                    email: account.email,
                    note: account.note,
                    type: account.type,
                    expiresAt: account.expiresAt,
                    lastRefreshAt: account.lastRefreshAt,
                    importedAt: account.importedAt
                )
            }
            .sorted { lhs, rhs in
                (lhs.lastRefreshAt ?? lhs.importedAt) > (rhs.lastRefreshAt ?? rhs.importedAt)
            }
    }

    @discardableResult
    static func importAccount(from url: URL) throws -> ImportedCodexAccount {
        let data = try Data(contentsOf: url)
        let account = try parseAccount(data: data, fallbackNote: url.deletingPathExtension().lastPathComponent)

        var accounts = loadAccounts().filter { $0.id != account.id }
        accounts.append(account)
        try save(accounts)
        return account
    }

    static func removeAccount(id: String) throws {
        let accounts = loadAccounts().filter { $0.id != id }
        try save(accounts)
    }

    static func updateTokens(
        id: String,
        accessToken: String,
        idToken: String?,
        refreshToken: String?,
        expiresAt: Date?,
        lastRefreshAt: Date
    ) throws {
        var accounts = loadAccounts()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let current = accounts[index]
        accounts[index] = ImportedCodexAccount(
            id: current.id,
            accountID: current.accountID,
            email: current.email,
            note: current.note,
            type: current.type,
            accessToken: accessToken,
            idToken: idToken ?? current.idToken,
            refreshToken: refreshToken ?? current.refreshToken,
            expiresAt: expiresAt,
            lastRefreshAt: lastRefreshAt,
            importedAt: current.importedAt
        )
        try save(accounts)
    }

    private static func save(_ accounts: [ImportedCodexAccount]) throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(accounts)
        try data.write(to: storeURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: storeURL.path
        )
    }

    private static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "codexStack", directoryHint: .isDirectory).appending(path: fileName)
    }

    private static func parseAccount(data: Data, fallbackNote: String) throws -> ImportedCodexAccount {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "codexStack", code: 101, userInfo: [NSLocalizedDescriptionKey: "Invalid account JSON"])
        }

        let tokenContainer = (root["tokens"] as? [String: Any]) ?? root
        guard let accessToken = normalizedString(
            tokenContainer["access_token"] as? String
                ?? tokenContainer["accessToken"] as? String
                ?? root["access_token"] as? String
                ?? root["accessToken"] as? String
        ) else {
            throw NSError(domain: "codexStack", code: 102, userInfo: [NSLocalizedDescriptionKey: "No OAuth access token found"])
        }

        let idToken = normalizedString(
            tokenContainer["id_token"] as? String
                ?? tokenContainer["idToken"] as? String
                ?? root["id_token"] as? String
                ?? root["idToken"] as? String
        )
        let refreshToken = normalizedString(
            tokenContainer["refresh_token"] as? String
                ?? tokenContainer["refreshToken"] as? String
                ?? root["refresh_token"] as? String
                ?? root["refreshToken"] as? String
        )

        let accessPayload = parseJWT(accessToken)
        let idPayload = idToken.flatMap(parseJWT)
        let authDetails = (idPayload?["https://api.openai.com/auth"] as? [String: Any])
            ?? (accessPayload?["https://api.openai.com/auth"] as? [String: Any])
        let profile = (idPayload?["https://api.openai.com/profile"] as? [String: Any])
            ?? (accessPayload?["https://api.openai.com/profile"] as? [String: Any])

        let accountID = normalizedString(authDetails?["chatgpt_account_id"] as? String)
            ?? normalizedString(tokenContainer["account_id"] as? String ?? tokenContainer["accountId"] as? String)
            ?? normalizedString(root["account_id"] as? String ?? root["accountId"] as? String)
        let email = normalizedString(root["email"] as? String)
            ?? normalizedString(profile?["email"] as? String)
            ?? normalizedString(idPayload?["email"] as? String)
        let note = normalizedString(root["note"] as? String) ?? fallbackNote
        let type = normalizedString(root["type"] as? String) ?? "codex"
        let expiresAt = parseDate(root["expired"] as? String)
            ?? parseDate(root["expires_at"] as? String)
            ?? jwtExpiration(accessPayload)
            ?? jwtExpiration(idPayload)
        let lastRefreshAt = parseDate(root["last_refresh"] as? String)
            ?? parseDate(root["lastRefresh"] as? String)

        let id = accountID ?? email ?? UUID().uuidString
        return ImportedCodexAccount(
            id: id,
            accountID: accountID,
            email: email,
            note: note,
            type: type,
            accessToken: accessToken,
            idToken: idToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            lastRefreshAt: lastRefreshAt,
            importedAt: Date()
        )
    }

    private static func parseJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func jwtExpiration(_ payload: [String: Any]?) -> Date? {
        guard let payload else { return nil }
        if let value = payload["exp"] as? TimeInterval {
            return Date(timeIntervalSince1970: value)
        }
        if let value = payload["exp"] as? NSNumber {
            return Date(timeIntervalSince1970: value.doubleValue)
        }
        return nil
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value = normalizedString(value) else { return nil }
        if let date = ISO8601DateFormatter.fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
