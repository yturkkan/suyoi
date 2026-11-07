import Foundation
import SQLite3
import Testing
@testable import SuyoiCore

private final class SteeringRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CommandRequest] = []
    let result: CommandResult
    init(exit: Int32 = 0, timeout: Bool = false) {
        result = CommandResult(exitCode: exit, stdout: Data("PRIVATE OUTPUT".utf8), stderr: Data("PRIVATE ERROR".utf8), timedOut: timeout, truncated: false)
    }
    var requests: [CommandRequest] { lock.lock(); defer { lock.unlock() }; return storage }
    func run(_ request: CommandRequest) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }; storage.append(request); return result
    }
}

@Suite("Explicit agent steering safety")
struct AgentSteererTests {
    private func process(pid: Int = 400, start: UInt64? = 100, tty: String? = nil, uid: Int = 501, stopped: Bool = false, cwd: String? = "/project") -> ObservedProcess {
        ObservedProcess(pid: pid, parentPID: 1, uid: uid, cpuPercent: 0, residentBytes: 0, executable: "/bin/codex", startTimeMicroseconds: start, cwd: cwd, tty: tty, isStopped: stopped)
    }
    private func agent(_ name: String = "Codex", process: ObservedProcess? = nil, terminal: String? = nil, session: String? = "session-1") -> AgentObservation {
        let p = process ?? self.process()
        return AgentObservation(id: p.pid, agentName: name, process: p, project: nil, terminalApp: terminal, statusSource: .processOnly, childServerPorts: [], sessionID: session)
    }
    private func steerer(_ runner: SteeringRunner, live: ObservedProcess) -> AgentSteerer {
        AgentSteerer(processLookup: { _, _ in live }, runner: runner, executableResolver: { "/tools/\($0)" })
    }

