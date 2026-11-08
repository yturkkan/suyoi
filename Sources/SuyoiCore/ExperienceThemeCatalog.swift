import Foundation
import Darwin

public enum SuyoiExperienceTheme: String, CaseIterable, Codable, Sendable {
    case nativeGlass = "Suyoi Glass"
    case macOSSystem = "macOS Native"
    case pixelArcade = "Pixel Arcade"
    case pixelOlive = "Game Boy Olive"
}

public enum SuyoiSurfaceMode: String, CaseIterable, Codable, Sendable {
    case menuBarPopover = "Menu Bar Popover"
    case notchIsland = "Notch Dynamic Island"
    case floatingBuddy = "Floating Companion"
}

public enum SuyoiAudioEvent: String, CaseIterable, Codable, Sendable {
    case sessionStarted = "Session Started"
    case attentionRequired = "Attention Required"
    case taskCompleted = "Task Completed"
    case taskError = "Task Error"
    case quotaWarning = "Quota Warning"
}

public enum SuyoiSoundMode: String, CaseIterable, Codable, Sendable {
    case muted = "Muted"
    case systemSounds = "macOS System Sounds"
    case soundPack = "OpenPeon Sound Pack"
}

public enum MascotAnimationState: String, Codable, Equatable, Sendable {
    case working, waitingForApproval, idle, completed, sleeping
}

public struct OpenPeonSoundPack: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let displayName: String
    public let directoryPath: String
    /// Validated paths relative to directoryPath; playback must revalidate before opening.
    public let eventSoundPaths: [SuyoiAudioEvent: String]

    public init(id: String, name: String, displayName: String, directoryPath: String, eventSoundPaths: [SuyoiAudioEvent: String]) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.directoryPath = directoryPath
        self.eventSoundPaths = eventSoundPaths
    }
}

public struct ThemeVisualTokens: Equatable, Sendable {
    public let theme: SuyoiExperienceTheme
    public let accentRed: Double
    public let accentGreen: Double
    public let accentBlue: Double
    public let usesMonospacedChrome: Bool
    public let cornerRadius: Double
    public let recommendedSoundMode: SuyoiSoundMode

    public init(theme: SuyoiExperienceTheme, accentRed: Double, accentGreen: Double, accentBlue: Double,
                usesMonospacedChrome: Bool, cornerRadius: Double, recommendedSoundMode: SuyoiSoundMode) {
        self.theme = theme
        self.accentRed = accentRed
        self.accentGreen = accentGreen
        self.accentBlue = accentBlue
        self.usesMonospacedChrome = usesMonospacedChrome
        self.cornerRadius = cornerRadius
        self.recommendedSoundMode = recommendedSoundMode
    }
}

public enum ExperienceThemeCatalog {
    public static func tokens(for theme: SuyoiExperienceTheme) -> ThemeVisualTokens {
        switch theme {
        case .nativeGlass:
            return ThemeVisualTokens(theme: theme, accentRed: 0.32, accentGreen: 0.65, accentBlue: 1,
                usesMonospacedChrome: false, cornerRadius: 18, recommendedSoundMode: .systemSounds)
        case .macOSSystem:
            return ThemeVisualTokens(theme: theme, accentRed: 0, accentGreen: 0.478, accentBlue: 1,
                usesMonospacedChrome: false, cornerRadius: 12, recommendedSoundMode: .systemSounds)
        case .pixelArcade:
            return ThemeVisualTokens(theme: theme, accentRed: 0.62, accentGreen: 0.45, accentBlue: 1,
                usesMonospacedChrome: true, cornerRadius: 4, recommendedSoundMode: .soundPack)
        case .pixelOlive:
            return ThemeVisualTokens(theme: theme, accentRed: 0.61, accentGreen: 0.73, accentBlue: 0.06,
                usesMonospacedChrome: true, cornerRadius: 2, recommendedSoundMode: .soundPack)
        }
    }

    /// Names accepted by NSSound; this lookup never plays audio or changes preferences.
    public static func systemSoundName(for event: SuyoiAudioEvent, theme: SuyoiExperienceTheme) -> String {
        switch event {
        case .sessionStarted:
            return theme == .pixelOlive ? "Pop" : "Tink"
        case .attentionRequired:
            return theme == .pixelOlive ? "Morse" : "Ping"
        case .taskCompleted:
            return theme == .pixelArcade ? "Hero" : "Glass"
        case .taskError:
            return "Basso"
        case .quotaWarning:
            return theme == .pixelOlive ? "Bottle" : "Sosumi"
        }
    }

