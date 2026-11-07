import Foundation

public struct AgentCacheCatalog: Sendable {
    public init() {}

    static let locations: [(String, String)] = [
        (".codex/cache", "Codex"), (".codex/log", "Codex"),
        (".claude/cache", "Claude Code"), (".claude/downloads", "Claude Code"), (".claude/debug", "Claude Code"),
        (".cursor/cache", "Cursor"), ("Library/Application Support/Cursor/Cache", "Cursor"),
        ("Library/Application Support/Cursor/Code Cache", "Cursor"), ("Library/Application Support/Cursor/GPUCache", "Cursor"),
        ("Library/Application Support/Cursor/CachedData", "Cursor"),
        (".cache/opencode", "OpenCode"), (".local/share/opencode/log", "OpenCode"), (".gemini/tmp", "Gemini CLI"),
        (".npm/_cacache", "npm"), ("Library/Caches/Yarn", "Yarn"), ("Library/Caches/pnpm", "pnpm"),
        (".bun/install/cache", "Bun"), ("Library/Caches/ms-playwright", "Playwright"), (".cache/puppeteer", "Puppeteer"),
        ("Library/Caches/com.openai.codex", "Codex"),
        ("Library/Caches/Codex", "Codex"),
        (".cache/codex-runtimes", "Codex"),
        ("Library/Caches/ai.opencode.desktop.ShipIt", "OpenCode"),
        ("Library/Caches/@opencodedesktop-updater", "OpenCode"),
        ("Library/Caches/com.google.antigravity", "Antigravity"),
        ("Library/Application Support/Antigravity/Cache", "Antigravity"),
        ("Library/Application Support/Antigravity/Code Cache", "Antigravity"),
        ("Library/Application Support/Antigravity/GPUCache", "Antigravity"),
        ("Library/Application Support/Antigravity/CachedData", "Antigravity"),
        ("Library/Application Support/Code/Cache", "VS Code"),
        ("Library/Application Support/Code/Code Cache", "VS Code"),
        ("Library/Application Support/Code/GPUCache", "VS Code"),
        ("Library/Application Support/Code/CachedData", "VS Code"),
        ("Library/Application Support/Windsurf/Cache", "Windsurf"),
        ("Library/Application Support/Windsurf/Code Cache", "Windsurf"),
        ("Library/Application Support/Windsurf/CachedData", "Windsurf"),
        ("Library/Caches/@deepseek-aidsh-desktop-updater", "DeepSeek"),
        (".cache/huggingface", "HuggingFace"),
        (".cache/uv", "uv"),
        ("Library/Caches/uv", "uv"),
        ("Library/Caches/pip", "pip"),
        ("Library/Caches/node-gyp", "node-gyp"),
        ("Library/Caches/electron", "Electron"),
        ("Library/Caches/Homebrew", "Homebrew"),
        ("Library/Developer/Xcode/DerivedData", "Xcode DerivedData"),
        ("Library/Developer/CoreSimulator/Caches", "CoreSimulator"),
        ("Library/Caches/org.swift.swiftpm", "SwiftPM"),
        ("Library/Caches/CocoaPods", "CocoaPods"),
        (".cargo/registry/cache", "Cargo"),
        (".gradle/caches", "Gradle")
    ]
    private static let forbidden = [
        ".codex/sessions", ".codex/archived_sessions", ".claude/projects", ".claude/file-history", ".claude/settings.json",
        "Library/Application Support/Cursor/User", ".cursor/User", ".gemini/settings.json", ".ssh", ".gnupg"
    ]

    public static func isForbiddenPath(_ path: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let home = homeDirectory.standardizedFileURL.path
        let value = path.standardizedFileURL.path
        guard value.hasPrefix(home == "/" ? "/" : home + "/") else { return true }
        let relative = String(value.dropFirst(home == "/" ? 1 : home.count + 1))
        let components = relative.lowercased().split(separator: "/").map(String.init)
        let sensitiveNames: Set<String> = ["sessions", "archived_sessions", "transcripts", "transcript", "history", "file-history", "prompts", "secrets", "credentials", "config", "configs", "settings.json", ".env", ".ssh", ".gnupg"]
        let sensitiveExtensions: Set<String> = ["db", "sqlite", "sqlite3", "jsonl", "pem", "key"]
        return forbidden.contains { relative == $0 || relative.hasPrefix($0 + "/") }
            || components.enumerated().contains { index, component in
                component == "projects" && components.prefix(index).contains { $0.hasPrefix(".") }
            }
            || components.contains { sensitiveNames.contains($0) || sensitiveExtensions.contains(($0 as NSString).pathExtension) }
    }

