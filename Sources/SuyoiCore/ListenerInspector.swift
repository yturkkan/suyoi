import Foundation

public struct ListenerInspector: ListenerInspecting {
    private let runner: any CommandRunning
    public init(runner: any CommandRunning = CommandRunner()) { self.runner = runner }
    public func inspectListeners(uid: Int) -> Observation<[Listener]> {
        let now = Date()
        do {
            let result = try runner.run(CommandRequest(executable: "/usr/sbin/lsof", arguments: ["-nP", "-a", "-u", String(uid), "-iTCP", "-sTCP:LISTEN", "-Fpcn"]))
            let listeners = InventoryParser.listeners(result.stdoutText)
            var warnings: [String] = []
            if result.timedOut { warnings.append("lsof timed out; listener results may be incomplete.") }
            if result.truncated { warnings.append("lsof output was truncated; listener results may be incomplete.") }
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stderr.isEmpty || result.stdoutText.contains("lsof:") { warnings.append("lsof reported a warning; listener results may be incomplete.") }
            if result.exitCode != 0 && !(result.exitCode == 1 && result.stdout.isEmpty && stderr.isEmpty) {
                warnings.append("lsof failed (exit \(result.exitCode)); listener results may be incomplete.")
            }
            let status: ObservationStatus = warnings.isEmpty ? .complete : (listeners.isEmpty ? .unavailable : .partial)
            return Observation(value: listeners, status: status, warnings: warnings, capturedAt: now)
        } catch {
            return Observation(value: [], status: .unavailable, warnings: ["Listener inspection unavailable: \(error.localizedDescription)"], capturedAt: now)
        }
    }
}
