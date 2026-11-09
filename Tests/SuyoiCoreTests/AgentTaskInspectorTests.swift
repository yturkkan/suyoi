import Foundation
import Darwin
import SQLite3
import Testing
@testable import SuyoiCore

@Suite("Bounded agent task metadata")
struct AgentTaskInspectorTests {
    private let rollout = ".codex/sessions/2026/11/07/rollout-safe-id.jsonl"

    private func process(_ name: String = "codex", pid: Int = 400, parent: Int = 1,
                         uid: Int = Int(getuid()), cpu: Double = 0, stopped: Bool = false,
                         cwd: String? = "/project") -> ObservedProcess {
        ObservedProcess(pid: pid, parentPID: parent, uid: uid, cpuPercent: cpu, residentBytes: 0,
            executable: "/bin/\(name)", startTimeMicroseconds: 100, cwd: cwd, isStopped: stopped)
    }

    private func meta(cwd: String = "/project") -> [String: Any] {
        ["type": "session_meta", "payload": ["id": "safe-id", "cwd": cwd, "prompt": "PRIVATE"]]
    }

    private func state(_ value: String) -> [String: Any] {
        ["type": "event_msg", "payload": ["type": value, "message": "PRIVATE"]]
    }

    private func evidence(at file: URL) throws -> SessionFileEvidence {
        let fd = SessionFileEvidence.openRegular(file)
        try #require(fd >= 0)
        defer { close(fd) }
        let identity = try #require(SessionFileEvidence.readIdentity(fd, uid: Int(getuid())))
        return SessionFileEvidence(url: file, identity: identity)
    }