    public static func mascotState(for agent: AgentObservation, hasPendingApproval: Bool = false) -> MascotAnimationState {
        // Completion is an explicit event, not something an idle observation can prove.
        // A stopped process takes precedence over stale activity or approval metadata.
        if agent.process.isStopped || agent.activityState == .stopped { return .sleeping }
        if hasPendingApproval { return .waitingForApproval }
        switch agent.activityState {
        case .active: return .working
        case .waiting: return .waitingForApproval
        case .idle, nil: return .idle
        case .stopped: return .sleeping
        }
    }

    /// Loads local CESP metadata only. Invalid entries are skipped; an unusable pack is nil.
    public static func loadSoundPack(at directoryURL: URL) -> OpenPeonSoundPack? {
        guard let directory = openDirectory(at: directoryURL) else { return nil }
        defer { close(directory) }
        guard let data = readManifest(in: directory),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = metadataString(json["name"]),
              let categories = json["categories"] as? [String: Any] else { return nil }

        // Prefer the dedicated session category, then fall back to acknowledgement.
        let mappings: [(SuyoiAudioEvent, [String])] = [
            (.sessionStarted, ["session.start", "task.acknowledge"]),
            (.attentionRequired, ["input.required"]),
            (.taskCompleted, ["task.complete"]),
            (.taskError, ["task.error"]),
            (.quotaWarning, ["resource.limit"])
        ]
        var paths: [SuyoiAudioEvent: String] = [:]
        for (event, categoryNames) in mappings {
            for categoryName in categoryNames {
                guard let category = categories[categoryName] as? [String: Any],
                      let sounds = category["sounds"] as? [Any] else { continue }
                for case let sound as [String: Any] in sounds {
                    guard let path = sound["file"] as? String,
                          isSafeAudioPath(path, in: directory) else { continue }
                    paths[event] = path
                    break
                }
                if paths[event] != nil { break }
            }
        }
        guard !paths.isEmpty else { return nil }
        let path = directoryURL.standardizedFileURL.path
        return OpenPeonSoundPack(id: path, name: name,
            displayName: metadataString(json["display_name"]) ?? name,
            directoryPath: path, eventSoundPaths: paths)
    }

    public static func discoverSoundPacks(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [OpenPeonSoundPack] {
        let roots = [".openpeon/packs", ".claude/hooks/peon-ping/packs"]
        var packs: [OpenPeonSoundPack] = []
        for relativeRoot in roots {
            let root = homeDirectory.appendingPathComponent(relativeRoot, isDirectory: true)
            guard let directory = openDirectory(at: root) else { continue }
            defer { close(directory) }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names.sorted() {
                if let pack = loadSoundPack(at: root.appendingPathComponent(name, isDirectory: true)) {
                    packs.append(pack)
                }
            }
        }
        return packs.sorted {
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.id < $1.id
        }
    }

    private static func metadataString(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf8.count <= 256 else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }

    /// Walk from the filesystem root with O_NOFOLLOW at every component.
    private static func openDirectory(at url: URL) -> Int32? {
        guard url.isFileURL, !url.path.utf8.contains(0) else { return nil }
        var normalizedPath = url.path
        if ["/var/", "/tmp/", "/etc/"].contains(where: { normalizedPath.hasPrefix($0) }) {
            normalizedPath = "/private" + normalizedPath
        }
        let components = normalizedPath.split(separator: "/").map(String.init)
        guard !components.contains("..") else { return nil }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        for component in components {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
        }
        return descriptor
    }

    private static func readManifest(in directory: Int32) -> Data? {
        let descriptor = openat(directory, "openpeon.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        let limit = 1_048_576
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= limit else { return nil }
        var bytes = [UInt8](repeating: 0, count: limit + 1)
        var count = 0
        while count < bytes.count {
            let amount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            }
            if amount == 0 { break }
            if amount < 0 {
                if errno == EINTR { continue }
                return nil
            }
            count += amount
        }
        guard count <= limit else { return nil }
        return Data(bytes.prefix(count))
    }

    private static func isSafeAudioPath(_ path: String, in directory: Int32) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let filename = components.last,
              ["wav", "mp3", "ogg", "aiff", "m4a", "caf"].contains((filename as NSString).pathExtension.lowercased()) else { return false }
        var parent = dup(directory)
        guard parent >= 0 else { return false }
        defer { close(parent) }
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return false }
            close(parent)
            parent = next
        }
        let file = openat(parent, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return false }
        defer { close(file) }
        var info = stat()
        return fstat(file, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}
