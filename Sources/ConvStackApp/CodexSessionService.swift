import Foundation

struct CodexSessionService {
    private let fileManager = FileManager.default
    private let codexRoot: URL
    private let activeRoot: URL
    private let archivedRoot: URL
    private let sessionIndexURL: URL
    private let idRegex = try! NSRegularExpression(
        pattern: #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$"#,
        options: [.caseInsensitive]
    )

    init(codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")) {
        self.codexRoot = codexRoot
        self.activeRoot = codexRoot.appending(path: "sessions")
        self.archivedRoot = codexRoot.appending(path: "archived_sessions")
        self.sessionIndexURL = codexRoot.appending(path: "session_index.jsonl")
    }

    func loadSessions() throws -> [CodexSession] {
        let index = try loadIndex()
        let active = scanSessions(in: activeRoot, archived: false, index: index)
        let archived = scanSessions(in: archivedRoot, archived: true, index: index)
        return (active + archived).sorted { $0.updatedAt > $1.updatedAt }
    }

    func archive(_ session: CodexSession) throws {
        try archive([session])
    }

    func archive(_ sessions: [CodexSession]) throws {
        guard !sessions.isEmpty else { return }
        try mutateSessions {
            for session in sessions {
                guard !session.isArchived else { continue }
                try moveSessionFile(session, from: activeRoot, to: archivedRoot)
            }
        }
    }

    func unarchive(_ session: CodexSession) throws {
        try unarchive([session])
    }

    func unarchive(_ sessions: [CodexSession]) throws {
        guard !sessions.isEmpty else { return }
        try mutateSessions {
            for session in sessions {
                guard session.isArchived else { continue }
                try moveSessionFile(session, from: archivedRoot, to: activeRoot)
            }
        }
    }

    func trash(_ sessions: [CodexSession]) throws {
        guard !sessions.isEmpty else { return }
        try mutateSessions {
            for session in sessions {
                var trashURL: NSURL?
                try fileManager.trashItem(at: session.fileURL, resultingItemURL: &trashURL)
            }
        }
    }

    func reconcileSessionIndex() throws {
        try syncSessionIndex()
    }

    func loadConversationPreview(for session: CodexSession, maxMessages: Int = 200) -> [SessionMessage] {
        guard let content = try? String(contentsOf: session.fileURL, encoding: .utf8) else {
            return []
        }

        var results: [SessionMessage] = []
        content.enumerateLines { line, stop in
            guard let data = line.data(using: .utf8) else { return }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let timestamp = parseTimestamp(root["timestamp"])

            if let parsed = parseEventMessage(root, timestamp: timestamp) {
                results.append(parsed)
            } else if let parsed = parseResponseItemMessage(root, timestamp: timestamp) {
                results.append(parsed)
            }

            if results.count >= maxMessages {
                stop = true
            }
        }
        return dedup(messages: results)
    }

    private func moveSessionFile(_ session: CodexSession, from sourceRoot: URL, to targetRoot: URL) throws {
        let sourcePath = session.fileURL.standardizedFileURL.path
        let sourceRootPath = sourceRoot.standardizedFileURL.path
        let relativePath: String
        if sourcePath.hasPrefix(sourceRootPath + "/") {
            relativePath = String(sourcePath.dropFirst(sourceRootPath.count + 1))
        } else {
            relativePath = session.fileURL.lastPathComponent
        }

        let destination = targetRoot.appending(path: relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: session.fileURL, to: destination)
    }

