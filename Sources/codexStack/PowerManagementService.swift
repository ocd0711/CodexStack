import Foundation

struct PowerManagementSnapshot: Sendable {
    var sleepDisabled: Bool?
    var displaySleepDisabled: Bool?
    var diskSleepDisabled: Bool?
    var wakeOnMagicPacketEnabled: Bool?
    var powerNapDisabled: Bool?
    var autoRestartEnabled: Bool?
    var restartAfterFreezeEnabled: Bool?
    var autoRestartAvailable: Bool
    var restartAfterFreezeRequiresAdmin: Bool

    var recommendedCount: Int {
        [
            sleepDisabled,
            displaySleepDisabled,
            diskSleepDisabled,
            wakeOnMagicPacketEnabled,
            powerNapDisabled,
            autoRestartEnabled,
            restartAfterFreezeEnabled
        ].filter { $0 == true }.count
    }

    var knownCount: Int {
        [
            sleepDisabled,
            displaySleepDisabled,
            diskSleepDisabled,
            wakeOnMagicPacketEnabled,
            powerNapDisabled,
            autoRestartEnabled,
            restartAfterFreezeEnabled
        ].filter { $0 != nil }.count
    }
}

enum PowerManagementScope: String, CaseIterable, Identifiable {
    case current, ac, battery, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .current: return "Current Power"
        case .ac: return "AC Power"
        case .battery: return "Battery Power"
        case .all: return "All Power Sources"
        }
    }
}

enum PowerManagementService {
    private static var keepAwakeProcess: Process?
    private static let restrictedReadCacheQueue = DispatchQueue(label: "dev.codexstack.power-management.restricted-read-cache")
    private static var restrictedReadCache: [String: String] = [:]

    static func loadSnapshot(scope: PowerManagementScope = .current) -> PowerManagementSnapshot {
        makeSnapshot(scope: scope, authorizeRestrictedReads: false)
    }

    static func loadSnapshotWithAuthorizedReads(scope: PowerManagementScope = .current) -> PowerManagementSnapshot {
        makeSnapshot(scope: scope, authorizeRestrictedReads: true)
    }

    private static func makeSnapshot(scope: PowerManagementScope, authorizeRestrictedReads: Bool) -> PowerManagementSnapshot {
        let activePowerSource = parseActivePowerSource(output: run("/usr/bin/pmset", arguments: ["-g", "ps"]))
        let capabilities = parsePMSetCapabilities(output: run("/usr/bin/pmset", arguments: ["-g", "cap"]))
        let restartAfterFreezeOutput = systemSetupReadOutput(arguments: ["-getrestartfreeze"], authorizeIfNeeded: authorizeRestrictedReads)
        let pmsetValues = parsePMSet(
            output: run("/usr/bin/pmset", arguments: ["-g", "custom"]),
            preferredPowerSource: powerSourceName(for: scope, activePowerSource: activePowerSource)
        )
        return PowerManagementSnapshot(
            sleepDisabled: pmsetValues["sleep"].map { $0 == 0 },
            displaySleepDisabled: pmsetValues["displaysleep"].map { $0 == 0 },
            diskSleepDisabled: pmsetValues["disksleep"].map { $0 == 0 },
            wakeOnMagicPacketEnabled: pmsetValues["womp"].map { $0 == 1 },
            powerNapDisabled: pmsetValues["powernap"].map { $0 == 0 },
            autoRestartEnabled: pmsetValues["autorestart"].map { $0 == 1 },
            restartAfterFreezeEnabled: parseSystemSetupOn(
                restartAfterFreezeOutput
            ),
            autoRestartAvailable: capabilities.contains("autorestart") || pmsetValues["autorestart"] != nil,
            restartAfterFreezeRequiresAdmin: needsAdmin(restartAfterFreezeOutput)
        )
    }