    /// Heavy downloads, runtime state, virtual environments and unrecognized cache roots
    /// merit explicit review even when their contents are regenerable.
    public static func isHighImpactCachePath(_ path: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let value = url.path
        let home = homeDirectory.standardizedFileURL
        let heavyRoots = [".cache/huggingface", ".cache/uv", "Library/Developer/CoreSimulator"]
            .map { home.appendingPathComponent($0).standardizedFileURL.path }
        if heavyRoots.contains(where: { value == $0 || value.hasPrefix($0 + "/") }) { return true }
        if [".venv", "venv"].contains(url.lastPathComponent) { return true }
        let cacheRoot = home.appendingPathComponent(".cache").path
        guard value.hasPrefix(cacheRoot + "/") else { return false }
        let childName = String(value.dropFirst(cacheRoot.count + 1).split(separator: "/")[0])
        let child = home.appendingPathComponent(".cache").appendingPathComponent(childName)
        return !locations.contains { home.appendingPathComponent($0.0).standardizedFileURL == child }
    }

    public func scanAgentCaches(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, entryLimit: Int = 100_000, timeLimit: TimeInterval = 10) -> (candidates: [CleanupCandidate], warnings: [String], partial: Bool) {
        let reader = FileMetadataReader()
        let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeLimit)
        guard entryLimit > 0, timeLimit > 0 else { return ([], ["Scan stopped at its time or entry budget. Results are partial."], true) }
        var found: [(URL, String)] = []
        var discoveryPartial = false
        for (path, name) in Self.locations {
            guard ProcessInfo.processInfo.systemUptime < deadline else { discoveryPartial = true; break }
            let url = home.appendingPathComponent(path)
            guard !Self.isForbiddenPath(url, homeDirectory: home), reader.canonicalPath(url, relativeTo: home) != nil,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            found.append((url, name))
        }
        let cacheRoot = home.appendingPathComponent(".cache")
        if reader.canonicalPath(cacheRoot, relativeTo: home) != nil,
           let children = try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            for childURL in children {
                guard ProcessInfo.processInfo.systemUptime < deadline else { discoveryPartial = true; break }
                let child = childURL.standardizedFileURL
                guard !Self.isForbiddenPath(child, homeDirectory: home),
                      reader.canonicalPath(child, relativeTo: home) != nil,
                      let metadata = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      metadata.isDirectory == true, metadata.isSymbolicLink != true else { continue }
                let path = child.standardizedFileURL.path
                guard !found.contains(where: {
                    let existing = $0.0.standardizedFileURL.path
                    return path == existing || path.hasPrefix(existing + "/") || existing.hasPrefix(path + "/")
                }) else { continue }
                found.append((child, child.lastPathComponent))
            }
        }
        var remaining = entryLimit
        var candidates: [CleanupCandidate] = []
        var warnings: [String] = []
        var partial = discoveryPartial
        for (index, item) in found.enumerated() {
            let count = found.count - index
            let slice = max(remaining / count, min(remaining, 25_000))
            let now = ProcessInfo.processInfo.systemUptime
            let sliceDeadline = now + max(0, deadline - now) / Double(count)
            let pre = reader.identity(at: item.0)
            let measurement = reader.measure(item.0, entryLimit: entryLimit >= 1_000_000 ? remaining : slice, deadline: entryLimit >= 1_000_000 ? deadline : sliceDeadline, excluding: { Self.isForbiddenPath($0, homeDirectory: home) })
            let post = reader.identity(at: item.0)
            let itemPartial = measurement.partial || pre == nil || pre != post
            remaining -= measurement.entries
            warnings.append(contentsOf: measurement.warnings)
            partial = partial || itemPartial
            candidates.append(CleanupCandidate(path: item.0.path, category: "Agent/developer cache", bytes: measurement.bytes, partial: itemPartial, scope: .agentCache, allocatedBytes: measurement.allocatedAvailable ? measurement.allocatedBytes : nil, fileIdentity: pre == post ? post : nil, agentName: item.1))
        }
        if partial { warnings.append("Scan stopped at its time or entry budget or could not inspect all entries. Results are partial.") }
        return (candidates, warnings, partial)
    }
}
