import Darwin
import Foundation

public enum ClaudeHookInstallStatus: Equatable, Sendable {
    case notInstalled
    case installed(command: String, includesPreToolUse: Bool)
    case outdated(currentCommand: String, expectedCommand: String)
    case blocked(reason: String)
}

public struct ClaudeHookPreview: Equatable, Sendable {
    public let settingsPath: String
    public let backupPath: String
    public let command: String
    public let events: [String]
    public let status: ClaudeHookInstallStatus

    public init(
        settingsPath: String,
        backupPath: String,
        command: String,
        events: [String],
        status: ClaudeHookInstallStatus
    ) {
        self.settingsPath = settingsPath
        self.backupPath = backupPath
        self.command = command
        self.events = events
        self.status = status
    }
}

/// Safely inspects, installs, updates, and removes Suyoi's `--hook-bridge` entries in `~/.claude/settings.json`
/// without clobbering unrelated Claude Code settings or third-party hooks.
public struct ClaudeHookInstaller: Sendable {
    public enum Error: Swift.Error, LocalizedError, Equatable {
        case invalidExecutablePath
        case unsafeSettingsLocation(String)
        case malformedSettingsJSON
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidExecutablePath:
                return "Invalid Suyoi executable path for hook bridge"
            case .unsafeSettingsLocation(let reason):
                return reason
            case .malformedSettingsJSON:
                return "Existing ~/.claude/settings.json is not a valid JSON object"
            case .writeFailed(let detail):
                return detail
            }
        }
    }

    public static let baseHookEvents = ["SessionStart", "SessionEnd", "Stop", "PermissionRequest"]
    private static let maxSettingsBytes = 512 * 1_024

    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public var claudeDirectoryURL: URL {
        homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    public var settingsFileURL: URL {
        claudeDirectoryURL.appendingPathComponent("settings.json", isDirectory: false)
    }

    public var backupFileURL: URL {
        claudeDirectoryURL.appendingPathComponent("settings.json.suyoi-backup", isDirectory: false)
    }

    public static func expectedCommand(bridgeExecutablePath: String) -> String? {
        guard bridgeExecutablePath.hasPrefix("/"),
              bridgeExecutablePath.utf8.count <= 4_096,
              !bridgeExecutablePath.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }) else {
            return nil
        }
        let quoted = "'" + bridgeExecutablePath.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        return "\(quoted) --hook-bridge"
    }

    public func preview(bridgeExecutablePath: String, includePreToolUse: Bool = false) -> ClaudeHookPreview? {
        guard let command = Self.expectedCommand(bridgeExecutablePath: bridgeExecutablePath) else { return nil }
        var events = Self.baseHookEvents
        if includePreToolUse {
            events.append("PreToolUse")
        }
        let status = inspectStatus(bridgeExecutablePath: bridgeExecutablePath)
        return ClaudeHookPreview(
            settingsPath: settingsFileURL.path,
            backupPath: backupFileURL.path,
            command: command,
            events: events,
            status: status
        )
    }

    public func inspectStatus(bridgeExecutablePath: String) -> ClaudeHookInstallStatus {
        guard let expected = Self.expectedCommand(bridgeExecutablePath: bridgeExecutablePath) else {
            return .blocked(reason: "Invalid Suyoi executable path")
        }
        do {
            guard let rootObject = try readExistingSettingsObjectIfPresent() else {
                return .notInstalled
            }
            guard let hooksDict = rootObject["hooks"] as? [String: Any] else {
                return .notInstalled
            }
            var discoveredCommands: [String] = []
            for eventName in Self.baseHookEvents + ["PreToolUse"] {
                for cmd in Self.extractHookBridgeCommands(in: hooksDict[eventName]) {
                    discoveredCommands.append(cmd)
                }
            }
            guard let firstFound = discoveredCommands.first else {
                return .notInstalled
            }
            let hasAllBaseEvents = Self.baseHookEvents.allSatisfy { event in
                Self.extractHookBridgeCommands(in: hooksDict[event]).contains(expected)
            }
            if hasAllBaseEvents && discoveredCommands.allSatisfy({ $0 == expected }) {
                let hasPreTool = Self.extractHookBridgeCommands(in: hooksDict["PreToolUse"]).contains(expected)
                return .installed(command: expected, includesPreToolUse: hasPreTool)
            }
            return .outdated(currentCommand: firstFound, expectedCommand: expected)
        } catch let err as Error {
            return .blocked(reason: err.errorDescription ?? "Cannot read ~/.claude/settings.json safely")
        } catch {
            return .blocked(reason: "Cannot read ~/.claude/settings.json safely")
        }
    }

    @discardableResult
    public func install(bridgeExecutablePath: String, includePreToolUse: Bool = false) throws -> ClaudeHookInstallStatus {
        guard let expected = Self.expectedCommand(bridgeExecutablePath: bridgeExecutablePath) else {
            throw Error.invalidExecutablePath
        }
        try ensureSafeClaudeDirectory()
        let existingRawData = try readRawSettingsDataIfPresent()
        var rootObject: [String: Any] = [:]
        if let existingRawData, !existingRawData.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: existingRawData) as? [String: Any] else {
                throw Error.malformedSettingsJSON
            }
            rootObject = parsed
        }

        var hooksDict = (rootObject["hooks"] as? [String: Any]) ?? [:]
        for key in Array(hooksDict.keys) {
            if let cleaned = Self.removingHookBridgeEntries(from: hooksDict[key]) {
                hooksDict[key] = cleaned
            } else {
                hooksDict.removeValue(forKey: key)
            }
        }

        var targetEvents = Self.baseHookEvents
        if includePreToolUse {
            targetEvents.append("PreToolUse")
        }

        let suyoiEntry: [String: Any] = [
            "hooks": [
                [
                    "type": "command",
                    "command": expected,
                    "timeout": 125
                ]
            ]
        ]

        for event in targetEvents {
            var eventArray = (hooksDict[event] as? [Any]) ?? []
            eventArray.append(suyoiEntry)
            hooksDict[event] = eventArray
        }
        rootObject["hooks"] = hooksDict

        try writeBackupAndSettings(existingData: existingRawData, updatedObject: rootObject)
        return .installed(command: expected, includesPreToolUse: includePreToolUse)
    }

    @discardableResult
    public func uninstall() throws -> ClaudeHookInstallStatus {
        guard let existingRawData = try readRawSettingsDataIfPresent() else {
            return .notInstalled
        }
        guard !existingRawData.isEmpty else {
            return .notInstalled
        }
        guard var rootObject = try? JSONSerialization.jsonObject(with: existingRawData) as? [String: Any] else {
            throw Error.malformedSettingsJSON
        }
        guard var hooksDict = rootObject["hooks"] as? [String: Any] else {
            return .notInstalled
        }
        for key in Array(hooksDict.keys) {
            if let cleaned = Self.removingHookBridgeEntries(from: hooksDict[key]) {
                hooksDict[key] = cleaned
            } else {
                hooksDict.removeValue(forKey: key)
            }
        }
        if hooksDict.isEmpty {
            rootObject.removeValue(forKey: "hooks")
        } else {
            rootObject["hooks"] = hooksDict
        }
        try writeBackupAndSettings(existingData: existingRawData, updatedObject: rootObject)
        return .notInstalled
    }

    // MARK: - Helpers

    private static func extractHookBridgeCommands(in rawEventValue: Any?) -> [String] {
        guard let items = rawEventValue as? [Any] else { return [] }
        var commands: [String] = []
        for item in items {
            guard let dict = item as? [String: Any] else { continue }
            if let cmd = dict["command"] as? String, isSuyoiBridgeCommand(cmd) {
                commands.append(cmd)
            }
            if let nestedHooks = dict["hooks"] as? [Any] {
                for nested in nestedHooks {
                    if let nestedDict = nested as? [String: Any],
                       let cmd = nestedDict["command"] as? String,
                       isSuyoiBridgeCommand(cmd) {
                        commands.append(cmd)
                    }
                }
            }
        }
        return commands
    }

    private static func removingHookBridgeEntries(from rawEventValue: Any?) -> [Any]? {
        guard let items = rawEventValue as? [Any] else { return nil }
        var kept: [Any] = []
        for item in items {
            guard var dict = item as? [String: Any] else {
                kept.append(item)
                continue
            }
            if let cmd = dict["command"] as? String, isSuyoiBridgeCommand(cmd) {
                continue
            }
            if let nestedHooks = dict["hooks"] as? [Any] {
                let filteredNested = nestedHooks.filter { nested in
                    guard let nestedDict = nested as? [String: Any],
                          let cmd = nestedDict["command"] as? String else {
                        return true
                    }
                    return !isSuyoiBridgeCommand(cmd)
                }
                if filteredNested.isEmpty {
                    continue
                }
                dict["hooks"] = filteredNested
            }
            kept.append(dict)
        }
        return kept.isEmpty ? nil : kept
    }

    private static func isSuyoiBridgeCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(" --hook-bridge") else { return false }
        let executablePart = String(trimmed.dropLast(" --hook-bridge".count))
        return executablePart.localizedCaseInsensitiveContains("/suyoi")
    }

    private func ensureSafeClaudeDirectory() throws {
        var homeStat = stat()
        guard lstat(homeDirectory.path, &homeStat) == 0,
              (homeStat.st_mode & S_IFMT) == S_IFDIR else {
            throw Error.unsafeSettingsLocation("Home directory is not a regular directory")
        }
        let claudePath = claudeDirectoryURL.path
        var dirStat = stat()
        if lstat(claudePath, &dirStat) == 0 {
            guard (dirStat.st_mode & S_IFMT) == S_IFDIR else {
                throw Error.unsafeSettingsLocation("~/.claude must be a regular directory (symlinks are blocked)")
            }
            guard dirStat.st_uid == getuid() else {
                throw Error.unsafeSettingsLocation("~/.claude is not owned by the current user")
            }
        } else {
            guard mkdir(claudePath, 0o700) == 0 else {
                throw Error.writeFailed("Could not create ~/.claude directory")
            }
        }
    }

    private func readExistingSettingsObjectIfPresent() throws -> [String: Any]? {
        guard let data = try readRawSettingsDataIfPresent(), !data.isEmpty else {
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.malformedSettingsJSON
        }
        return obj
    }

    private func readRawSettingsDataIfPresent() throws -> Data? {
        let claudePath = claudeDirectoryURL.path
        var dirStat = stat()
        if lstat(claudePath, &dirStat) == 0 {
            guard (dirStat.st_mode & S_IFMT) == S_IFDIR else {
                throw Error.unsafeSettingsLocation("~/.claude must not be a symlink")
            }
        } else {
            return nil
        }

        let settingsPath = settingsFileURL.path
        var fileStat = stat()
        guard lstat(settingsPath, &fileStat) == 0 else {
            if errno == ENOENT { return nil }
            throw Error.unsafeSettingsLocation("Could not inspect ~/.claude/settings.json")
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw Error.unsafeSettingsLocation("~/.claude/settings.json must be a regular file (symlinks are blocked)")
        }
        guard fileStat.st_uid == getuid() else {
            throw Error.unsafeSettingsLocation("~/.claude/settings.json is not owned by the current user")
        }
        guard fileStat.st_size <= Self.maxSettingsBytes else {
            throw Error.unsafeSettingsLocation("~/.claude/settings.json exceeds 512 KiB safety limit")
        }

        let fd = open(settingsPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw Error.unsafeSettingsLocation("Could not open ~/.claude/settings.json safely")
        }
        defer { close(fd) }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                throw Error.unsafeSettingsLocation("Failed while reading ~/.claude/settings.json")
            }
            if count == 0 { break }
            buffer.append(chunk, count: count)
            if buffer.count > Self.maxSettingsBytes {
                throw Error.unsafeSettingsLocation("~/.claude/settings.json exceeds 512 KiB safety limit")
            }
        }
        return buffer
    }

    private func writeBackupAndSettings(existingData: Data?, updatedObject: [String: Any]) throws {
        guard let formatted = try? JSONSerialization.data(
            withJSONObject: updatedObject,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw Error.writeFailed("Could not serialize updated Claude settings")
        }
        var payload = formatted
        payload.append(0x0A)

        if let existingData {
            var backupStat = stat()
            let backupExists = lstat(backupFileURL.path, &backupStat) == 0
            if backupExists && (backupStat.st_mode & S_IFMT) != S_IFREG {
                throw Error.unsafeSettingsLocation("Backup path ~/.claude/settings.json.suyoi-backup is not a regular file")
            }
            // Only write/refresh the backup when none exists yet or the existing file is clean of Suyoi hooks,
            // so toggling PreToolUse never overwrites the user's pre-Suyoi backup.
            let existingHasSuyoiHook: Bool = {
                guard let obj = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
                      let hooks = obj["hooks"] as? [String: Any] else { return false }
                return hooks.values.contains { !Self.extractHookBridgeCommands(in: $0).isEmpty }
            }()
            if !backupExists || !existingHasSuyoiHook {
                try writeDataAtomically(existingData, to: backupFileURL)
            }
            // Verify settings.json did not change on disk since we read existingData.
            let latestData = try readRawSettingsDataIfPresent()
            guard latestData == existingData else {
                throw Error.writeFailed("~/.claude/settings.json changed concurrently; please retry")
            }
        } else if FileManager.default.fileExists(atPath: settingsFileURL.path) {
            throw Error.writeFailed("~/.claude/settings.json appeared concurrently; please retry")
        }
        try writeDataAtomically(payload, to: settingsFileURL)
    }

    private func writeDataAtomically(_ data: Data, to destination: URL) throws {
        let tempName = ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)"
        let tempURL = destination.deletingLastPathComponent().appendingPathComponent(tempName, isDirectory: false)
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw Error.writeFailed("Could not create temporary file in ~/.claude")
        }
        var closed = false
        defer {
            if !closed { close(fd) }
            unlink(tempURL.path)
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if written <= 0 {
                    throw Error.writeFailed("Failed writing temporary settings file")
                }
                offset += written
            }
        }
        _ = fsync(fd)
        close(fd)
        closed = true
        guard rename(tempURL.path, destination.path) == 0 else {
            throw Error.writeFailed("Failed replacing \(destination.lastPathComponent)")
        }
    }
}
