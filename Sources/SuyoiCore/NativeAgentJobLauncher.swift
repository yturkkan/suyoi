import Foundation

/// Starts a local child process. A successful return only confirms process creation.
public protocol NativeAgentJobLaunching: Sendable {
    func launch(executable: String, arguments: [String], workingDirectory: URL?) throws
}

public final class NativeAgentJobLauncher: NativeAgentJobLaunching, @unchecked Sendable {
    public enum Error: Swift.Error {
        case relativeExecutable
        case invalidWorkingDirectory
        case launchFailed
    }

    private let lock = NSLock()
    private var runningJobs: [UUID: Process] = [:]
    private let catalog: NativeSessionCatalog

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        catalog = NativeSessionCatalog(homeDirectory: homeDirectory)
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
        process.environment = Self.environment(for: executable, catalog: catalog)
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
    }

    static func environment(for executable: String, catalog: NativeSessionCatalog) -> [String: String] {
        var environment = [
            "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "GIT_OPTIONAL_LOCKS": "0"
        ]
        // Continue the same provider store that supplied the selected session.
        switch URL(fileURLWithPath: executable).lastPathComponent {
        case "codex":
            environment["CODEX_HOME"] = catalog.codexHome.path
            environment["CODEX_SQLITE_HOME"] = catalog.codexHome.path
        case "opencode":
            environment["OPENCODE_DB"] = catalog.openCodeDB.path
        default:
            break
        }
        return environment
    }

    private func release(_ id: UUID) {
        _ = lock.withLock { runningJobs.removeValue(forKey: id) }
    }
}
