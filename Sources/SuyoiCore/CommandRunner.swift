import Foundation
import Darwin

public struct CommandRequest: Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let timeout: TimeInterval
    public let maximumOutputBytes: Int
    public let workingDirectory: URL?
    public let includeStandardUserPaths: Bool

    public init(executable: String, arguments: [String] = [], environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0"], timeout: TimeInterval = 5, maximumOutputBytes: Int = 4 * 1024 * 1024, workingDirectory: URL? = nil, includeStandardUserPaths: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.workingDirectory = workingDirectory
        self.includeStandardUserPaths = includeStandardUserPaths
    }
}

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool
    public let truncated: Bool
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }

    public init(exitCode: Int32, stdout: Data, stderr: Data, timedOut: Bool, truncated: Bool) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
        self.timedOut = timedOut; self.truncated = truncated
    }
}

public protocol CommandRunning: Sendable {
    func run(_ request: CommandRequest) throws -> CommandResult
}

public extension CommandRunning {
    func run(_ request: CommandRequest, workingDirectory: URL? = nil, includeStandardUserPaths: Bool = false) throws -> CommandResult {
        try run(CommandRequest(executable: request.executable, arguments: request.arguments,
                               environment: request.environment, timeout: request.timeout,
                               maximumOutputBytes: request.maximumOutputBytes,
                               workingDirectory: workingDirectory ?? request.workingDirectory,
                               includeStandardUserPaths: includeStandardUserPaths || request.includeStandardUserPaths))
    }
}

public struct CommandRunner: CommandRunning, Sendable {
    public init() {}
    public enum Error: Swift.Error { case relativeExecutable }

    public func run(_ request: CommandRequest) throws -> CommandResult {
        guard request.executable.hasPrefix("/") else { throw Error.relativeExecutable }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.workingDirectory
        if request.includeStandardUserPaths {
            process.environment?["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        try process.run()
        // Both pipes are drained in the same nonblocking loop. The limit is shared.
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = errors.fileHandleForReading.fileDescriptor
        _ = fcntl(outFD, F_SETFL, fcntl(outFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(errFD, F_SETFL, fcntl(errFD, F_GETFL) | O_NONBLOCK)
        var stdout = Data(), stderr = Data(), timedOut = false, truncated = false
        var outOpen = true, errOpen = true, stoppedAt: UInt64?
        let start = DispatchTime.now().uptimeNanoseconds
        let timeout = max(0, request.timeout.isFinite ? request.timeout : 5)
        let limit = max(0, request.maximumOutputBytes)
        func drain(_ fd: Int32, into data: inout Data, open: inout Bool, otherCount: Int) {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while open {
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    let remaining = max(0, limit - data.count - otherCount)
                    let keep = min(n, remaining)
                    if keep > 0 { data.append(contentsOf: buffer.prefix(keep)) }
                    if n > remaining { truncated = true; break }
                } else if n == 0 { open = false; break }
                else if errno == EINTR { continue }
                else { if errno != EAGAIN && errno != EWOULDBLOCK { open = false }; break }
            }
        }
        while true {
            drain(outFD, into: &stdout, open: &outOpen, otherCount: stderr.count)
            drain(errFD, into: &stderr, open: &errOpen, otherCount: stdout.count)
            let now = DispatchTime.now().uptimeNanoseconds
            if !timedOut && Double(now - start) / 1_000_000_000 >= timeout && process.isRunning { timedOut = true }
            if (timedOut || truncated) && stoppedAt == nil {
                stoppedAt = now
                if process.isRunning { process.terminate() }
            }
            if let stoppedAt, process.isRunning, now - stoppedAt > 200_000_000 {
                // This PID belongs to the Process created above, not an inventory PID.
                _ = kill(process.processIdentifier, SIGKILL)
            }
            if !process.isRunning {
                // A descendant may retain the descriptors; never wait indefinitely for it.
                if !outOpen && !errOpen { break }
                if stoppedAt == nil { stoppedAt = now }
                if let stoppedAt, now - stoppedAt > 200_000_000 { break }
            }
            usleep(2_000)
        }
        process.waitUntilExit()
        try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut, truncated: truncated)
    }
}
