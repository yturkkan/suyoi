import Foundation
import Darwin
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
        verifySessionOwnership: (@Sendable (ProcessIdentity, AgentSteerMode, String) -> Bool)? = nil,
        foreground: TerminalForegroundVerifier? = nil,
        launcher: SteeringLauncher = SteeringLauncher()
    ) -> AgentSteerer {
        AgentSteerer(processLookup: { _, _ in live }, runner: runner, executableResolver: { "/tools/\($0)" },
                     verifySessionOwnership: verifySessionOwnership, nativeJobLauncher: launcher,
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
    private func sessionOwner(
        _ identity: ProcessIdentity,
        mode: AgentSteerMode,
        session: String = "session-1"
    ) -> @Sendable (ProcessIdentity, AgentSteerMode, String) -> Bool {
        { liveIdentity, requestedMode, requestedSession in
            liveIdentity == identity && requestedMode == mode && requestedSession == session
        }
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
            let steerer = steerer(runner, live: process(), verifySessionOwnership: { _, _, _ in true }, launcher: launcher)
            #expect(!steerer.steer(agent: agent(session: id), prompt: "hello", uid: 501).succeeded)
            #expect(runner.requests.isEmpty && launcher.requests.isEmpty)
        }
        for tty in ["/dev/ttys001;evil", "../../tty", "tty", "ttys001\n"] { #expect(!AgentSteerer.isValidTTY(tty)) }
    }

    @Test func identityAndTTYReverificationFailuresNeverLaunch() {
        for live in [process(pid: 401), process(start: 101), process(uid: 502)] {
            let runner = SteeringRunner(), launcher = SteeringLauncher()
            let steerer = steerer(runner, live: live, verifySessionOwnership: sessionOwner(live.identity, mode: .codexResume), launcher: launcher)
            #expect(!steerer.steer(agent: agent(), prompt: "hello", uid: 501).succeeded)
            #expect(runner.requests.isEmpty && launcher.requests.isEmpty)
        }
        let runner = SteeringRunner()
        let target = agent(process: process(tty: "ttys001"), terminal: "Terminal")
        #expect(!steerer(runner, live: process(tty: "ttys002")).steer(agent: target, prompt: "hello", uid: 501).succeeded)
        #expect(!steerer(runner, live: process(tty: "ttys001", stopped: true)).steer(agent: target, prompt: "hello", uid: 501).succeeded)
        #expect(!steerer(runner, live: process()).steer(agent: target, prompt: "hello", uid: 501).succeeded)
        let launcher = SteeringLauncher()
        let native = steerer(runner, live: process(), verifySessionOwnership: sessionOwner(process().identity, mode: .codexResume), launcher: launcher)
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

    @Test func cliUsesSafeArgvAndReportsOnlyLocalLaunch() throws {
        for (name, mode, args) in [("OpenCode", AgentSteerMode.openCodeSession, ["run", "--session", "session-1", "--", "--safe\ttext"]), ("Codex", .codexResume, ["exec", "resume", "session-1", "--", "--safe\ttext"])] {
            let live = process(), runner = SteeringRunner(timeout: true), launcher = SteeringLauncher()
            let steerer = steerer(runner, live: live, verifySessionOwnership: sessionOwner(live.identity, mode: mode), launcher: launcher)
            let outcome = steerer.steer(agent: agent(name), prompt: " \0\n--safe\ttext\r ", uid: 501)
            #expect(outcome.succeeded && outcome.mode == mode)
            #expect(outcome.detail == "Started local \(name) continuation process")
            #expect(runner.requests.isEmpty)
            let request = try #require(launcher.requests.first)
            #expect(request.executable == "/tools/\(name == "OpenCode" ? "opencode" : "codex")")
            #expect(request.arguments == args)
            #expect(launcher.requests.count == 1)
        }
    }

    @Test func nativeSessionOwnershipMustMatchProcessProviderAndSession() {
        let proof = sessionOwner(process().identity, mode: .codexResume)
        for target in [agent(process: process(start: 101)), agent("OpenCode"), agent(session: "other-session")] {
            let runner = SteeringRunner(), launcher = SteeringLauncher()
            let steerer = steerer(runner, live: target.process, verifySessionOwnership: proof, launcher: launcher)
            #expect(!steerer.steer(agent: target, prompt: "continue", uid: 501).succeeded)
            #expect(runner.requests.isEmpty && launcher.requests.isEmpty)
        }
    }

    @Test func cliUsesValidProjectThenCWDFallback() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let project = fixture.home.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = fixture.home.appendingPathComponent("file")
        try Data().write(to: file)
        for (name, mode) in [("Codex", AgentSteerMode.codexResume), ("OpenCode", .openCodeSession)] {
            for (root, cwd, expected) in [(project.path, fixture.home.path, project),
                                           (file.path, fixture.home.path, fixture.home),
                                           ("/missing-\(UUID().uuidString)", fixture.home.path, fixture.home)] {
                let live = process(cwd: cwd), launcher = SteeringLauncher()
                let context = ProjectContext(rootPath: root, name: "Fixture", framework: nil, gitBranch: nil, gitCommit: nil, isWorktree: false)
                let target = AgentObservation(id: live.pid, agentName: name, process: live, project: context, terminalApp: nil, statusSource: .processOnly, childServerPorts: [], sessionID: "safe-session")
                let steerer = steerer(SteeringRunner(), live: live, verifySessionOwnership: sessionOwner(live.identity, mode: mode, session: "safe-session"), launcher: launcher)
                #expect(steerer.steer(agent: target, prompt: "continue", uid: 501).succeeded)
                #expect(try #require(launcher.requests.first).workingDirectory?.path == expected.path)
            }
        }
        let live = process(cwd: file.path), launcher = SteeringLauncher()
        let steerer = steerer(SteeringRunner(), live: live, verifySessionOwnership: sessionOwner(live.identity, mode: .codexResume), launcher: launcher)
        #expect(steerer.steer(agent: agent(process: live), prompt: "continue", uid: 501).succeeded)
        #expect(try #require(launcher.requests.first).workingDirectory == nil)
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
                #expect(single.sessionID == "safe-session")
                let observation = agent(name, process: target, session: single.sessionID)
                let runner = SteeringRunner(), launcher = SteeringLauncher()
                #expect(!AgentSteerer.canSteer(observation))
                #expect(!steerer(runner, live: target, launcher: launcher).steer(agent: observation, prompt: "continue", uid: 501).succeeded)
                #expect(runner.requests.isEmpty && launcher.requests.isEmpty)
                // Generic-directory display metadata remains available even when it cannot identify a single session.
                guard cwd != "/workspace/Suyoi" else { continue }
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

        let live = process(), runner = SteeringRunner(), launcher = SteeringLauncher()
        let steerer = AgentSteerer(processLookup: { _, _ in live }, runner: runner, homeDirectory: tempHome,
                                   verifySessionOwnership: sessionOwner(live.identity, mode: .codexResume), nativeJobLauncher: launcher)
        let outcome = steerer.steer(agent: agent(process: live), prompt: "continue", uid: 501)

        #expect(outcome.succeeded)
        let request = try #require(launcher.requests.first)
        #expect(request.executable == executable.path)
    }

    @Test func invalidPromptsAndNativeLaunchFailureArePrivate() throws {
        let live = process(), runner = SteeringRunner(), launcher = SteeringLauncher(fails: true)
        let proof = sessionOwner(live.identity, mode: .codexResume)
        let steering = steerer(runner, live: live, verifySessionOwnership: proof, launcher: launcher)
        for prompt in [" \n\0", String(repeating: "x", count: 2001)] {
            #expect(!steering.steer(agent: agent(), prompt: prompt, uid: 501).succeeded)
        }
        #expect(launcher.requests.isEmpty)
        let outcome = steering.steer(agent: agent(), prompt: "PRIVATE PROMPT", uid: 501)
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