    static func snapshotAfterApplyingRecommendedSettings(scope: PowerManagementScope = .current) -> PowerManagementSnapshot {
        var snapshot = loadSnapshot(scope: scope)
        snapshot.restartAfterFreezeEnabled = true
        snapshot.restartAfterFreezeRequiresAdmin = false
        return snapshot
    }

    static func applyRecommendedSettings(scope: PowerManagementScope = .all) throws {
        let flag = pmsetFlag(for: scope)
        var commands = [
            "/usr/bin/pmset \(flag) sleep 0 displaysleep 0 disksleep 0",
            "/usr/bin/pmset \(flag) womp 1",
            "/usr/bin/pmset \(flag) powernap 0"
        ]
        if supportsPMSetKey("autorestart") {
            commands.append("/usr/bin/pmset \(flag) autorestart 1")
        }
        commands.append("/usr/sbin/systemsetup -setrestartfreeze on")
        let script = """
        do shell script "\(commands.joined(separator: "; "))" with administrator privileges
        """
        try executePrivilegedScript(script)
        cacheSystemSetupOutput("Restart After Freeze: On", arguments: ["-getrestartfreeze"])
    }

    static func applyDisabledSettings(scope: PowerManagementScope = .all) throws {
        let flag = pmsetFlag(for: scope)
        var commands = [
            "/usr/bin/pmset \(flag) sleep 20 displaysleep 10 disksleep 10",
            "/usr/bin/pmset \(flag) womp 0",
            "/usr/bin/pmset \(flag) powernap 1"
        ]
        if supportsPMSetKey("autorestart") {
            commands.append("/usr/bin/pmset \(flag) autorestart 0")
        }
        commands.append("/usr/sbin/systemsetup -setrestartfreeze off")
        let script = """
        do shell script "\(commands.joined(separator: "; "))" with administrator privileges
        """
        try executePrivilegedScript(script)
        cacheSystemSetupOutput("Restart After Freeze: Off", arguments: ["-getrestartfreeze"])
    }

    static func applyPMSetSetting(key: String, value: Int, scope: PowerManagementScope) throws {
        let script = """
        do shell script "/usr/bin/pmset \(pmsetFlag(for: scope)) \(key) \(value)" with administrator privileges
        """
        try executePrivilegedScript(script)
    }

    static func applyRestartAfterFreeze(enabled: Bool) throws {
        let script = """
        do shell script "/usr/sbin/systemsetup -setrestartfreeze \(enabled ? "on" : "off")" with administrator privileges
        """
        try executePrivilegedScript(script)
        cacheSystemSetupOutput("Restart After Freeze: \(enabled ? "On" : "Off")", arguments: ["-getrestartfreeze"])
    }

