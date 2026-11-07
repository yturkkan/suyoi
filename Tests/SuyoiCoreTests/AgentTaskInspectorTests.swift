import Foundation
import SQLite3
import Testing
@testable import SuyoiCore

@Suite("Bounded agent task metadata")
struct AgentTaskInspectorTests {
    private func process(_ name: String = "codex", pid: Int = 400, parent: Int = 1, cpu: Double = 0, stopped: Bool = false, cwd: String? = "/project") -> ObservedProcess {
        ObservedProcess(pid: pid, parentPID: parent, uid: 501, cpuPercent: cpu, residentBytes: 0, executable: "/bin/\(name)", startTimeMicroseconds: 100, cwd: cwd, isStopped: stopped)
    }
    private func inspect(_ fixture: QuotaFixture, name: String = "Codex", rows: [ObservedProcess] = [], now: Date = Date()) -> AgentTaskContext {
        AgentTaskInspector(homeDirectory: fixture.home).inspect(agentName: name, process: process(name == "OpenCode" ? "opencode" : "codex"), projectRoot: "/project", allProcesses: rows, now: now)
    }

    @Test func openCodeSessionAndPrioritizedTodo() throws {
        let f = try QuotaFixture(); defer { f.clean() }
        try f.write(Data(), to: ".local/share/opencode/opencode.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(f.home.appendingPathComponent(".local/share/opencode/opencode.db").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE session_v2 (id TEXT, title TEXT, directory TEXT, time_updated INTEGER);
        CREATE TABLE todo (session_id TEXT, status TEXT, content TEXT, position INTEGER, time_updated INTEGER);
        INSERT INTO session_v2 VALUES ('ses_safe', 'Build core', '/project', 100), ('other', 'Wrong project', '/elsewhere', 200);
        INSERT INTO todo VALUES ('ses_safe', 'pending', 'Later work', 0, 200), ('ses_safe', 'in_progress', 'Implement inspector', 1, 100);
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        let context = inspect(f, name: "OpenCode")
        #expect(context.sessionID == "ses_safe")
        #expect(context.sessionTitle == "Build core")
        #expect(context.currentTask == "Todo: Implement inspector")
        #expect(inspect(f, name: "OpenCode", rows: [process("opencode"), process("swift", pid: 401, parent: 400)]).currentTask == "Running: swift · Todo: Implement inspector")
        #expect(sqlite3_exec(db, "UPDATE todo SET status = 'completed' WHERE status = 'in_progress'", nil, nil, nil) == SQLITE_OK)
        #expect(inspect(f, name: "OpenCode").currentTask == "Next: Later work")
        #expect(sqlite3_exec(db, "UPDATE todo SET status = 'completed'", nil, nil, nil) == SQLITE_OK)
        #expect(inspect(f, name: "OpenCode").currentTask == nil)
    }

    @Test func codexStructuredTaskStatesAndRecognizerWiring() throws {
        let f = try QuotaFixture(); defer { f.clean() }
        let path = ".codex/sessions/2026/11/07/session.jsonl"
        let meta: [String: Any] = ["type": "session_meta", "payload": ["id": "safe-UUID_1", "cwd": "/project/.", "prompt": "PRIVATE"]]
        let started: [String: Any] = ["type": "event_msg", "payload": ["type": "task_started", "message": "PRIVATE"]]
        try f.write([meta, ["type": "response_item", "payload": ["message": "PRIVATE"]], started], to: path)
        let context = inspect(f)
        #expect(context.sessionID == "safe-UUID_1")
        #expect(context.sessionTitle == nil)
        #expect(context.currentTask == "Active turn in progress")
        let rows = [process(), process("swift", pid: 401, parent: 400)]
        #expect(inspect(f, rows: rows).currentTask == "Active turn · Running: swift")
        let observation = AgentRecognizer.observations(processes: rows, serverGroups: [], projectsByPath: [:], homeDirectory: f.home).first
        #expect(observation?.sessionID == context.sessionID)
        #expect(observation?.currentTask == "Active turn · Running: swift")
        for (state, expected) in [("task_complete", "Turn complete · waiting for prompt"), ("turn_aborted", "Turn aborted · waiting for prompt")] {
            try f.write([meta, started, ["type": "event_msg", "payload": ["type": state, "message": "PRIVATE"]]], to: path)
            #expect(inspect(f).currentTask == expected)
        }
        try f.write([["type": "session_meta", "payload": ["id": "safe-id", "cwd": "/other"]], started], to: path)
        #expect(inspect(f).sessionID == nil)
    }

    @Test func openCodeGenericDirectoryUsesLatestSession() throws {
        let f = try QuotaFixture(); defer { f.clean() }
        try f.write(Data(), to: ".local/share/opencode/opencode.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(f.home.appendingPathComponent(".local/share/opencode/opencode.db").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, """
        CREATE TABLE session_v2 (id TEXT, title TEXT, directory TEXT, idle_outcome TEXT, time_updated INTEGER);
        CREATE TABLE todo (session_id TEXT, status TEXT, content TEXT, position INTEGER, time_updated INTEGER);
        INSERT INTO session_v2 VALUES ('older', 'Older work', '/project', 'completed', 100), ('latest', 'Build core', '/workspace/Suyoi', 'completed', 200);
        """, nil, nil, nil) == SQLITE_OK)
        let inspector = AgentTaskInspector(homeDirectory: f.home)
        for cwd: String? in [nil, "/", f.home.path, f.home.path + "/."] {
            let agent = process("opencode", cwd: cwd)
            let context = inspector.inspect(agentName: "OpenCode", process: agent, projectRoot: nil, allProcesses: [agent])
            #expect(context.sessionID == "latest")
            #expect(context.sessionTitle == "Suyoi · Build core")
            #expect(context.currentTask == "Last turn: completed")
            let running = inspector.inspect(agentName: "OpenCode", process: agent, projectRoot: nil, allProcesses: [agent, process("swift", pid: 401, parent: 400)])
            #expect(running.currentTask == "Running: swift")
        }
        #expect(sqlite3_exec(db, "INSERT INTO todo VALUES ('latest', 'in_progress', 'Implement inspector', 0, 200)", nil, nil, nil) == SQLITE_OK)
        let context = inspector.inspect(agentName: "OpenCode", process: process("opencode", cwd: f.home.path), projectRoot: nil, allProcesses: [])
        #expect(context.currentTask == "Todo: Implement inspector")
        #expect(inspector.inspect(agentName: "OpenCode", process: process("opencode", cwd: f.home.path), projectRoot: "/project", allProcesses: []).sessionID == "older")
    }

    @Test func codexGenericDirectoryUsesLatestFileAndTaskState() throws {
        let f = try QuotaFixture(); defer { f.clean() }
        let older = ".codex/sessions/2026/11/07/older.jsonl"
        let latest = ".codex/sessions/2026/11/07/latest.jsonl"
        try f.write([["type": "session_meta", "payload": ["id": "older", "cwd": "/project"]]], to: older)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: f.home.appendingPathComponent(older).path)
        let meta: [String: Any] = ["type": "session_meta", "payload": ["id": "latest", "cwd": "/workspace/Suyoi", "prompt": "PRIVATE"]]
        let inspector = AgentTaskInspector(homeDirectory: f.home)
        for (state, expected, active) in [("task_started", "Active turn in progress", "Active turn"), ("task_complete", "Turn complete · waiting for prompt", "Turn complete"), ("turn_aborted", "Turn aborted · waiting for prompt", "Turn aborted")] {
            try f.write([meta, ["type": "event_msg", "payload": ["type": "task_started"]], ["type": "event_msg", "payload": ["type": state]], ["type": "response_item", "payload": ["text": "PRIVATE"]]], to: latest)
            for cwd: String? in [nil, "/", f.home.path, f.home.path + "/."] {
                let agent = process(cwd: cwd)
                let context = inspector.inspect(agentName: "Codex", process: agent, projectRoot: nil, allProcesses: [agent])
                #expect(context.sessionID == "latest")
                #expect(context.sessionTitle == "Suyoi session")
                #expect(context.currentTask == expected)
                #expect(inspector.inspect(agentName: "Codex", process: agent, projectRoot: nil, allProcesses: [agent, process("swift", pid: 401, parent: 400)]).currentTask == "\(active) · Running: swift")
            }
        }
        #expect(inspector.inspect(agentName: "Codex", process: process(cwd: f.home.path), projectRoot: "/project", allProcesses: []).sessionID == "older")
    }

    @Test func largeCodexFileReadsMetadataAndRecentStateWithinBudget() throws {
        let f = try QuotaFixture(); defer { f.clean() }
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"safe\",\"cwd\":\"/project\"}}\n"
        let ignored = "{\"type\":\"response_item\",\"payload\":{\"text\":\"PRIVATE\"}}\n"
        let tail = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
        try f.write(Data((meta + String(repeating: ignored, count: 10000) + tail).utf8), to: ".codex/sessions/2026/11/07/large.jsonl")
        #expect(inspect(f).sessionID == "safe")
        #expect(inspect(f).currentTask == "Active turn in progress")
    }

    @Test func activeChildrenAndSanitization() throws {
        let f = try QuotaFixture(); defer { f.clean() }
        #expect(inspect(f, rows: [process(), process("swift", pid: 401, parent: 400)]).currentTask == "Running: swift")
        #expect(inspect(f, rows: [process(), process("swift", pid: 401, parent: 400, stopped: true)]).currentTask == nil)
        #expect(inspect(f, rows: [process(), process("worker", pid: 401, parent: 400, cpu: 0.7)]).currentTask == "Running: worker")
        let context = AgentTaskContext(sessionID: "--unsafe", sessionTitle: "\n " + String(repeating: "x", count: 130), currentTask: "\0\n" + String(repeating: "t", count: 150))
        #expect(context.sessionID == nil)
        #expect(context.sessionTitle?.count == 100)
        #expect(context.currentTask?.count == 120)
        #expect(AgentTaskContext(sessionID: "abc/def").sessionID == nil)
        #expect(AgentTaskContext(sessionID: "é").sessionID == nil)
    }

    @Test func symlinkAndAmbiguousProjectFailClosed() throws {
        let f = try QuotaFixture(); defer { f.clean() }
        try f.write([["type": "session_meta", "payload": ["id": "safe", "cwd": "/project"]]], to: "elsewhere.jsonl")
        let path = f.home.appendingPathComponent(".codex/sessions/2026/11/07")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: path.appendingPathComponent("unsafe.jsonl"), withDestinationURL: f.home.appendingPathComponent("elsewhere.jsonl"))
        #expect(inspect(f).sessionID == nil)
        try f.write([["type": "session_meta", "payload": ["id": "safe", "cwd": "/project"]]], to: ".codex/sessions/2026/11/07/safe.jsonl")
        #expect(inspect(f, rows: [process(), process(pid: 402)]).sessionID == nil)
    }
}
