import Foundation
import SQLite3

struct CodexSessionService {
    private let fileManager = FileManager.default
    private let codexRoot: URL
    private let activeRoot: URL
    private let archivedRoot: URL
    private let sessionIndexURL: URL
    private let stateDatabaseURL: URL
    private let globalStateURL: URL
    private let idRegex = try! NSRegularExpression(
        pattern: #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$"#,
        options: [.caseInsensitive]
    )

    init(codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")) {
        self.codexRoot = codexRoot
        self.activeRoot = codexRoot.appending(path: "sessions")
        self.archivedRoot = codexRoot.appending(path: "archived_sessions")
        self.sessionIndexURL = codexRoot.appending(path: "session_index.jsonl")
        self.stateDatabaseURL = codexRoot.appending(path: "state_5.sqlite")
        self.globalStateURL = codexRoot.appending(path: ".codex-global-state.json")
    }

    var codexRootURL: URL { codexRoot }

    func loadSessions() throws -> [CodexSession] {
        let index = try loadIndex()
        let threads = loadThreadLookup()
        let active = scanSessions(in: activeRoot, archived: false, index: index, threads: threads)
        let archived = scanSessions(in: archivedRoot, archived: true, index: index, threads: threads)
        return (active + archived).sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadProjects(including sessions: [CodexSession]) -> [CodexProject] {
        var paths = Set<String>()

        for path in loadSavedWorkspaceRoots() {
            paths.insert(path)
        }

        for session in sessions {
            if let projectPath = normalizedText(session.projectPath) {
                paths.insert(projectPath)
            }
        }

        return paths
            .map(CodexProject.init(path:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

    func removeSavedWorkspaceRoot(_ projectPath: String) throws -> Bool {
        guard fileManager.fileExists(atPath: globalStateURL.path),
              let normalizedProjectPath = normalizedText(projectPath) else {
            return false
        }

        let data = try Data(contentsOf: globalStateURL)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["electron-saved-workspace-roots"] as? [String] else {
            return false
        }

        let standardizedTarget = standardizedPath(normalizedProjectPath)
        let filteredRoots = roots.filter { standardizedPath($0) != standardizedTarget }
        guard filteredRoots.count != roots.count else { return false }

        json["electron-saved-workspace-roots"] = filteredRoots
        try writeGlobalState(json)
        return true
    }

    func renameSession(id: String, newTitle: String) throws {
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw NSError(domain: "codexStack", code: 1, userInfo: [NSLocalizedDescriptionKey: "Title cannot be empty"])
        }
        var changedCodexState = false
        var changedIndex = false

        if fileManager.fileExists(atPath: stateDatabaseURL.path) {
            changedCodexState = try updateThreadTitle(id: id, title: trimmedTitle)
        }

        guard fileManager.fileExists(atPath: sessionIndexURL.path) else {
            if changedCodexState { return }
            throw NSError(domain: "codexStack", code: 2, userInfo: [NSLocalizedDescriptionKey: "Session title store not found"])
        }

        let original = try String(contentsOf: sessionIndexURL, encoding: .utf8)
        let originalLines = original.split(whereSeparator: \.isNewline).map(String.init)
        guard !originalLines.isEmpty else {
            if changedCodexState { return }
            throw NSError(domain: "codexStack", code: 3, userInfo: [NSLocalizedDescriptionKey: "Session not found"])
        }

        var rewrittenLines: [String] = []
        for line in originalLines {
            guard let data = line.data(using: .utf8),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                rewrittenLines.append(line)
                continue
            }
            guard (json["id"] as? String) == id else {
                rewrittenLines.append(line)
                continue
            }

            json["thread_name"] = trimmedTitle
            if let rewrittenData = try? JSONSerialization.data(withJSONObject: json),
               let rewritten = String(data: rewrittenData, encoding: .utf8) {
                rewrittenLines.append(rewritten)
                changedIndex = true
            } else {
                rewrittenLines.append(line)
            }
        }

        guard changedCodexState || changedIndex else {
            throw NSError(domain: "codexStack", code: 3, userInfo: [NSLocalizedDescriptionKey: "Session not found in index"])
        }

        guard changedIndex else { return }
        let rewritten = rewrittenLines.joined(separator: "\n") + "\n"
        let tempURL = codexRoot.appending(path: "session_index.jsonl.tmp")
        try rewritten.write(to: tempURL, atomically: true, encoding: .utf8)
        _ = try fileManager.replaceItemAt(
            sessionIndexURL,
            withItemAt: tempURL,
            backupItemName: "session_index.backup-\(indexBackupSuffix()).jsonl",
            options: []
        )
    }

    func moveSessions(_ sessions: [CodexSession], toProjectPath projectPath: String?) throws {
        guard !sessions.isEmpty else { return }
        let normalizedProjectPath = normalizedText(projectPath)
        let ids = sessions.map(\.id)
        var changedCodexState = false
        var changedSessionFiles = false

        changedCodexState = try updateProjectlessThreadState(
            ids: ids,
            projectPath: normalizedProjectPath
        )

        if let normalizedProjectPath,
           fileManager.fileExists(atPath: stateDatabaseURL.path) {
            changedCodexState = try updateThreadProjectPath(
                ids: ids,
                projectPath: normalizedProjectPath
            ) || changedCodexState
        }

        if normalizedProjectPath != nil {
            for session in sessions {
                changedSessionFiles = try updateSessionFileProjectPath(
                    session.fileURL,
                    projectPath: normalizedProjectPath
                ) || changedSessionFiles
            }
        }

        guard changedCodexState || changedSessionFiles else {
            throw NSError(domain: "codexStack", code: 7, userInfo: [NSLocalizedDescriptionKey: "Session project store not found"])
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

    func countConversationMessages(for session: CodexSession) -> Int {
        loadConversationPreview(for: session, maxMessages: .max).count
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
        index: [String: SessionIndexEntry],
        threads: ThreadLookup
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
            let thread = threads.metadata(for: sessionID, fileURL: fileURL)
            let fileMetadata = readSessionFileMetadata(from: fileURL)
            let title = resolvedSessionTitle(threadTitle: thread?.title, indexTitle: metadata?.threadName)
            let updatedAt = thread?.updatedAt ?? metadata?.updatedAt ?? values?.contentModificationDate ?? .distantPast
            let size = Int64(values?.fileSize ?? 0)
            let projectPath = thread?.isProjectless == true ? nil : (normalizedText(thread?.cwd) ?? fileMetadata.projectPath)

            results.append(
                CodexSession(
                    id: sessionID,
                    title: title,
                    updatedAt: updatedAt,
                    fileURL: fileURL,
                    isArchived: archived,
                    sizeInBytes: size,
                    projectPath: projectPath,
                    usageTokens: 0,
                    usageCostUSD: 0
                )
            )
        }
        return results
    }

    private func loadThreadLookup() -> ThreadLookup {
        let projectlessThreadIDs = loadProjectlessThreadIDs()
        guard fileManager.fileExists(atPath: stateDatabaseURL.path) else {
            return ThreadLookup(entries: [], projectlessThreadIDs: projectlessThreadIDs)
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(stateDatabaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if database != nil {
                sqlite3_close(database)
            }
            return ThreadLookup(entries: [], projectlessThreadIDs: projectlessThreadIDs)
        }
        defer { sqlite3_close(database) }

        let sql = "SELECT id, rollout_path, title, cwd, updated_at FROM threads"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return ThreadLookup(entries: [], projectlessThreadIDs: projectlessThreadIDs)
        }
        defer { sqlite3_finalize(statement) }

        var entries: [ThreadMetadata] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqliteText(statement, 0) else { continue }
            let rolloutPath = sqliteText(statement, 1)
            let title = sqliteText(statement, 2)
            let cwd = sqliteText(statement, 3)
            let updatedAt = sqliteDateFromSeconds(statement, 4)
            entries.append(
                ThreadMetadata(
                    id: id,
                    rolloutPath: rolloutPath,
                    title: title,
                    cwd: cwd,
                    updatedAt: updatedAt,
                    isProjectless: projectlessThreadIDs.contains(id)
                )
            )
        }
        return ThreadLookup(entries: entries, projectlessThreadIDs: projectlessThreadIDs)
    }

    private func updateThreadTitle(id: String, title: String) throws -> Bool {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(stateDatabaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            defer {
                if database != nil {
                    sqlite3_close(database)
                }
            }
            throw NSError(domain: "codexStack", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not open Codex state database"])
        }
        defer { sqlite3_close(database) }

        let sql = "UPDATE threads SET title = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "codexStack", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not prepare title update"])
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, id, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "codexStack", code: 6, userInfo: [NSLocalizedDescriptionKey: "Could not update Codex title"])
        }
        return sqlite3_changes(database) > 0
    }

    private func updateThreadProjectPath(ids: [String], projectPath: String) throws -> Bool {
        guard !ids.isEmpty else { return false }
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(stateDatabaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            defer {
                if database != nil {
                    sqlite3_close(database)
                }
            }
            throw NSError(domain: "codexStack", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not open Codex state database"])
        }
        defer { sqlite3_close(database) }

        let sql = "UPDATE threads SET cwd = ? WHERE id = ?"
        var changed = false
        for id in ids {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw NSError(domain: "codexStack", code: 9, userInfo: [NSLocalizedDescriptionKey: "Could not prepare project update"])
            }

            sqlite3_bind_text(statement, 1, projectPath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, id, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement)
                throw NSError(domain: "codexStack", code: 10, userInfo: [NSLocalizedDescriptionKey: "Could not update Codex project"])
            }
            changed = changed || sqlite3_changes(database) > 0
            sqlite3_finalize(statement)
        }
        return changed
    }

    private func updateProjectlessThreadState(ids: [String], projectPath: String?) throws -> Bool {
        guard !ids.isEmpty,
              fileManager.fileExists(atPath: globalStateURL.path) else {
            return false
        }

        let data = try Data(contentsOf: globalStateURL)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        var changed = false
        var projectlessIDs = json["projectless-thread-ids"] as? [String] ?? []
        let idSet = Set(ids)

        if projectPath == nil {
            for id in ids where !projectlessIDs.contains(id) {
                projectlessIDs.append(id)
                changed = true
            }
        } else {
            let filtered = projectlessIDs.filter { !idSet.contains($0) }
            if filtered.count != projectlessIDs.count {
                projectlessIDs = filtered
                changed = true
            }

            if var hints = json["thread-workspace-root-hints"] as? [String: String] {
                for id in ids where hints.removeValue(forKey: id) != nil {
                    changed = true
                }
                json["thread-workspace-root-hints"] = hints
            }
        }

        guard changed else { return false }
        json["projectless-thread-ids"] = projectlessIDs
        try writeGlobalState(json)
        return true
    }

    private func updateSessionFileProjectPath(_ fileURL: URL, projectPath: String?) throws -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        let original = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return false }

        var changed = false
        let rewrittenLines = lines.map { line -> String in
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["type"] as? String) == "session_meta" else {
                return line
            }

            var payload = (root["payload"] as? [String: Any]) ?? [:]
            if let projectPath {
                guard (payload["cwd"] as? String) != projectPath else { return line }
                payload["cwd"] = projectPath
            } else {
                guard payload["cwd"] != nil else { return line }
                payload.removeValue(forKey: "cwd")
            }
            root["payload"] = payload

            guard let rewrittenData = try? JSONSerialization.data(withJSONObject: root),
                  let rewritten = String(data: rewrittenData, encoding: .utf8) else {
                return line
            }
            changed = true
            return rewritten
        }

        guard changed else { return false }
        try rewrittenLines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        return true
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

    private func loadSavedWorkspaceRoots() -> [String] {
        guard fileManager.fileExists(atPath: globalStateURL.path),
              let data = try? Data(contentsOf: globalStateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["electron-saved-workspace-roots"] as? [String] else {
            return []
        }

        var seen = Set<String>()
        var results: [String] = []
        for root in roots {
            guard let normalized = normalizedText(root) else { continue }
            let standardized = standardizedPath(normalized)
            guard !seen.contains(standardized) else { continue }
            seen.insert(standardized)
            results.append(standardized)
        }
        return results
    }

    private func loadProjectlessThreadIDs() -> Set<String> {
        guard fileManager.fileExists(atPath: globalStateURL.path),
              let data = try? Data(contentsOf: globalStateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = json["projectless-thread-ids"] as? [String] else {
            return []
        }
        return Set(ids.filter { !$0.isEmpty })
    }

    private func writeGlobalState(_ json: [String: Any]) throws {
        let rewritten = try JSONSerialization.data(withJSONObject: json, options: [])
        let tempURL = codexRoot.appending(path: ".codex-global-state.json.tmp")
        try rewritten.write(to: tempURL, options: .atomic)

        _ = try fileManager.replaceItemAt(
            globalStateURL,
            withItemAt: tempURL,
            backupItemName: ".codex-global-state.backup-\(indexBackupSuffix()).json",
            options: []
        )
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

    private func readSessionFileMetadata(from sessionFile: URL) -> SessionFileMetadata {
        guard let handle = try? FileHandle(forReadingFrom: sessionFile) else { return .empty }
        defer { try? handle.close() }

        let newline = UInt8(ascii: "\n")
        let maxBytes = 4 * 1024 * 1024
        let maxLines = 200

        var buffer = Data()
        var inspectedBytes = 0
        var inspectedLines = 0
        var metadata = SessionFileMetadata.empty

        while inspectedBytes < maxBytes,
              inspectedLines < maxLines,
              metadata.projectPath == nil {
            guard let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty else {
                break
            }
            inspectedBytes += chunk.count
            buffer.append(chunk)

            while inspectedLines < maxLines,
                  let newlineIndex = buffer.firstIndex(of: newline),
                  metadata.projectPath == nil {
                let line = buffer[..<newlineIndex]
                inspectSessionLine(Data(line), metadata: &metadata)
                buffer.removeSubrange(...newlineIndex)
                inspectedLines += 1
            }
        }

        if inspectedLines < maxLines,
           !buffer.isEmpty,
           metadata.projectPath == nil {
            inspectSessionLine(buffer, metadata: &metadata)
        }

        return metadata
    }

    private func inspectSessionLine(_ data: Data, metadata: inout SessionFileMetadata) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if metadata.projectPath == nil,
           (root["type"] as? String) == "session_meta",
           let payload = root["payload"] as? [String: Any],
           let cwd = normalizedText(payload["cwd"]) {
            metadata.projectPath = cwd
        }

    }

    private func resolvedSessionTitle(threadTitle: String?, indexTitle: String?) -> String {
        if let title = normalizedTitle(threadTitle), title != "Untitled" {
            return title
        }
        if let title = normalizedTitle(indexTitle), title != "Untitled" {
            return title
        }
        return "Untitled"
    }

    private func normalizedTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let title = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return title.isEmpty ? nil : title
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

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
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

private struct SessionFileMetadata {
    var projectPath: String?

    static let empty = SessionFileMetadata(projectPath: nil)
}

private struct ThreadMetadata {
    let id: String
    let rolloutPath: String?
    let title: String?
    let cwd: String?
    let updatedAt: Date?
    let isProjectless: Bool
}

private struct ThreadLookup {
    let byID: [String: ThreadMetadata]
    let byRolloutPath: [String: ThreadMetadata]
    let projectlessThreadIDs: Set<String>

    static let empty = ThreadLookup(entries: [], projectlessThreadIDs: [])

    init(entries: [ThreadMetadata], projectlessThreadIDs: Set<String>) {
        var byID: [String: ThreadMetadata] = [:]
        var byRolloutPath: [String: ThreadMetadata] = [:]
        for entry in entries {
            byID[entry.id] = entry
            if let rolloutPath = entry.rolloutPath {
                byRolloutPath[Self.standardizedPath(rolloutPath)] = entry
            }
        }
        self.byID = byID
        self.byRolloutPath = byRolloutPath
        self.projectlessThreadIDs = projectlessThreadIDs
    }

    func metadata(for id: String, fileURL: URL) -> ThreadMetadata? {
        if let metadata = byID[id] ?? byRolloutPath[Self.standardizedPath(fileURL.path)] {
            return metadata
        }
        guard projectlessThreadIDs.contains(id) else { return nil }
        return ThreadMetadata(
            id: id,
            rolloutPath: nil,
            title: nil,
            cwd: nil,
            updatedAt: nil,
            isProjectless: true
        )
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
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

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func sqliteText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, index) else { return nil }
    let text = String(cString: value)
    return text.isEmpty ? nil : text
}

private func sqliteDateFromSeconds(_ statement: OpaquePointer, _ index: Int32) -> Date? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    let seconds = sqlite3_column_int64(statement, index)
    guard seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(seconds))
}

private extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