    @Test func structuredCodexTaskStatesRequireExactLiveFile() throws {
        let f = try QuotaFixture(); defer { f.clean() }
        let row = process()
        let child = process("swift", pid: 401, parent: 400)
        let unrelated = process("codex", pid: 405, parent: row.parentPID)
        let records = [meta(cwd: "/project/."), state("task_started")]
        try f.write(records, to: rollout)
        try f.write([meta(cwd: "/other"), state("task_complete")], to: ".codex/sessions/2026/11/08/other.jsonl")
        let file = try evidence(at: f.home.appendingPathComponent(rollout))
        let inspector = AgentTaskInspector(homeDirectory: f.home, liveFile: { process, _ in
            process.identity == row.identity ? file : nil
        })

        let started = inspector.inspect(agentName: "Codex", process: row, projectRoot: "/project", allProcesses: [row, child, unrelated])
        #expect(started.sessionID == "safe-id")
        #expect(started.currentTask == "Active turn · Running: swift")
        #expect(inspector.inspect(agentName: "Codex", process: unrelated, projectRoot: "/project",
                                  allProcesses: [row, unrelated]).sessionID == nil)

        for (value, expected) in [("task_complete", "Turn complete · waiting for prompt"), ("turn_aborted", "Turn aborted · waiting for prompt")] {
            try f.write(records + [state(value)], to: rollout)
            #expect(inspector.inspect(agentName: "Codex", process: row, projectRoot: "/project", allProcesses: [row]).currentTask == expected)
        }
        try f.write([meta(cwd: "/other"), state("task_started")], to: rollout)
        #expect(inspector.inspect(agentName: "Codex", process: row, projectRoot: "/project", allProcesses: [row]).sessionID == nil)
    }

    @Test func historicalRecordsCannotAttachToSiblingOrGenericDirectoryRows() throws {
        let f = try QuotaFixture(); defer { f.clean() }
        try f.write([meta(), state("task_started")], to: rollout)
        for cwd: String? in ["/project", nil, "/", f.home.path] {
            let first = process(pid: 510, parent: 9, cwd: cwd)
            let second = process(pid: 511, parent: 9, cwd: cwd)
            let rows = AgentRecognizer.observations(processes: [first, second], serverGroups: [], projectsByPath: [:], homeDirectory: f.home)
            #expect(rows.count == 2)
            #expect(rows.allSatisfy { $0.sessionID == nil && $0.sessionTitle == nil && $0.currentTask == nil })
        }
    }

    @Test func openCodeAndGeminiStorageDoNotSupplyLiveRowMetadata() throws {
        let f = try QuotaFixture(); defer { f.clean() }
        try f.write(Data(), to: ".local/share/opencode/opencode.db")
        var db: OpaquePointer?
        try #require(sqlite3_open(f.home.appendingPathComponent(".local/share/opencode/opencode.db").path, &db) == SQLITE_OK)
        defer { if let db { sqlite3_close(db) } }
        try #require(sqlite3_exec(db, """
            CREATE TABLE session_v2 (id TEXT, title TEXT, directory TEXT, time_updated INTEGER);
            CREATE TABLE todo (session_id TEXT, status TEXT, content TEXT, position INTEGER, time_updated INTEGER);
            INSERT INTO session_v2 VALUES ('ses_other', 'Other work', '/project', 100);
            INSERT INTO todo VALUES ('ses_other', 'in_progress', 'Other task', 1, 100);
            """, nil, nil, nil) == SQLITE_OK)
        try f.write([["sessionId": "gem-other", "cwd": "/project"]], to: ".gemini/sessions/gem-other.jsonl")
        let inspector = AgentTaskInspector(homeDirectory: f.home)
        for (name, executable) in [("OpenCode", "opencode"), ("Gemini CLI", "gemini")] {
            let row = process(executable)
            let running = process("swift", pid: 401, parent: row.pid)
            let context = inspector.inspect(agentName: name, process: row, projectRoot: "/project", allProcesses: [row, running])
            #expect(context.sessionID == nil && context.sessionTitle == nil)
            #expect(context.currentTask == "Running: swift")
        }
    }

    @Test func largeCodexFileReadsVerifiedMetadataAndRecentStateWithinBudget() throws {
        let f = try QuotaFixture(); defer { f.clean() }
        let header = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"safe-id\",\"cwd\":\"/project\"}}\n"
        let ignored = "{\"type\":\"response_item\",\"payload\":{\"text\":\"PRIVATE\"}}\n"
        let tail = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
        try f.write(Data((header + String(repeating: ignored, count: 10000) + tail).utf8), to: rollout)
        let file = try evidence(at: f.home.appendingPathComponent(rollout))
        let inspector = AgentTaskInspector(homeDirectory: f.home, liveFile: { _, _ in file })
        let context = inspector.inspect(agentName: "Codex", process: process(), projectRoot: "/project", allProcesses: [])
        #expect(context.sessionID == "safe-id")
        #expect(context.currentTask == "Active turn in progress")
    }

    @Test func activeChildrenAndSanitization() throws {
        let f = try QuotaFixture(); defer { f.clean() }
        let inspector = AgentTaskInspector(homeDirectory: f.home)
        let row = process()
        for (child, task) in [
            (process("swift", pid: 401, parent: 400), "Running: swift"),
            (process("swift", pid: 401, parent: 400, uid: Int(getuid()) + 1), nil),
            (process("swift", pid: 401, parent: 400, stopped: true), nil),
            (process("worker", pid: 401, parent: 400, cpu: 0.7), "Running: worker")
        ] {
            #expect(inspector.inspect(agentName: "Codex", process: row, projectRoot: "/project", allProcesses: [row, child]).currentTask == task)
        }
        let context = AgentTaskContext(sessionID: "--unsafe", sessionTitle: "\n " + String(repeating: "x", count: 130), currentTask: "\0\n" + String(repeating: "t", count: 150))
        #expect(context.sessionID == nil)
        #expect(context.sessionTitle?.count == 100)
        #expect(context.currentTask?.count == 120)
        #expect(AgentTaskContext(sessionID: "abc/def").sessionID == nil)
        #expect(AgentTaskContext(sessionID: "é").sessionID == nil)
    }

    @Test func exactWritableDescriptorRequiresOneOpenSessionFile() throws {
        let f = try QuotaFixture(); defer { f.clean() }
        try f.write([meta(), state("task_started")], to: rollout)
        let other = ".codex/sessions/2026/11/07/rollout-other.jsonl"
        try f.write([meta(), state("task_started")], to: other)
        let file = f.home.appendingPathComponent(rollout)
        let base = f.home.appendingPathComponent(".codex/sessions")
        let selfProcess = try #require(DarwinProcessReader().process(pid: getpid(), uid: Int(getuid())))
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        #expect(SessionFileEvidence.live(for: selfProcess, beneath: base) == nil)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        let expected = try evidence(at: file)
        let actual = try #require(SessionFileEvidence.live(for: selfProcess, beneath: base))
        #expect(actual.identity == expected.identity)
        #expect(SessionFileEvidence.filesystemPath(actual.url) == SessionFileEvidence.filesystemPath(file))
        let second = try FileHandle(forWritingTo: f.home.appendingPathComponent(other))
        defer { try? second.close() }
        #expect(SessionFileEvidence.live(for: selfProcess, beneath: base) == nil)
    }

    @Test func replacedAndSymlinkRolloutsFailClosed() throws {
        let f = try QuotaFixture(); defer { f.clean() }
        try f.write([meta(), state("task_started")], to: rollout)
        let url = f.home.appendingPathComponent(rollout)
        let file = try evidence(at: url)
        let inspector = AgentTaskInspector(homeDirectory: f.home, liveFile: { _, _ in file })
        let source = try Data(contentsOf: url)
        try source.write(to: url, options: .atomic)
        #expect(inspector.inspect(agentName: "Codex", process: process(), projectRoot: "/project", allProcesses: []).sessionID == nil)
        let moved = url.deletingLastPathComponent().appendingPathComponent("other.jsonl")
        try FileManager.default.moveItem(at: url, to: moved)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: moved)
        #expect(inspector.inspect(agentName: "Codex", process: process(), projectRoot: "/project", allProcesses: []).sessionID == nil)
    }
}