    @Test func selectsModesAndRejectsUnsafeMetadata() {
        #expect(AgentSteerer.preferredMode(for: agent()) == .codexResume)
        #expect(AgentSteerer.preferredMode(for: agent("OpenCode")) == .openCodeSession)
        #expect(AgentSteerer.preferredMode(for: agent(process: process(tty: "ttys001"), terminal: "Terminal")) == .terminalTTY)
        #expect(AgentSteerer.preferredMode(for: agent(process: process(tty: "/dev/ttys001"), terminal: "iTerm2")) == .terminalTTY)
        #expect(!AgentSteerer.canSteer(agent("Claude Code", session: nil)))
        #expect(!AgentSteerer.canSteer(agent(process: process(start: nil))))
        for id in ["--help", "-session", "bad/id", "bad\nID", "é", "", String(repeating: "a", count: 97)] {
            #expect(!AgentSteerer.canSteer(agent(session: id)))
            let runner = SteeringRunner()
            #expect(!steerer(runner, live: process()).steer(agent: agent(session: id), prompt: "hello", uid: 501).succeeded)
            #expect(runner.requests.isEmpty)
        }
        for tty in ["/dev/ttys001;evil", "../../tty", "tty", "ttys001\n"] { #expect(!AgentSteerer.isValidTTY(tty)) }
    }

    @Test func identityAndTTYReverificationFailuresNeverLaunch() {
        for live in [process(pid: 401), process(start: 101), process(uid: 502)] {
            let runner = SteeringRunner()
            #expect(!steerer(runner, live: live).steer(agent: agent(), prompt: "hello", uid: 501).succeeded)
            #expect(runner.requests.isEmpty)
        }
        let runner = SteeringRunner()
        let target = agent(process: process(tty: "ttys001"), terminal: "Terminal")
        #expect(!steerer(runner, live: process(tty: "ttys002")).steer(agent: target, prompt: "hello", uid: 501).succeeded)
        #expect(!steerer(runner, live: process(tty: "ttys001", stopped: true)).steer(agent: target, prompt: "hello", uid: 501).succeeded)
        #expect(!steerer(runner, live: process()).steer(agent: target, prompt: "hello", uid: 501).succeeded)
        #expect(!steerer(runner, live: process()).steer(agent: agent(), prompt: "hello", uid: 502).succeeded)
        #expect(runner.requests.isEmpty)
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

    @Test func cliUsesSafeArgvAndSanitizedPrompt() throws {
        for (name, mode, args) in [("OpenCode", AgentSteerMode.openCodeSession, ["run", "--session", "session-1", "--", "--safe\ttext"]), ("Codex", .codexResume, ["exec", "resume", "session-1", "--", "--safe\ttext"])] {
            let runner = SteeringRunner()
            let outcome = steerer(runner, live: process()).steer(agent: agent(name), prompt: " \0\n--safe\ttext\r ", uid: 501)
            #expect(outcome.succeeded && outcome.mode == mode)
            let request = try #require(runner.requests.first)
            #expect(request.executable == "/tools/\(name == "OpenCode" ? "opencode" : "codex")")
            #expect(request.arguments == args)
            #expect(request.timeout == 60)
            #expect(request.includeStandardUserPaths)
        }
    }

    @Test func cliUsesValidProjectThenCWDFallback() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let project = fixture.home.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = fixture.home.appendingPathComponent("file")
        try Data().write(to: file)
        for name in ["Codex", "OpenCode"] {
            for (root, cwd, expected) in [(project.path, fixture.home.path, project),
                                           (file.path, fixture.home.path, fixture.home),
                                           ("/missing-\(UUID().uuidString)", fixture.home.path, fixture.home)] {
                let live = process(cwd: cwd), runner = SteeringRunner()
                let context = ProjectContext(rootPath: root, name: "Fixture", framework: nil, gitBranch: nil, gitCommit: nil, isWorktree: false)
                let target = AgentObservation(id: live.pid, agentName: name, process: live, project: context, terminalApp: nil, statusSource: .processOnly, childServerPorts: [], sessionID: "safe-session")
                #expect(steerer(runner, live: live).steer(agent: target, prompt: "continue", uid: 501).succeeded)
                #expect(try #require(runner.requests.first).workingDirectory?.path == expected.path)
            }
        }
        let live = process(cwd: file.path), runner = SteeringRunner()
        #expect(steerer(runner, live: live).steer(agent: agent(process: live), prompt: "continue", uid: 501).succeeded)
        #expect(try #require(runner.requests.first).workingDirectory == nil)
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

    @Test func genericDirectoryMetadataDoesNotAuthorizeAmbiguousSessions() throws {
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
            for cwd in ["/", fixture.home.path] {
                let target = ObservedProcess(pid: 400, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0, executable: "/bin/\(executable)", startTimeMicroseconds: 100, cwd: cwd)
                let single = inspector.inspect(agentName: name, process: target, projectRoot: nil, allProcesses: [target])
                #expect(single.sessionID == "safe-session")
                #expect(single.sessionTitle != nil && single.currentTask != nil)
                for stopped in [false, true] {
                    let peer = ObservedProcess(pid: 401, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0, executable: "/bin/\(executable)", startTimeMicroseconds: 101, cwd: "/another-project", isStopped: stopped)
                    let context = inspector.inspect(agentName: name, process: target, projectRoot: nil, allProcesses: [target, peer])
                    #expect(context.sessionID == (stopped ? single.sessionID : nil))
                    #expect(context.sessionTitle == single.sessionTitle)
                    #expect(context.currentTask == single.currentTask)
                }
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
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = tempHome.appendingPathComponent(".bun/bin/codex")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let live = process(), runner = SteeringRunner()
        let steerer = AgentSteerer(processLookup: { _, _ in live }, runner: runner, homeDirectory: tempHome)
        let outcome = steerer.steer(agent: agent(process: live), prompt: "continue", uid: 501)

        #expect(outcome.succeeded)
        let request = try #require(runner.requests.first)
        #expect(request.executable == executable.path)
    }

    @Test func invalidPromptsAndCommandFailureArePrivate() throws {
        let runner = SteeringRunner()
        for prompt in [" \n\0", String(repeating: "x", count: 2001)] {
            #expect(!steerer(runner, live: process()).steer(agent: agent(), prompt: prompt, uid: 501).succeeded)
        }
        #expect(runner.requests.isEmpty)
        for failing in [SteeringRunner(exit: 1), SteeringRunner(timeout: true)] {
            let outcome = steerer(failing, live: process()).steer(agent: agent(), prompt: "PRIVATE PROMPT", uid: 501)
            #expect(!outcome.succeeded)
            let json = String(decoding: try JSONEncoder().encode(outcome), as: UTF8.self)
            #expect(!json.contains("PRIVATE"))
        }
    }
}
