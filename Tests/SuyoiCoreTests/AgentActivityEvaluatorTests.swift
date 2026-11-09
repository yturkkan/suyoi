import Foundation
import Testing
@testable import SuyoiCore

@Suite("Agent activity signals")
struct AgentActivityEvaluatorTests {
    func process(_ pid: Int = 1, parent: Int = 0, executable: String = "/bin/codex", cpu: Double = 0, tty: String? = nil, stopped: Bool = false) -> ObservedProcess {
        ObservedProcess(pid: pid, parentPID: parent, uid: 501, cpuPercent: cpu, residentBytes: 0, executable: executable, tty: tty, isStopped: stopped)
    }
    @Test func processAndChildSignals() {
        let evaluator = AgentActivityEvaluator()
        let stopped = process(cpu: 5, stopped: true)
        #expect(evaluator.evaluate(process: stopped, allProcesses: [stopped]).state == .stopped)
        let agent = process(tty: "ttys001")
        #expect(evaluator.evaluate(process: agent, allProcesses: [agent]).state == .idle)
        let child = process(2, parent: 1, executable: "/usr/bin/git")
        #expect(evaluator.evaluate(process: agent, allProcesses: [agent, child]).state == .active)
        let stoppedChild = process(2, parent: 1, executable: "/usr/bin/git", stopped: true)
        #expect(evaluator.evaluate(process: agent, allProcesses: [agent, stoppedChild]).state == .idle)
        let idle = process()
        #expect(evaluator.evaluate(process: idle, allProcesses: [idle]).state == .idle)
        let busy = process(cpu: 1)
        #expect(evaluator.evaluate(process: busy, allProcesses: [busy]).state == .active)
    }
    @Test func unrelatedSessionMetadataDoesNotMarkAProcessActive() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let agent = process(42)
        let result = try #require(AgentRecognizer.observations(
            processes: [agent], serverGroups: [], projectsByPath: [:], homeDirectory: home
        ).first)
        #expect(result.activityState == .idle)
        #expect(result.lastActivityAt == nil)
        #expect(result.statusSource == .processOnly)
    }
}
