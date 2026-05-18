import Foundation

struct ProviderSyncService {
    private let codexRoot: URL
    private let fileManager = FileManager.default
    
    init(codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")) {
        self.codexRoot = codexRoot
    }
    
    func sync() throws -> Int {
        let targetProvider = try getTargetProvider()
        let targetAccountID = try getTargetAccountID()
        
        var updatedCount = 0
        updatedCount += try syncSessions(in: codexRoot.appending(path: "sessions"), targetProvider: targetProvider, targetAccountID: targetAccountID)
        updatedCount += try syncSessions(in: codexRoot.appending(path: "archived_sessions"), targetProvider: targetProvider, targetAccountID: targetAccountID)
        
        try syncGlobalState(targetProvider: targetProvider, targetAccountID: targetAccountID)
        
        return updatedCount
    }
    
    private func getTargetProvider() throws -> String {
        let configURL = codexRoot.appending(path: "config.toml")
        guard fileManager.fileExists(atPath: configURL.path),
              let configContent = try? String(contentsOf: configURL, encoding: .utf8) else {
            return "openai"
        }
        
        for line in configContent.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("model_provider"),
               let equalsRange = trimmed.range(of: "=") {
                var value = String(trimmed[equalsRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                return value.isEmpty ? "openai" : value
            }
        }
        return "openai"
    }
    
    private func getTargetAccountID() throws -> String {
        let authURL = codexRoot.appending(path: "auth.json")
        guard fileManager.fileExists(atPath: authURL.path),
              let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        
        if let accountID = json["account_id"] as? String { return accountID }
        if let accountID = json["chatgpt_account_id"] as? String { return accountID }
        if let tokens = json["tokens"] as? [String: Any],
           let accountID = tokens["account_id"] as? String { return accountID }
        if let tokens = json["tokens"] as? [String: Any],
           let accountID = tokens["chatgpt_account_id"] as? String { return accountID }
        
        return ""
    }
    
    private func syncSessions(in directory: URL, targetProvider: String, targetAccountID: String) throws -> Int {
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        
        var updatedCount = 0
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            
            let original = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard !lines.isEmpty else { continue }
            
            var changed = false
            var rewrittenLines = lines
            
            for (index, line) in lines.enumerated() {
                guard !line.isEmpty,
                      let data = line.data(using: .utf8),
                      var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (root["type"] as? String) == "session_meta",
                      var payload = root["payload"] as? [String: Any] else {
                    continue
                }
                
                let currentProvider = (payload["provider"] as? String) ?? (payload["model_provider"] as? String) ?? ""
                let currentAccountID = (payload["account_id"] as? String) ?? ""
                
                if currentProvider != targetProvider {
                    payload["provider"] = targetProvider
                    payload["model_provider"] = targetProvider
                    changed = true
                }
                
                if !targetAccountID.isEmpty && currentAccountID != targetAccountID {
                    payload["account_id"] = targetAccountID
                    changed = true
                }
                
                if changed {
                    root["payload"] = payload
                    if let rewrittenData = try? JSONSerialization.data(withJSONObject: root, options: []),
                       let rewrittenString = String(data: rewrittenData, encoding: .utf8) {
                        rewrittenLines[index] = rewrittenString
                        break // Usually only one session_meta at the top
                    }
                }
            }
            
            if changed {
                let newContent = rewrittenLines.joined(separator: "\n")
                try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
                updatedCount += 1
            }
        }
        
        return updatedCount
    }
    
    private func syncGlobalState(targetProvider: String, targetAccountID: String) throws {
        let globalStateURL = codexRoot.appending(path: ".codex-global-state.json")
        guard fileManager.fileExists(atPath: globalStateURL.path),
              let data = try? Data(contentsOf: globalStateURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var workspaces = json["workspaces"] as? [[String: Any]] else {
            return
        }
        
        var changed = false
        for i in 0..<workspaces.count {
            let currentProvider = workspaces[i]["provider"] as? String ?? ""
            let currentAccountID = workspaces[i]["accountId"] as? String ?? ""
            
            if currentProvider != targetProvider {
                workspaces[i]["provider"] = targetProvider
                changed = true
            }
            if !targetAccountID.isEmpty && currentAccountID != targetAccountID {
                workspaces[i]["accountId"] = targetAccountID
                changed = true
            }
        }
        
        if changed {
            json["workspaces"] = workspaces
            let newData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            try newData.write(to: globalStateURL, options: .atomic)
        }
    }
}
