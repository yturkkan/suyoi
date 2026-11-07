import Foundation
import Darwin

public struct OpenFileInspector: Sendable {
    private let runner: any CommandRunning
    public init(runner: any CommandRunning = CommandRunner()) { self.runner = runner }

    /// Explicit, potentially expensive recursive inspection. Callers can instead inject a
    /// cached/batch usage lookup into SafetyEvaluator and WorktreeInspector.
    public func checkPathInUse(_ path: String, uid: Int = Int(getuid())) -> UsageState {
        guard path.hasPrefix("/"), let result = try? runner.run(CommandRequest(
            executable: "/usr/sbin/lsof", arguments: ["-nP", "-a", "-u", String(uid), "+D", path, "-Fp"], timeout: 4
        )), !result.timedOut, !result.truncated, result.stderr.isEmpty else { return .unknown }
        if result.exitCode == 1 && result.stdout.isEmpty { return .clear }
        guard result.exitCode == 0 else { return .unknown }
        let lines = result.stdoutText.split(separator: "\n")
        guard !lines.isEmpty else { return .unknown }
        var pids: [Int] = []
        for line in lines {
            guard line.first == "p", let pid = Int(line.dropFirst()), pid > 0 else { return .unknown }
            pids.append(pid)
        }
        return pids.contains { $0 != Int(getpid()) } ? .inUse : .clear
    }
}
