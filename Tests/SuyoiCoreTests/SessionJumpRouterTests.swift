import Foundation
import Testing
@testable import SuyoiCore

private final class JumpCommandRecorder: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CommandRequest] = []
    private let response: @Sendable (CommandRequest) throws -> CommandResult

    init(response: @escaping @Sendable (CommandRequest) throws -> CommandResult = { _ in jumpResult() }) {
        self.response = response
    }

    var requests: [CommandRequest] { lock.withLock { storage } }

    func run(_ request: CommandRequest) throws -> CommandResult {
        lock.withLock { storage.append(request) }
        return try response(request)
    }
}

private func jumpResult(_ output: String = "", exit: Int32 = 0, timedOut: Bool = false, truncated: Bool = false) -> CommandResult {
    CommandResult(exitCode: exit, stdout: Data(output.utf8), stderr: Data("PRIVATE COMMAND ERROR".utf8),
                  timedOut: timedOut, truncated: truncated)
}

@Suite("Session jump routing")
struct SessionJumpRouterTests {
    private func agent(app: String? = nil, tty: String? = nil, pid: Int? = nil,
                       root: String? = nil, cwd: String? = nil) -> AgentObservation {
        let process = ObservedProcess(pid: 400, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0,
                                      executable: "/opt/bin/codex", startTimeMicroseconds: 100, cwd: cwd, tty: tty)
        let project = root.map {
            ProjectContext(rootPath: $0, name: "Example", framework: nil, gitBranch: nil, gitCommit: nil, isWorktree: false)
        }
        return AgentObservation(id: 400, agentName: "Codex", process: process, project: project,
                                terminalApp: app, statusSource: .processOnly, childServerPorts: [], terminalPID: pid)
    }

    @Test func supportsEveryRequestedProductWithDistinctVisuals() {
        let names = ["Claude Code", "Codex", "OpenCode", "Gemini CLI", "Antigravity CLI", "Hermes Agent",
                     "Qwen Code", "Kimi CLI", "OpenClaw", "Pi Agent", "Oh My Pi", "Aider", "Cursor",
                     "Windsurf", "Qoder", "CodeBuddy", "GitHub Copilot", "Goose", "Amp", "Droid", "Kiro"]
        #expect(Set(SessionJumpRouter.allSupportedAgentNames) == Set(names + ["Cursor Agent"]))
        let profiles = names.map { SessionJumpRouter.visualProfile(for: $0) }
        #expect(profiles.map(\.agentName) == names)
        #expect(Set(profiles.map(\.symbolName)).count == names.count)
        #expect(Set(profiles.map(\.badgeLabel)).count == names.count)
        #expect(Set(profiles.map { "\($0.accentRed),\($0.accentGreen),\($0.accentBlue)" }).count == names.count)
        for profile in profiles {
            #expect(!profile.symbolName.isEmpty)
            #expect(!profile.badgeLabel.isEmpty)
            #expect((0...1).contains(profile.accentRed))
            #expect((0...1).contains(profile.accentGreen))
            #expect((0...1).contains(profile.accentBlue))
        }
    }

    @Test func profileAliasesAndSchemes() {
        #expect(SessionJumpRouter.visualProfile(for: "Cursor Agent") == SessionJumpRouter.visualProfile(for: "Cursor"))
        #expect(SessionJumpRouter.visualProfile(for: "  cOdEx\n") == SessionJumpRouter.visualProfile(for: "Codex"))
        #expect(SessionJumpRouter.visualProfile(for: "Claude Code").deepLinkScheme == "claude://")
        #expect(SessionJumpRouter.visualProfile(for: "Codex").deepLinkScheme == "codex://")
        #expect(SessionJumpRouter.visualProfile(for: "Cursor").deepLinkScheme == "cursor://file")
        #expect(SessionJumpRouter.visualProfile(for: "Windsurf").deepLinkScheme == "windsurf://file")
        #expect(SessionJumpRouter.visualProfile(for: "Aider").deepLinkScheme == nil)
        let unknown = SessionJumpRouter.visualProfile(for: "New Client")
        #expect(unknown.agentName == "New Client")
        #expect(!unknown.symbolName.isEmpty)
        #expect(unknown.deepLinkScheme == nil)
    }