    private func scanSessions(
        in root: URL,
        archived: Bool,
        index: [String: SessionIndexEntry]
    ) -> [CodexSession] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        ) else {
            return []
        }

        var results: [CodexSession] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let sessionID = extractSessionID(from: fileURL.lastPathComponent) else { continue }

            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }

            let metadata = index[sessionID]
            let title = metadata?.threadName ?? "Untitled"
            let updatedAt = metadata?.updatedAt ?? values?.contentModificationDate ?? .distantPast
            let size = Int64(values?.fileSize ?? 0)
            let projectPath = readProjectPath(from: fileURL)

            results.append(
                CodexSession(
                    id: sessionID,
                    title: title,
                    updatedAt: updatedAt,
                    fileURL: fileURL,
                    isArchived: archived,
                    sizeInBytes: size,
                    projectPath: projectPath
                )
            )
        }
        return results
    }

    private func extractSessionID(from fileName: String) -> String? {
        let nsRange = NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
        guard let match = idRegex.firstMatch(in: fileName, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: fileName) else {
            return nil
        }
        return String(fileName[range])
    }

    private func loadIndex() throws -> [String: SessionIndexEntry] {
        guard fileManager.fileExists(atPath: sessionIndexURL.path) else { return [:] }
        let content = try String(contentsOf: sessionIndexURL, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds

        var entries: [String: SessionIndexEntry] = [:]
        for line in content.split(whereSeparator: \.isNewline) {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else { continue }
            guard let parsed = try? decoder.decode(SessionIndexEntry.self, from: data) else { continue }
            entries[parsed.id] = parsed
        }
        return entries
    }

    private func mutateSessions(_ mutation: () throws -> Void) throws {
        try mutation()
        try syncSessionIndex()
    }

    private func syncSessionIndex() throws {
        guard fileManager.fileExists(atPath: sessionIndexURL.path) else { return }

        let existingIDs = collectAllSessionIDs()
        let original = try String(contentsOf: sessionIndexURL, encoding: .utf8)
        let originalLines = original.split(whereSeparator: \.isNewline).map(String.init)
        guard !originalLines.isEmpty else { return }

        var filteredLines: [String] = []
        var removedCount = 0

        for line in originalLines {
            guard let id = extractIndexID(fromLine: line) else {
                filteredLines.append(line)
                continue
            }
            if existingIDs.contains(id) {
                filteredLines.append(line)
            } else {
                removedCount += 1
            }
        }

        guard removedCount > 0 else { return }
        let rewritten = filteredLines.joined(separator: "\n") + (filteredLines.isEmpty ? "" : "\n")
        let tempURL = codexRoot.appending(path: "session_index.jsonl.tmp")
        try rewritten.write(to: tempURL, atomically: true, encoding: .utf8)

        _ = try fileManager.replaceItemAt(
            sessionIndexURL,
            withItemAt: tempURL,
            backupItemName: "session_index.backup-\(indexBackupSuffix()).jsonl",
            options: []
        )
    }

    private func collectAllSessionIDs() -> Set<String> {
        var ids = Set<String>()
        ids.formUnion(scanSessionIDs(in: activeRoot))
        ids.formUnion(scanSessionIDs(in: archivedRoot))
        return ids
    }

    private func scanSessionIDs(in root: URL) -> Set<String> {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }

        var ids = Set<String>()
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let id = extractSessionID(from: fileURL.lastPathComponent) else { continue }
            ids.insert(id)
        }
        return ids
    }

    private func extractIndexID(fromLine line: String) -> String? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    private func indexBackupSuffix() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func readProjectPath(from sessionFile: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: sessionFile) else { return nil }
        defer { try? handle.close() }

        // Parse only the first JSONL line (session_meta), but allow a long line.
        let newline = UInt8(ascii: "\n")
        var firstLine = Data()
        var inspectedBytes = 0
        let maxBytes = 1024 * 1024

        while inspectedBytes < maxBytes {
            guard let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty else {
                break
            }
            inspectedBytes += chunk.count

            if let newlineIndex = chunk.firstIndex(of: newline) {
                firstLine.append(chunk[..<newlineIndex])
                break
            }
            firstLine.append(chunk)
        }

        guard !firstLine.isEmpty else { return nil }
        guard let envelope = try? JSONDecoder().decode(SessionMetaEnvelope.self, from: firstLine) else {
            return nil
        }
        guard envelope.type == "session_meta" else { return nil }
        if let cwd = envelope.payload?.cwd, !cwd.isEmpty {
            return cwd
        }
        return nil
    }

    private func parseEventMessage(_ root: [String: Any], timestamp: Date?) -> SessionMessage? {
        guard (root["type"] as? String) == "event_msg",
              let payload = root["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else {
            return nil
        }

        if payloadType == "user_message",
           let message = normalizedText(payload["message"]) {
            return SessionMessage(role: .user, text: message, timestamp: timestamp)
        }
        if payloadType == "agent_message",
           let message = normalizedText(payload["message"]) {
            return SessionMessage(role: .assistant, text: message, timestamp: timestamp)
        }
        return nil
    }

    private func parseResponseItemMessage(_ root: [String: Any], timestamp: Date?) -> SessionMessage? {
        guard (root["type"] as? String) == "response_item",
              let payload = root["payload"] as? [String: Any],
              (payload["type"] as? String) == "message" else {
            return nil
        }

        let roleValue = (payload["role"] as? String) ?? ""
        let role: SessionMessageRole
        switch roleValue {
        case "user":
            role = .user
        case "assistant":
            role = .assistant
        default:
            role = .system
        }

        var parts: [String] = []
        if let contentItems = payload["content"] as? [[String: Any]] {
            for item in contentItems {
                if let text = normalizedText(item["text"]) {
                    parts.append(text)
                }
            }
        }
        guard !parts.isEmpty else { return nil }
        return SessionMessage(role: role, text: parts.joined(separator: "\n"), timestamp: timestamp)
    }

    private func normalizedText(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseTimestamp(_ raw: Any?) -> Date? {
        guard let value = raw as? String else { return nil }
        if let date = ISO8601DateFormatter.fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private func dedup(messages: [SessionMessage]) -> [SessionMessage] {
        var deduped: [SessionMessage] = []
        var lastKey: String?
        for message in messages {
            let key = "\(message.role.rawValue)|\(message.text)"
            if key == lastKey { continue }
            deduped.append(message)
            lastKey = key
        }
        return deduped
    }
}

private struct SessionIndexEntry: Decodable {
    let id: String
    let threadName: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case threadName = "thread_name"
        case updatedAt = "updated_at"
    }
}

private struct SessionMetaEnvelope: Decodable {
    let type: String
    let payload: SessionMetaPayload?
}

private struct SessionMetaPayload: Decodable {
    let cwd: String?
}

private extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithFractionalSeconds: Self = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if let date = ISO8601DateFormatter.fractional.date(from: value) {
            return date
        }
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO8601 date: \(value)"
        )
    }
}

private extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
