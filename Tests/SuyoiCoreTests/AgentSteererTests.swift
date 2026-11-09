import Foundation
import Darwin
import SQLite3
import Testing
@testable import SuyoiCore

private final class SteeringRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CommandRequest] = []
    let result: CommandResult
    init(exit: Int32 = 0, timeout: Bool = false, stdout: String = "PRIVATE OUTPUT") {
        result = CommandResult(exitCode: exit, stdout: Data(stdout.utf8), stderr: Data("PRIVATE ERROR".utf8), timedOut: timeout, truncated: false)
    }
    var requests: [CommandRequest] { lock.lock(); defer { lock.unlock() }; return storage }
    func run(_ request: CommandRequest) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }; storage.append(request); return result
    }
}

private final class SteeringLauncher: NativeAgentJobLaunching, @unchecked Sendable {
    struct Request {
        let executable: String
        let arguments: [String]
        let workingDirectory: URL?
    }

    private let lock = NSLock()
    private var storage: [Request] = []
    private let fails: Bool

    init(fails: Bool = false) { self.fails = fails }

    var requests: [Request] { lock.withLock { storage } }

    func launch(executable: String, arguments: [String], workingDirectory: URL?) throws {
        lock.withLock {
            storage.append(Request(executable: executable, arguments: arguments, workingDirectory: workingDirectory))
        }
        if fails { throw NSError(domain: "PRIVATE LAUNCH ERROR", code: 1) }
    }
}

private func foregroundBSDInfo() -> proc_bsdinfo {
    var info = proc_bsdinfo()
    info.pbi_pid = 400
    info.pbi_uid = 501
    info.pbi_ruid = 501
    info.pbi_start_tvusec = 100
    info.pbi_status = UInt32(SSLEEP)
    info.pbi_flags = UInt32(PROC_FLAG_CONTROLT)
    info.e_tdev = 17
    info.pbi_pgid = 400
    info.e_tpgid = 400
    return info
}

private final class ForegroundReads: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [proc_bsdinfo?]
    init(_ snapshots: [proc_bsdinfo?]) { self.snapshots = snapshots }
    func next() -> proc_bsdinfo? {
        lock.lock(); defer { lock.unlock() }
        return snapshots.isEmpty ? nil : snapshots.removeFirst()
    }
}

@Suite("Explicit agent steering safety")
struct AgentSteererTests {
    private func process(pid: Int = 400, start: UInt64? = 100, tty: String? = nil, uid: Int = 501, stopped: Bool = false, cwd: String? = "/project",
                         executable: String = "/bin/codex", invocation: AgentInvocation? = nil) -> ObservedProcess {
        ObservedProcess(pid: pid, parentPID: 1, uid: uid, cpuPercent: 0, residentBytes: 0, executable: executable,
                        startTimeMicroseconds: start, cwd: cwd, tty: tty, isStopped: stopped, agentInvocation: invocation)
    }
    private func agent(_ name: String = "Codex", process: ObservedProcess? = nil, terminal: String? = nil, session: String? = "session-1") -> AgentObservation {
        let p = process ?? self.process()
        return AgentObservation(id: p.pid, agentName: name, process: p, project: nil, terminalApp: terminal, statusSource: .processOnly, childServerPorts: [], sessionID: session)
    }
    private func steerer(
        _ runner: SteeringRunner,
        live: ObservedProcess,
        foreground: TerminalForegroundVerifier? = nil,
        launcher: SteeringLauncher = SteeringLauncher()
    ) -> AgentSteerer {
        AgentSteerer(processLookup: { _, _ in live }, runner: runner, executableResolver: { "/tools/\($0)" },
                     nativeJobLauncher: launcher,
                     terminalForegroundVerifier: foreground ?? terminalVerifier())
    }

