import Darwin
import Foundation

public struct NativeContinuationMetadata: Equatable, Sendable {
    public let agentID: Int
    public let agentName: String
    public let sessionID: String
    public let projectPath: String

    public init(agentID: Int, agentName: String, sessionID: String, projectPath: String) {
        self.agentID = agentID
        self.agentName = agentName
        self.sessionID = sessionID
        self.projectPath = projectPath
    }
}

public struct NativeContinuationJob: Equatable, Identifiable, Sendable {
    public enum State: Equatable, Sendable {
        case running
        case completed
        case failed(exitCode: Int32)
        case cancelled
    }

    public let id: UUID
    public let agentID: Int
    public let agentName: String
    public let sessionID: String
    public let projectPath: String
    public let executableName: String
    public let pid: Int32
    public let startedAt: Date
    public var endedAt: Date?
    public var state: State

    public init(
        id: UUID,
        agentID: Int,
        agentName: String,
        sessionID: String,
        projectPath: String,
        executableName: String,
        pid: Int32,
        startedAt: Date,
        endedAt: Date? = nil,
        state: State = .running
    ) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.executableName = executableName
        self.pid = pid
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
    }
}

/// Starts a local child process and verifies it does not immediately fail on startup.
public protocol NativeAgentJobLaunching: Sendable {
    func launch(executable: String, arguments: [String], workingDirectory: URL?) throws
    @discardableResult
    func launch(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        metadata: NativeContinuationMetadata?
    ) throws -> UUID
}

public extension NativeAgentJobLaunching {
    @discardableResult
    func launch(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        metadata: NativeContinuationMetadata?
    ) throws -> UUID {
        try launch(executable: executable, arguments: arguments, workingDirectory: workingDirectory)
        return UUID()
    }
}

public final class NativeAgentJobLauncher: NativeAgentJobLaunching, @unchecked Sendable {
    public enum Error: Swift.Error, Equatable {
        case relativeExecutable
        case invalidWorkingDirectory
        case launchFailed
        case startupExited(Int32)
    }

    private struct ActiveEntry {
        let process: Process
        var job: NativeContinuationJob
        var wasCancelled: Bool = false
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

    private static let maxHistoryCount = 20

    private let lock = NSLock()
    private var runningJobs: [UUID: ActiveEntry] = [:]
    private var finishedJobs: [NativeContinuationJob] = []
    private var stateObserver: (@Sendable () -> Void)?
    private let catalog: NativeSessionCatalog
    private let baseEnvironment: [String: String]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        catalog = NativeSessionCatalog(homeDirectory: homeDirectory)
        self.baseEnvironment = baseEnvironment
    }

    public func setStateObserver(_ observer: (@Sendable () -> Void)?) {
        lock.withLock {
            stateObserver = observer
        }
    }

    public func activeJobs() -> [NativeContinuationJob] {
        lock.withLock {
            runningJobs.values.map(\.job).sorted { $0.startedAt > $1.startedAt }
        }
    }

    public func recentJobs() -> [NativeContinuationJob] {
        lock.withLock {
            let active = runningJobs.values.map(\.job).sorted { $0.startedAt > $1.startedAt }
            let finished = finishedJobs.sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
            return active + finished
        }
    }

    @discardableResult
    public func cancelJob(id: UUID) -> Bool {
        let target: (Process?, (@Sendable () -> Void)?) = lock.withLock {
            guard var entry = runningJobs[id] else { return (nil, nil) }
            entry.wasCancelled = true
            runningJobs[id] = entry
            return (entry.process, stateObserver)
        }
        guard let process = target.0 else { return false }
        if process.isRunning {
            process.terminate()
        }
        target.1?()
        return true
    }

    public func launch(executable: String, arguments: [String], workingDirectory: URL?) throws {
        _ = try launch(executable: executable, arguments: arguments, workingDirectory: workingDirectory, metadata: nil)
    }

    @discardableResult
    public func launch(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        metadata: NativeContinuationMetadata?
    ) throws -> UUID {
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

        let id = UUID()
        let startedAt = Date()
        let execName = URL(fileURLWithPath: executable).lastPathComponent
        let initialJob = NativeContinuationJob(
            id: id,
            agentID: metadata?.agentID ?? 0,
            agentName: metadata?.agentName ?? execName,
            sessionID: metadata?.sessionID ?? "",
            projectPath: metadata?.projectPath ?? workingDirectory?.path ?? "",
            executableName: execName,
            pid: 0,
            startedAt: startedAt,
            state: .running
        )

        process.terminationHandler = { [self] terminated in
            finalize(id: id, status: terminated.terminationStatus)
        }
        lock.withLock {
            runningJobs[id] = ActiveEntry(process: process, job: initialJob)
        }
        do {
            try process.run()
        } catch {
            removeWithoutHistory(id)
            throw Error.launchFailed
        }

        let launchedPID = process.processIdentifier
        let observerAfterLaunch: (@Sendable () -> Void)? = lock.withLock {
            if var entry = runningJobs[id] {
                entry.job = NativeContinuationJob(
                    id: entry.job.id,
                    agentID: entry.job.agentID,
                    agentName: entry.job.agentName,
                    sessionID: entry.job.sessionID,
                    projectPath: entry.job.projectPath,
                    executableName: entry.job.executableName,
                    pid: launchedPID,
                    startedAt: entry.job.startedAt,
                    state: .running
                )
                runningJobs[id] = entry
            }
            return stateObserver
        }
        observerAfterLaunch?()

        // Catch immediate CLI/auth/runtime startup failures without attaching blocking pipes.
        for _ in 0..<9 {
            if !process.isRunning {
                let status = process.terminationStatus
                finalize(id: id, status: status)
                if status != 0 {
                    throw Error.startupExited(status)
                }
                return id
            }
            usleep(20_000)
        }
        if !process.isRunning {
            let status = process.terminationStatus
            finalize(id: id, status: status)
            if status != 0 {
                throw Error.startupExited(status)
            }
        }
        return id
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

    private func removeWithoutHistory(_ id: UUID) {
        _ = lock.withLock { runningJobs.removeValue(forKey: id) }
    }

    private func finalize(id: UUID, status: Int32) {
        let observer: (@Sendable () -> Void)? = lock.withLock {
            guard let entry = runningJobs.removeValue(forKey: id) else { return nil }
            var completedJob = entry.job
            if completedJob.pid == 0 {
                completedJob = NativeContinuationJob(
                    id: completedJob.id,
                    agentID: completedJob.agentID,
                    agentName: completedJob.agentName,
                    sessionID: completedJob.sessionID,
                    projectPath: completedJob.projectPath,
                    executableName: completedJob.executableName,
                    pid: entry.process.processIdentifier,
                    startedAt: completedJob.startedAt,
                    state: .running
                )
            }
            completedJob.endedAt = Date()
            if entry.wasCancelled {
                completedJob.state = .cancelled
            } else if status == 0 {
                completedJob.state = .completed
            } else {
                completedJob.state = .failed(exitCode: status)
            }
            finishedJobs.removeAll { $0.id == id }
            finishedJobs.insert(completedJob, at: 0)
            if finishedJobs.count > Self.maxHistoryCount {
                finishedJobs.removeLast(finishedJobs.count - Self.maxHistoryCount)
            }
            return stateObserver
        }
        observer?()
    }
}