    private static func executePrivilegedScript(_ script: String) throws {
        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw NSError(domain: "codexStack", code: 201, userInfo: [NSLocalizedDescriptionKey: "Could not create authorization script"])
        }
        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Could not update power settings"
            throw NSError(domain: "codexStack", code: 202, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func executePrivilegedScriptWithOutput(_ script: String) throws -> String {
        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw NSError(domain: "codexStack", code: 201, userInfo: [NSLocalizedDescriptionKey: "Could not create authorization script"])
        }
        let descriptor = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Could not read power settings"
            throw NSError(domain: "codexStack", code: 203, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return descriptor.stringValue ?? ""
    }

    private static func systemSetupReadOutput(arguments: [String], authorizeIfNeeded: Bool) -> String {
        let output = run("/usr/sbin/systemsetup", arguments: arguments)
        guard authorizeIfNeeded, needsAdmin(output) else {
            return output
        }
        if let cachedOutput = cachedSystemSetupOutput(arguments: arguments) {
            return cachedOutput
        }
        do {
            let command = (["/usr/sbin/systemsetup"] + arguments).joined(separator: " ")
            let authorizedOutput = try executePrivilegedScriptWithOutput("""
            do shell script "\(command)" with administrator privileges
            """)
            cacheSystemSetupOutput(authorizedOutput, arguments: arguments)
            return authorizedOutput
        } catch {
            return output
        }
    }

    private static func cachedSystemSetupOutput(arguments: [String]) -> String? {
        let key = systemSetupCacheKey(arguments: arguments)
        return restrictedReadCacheQueue.sync {
            restrictedReadCache[key]
        }
    }

    private static func cacheSystemSetupOutput(_ output: String, arguments: [String]) {
        let key = systemSetupCacheKey(arguments: arguments)
        restrictedReadCacheQueue.sync {
            restrictedReadCache[key] = output
        }
    }

    private static func systemSetupCacheKey(arguments: [String]) -> String {
        arguments.joined(separator: " ")
    }

    static func lockScreenKeepingAwake() throws {
        try startKeepAwakeUntilQuit()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
        process.arguments = ["-suspend"]
        try process.run()
    }

    private static func pmsetFlag(for scope: PowerManagementScope) -> String {
        switch scope {
        case .current:
            return parseActivePowerSource(output: run("/usr/bin/pmset", arguments: ["-g", "ps"])) == "Battery Power" ? "-b" : "-c"
        case .ac:
            return "-c"
        case .battery:
            return "-b"
        case .all:
            return "-a"
        }
    }

    private static func supportsPMSetKey(_ key: String) -> Bool {
        let capabilities = parsePMSetCapabilities(output: run("/usr/bin/pmset", arguments: ["-g", "cap"]))
        if capabilities.contains(key) {
            return true
        }
        let customValues = parsePMSet(output: run("/usr/bin/pmset", arguments: ["-g", "custom"]), preferredPowerSource: nil)
        return customValues[key] != nil
    }

    private static func run(_ launchPath: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private static func startKeepAwakeUntilQuit() throws {
        if keepAwakeProcess?.isRunning == true {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-ims", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        try process.run()
        keepAwakeProcess = process
    }

    private static func parseActivePowerSource(output: String) -> String? {
        let pattern = #"Now drawing from '([^']+)'"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[range])
    }

    private static func powerSourceName(for scope: PowerManagementScope, activePowerSource: String?) -> String? {
        switch scope {
        case .current:
            return activePowerSource
        case .ac:
            return "AC Power"
        case .battery:
            return "Battery Power"
        case .all:
            return nil
        }
    }

    private static func parsePMSetCapabilities(output: String) -> Set<String> {
        var capabilities: Set<String> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasSuffix(":") {
                continue
            }
            capabilities.insert(trimmed)
        }
        return capabilities
    }

    private static func parsePMSet(output: String, preferredPowerSource: String?) -> [String: Int] {
        var sectionValues: [String: [String: Int]] = [:]
        var currentSection: String?
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":") {
                currentSection = String(trimmed.dropLast())
                continue
            }

            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let value = Int(parts[1]) else {
                continue
            }
            let section = currentSection ?? "default"
            sectionValues[section, default: [:]][String(parts[0])] = value
        }

        if let preferredPowerSource,
           let preferredValues = sectionValues[preferredPowerSource] {
            return preferredValues
        }
        if preferredPowerSource == nil {
            var merged: [String: Set<Int>] = [:]
            for values in sectionValues.values {
                for (key, value) in values {
                    merged[key, default: []].insert(value)
                }
            }
            return merged.reduce(into: [:]) { result, item in
                if item.value.count == 1 {
                    result[item.key] = item.value.first
                }
            }
        }
        if let defaultValues = sectionValues["default"] {
            return defaultValues
        }
        return sectionValues.values.first ?? [:]
    }

    private static func parseSystemSetupOn(_ output: String) -> Bool? {
        let lowercased = output.lowercased()
        if lowercased.contains(": on") { return true }
        if lowercased.contains(": off") { return false }
        return nil
    }

    private static func needsAdmin(_ output: String) -> Bool {
        output.lowercased().contains("administrator access")
    }
}