    private func terminalVerifier(
        metadata: @escaping @Sendable (Int32) -> proc_bsdinfo? = { _ in foregroundBSDInfo() },
        members: [Int32]? = [400],
        deviceNumber: UInt32? = 17,
        currentUID: Int = 501
    ) -> TerminalForegroundVerifier {
        TerminalForegroundVerifier(bsdInfo: { $0 == 400 ? metadata($0) : nil },
                                   groupMembers: { $0 == 400 ? members : nil },
                                   ttyDevice: { $0 == "/dev/ttys001" ? deviceNumber : nil },
                                   currentUID: { currentUID })
    }
    private func codexTarget(in fixture: QuotaFixture, for row: AgentObservation) throws -> NativeSessionTarget {
        let id = "4fa50a5b-6037-477d-899b-98257d4e707b"
        let project = fixture.home.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try fixture.write([["type": "session_meta", "payload": ["id": id, "cwd": project.path]]],
                          to: ".codex/sessions/2026/11/07/rollout-2026-11-07T10-30-00-\(id).jsonl")
        return try #require(AgentTaskInspector(homeDirectory: fixture.home).nativeSessionTargets(for: row).first)
    }

    @Test func selectsModesAndRejectsUnsafeMetadata() {
        #expect(AgentSteerer.preferredMode(for: agent()) == nil)
        #expect(AgentSteerer.preferredMode(for: agent("OpenCode")) == nil)
        #expect(AgentSteerer.preferredMode(for: agent(process: process(tty: "ttys001"), terminal: "Terminal")) == .terminalTTY)
        #expect(AgentSteerer.preferredMode(for: agent(process: process(tty: "/dev/ttys001"), terminal: "iTerm2")) == .terminalTTY)
        #expect(!AgentSteerer.canSteer(agent("Claude Code", session: nil)))
        #expect(!AgentSteerer.canSteer(agent(process: process(start: nil))))
        for id in ["--help", "-session", "bad/id", "bad\nID", "é", "", String(repeating: "a", count: 97)] {
            #expect(!AgentSteerer.canSteer(agent(session: id)))
            let runner = SteeringRunner(), launcher = SteeringLauncher()
            let steerer = steerer(runner, live: process(), launcher: launcher)
            #expect(!steerer.steer(agent: agent(session: id), prompt: "hello", uid: 501).succeeded)
            #expect(runner.requests.isEmpty && launcher.requests.isEmpty)
        }
        for tty in ["/dev/ttys001;evil", "../../tty", "tty", "ttys001\n"] { #expect(!AgentSteerer.isValidTTY(tty)) }
    }

    @Test func identityAndTTYReverificationFailuresNeverLaunch() {
        for live in [process(pid: 401), process(start: 101), process(uid: 502)] {
            let runner = SteeringRunner(), launcher = SteeringLauncher()
            let steerer = steerer(runner, live: live, launcher: launcher)
            #expect(!steerer.steer(agent: agent(), prompt: "hello", uid: 501).succeeded)
            #expect(runner.requests.isEmpty && launcher.requests.isEmpty)
        }
        let runner = SteeringRunner()
        let target = agent(process: process(tty: "ttys001"), terminal: "Terminal")
        #expect(!steerer(runner, live: process(tty: "ttys002")).steer(agent: target, prompt: "hello", uid: 501).succeeded)
        #expect(!steerer(runner, live: process(tty: "ttys001", stopped: true)).steer(agent: target, prompt: "hello", uid: 501).succeeded)
        #expect(!steerer(runner, live: process()).steer(agent: target, prompt: "hello", uid: 501).succeeded)
        let launcher = SteeringLauncher()
        let native = steerer(runner, live: process(), launcher: launcher)
        #expect(!native.steer(agent: agent(), prompt: "hello", uid: 502).succeeded)
        #expect(runner.requests.isEmpty && launcher.requests.isEmpty)
    }

    @Test func terminalUsesFixedScriptAndSeparateArguments() throws {
        let prompt = "do work \"quoted\" $(touch /tmp/never)"
        for terminal in ["Terminal", "iTerm2"] {
            let p = process(tty: "ttys001"), runner = SteeringRunner()
            let result = steerer(runner, live: p).steer(agent: agent(process: p, terminal: terminal), prompt: prompt, uid: 501)
            #expect(result.succeeded)
            let request = try #require(runner.requests.first)
            #expect(request.executable == "/usr/bin/osascript")
            #expect(request.arguments.count == 4)
            #expect(request.arguments[0] == "-e")
            #expect(request.arguments[1].contains("on run argv"))
            #expect(!request.arguments[1].contains(prompt))
            #expect(!request.arguments[1].contains("ttys001"))
            #expect(request.arguments[2] == "/dev/ttys001")
            #expect(request.arguments[3] == prompt)
            #expect(request.timeout == 8)
            #expect(result.detail?.contains(prompt) == false)
        }
    }

    @Test func claimedAgentNameCannotSendToUnrelatedProcess() {
        for executable in ["/bin/zsh", "/usr/bin/vim"] {
            let process = process(tty: "ttys001", executable: executable)
            let runner = SteeringRunner()
            let target = agent(process: process, terminal: "Terminal")
            #expect(!steerer(runner, live: process).steer(agent: target, prompt: "hello", uid: 501).succeeded)
            #expect(runner.requests.isEmpty)
        }
    }

    @Test func terminalRequiresUnambiguousForegroundOwnership() {
        let invalidFields: [(String, (inout proc_bsdinfo) -> Void)] = [
            ("foreground shell or separate child group", { $0.e_tpgid = 401 }),
            ("selected process is a group member but cannot be verified as the leader", {
                $0.pbi_pgid = 401
                $0.e_tpgid = 401
            }),
            ("different TTY", { $0.e_tdev = 18 }),
            ("no controlling TTY", { $0.pbi_flags = 0 }),
            ("stopped process", { $0.pbi_status = UInt32(SSTOP) }),
            ("exiting process", { $0.pbi_flags |= UInt32(PROC_FLAG_INEXIT) }),
            ("reused PID", { $0.pbi_start_tvusec = 101 }),
            ("foreign effective UID", { $0.pbi_uid = 502 }),
            ("foreign real UID", { $0.pbi_ruid = 502 })
        ]
        let cases = invalidFields.map { reason, change in
            var info = foregroundBSDInfo()
            change(&info)
            let snapshot = info
            return (reason, terminalVerifier(metadata: { _ in snapshot }))
        } + [
            ("missing BSD record", terminalVerifier(metadata: { _ in nil })),
            ("missing TTY device", terminalVerifier(deviceNumber: nil)),
            ("unreadable group membership", terminalVerifier(members: nil)),
            ("same-group child tool", terminalVerifier(members: [400, 401])),
            ("foreign steering user", terminalVerifier(currentUID: 502))
        ]
        for terminal in ["Terminal", "iTerm2"] {
            let live = process(tty: "ttys001")
            let target = agent(process: live, terminal: terminal)
            for (reason, verifier) in cases {
                let runner = SteeringRunner()
                let outcome = steerer(runner, live: live, foreground: verifier).steer(agent: target, prompt: "hello", uid: 501)
                #expect(!outcome.succeeded, "\(terminal), \(reason)")
                #expect(runner.requests.isEmpty, "\(terminal), \(reason)")
            }
        }
    }

    @Test func terminalRechecksForegroundAfterGroupEnumeration() {
        var switched = foregroundBSDInfo()
        switched.e_tpgid = 401
        let reads = ForegroundReads([foregroundBSDInfo(), switched])
        let runner = SteeringRunner()
        let live = process(tty: "ttys001")
        let target = agent(process: live, terminal: "iTerm2")
        let verifier = terminalVerifier(metadata: { _ in reads.next() })
        #expect(!steerer(runner, live: live, foreground: verifier).steer(agent: target, prompt: "hello", uid: 501).succeeded)
        #expect(runner.requests.isEmpty)
    }

    @Test func wrappedAgentMustRetainRecognizedInvocation() {
        let invocation = AgentInvocation(agentName: "Codex", runtime: "node", entrypoint: "codex")
        let selected = process(tty: "ttys001", executable: "/tools/node", invocation: invocation)
        let target = agent(process: selected, terminal: "Terminal")
        let runner = SteeringRunner()
        #expect(steerer(runner, live: selected).steer(agent: target, prompt: "hello", uid: 501).succeeded)
        #expect(runner.requests.count == 1)

        let unknown = process(tty: "ttys001", executable: "/tools/node")
        let rejected = SteeringRunner()
        #expect(!steerer(rejected, live: unknown).steer(agent: target, prompt: "hello", uid: 501).succeeded)
        #expect(rejected.requests.isEmpty)
    }

    @Test(arguments: ["Codex", "OpenCode"])
    func explicitSessionContinuationFromGenericDirectoryUsesChosenProject(_ provider: String) throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let project = fixture.home.appendingPathComponent("selected-project").resolvingSymlinksInPath()
        let other = fixture.home.appendingPathComponent("other-project").resolvingSymlinksInPath()
        for directory in [project, other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let isCodex = provider == "Codex"
        let sessionID = isCodex ? "4fa50a5b-6037-477d-899b-98257d4e707b" : "ses_important"
        let otherID = isCodex ? "e7038a11-aac6-499c-87c1-9b2e44d826a1" : "ses_other"
        var db: OpaquePointer?
        defer { if let db { sqlite3_close(db) } }
        var rollout: URL?
        if isCodex {
            for (id, directory) in [(sessionID, project), (otherID, other)] {
                let path = ".codex/sessions/2026/11/07/rollout-2026-11-07T10-30-00-\(id).jsonl"
                try fixture.write([["type": "session_meta", "payload": ["id": id, "cwd": directory.path]]], to: path)
                if id == sessionID { rollout = fixture.home.appendingPathComponent(path) }
            }
        } else {
            try fixture.write(Data(), to: ".local/share/opencode/opencode.db")
            let path = fixture.home.appendingPathComponent(".local/share/opencode/opencode.db").path
            try #require(sqlite3_open(path, &db) == SQLITE_OK)
            try #require(sqlite3_exec(db, """
                CREATE TABLE session_v2 (id TEXT PRIMARY KEY, title TEXT, directory TEXT, time_updated INTEGER);
                INSERT INTO session_v2 VALUES ('\(sessionID)', 'Selected work', '\(project.path)', 100);
                INSERT INTO session_v2 VALUES ('\(otherID)', 'Different work', '\(other.path)', 200);
                """, nil, nil, nil) == SQLITE_OK)
        }
        let uid = Int(getuid())
        let executable = isCodex ? "codex" : "opencode"
        let live = process(uid: uid, cwd: "/", executable: "/tools/\(executable)")
        let row = agent(provider, process: live, session: otherID)
        let inspector = AgentTaskInspector(homeDirectory: fixture.home)
        let targets = inspector.nativeSessionTargets(for: row)
        #expect(Set(targets.map(\.sessionID)) == [sessionID, otherID])
        let choice = try #require(targets.first { $0.sessionID == sessionID })
        let catalog = NativeSessionCatalog(homeDirectory: fixture.home)
        let runner = SteeringRunner(stdout: catalog.openCodeDB.path + "\n"), launcher = SteeringLauncher()
        let steerer = AgentSteerer(processLookup: { _, _ in live }, runner: runner,
                                   executableResolver: { "/tools/\($0)" }, homeDirectory: fixture.home,
                                   nativeJobLauncher: launcher)
        #expect(!steerer.steer(agent: row, prompt: "continue", uid: uid).succeeded)
        #expect(launcher.requests.isEmpty)
        let outcome = steerer.steer(agent: row, target: choice, prompt: " \0\n--follow up\r ", uid: uid)
        #expect(outcome.succeeded && outcome.mode == (isCodex ? .codexResume : .openCodeSession))
        #expect(outcome.detail?.contains("Started continuation") == true)
        let request = try #require(launcher.requests.first)
        let expected = isCodex ? ["exec", "-c", "sqlite_home=\"\(catalog.codexHome.path)\"", "resume", sessionID, "--", "--follow up"]
                               : ["--standalone", "run", "--session", sessionID, "--", "--follow up"]
        #expect(request.arguments == expected)
        #expect(request.workingDirectory?.path == project.path)
        if isCodex {
            #expect(runner.requests.isEmpty)
        } else {
            let preflight = try #require(runner.requests.first)
            #expect(preflight.arguments == ["debug", "paths", "db"])
            #expect(preflight.environment["OPENCODE_DB"] == catalog.openCodeDB.path)
            let mismatched = AgentSteerer(processLookup: { _, _ in live }, runner: SteeringRunner(stdout: "/elsewhere/opencode.db\n"),
                                          executableResolver: { "/tools/\($0)" }, homeDirectory: fixture.home,
                                          nativeJobLauncher: launcher)
            #expect(!mismatched.steer(agent: row, target: choice, prompt: "continue", uid: uid).succeeded)
        }

        let otherRow = agent(provider, process: process(pid: 401, uid: uid, cwd: "/", executable: "/tools/\(executable)"))
        #expect(!steerer.steer(agent: otherRow, target: choice, prompt: "continue", uid: uid).succeeded)
        let otherProvider = agent(isCodex ? "OpenCode" : "Codex", process: live)
        #expect(!steerer.steer(agent: otherProvider, target: choice, prompt: "continue", uid: uid).succeeded)
        let changed = process(start: 101, uid: uid, cwd: "/", executable: "/tools/\(executable)")
        let stale = AgentSteerer(processLookup: { _, _ in changed }, runner: runner,
                                 executableResolver: { "/tools/\($0)" }, homeDirectory: fixture.home,
                                 nativeJobLauncher: launcher)
        #expect(!stale.steer(agent: row, target: choice, prompt: "continue", uid: uid).succeeded)
        let projectRow = agent(provider, process: process(uid: uid, cwd: project.path, executable: "/tools/\(executable)"))
        #expect(inspector.nativeSessionTargets(for: projectRow).map(\.sessionID) == [sessionID])
        if let rollout {
            let original = try Data(contentsOf: rollout)
            try original.write(to: rollout, options: .atomic)
        } else {
            try #require(sqlite3_exec(db, "DELETE FROM session_v2 WHERE id = '\(sessionID)'", nil, nil, nil) == SQLITE_OK)
        }
        let probesBeforeStaleSelection = runner.requests.count
        #expect(!steerer.steer(agent: row, target: choice, prompt: "continue", uid: uid).succeeded)
        #expect(runner.requests.count == probesBeforeStaleSelection)
        #expect(launcher.requests.count == 1)
    }

    @Test func codexConflictingIndexOrArchiveCannotAuthorizeContinuation() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let uid = Int(getuid())
        let live = process(uid: uid, cwd: "/")
        let row = agent(process: live)
        let choice = try codexTarget(in: fixture, for: row)
        let catalog = NativeSessionCatalog(homeDirectory: fixture.home)
        #expect(catalog.validate(choice, for: row, live: live))

        let duplicate = ".codex/archived_sessions/rollout-2026-01-01T12-00-00-\(choice.sessionID).jsonl.zst"
        try fixture.write(Data("fixture".utf8), to: duplicate)
        #expect(!catalog.validate(choice, for: row, live: live))
        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent(duplicate))
        let revised = ".codex/sessions/recovered/rollout-2026-11-09T10-00-00-\(choice.sessionID)_4abb52c8-09bc-42b2-82a8-1d043d39c49c.jsonl"
        try fixture.write(Data("fixture".utf8), to: revised)
        #expect(!catalog.validate(choice, for: row, live: live))
        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent(revised))

        var db: OpaquePointer?
        let indexPath = catalog.codexHome.appendingPathComponent("state_5.sqlite").path
        try #require(sqlite3_open(indexPath, &db) == SQLITE_OK)
        defer { if let db { sqlite3_close(db) } }
        try #require(sqlite3_exec(db, """
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT);
            INSERT INTO threads VALUES ('\(choice.sessionID)', '/different/rollout.jsonl');
            """, nil, nil, nil) == SQLITE_OK)
        #expect(!catalog.validate(choice, for: row, live: live))
        try #require(sqlite3_exec(db, "UPDATE threads SET rollout_path = '\(choice.source.path)'", nil, nil, nil) == SQLITE_OK)
        #expect(catalog.validate(choice, for: row, live: live))

        let symlink = catalog.codexRoot.appendingPathComponent("2025")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: catalog.codexRoot.appendingPathComponent("2026"))
        #expect(!catalog.validate(choice, for: row, live: live))
    }

    @Test func replacingSelectedProjectDirectoryInvalidatesNativeTarget() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let live = process(uid: Int(getuid()), cwd: "/")
        let row = agent(process: live)
        let choice = try codexTarget(in: fixture, for: row)
        let catalog = NativeSessionCatalog(homeDirectory: fixture.home)
        #expect(catalog.validate(choice, for: row, live: live))
        let project = URL(fileURLWithPath: choice.projectPath, isDirectory: true)
        try FileManager.default.moveItem(at: project, to: fixture.home.appendingPathComponent("original"))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        #expect(!catalog.validate(choice, for: row, live: live))
    }

    @Test func openCodeDuplicateIDOutsideTheProjectCannotAuthorizeContinuation() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let catalog = NativeSessionCatalog(homeDirectory: fixture.home)
        let project = fixture.home.appendingPathComponent("project")
        let other = fixture.home.appendingPathComponent("other")
        for directory in [project, other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fixture.write(Data(), to: ".local/share/opencode/opencode.db")
        var db: OpaquePointer?
        try #require(sqlite3_open(catalog.openCodeDB.path, &db) == SQLITE_OK)
        defer { if let db { sqlite3_close(db) } }
        try #require(sqlite3_exec(db, """
            CREATE TABLE session_v2 (id TEXT, title TEXT, directory TEXT, time_updated INTEGER);
            INSERT INTO session_v2 VALUES ('ses_same', 'First', '\(project.path)', 100);
            INSERT INTO session_v2 VALUES ('ses_same', 'Second', '\(other.path)', 200);
            """, nil, nil, nil) == SQLITE_OK)
        let live = process(uid: Int(getuid()), cwd: project.path, executable: "/tools/opencode")
        let row = agent("OpenCode", process: live)
        let choice = try #require(catalog.choices(for: row).first)
        #expect(!catalog.validate(choice, for: row, live: live))
    }

    @Test func commandRunnerAppliesDirectoryAndOptInPATH() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let runner: any CommandRunning = CommandRunner()
        let pwd = try runner.run(CommandRequest(executable: "/bin/pwd"), workingDirectory: fixture.home)
        #expect(pwd.exitCode == 0 && !pwd.timedOut)
        let observed = URL(fileURLWithPath: pwd.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath()
        #expect(observed == fixture.home.resolvingSymlinksInPath())
        let request = CommandRequest(executable: "/usr/bin/printenv", arguments: ["PATH"], environment: ["PATH": "/custom"])
        let standard = try runner.run(request, includeStandardUserPaths: true)
        #expect(standard.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(try runner.run(request).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "/custom")
        let mock: any CommandRunning = SteeringRunner()
        #expect(try mock.run(request, workingDirectory: fixture.home, includeStandardUserPaths: true).exitCode == 0)
    }

    @Test func localSessionMetadataDoesNotAuthorizeNativeSteering() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        try fixture.write([["type": "session_meta", "payload": ["id": "safe-session", "cwd": "/workspace/Suyoi"]],
                           ["type": "event_msg", "payload": ["type": "task_started"]]], to: ".codex/sessions/2026/11/07/session.jsonl")
        try fixture.write(Data(), to: ".local/share/opencode/opencode.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(fixture.home.appendingPathComponent(".local/share/opencode/opencode.db").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, """
        CREATE TABLE session_v2 (id TEXT, title TEXT, directory TEXT, idle_outcome TEXT, time_updated INTEGER);
        CREATE TABLE todo (session_id TEXT, status TEXT, content TEXT, position INTEGER, time_updated INTEGER);
        INSERT INTO session_v2 VALUES ('safe-session', 'Build core', '/workspace/Suyoi', 'completed', 100);
        INSERT INTO todo VALUES ('safe-session', 'in_progress', 'Implement inspector', 0, 100);
        """, nil, nil, nil) == SQLITE_OK)
        let inspector = AgentTaskInspector(homeDirectory: fixture.home)
        for (name, executable) in [("Codex", "codex"), ("OpenCode", "opencode")] {
            for cwd in ["/", fixture.home.path, "/workspace/Suyoi"] {
                let target = ObservedProcess(pid: 400, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0, executable: "/bin/\(executable)", startTimeMicroseconds: 100, cwd: cwd)
                let single = inspector.inspect(agentName: name, process: target, projectRoot: nil, allProcesses: [target])
                #expect(single.sessionID == nil && single.sessionTitle == nil && single.currentTask == nil)
                let observation = agent(name, process: target, session: single.sessionID)
                let runner = SteeringRunner(), launcher = SteeringLauncher()
                #expect(!AgentSteerer.canSteer(observation))
                #expect(!steerer(runner, live: target, launcher: launcher).steer(agent: observation, prompt: "continue", uid: 501).succeeded)
                #expect(runner.requests.isEmpty && launcher.requests.isEmpty)

            }
        }
    }

    @Test func malformedQuotaTimestampsAreRejected() {
        for value in [Double.nan, .infinity, -.infinity, 0, -1, Double.greatestFiniteMagnitude, Date().timeIntervalSince1970 + 315_360_060] {
            #expect(QuotaParsing.parseTimestamp(value) == nil)
            #expect(QuotaParsing.date(NSNumber(value: value)) == nil)
        }
        for value in ["NaN", "inf", "1e300", "0", "-1", "9999-12-31T23:59:59Z", "1970-01-01T00:00:00Z"] {
            #expect(QuotaParsing.date(value) == nil)
        }
        let now = Date().timeIntervalSince1970
        #expect(QuotaParsing.parseTimestamp(now)?.timeIntervalSince1970 == now)
        #expect(QuotaParsing.date("2026-11-07T12:00:00Z") != nil)
    }

    @Test func discoversCLIInUserBinWithoutCustomResolver() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let executable = fixture.home.appendingPathComponent(".bun/bin/codex")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let uid = Int(getuid())
        let live = process(uid: uid, cwd: "/", executable: "/bin/codex")
        let row = agent(process: live)
        let target = try codexTarget(in: fixture, for: row)
        let launcher = SteeringLauncher()
        let steerer = AgentSteerer(processLookup: { _, _ in live }, runner: SteeringRunner(), homeDirectory: fixture.home,
                                   nativeJobLauncher: launcher)
        let outcome = steerer.steer(agent: row, target: target, prompt: "continue", uid: uid)

        #expect(outcome.succeeded)
        let request = try #require(launcher.requests.first)
        #expect(request.executable == executable.path)
    }

    @Test func invalidPromptsAndNativeLaunchFailureArePrivate() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let uid = Int(getuid())
        let live = process(uid: uid, cwd: "/", executable: "/bin/codex")
        let row = agent(process: live)
        let target = try codexTarget(in: fixture, for: row)
        let runner = SteeringRunner(), launcher = SteeringLauncher(fails: true)
        let steering = AgentSteerer(processLookup: { _, _ in live }, runner: runner,
                                    executableResolver: { "/tools/\($0)" }, homeDirectory: fixture.home,
                                    nativeJobLauncher: launcher)
        for prompt in [" \n\0", String(repeating: "x", count: 2001)] {
            #expect(!steering.steer(agent: row, target: target, prompt: prompt, uid: uid).succeeded)
        }
        #expect(launcher.requests.isEmpty)
        let outcome = steering.steer(agent: row, target: target, prompt: "PRIVATE PROMPT", uid: uid)
        #expect(!outcome.succeeded)
        #expect(launcher.requests.count == 1)
        #expect(runner.requests.isEmpty)
        let json = String(decoding: try JSONEncoder().encode(outcome), as: UTF8.self)
        #expect(!json.contains("PRIVATE"))
    }

    @Test func terminalCommandFailureIsPrivate() throws {
        let live = process(tty: "ttys001")
        let target = agent(process: live, terminal: "Terminal")
        for failing in [SteeringRunner(exit: 1), SteeringRunner(timeout: true)] {
            let outcome = steerer(failing, live: live).steer(agent: target, prompt: "PRIVATE PROMPT", uid: 501)
            #expect(!outcome.succeeded)
            #expect(failing.requests.count == 1)
            let json = String(decoding: try JSONEncoder().encode(outcome), as: UTF8.self)
            #expect(!json.contains("PRIVATE"))
        }
    }
}