    @Test(arguments: ["ttys001", "/dev/ttys001"])
    func resolvesTmuxBeforeHostTerminal(tty: String) {
        let runner = JumpCommandRecorder { _ in jumpResult("/dev/ttys002\tother:0.0\n/dev/ttys001\tproject:2.3\n") }
        let target = SessionJumpRouter(runner: runner).resolveTarget(for: agent(app: "Terminal", tty: tty, pid: 9))
        #expect(target == .tmuxPane(sessionWindowPane: "project:2.3", tty: "ttys001"))
        #expect(runner.requests.count == 1)
        #expect(runner.requests.first?.executable == "/usr/bin/env")
        #expect(runner.requests.first?.arguments == ["tmux", "list-panes", "-a", "-F", "#{pane_tty}\t#{session_name}:#{window_index}.#{pane_index}"])
        #expect(runner.requests.first?.includeStandardUserPaths == true)
    }

    @Test func resolvesBareTmuxTTYAndExplicitHost() {
        let runner = JumpCommandRecorder { _ in jumpResult("ttys007\twork:12.4\n") }
        #expect(SessionJumpRouter(runner: runner).resolveTarget(for: agent(app: "tmux", tty: "ttys007"))
                == .tmuxPane(sessionWindowPane: "work:12.4", tty: "ttys007"))
    }

    @Test func selectsTmuxWindowThenPane() {
        let runner = JumpCommandRecorder { request in
            request.arguments.contains("list-panes") ? jumpResult("/dev/ttys001\tmy project:12.4\n") : jumpResult()
        }
        var activated: [Int] = []
        let outcome = SessionJumpRouter(runner: runner).executeJump(
            for: agent(app: "iTerm2", tty: "ttys001", pid: 9), activatePID: { activated.append($0); return true })
        #expect(outcome.succeeded)
        #expect(outcome.error == nil)
        #expect(outcome.target == .tmuxPane(sessionWindowPane: "my project:12.4", tty: "ttys001"))
        #expect(runner.requests.map(\.arguments).dropFirst() == [
            ["tmux", "select-window", "-t", "my project:12"],
            ["tmux", "select-pane", "-t", "my project:12.4"]
        ])
        #expect(runner.requests.allSatisfy { $0.executable == "/usr/bin/env" })
        #expect(activated == [9])
    }

    @Test(arguments: ["select-window", "select-pane"])
    func tmuxSelectionFailureIsNotReportedAsSuccess(command: String) {
        let runner = JumpCommandRecorder { request in
            if request.arguments.contains("list-panes") { return jumpResult("/dev/ttys001\twork:0.1\n") }
            return jumpResult("PRIVATE OUTPUT", exit: request.arguments.contains(command) ? 1 : 0)
        }
        let outcome = SessionJumpRouter(runner: runner).executeJump(for: agent(app: "tmux", tty: "ttys001"))
        #expect(!outcome.succeeded)
        #expect(outcome.target == .tmuxPane(sessionWindowPane: "work:0.1", tty: "ttys001"))
        #expect(outcome.error != nil)
        #expect(!String(describing: outcome).contains("PRIVATE"))
        #expect(runner.requests.count == (command == "select-window" ? 2 : 3))
    }

    @Test(arguments: [
        "/dev/ttys001\twork:0.0\n/dev/ttys001\tother:0.1\n",
        "/dev/ttys001\twork:not-a-window.0\n",
        "/dev/ttys001\t-work:0.0\n",
        "/dev/ttys001\twork:0.0;kill-server\n",
        "/dev/ttys001\twork:0.0\textra\n",
        "/dev/ttys001\n",
        "/dev/ttys0010\twork:0.0\n"
    ])
    func rejectsAmbiguousMalformedOrNonmatchingTmuxOutput(output: String) {
        let runner = JumpCommandRecorder { _ in jumpResult(output) }
        #expect(SessionJumpRouter(runner: runner).resolveTarget(for: agent(app: "Terminal", tty: "ttys001"))
                == .terminalTab(app: "Terminal", tty: "ttys001", hostPID: nil))
    }

    @Test(arguments: [jumpResult("/dev/ttys001\twork:0.0\n", exit: 1),
                      jumpResult("/dev/ttys001\twork:0.0\n", timedOut: true),
                      jumpResult("/dev/ttys001\twork:0.0\n", truncated: true)])
    func ignoresFailedOrIncompleteTmuxDiscovery(result: CommandResult) {
        let runner = JumpCommandRecorder { _ in result }
        #expect(SessionJumpRouter(runner: runner).resolveTarget(for: agent(app: "iTerm2", tty: "ttys001"))
                == .terminalTab(app: "iTerm2", tty: "ttys001", hostPID: nil))
    }

    @Test(arguments: ["Terminal", "iTerm2"])
    func selectsTerminalTabUsingDeviceArgument(app: String) {
        let runner = JumpCommandRecorder()
        var activated = false
        let outcome = SessionJumpRouter(runner: runner).executeJump(
            for: agent(app: app, tty: "/dev/ttys001", pid: 9), activatePID: { _ in activated = true; return true })
        #expect(outcome.succeeded)
        #expect(outcome.target == .terminalTab(app: app, tty: "ttys001", hostPID: 9))
        #expect(!activated)
        #expect(runner.requests.count == 2)
        #expect(runner.requests.last?.executable == "/usr/bin/osascript")
        #expect(runner.requests.last?.arguments.first == "-e")
        #expect(runner.requests.last?.arguments.count == 3)
        #expect(runner.requests.last?.arguments.last == "/dev/ttys001")
    }

    @Test(arguments: ["", "-tty", "ttys001;bad", "../ttys001", "/dev/../ttys001", "ttys001\n", "pts/1"])
    func invalidTTYDoesNotLaunchCommands(tty: String) {
        let runner = JumpCommandRecorder()
        #expect(SessionJumpRouter(runner: runner).resolveTarget(for: agent(app: "Terminal", tty: tty, pid: 9))
                == .hostProcess(app: "Terminal", pid: 9))
        #expect(runner.requests.isEmpty)
    }

    @Test func terminalFailureFallsBackToHostActivation() {
        let runner = JumpCommandRecorder { _ in jumpResult("PRIVATE OUTPUT", exit: 1) }
        var activated: [Int] = []
        let outcome = SessionJumpRouter(runner: runner).executeJump(
            for: agent(app: "Terminal", tty: "ttys001", pid: 9), activatePID: { activated.append($0); return true })
        #expect(outcome.succeeded)
        #expect(outcome.error == nil)
        #expect(activated == [9])
        #expect(!String(describing: outcome).contains("PRIVATE"))
    }

    @Test(arguments: [jumpResult(exit: 1), jumpResult(timedOut: true), jumpResult(truncated: true)])
    func terminalFailureWithoutWorkingFallbackFails(result: CommandResult) {
        let runner = JumpCommandRecorder { _ in result }
        let outcome = SessionJumpRouter(runner: runner).executeJump(for: agent(app: "iTerm2", tty: "ttys001", pid: 9))
        #expect(!outcome.succeeded)
        #expect(outcome.error != nil)
        #expect(!String(describing: outcome).contains("PRIVATE"))
    }

    @Test(arguments: [("Cursor", "cursor"), ("VS Code", "vscode"), ("Windsurf", "windsurf"),
                      ("Zed", "zed"), ("Antigravity", "antigravity")])
    func generatesEncodedIDEWorkspaceLinks(app: String, scheme: String) {
        let runner = JumpCommandRecorder()
        let root = "/work/My Project/#draft?rate=100%/日本語"
        let target = SessionJumpRouter(runner: runner).resolveTarget(for: agent(app: app, pid: 9, root: root, cwd: "/other"))
        guard case let .ideWorkspace(actualApp, link, path, pid) = target else { Issue.record("Expected IDE workspace"); return }
        #expect(actualApp == app)
        #expect(path == root)
        #expect(pid == 9)
        #expect(link?.scheme == scheme)
        #expect(link?.host == "file")
        #expect(link?.path == root)
        #expect(link?.query == nil)
        #expect(link?.fragment == nil)
        #expect(link?.absoluteString.contains("%20") == true)
        #expect(runner.requests.isEmpty)
    }

    @Test func workspaceUsesCWDWhenProjectIsMissingOrInvalid() {
        let router = SessionJumpRouter(runner: JumpCommandRecorder())
        #expect(router.resolveTarget(for: agent(app: "Cursor", cwd: "/work/repo"))
                == .ideWorkspace(app: "Cursor", deepLinkURL: URL(string: "cursor://file/work/repo"), rootPath: "/work/repo", hostPID: nil))
        #expect(router.resolveTarget(for: agent(app: "Cursor", root: "", cwd: "/work/repo"))
                == .ideWorkspace(app: "Cursor", deepLinkURL: URL(string: "cursor://file/work/repo"), rootPath: "/work/repo", hostPID: nil))
        #expect(router.resolveTarget(for: agent(app: "Zed"))
                == .ideWorkspace(app: "Zed", deepLinkURL: nil, rootPath: nil, hostPID: nil))
    }

    @Test func idePrefersHostActivationAndFallsBackToURL() {
        let router = SessionJumpRouter(runner: JumpCommandRecorder())
        let observation = agent(app: "Cursor", pid: 9, root: "/work/repo")
        var activated: [Int] = []
        var opened: [URL] = []
        let focused = router.executeJump(for: observation, activatePID: { activated.append($0); return true },
                                         openURL: { opened.append($0); return true })
        #expect(focused.succeeded)
        #expect(activated == [9])
        #expect(opened.isEmpty)
        let openedWorkspace = router.executeJump(for: observation, openURL: { opened.append($0); return true })
        #expect(openedWorkspace.succeeded)
        #expect(opened == [URL(string: "cursor://file/work/repo")!])
        #expect(!router.executeJump(for: observation).succeeded)
        #expect(!router.executeJump(for: agent(app: "Zed")).succeeded)
    }

    @Test func hostAndFinderFallbackPriority() {
        let router = SessionJumpRouter(runner: JumpCommandRecorder())
        #expect(router.resolveTarget(for: agent(pid: 9, root: "/work/repo")) == .hostProcess(app: "Terminal", pid: 9))
        #expect(router.resolveTarget(for: agent(app: "Other", pid: 9)) == .hostProcess(app: "Other", pid: 9))
        #expect(router.resolveTarget(for: agent(root: "/work/repo", cwd: "/other")) == .finderReveal(path: "/work/repo"))
        #expect(router.resolveTarget(for: agent(cwd: "/work/repo")) == .finderReveal(path: "/work/repo"))
        #expect(router.resolveTarget(for: agent(app: "tmux")) == nil)
        #expect(router.resolveTarget(for: agent()) == nil)
        #expect(router.executeJump(for: agent(pid: 9), activatePID: { $0 == 9 }).succeeded)
        #expect(!router.executeJump(for: agent(pid: 9)).succeeded)
    }

    @Test(arguments: [0, -1, Int.max])
    func invalidHostPIDsCannotBeActivated(pid: Int) {
        let router = SessionJumpRouter(runner: JumpCommandRecorder())
        var activated = false
        #expect(router.resolveTarget(for: agent(pid: pid)) == nil)
        #expect(!router.executeJump(for: agent(pid: pid), activatePID: { _ in activated = true; return true }).succeeded)
        #expect(!activated)
    }

    @Test func finderRevealPassesLiteralPathAsOneArgument() {
        let path = "/work/space name;$(touch ignored)"
        let runner = JumpCommandRecorder()
        let outcome = SessionJumpRouter(runner: runner).executeJump(for: agent(cwd: path))
        #expect(outcome.succeeded)
        #expect(outcome.target == .finderReveal(path: path))
        #expect(runner.requests.count == 1)
        #expect(runner.requests.first?.executable == "/usr/bin/open")
        #expect(runner.requests.first?.arguments == ["-R", path])
    }

    @Test func finderAndUnavailableTargetReportFailure() {
        let runner = JumpCommandRecorder { _ in jumpResult("PRIVATE OUTPUT", exit: 1) }
        let router = SessionJumpRouter(runner: runner)
        let failed = router.executeJump(for: agent(cwd: "/work/repo"))
        #expect(!failed.succeeded)
        #expect(failed.error != nil)
        #expect(!String(describing: failed).contains("PRIVATE"))
        let unavailable = router.executeJump(for: agent())
        #expect(!unavailable.succeeded)
        #expect(unavailable.target == nil)
        #expect(unavailable.error != nil)
    }

    @Test(arguments: ["", "relative/path", "-option", "/work/\u{0}repo", "/work/repo\n"])
    func invalidPathsCannotBecomeJumpTargets(path: String) {
        let runner = JumpCommandRecorder()
        let router = SessionJumpRouter(runner: runner)
        #expect(router.resolveTarget(for: agent(cwd: path)) == nil)
        #expect(!router.executeJump(for: agent(cwd: path)).succeeded)
        #expect(runner.requests.isEmpty)
    }

    @Test func thrownCommandsUseSafeErrorsAndFallbacks() {
        let runner = JumpCommandRecorder { _ in throw NSError(domain: "PRIVATE THROW", code: 1) }
        let router = SessionJumpRouter(runner: runner)
        let observation = agent(app: "Terminal", tty: "ttys001", pid: 9)
        #expect(router.resolveTarget(for: observation) == .terminalTab(app: "Terminal", tty: "ttys001", hostPID: 9))
        #expect(router.executeJump(for: observation, activatePID: { _ in true }).succeeded)
        let failed = router.executeJump(for: observation)
        #expect(!failed.succeeded)
        #expect(!String(describing: failed).contains("PRIVATE"))
    }
}
