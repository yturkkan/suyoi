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

    public init() {}

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
        process.environment = [
            "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "GIT_OPTIONAL_LOCKS": "0"
        ]
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

    private func release(_ id: UUID) {
        _ = lock.withLock { runningJobs.removeValue(forKey: id) }
    }
}
