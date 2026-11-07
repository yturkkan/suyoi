import Foundation
import Darwin
import Testing
@testable import SuyoiCore

private struct StubReader: NativeProcessReading {
    let listed: [Int32]?
    let rows: [Int32: ObservedProcess]
    func pids() -> [Int32]? { listed }
    func process(pid: Int32, uid: Int) -> ObservedProcess? { rows[pid] }
}
private struct StubCommand: CommandRunning {
    let result: CommandResult
    func run(_ request: CommandRequest) throws -> CommandResult { result }
}
private func commandResult(_ code: Int32 = 0, _ stdout: String = "", _ stderr: String = "", timeout: Bool = false, truncated: Bool = false) -> CommandResult {
    CommandResult(exitCode: code, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), timedOut: timeout, truncated: truncated)
}
private func sample(_ pid: Int = 42, start: UInt64 = 10, cpu: UInt64 = 100) -> ObservedProcess {
    ObservedProcess(pid: pid, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 100, executable: "/bin/example", startTimeMicroseconds: start, cwd: "/tmp", footprintBytes: 100, cpuNanoseconds: cpu)
}

@Test func nativeCurrentProcess() throws {
    let result = NativeProcessInspector().inspectProcesses(uid: Int(getuid()))
    let current = try #require(result.value.first { $0.pid == Int(getpid()) })
    #expect(current.executable.hasPrefix("/"))
    #expect(current.cwd != nil)
    #expect((current.startTimeMicroseconds ?? 0) > 0)
    #expect((current.footprintBytes ?? 0) > 0)
}

@Test func processCPUUsesMatchingIdentityAndMonotonicSamples() {
    let first = sample()
    #expect(NativeProcessInspector.cpuPercent(previous: nil, identity: first.identity, cpu: 200, wall: 2000) == 0)
    let previous = (first.identity, UInt64(100), UInt64(1000))
    #expect(NativeProcessInspector.cpuPercent(previous: previous, identity: first.identity, cpu: 600, wall: 2000) == 50)
    #expect(NativeProcessInspector.cpuPercent(previous: previous, identity: sample(start: 11).identity, cpu: 600, wall: 2000) == 0)
    #expect(NativeProcessInspector.cpuPercent(previous: previous, identity: first.identity, cpu: 99, wall: 2000) == 0)
}

@Test func processVanishedAndEmptyTable() {
    let vanished = NativeProcessInspector(reader: StubReader(listed: [42, 43], rows: [42: sample()])).inspectProcesses(uid: 501)
    #expect(vanished.status == .partial)
    #expect(vanished.value.count == 1)
    let empty = NativeProcessInspector(reader: StubReader(listed: [], rows: [:])).inspectProcesses(uid: 501)
    #expect(empty.status == .complete && empty.value.isEmpty)
}

@Test func processFallbackAndFailure() {
    let command = StubCommand(result: commandResult(0, "42 1 501 2.0 5 /bin/example\n"))
    let inspector = NativeProcessInspector(reader: StubReader(listed: nil, rows: [42: sample()]), runner: command)
    let result = inspector.inspectProcesses(uid: 501)
    #expect(result.status == .partial && result.value.first?.footprintBytes == 100)
    let failure = NativeProcessInspector(reader: StubReader(listed: nil, rows: [:]), runner: StubCommand(result: commandResult(1, "", "failed"))).inspectProcesses(uid: 501)
    #expect(failure.status == .unavailable)
}

@Test func listenerOutcomes() {
    func inspect(_ result: CommandResult) -> Observation<[Listener]> { ListenerInspector(runner: StubCommand(result: result)).inspectListeners(uid: 501) }
    let valid = "p42\ncnode\nn127.0.0.1:3000\n"
    #expect(inspect(commandResult(0, valid)).status == .complete)
    #expect(inspect(commandResult(1)).status == .complete)
    #expect(inspect(commandResult(1, "", "error")).status == .unavailable)
    #expect(inspect(commandResult(0, valid, timeout: true)).status == .partial)
    #expect(inspect(commandResult(0, "", truncated: true)).status == .unavailable)
    #expect(inspect(commandResult(0, valid, "lsof: warning")).status == .partial)
}

@Test func nativePreservesInvocationAndCompleteness() {
    let invocation = AgentInvocation(agentName: "Codex", runtime: "node", entrypoint: "codex")
    let row = ObservedProcess(pid: 42, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0, executable: "node", startTimeMicroseconds: 1, agentInvocation: invocation)
    let result = NativeProcessInspector(reader: StubReader(listed: [42], rows: [42: row])).inspectProcesses(uid: 501)
    #expect(result.status == .complete)
    #expect(result.value.first?.agentInvocation == invocation)
    let unknown = ObservedProcess(pid: 42, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0, executable: "/bin/node")
    #expect(NativeProcessInspector(reader: StubReader(listed: [42], rows: [42: unknown])).inspectProcesses(uid: 501).status == .partial)
}
