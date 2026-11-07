import Foundation
import Testing
@testable import SuyoiCore

@Suite("Agent activity signals")
struct AgentActivityEvaluatorTests {
    func process(_ pid: Int = 1, parent: Int = 0, executable: String = "/bin/codex", cpu: Double = 0, tty: String? = nil, stopped: Bool = false) -> ObservedProcess {
        ObservedProcess(pid: pid, parentPID: parent, uid: 501, cpuPercent: cpu, residentBytes: 0, executable: executable, tty: tty, isStopped: stopped)
    }
    @Test func processAndChildSignals() {
        let evaluator = AgentActivityEvaluator(), home = URL(fileURLWithPath: "/nonexistent-suyoi-test")
        let stopped = process(cpu: 5, stopped: true)
        #expect(evaluator.evaluate(process: stopped, allProcesses: [stopped], homeDirectory: home).state == .stopped)
        let agent = process(tty: "ttys001")
        #expect(evaluator.evaluate(process: agent, allProcesses: [agent], homeDirectory: home).state == .waiting)
        let child = process(2, parent: 1, executable: "/usr/bin/git")
        #expect(evaluator.evaluate(process: agent, allProcesses: [agent, child], homeDirectory: home).state == .active)
        let stoppedChild = process(2, parent: 1, executable: "/usr/bin/git", stopped: true)
        #expect(evaluator.evaluate(process: agent, allProcesses: [agent, stoppedChild], homeDirectory: home).state == .waiting)
        let idle = process()
        #expect(evaluator.evaluate(process: idle, allProcesses: [idle], homeDirectory: home).state == .idle)
        let busy = process(cpu: 1)
        #expect(evaluator.evaluate(process: busy, allProcesses: [busy], homeDirectory: home).state == .active)
    }
    @Test func sessionMetadataTimestamp() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let result = AgentActivityEvaluator().evaluate(process: process(), allProcesses: [], homeDirectory: home, now: now)
        #expect(result.state == .active)
        #expect(result.detail == "Recent session state update")
        #expect(result.statusSource == .processOnly)
        let later = AgentActivityEvaluator().evaluate(process: process(), allProcesses: [], homeDirectory: home, now: now.addingTimeInterval(60))
        #expect(later.state == .idle)
    }
}
