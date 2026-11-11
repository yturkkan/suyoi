import Darwin
import Foundation

/// Starts a local child process and verifies it does not immediately fail on startup.
public protocol NativeAgentJobLaunching: Sendable {
    func launch(executable: String, arguments: [String], workingDirectory: URL?) throws
}

public final class NativeAgentJobLauncher: NativeAgentJobLaunching, @unchecked Sendable {
    public enum Error: Swift.Error, Equatable {
        case relativeExecutable
        case invalidWorkingDirectory
        case launchFailed
        case startupExited(Int32)
    }

    private static let commonAllowedEnvironmentKeys: [String] = [
        "USER", "LOGNAME", "TMPDIR", "SHELL", "SSH_AUTH_SOCK",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
        "http_proxy", "https_proxy", "no_proxy",
        "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS"
    ]

    private static let userToolRelativeDirectories: [String] = [
        ".opencode/bin", ".local/bin", ".bun/bin", ".npm-global/bin",
        "Library/pnpm", ".volta/bin", ".asdf/shims", ".local/share/mise/shims"
    ]

    private let lock = NSLock()
    private var runningJobs: [UUID: Process] = [:]
    private let catalog: NativeSessionCatalog
    private let baseEnvironment: [String: String]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        catalog = NativeSessionCatalog(homeDirectory: homeDirectory)
        self.baseEnvironment = baseEnvironment
    }

    public func launch(executable: String, arguments: [String], workingDirectory: URL?) throws {
        guard executable.hasPrefix("/") else { throw Error.relativeExecutable }
        if let workingDirectory {
            var isDirectory: ObjCBool = false
            guard workingDirectory.isFileURL, workingDirectory.path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw Error.invalidWorkingDirectory }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = Self.environment(for: executable, catalog: catalog, baseEnvironment: baseEnvironment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Keep the handle until Foundation observes and reaps the child. Register
        // before launch so a quick exit cannot leave a finished handle behind.
        let id = UUID()
        process.terminationHandler = { [self] _ in release(id) }
        lock.withLock { runningJobs[id] = process }
        do {
            try process.run()
        } catch {
            release(id)
            throw Error.launchFailed
        }

        // Catch immediate CLI/auth/runtime startup failures without attaching blocking pipes.
        for _ in 0..<9 {
            if !process.isRunning {
                let status = process.terminationStatus
                release(id)
                if status != 0 {
                    throw Error.startupExited(status)
                }
                return
            }
            usleep(20_000)
        }
        if !process.isRunning {
            let status = process.terminationStatus
            release(id)
            if status != 0 {
                throw Error.startupExited(status)
            }
        }
    }

    static func environment(
        for executable: String,
        catalog: NativeSessionCatalog,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let standardPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existingUserPaths = userToolRelativeDirectories.compactMap { relative -> String? in
            let path = catalog.homeDirectory.appendingPathComponent(relative, isDirectory: true).path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return path
        }
        var environment: [String: String] = [
            "HOME": catalog.homeDirectory.path,
            "PATH": (existingUserPaths + standardPaths).joined(separator: ":"),
            "LC_ALL": "C",
            "GIT_OPTIONAL_LOCKS": "0"
        ]

        let toolName = URL(fileURLWithPath: executable).lastPathComponent
        let providerKeys: [String]
        switch toolName {
        case "codex":
            providerKeys = ["OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_ORG_ID"]
        case "opencode":
            providerKeys = [
                "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY",
                "GOOGLE_GENERATIVE_AI_API_KEY", "OPENROUTER_API_KEY"
            ]
        case "claude":
            providerKeys = [
                "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL",
                "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"
            ]
        default:
            providerKeys = []
        }

        for key in commonAllowedEnvironmentKeys + providerKeys {
            if let value = sanitizedEnvironmentValue(baseEnvironment[key]) {
                environment[key] = value
            }
        }

        // Continue the same provider store that supplied the selected session.
        switch toolName {
        case "codex":
            environment["CODEX_HOME"] = catalog.codexHome.path
            environment["CODEX_SQLITE_HOME"] = catalog.codexHome.path
        case "opencode":
            environment["OPENCODE_DB"] = catalog.openCodeDB.path
        case "claude":
            environment["CLAUDE_CONFIG_DIR"] = catalog.claudeHome.path
        default:
            break
        }
        return environment
    }

    private static func sanitizedEnvironmentValue(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 4_096,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return raw
    }

    private func release(_ id: UUID) {
        _ = lock.withLock { runningJobs.removeValue(forKey: id) }
    }
}
