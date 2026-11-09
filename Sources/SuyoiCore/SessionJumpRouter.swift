import Darwin
import Foundation

public struct AgentClientVisualProfile: Equatable, Sendable {
    public let agentName: String
    public let symbolName: String
    public let badgeLabel: String
    public let accentRed: Double
    public let accentGreen: Double
    public let accentBlue: Double
    public let deepLinkScheme: String?

    public init(agentName: String, symbolName: String, badgeLabel: String,
                accentRed: Double, accentGreen: Double, accentBlue: Double, deepLinkScheme: String?) {
        self.agentName = agentName
        self.symbolName = symbolName
        self.badgeLabel = badgeLabel
        self.accentRed = accentRed
        self.accentGreen = accentGreen
        self.accentBlue = accentBlue
        self.deepLinkScheme = deepLinkScheme
    }
}

public enum SessionJumpTarget: Equatable, Sendable {
    case tmuxPane(sessionWindowPane: String, tty: String)
    case terminalTab(app: String, tty: String, hostPID: Int?)
    case ideWorkspace(app: String, deepLinkURL: URL?, rootPath: String?, hostPID: Int?)
    case hostProcess(app: String, pid: Int)
    case finderReveal(path: String)
}

public struct SessionJumpOutcome: Equatable, Sendable {
    public let succeeded: Bool
    public let target: SessionJumpTarget?
    public let summary: String
    public let error: String?

    public init(succeeded: Bool, target: SessionJumpTarget?, summary: String, error: String?) {
        self.succeeded = succeeded
        self.target = target
        self.summary = summary
        self.error = error
    }
}

/// Navigation only: selects existing sessions or opens a workspace, without sending terminal input.
public struct SessionJumpRouter: Sendable {
    private let runner: any CommandRunning
    private let verifyProcess: @Sendable (AgentObservation) -> Bool
    private let verifyHost: @Sendable (AgentObservation, Int) -> Bool

    public init(runner: any CommandRunning = CommandRunner()) {
        self.init(runner: runner, verifyProcess: { Self.liveProcessMatches($0) }, verifyHost: { Self.liveHostMatches($0, $1) })
    }

    init(runner: any CommandRunning,
         verifyProcess: @escaping @Sendable (AgentObservation) -> Bool,
         verifyHost: @escaping @Sendable (AgentObservation, Int) -> Bool) {
        self.runner = runner
        self.verifyProcess = verifyProcess
        self.verifyHost = verifyHost
    }

    public static let allSupportedAgentNames: [String] = [
        "Claude Code", "Codex", "OpenCode", "Gemini CLI", "Antigravity CLI", "Hermes Agent",
        "Qwen Code", "Kimi CLI", "OpenClaw", "Pi Agent", "Oh My Pi", "Aider", "Cursor", "Cursor Agent",
        "Windsurf", "Qoder", "CodeBuddy", "GitHub Copilot", "Goose", "Amp", "Droid", "Kiro"
    ]

    public static func visualProfile(for agentName: String) -> AgentClientVisualProfile {
        let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile: (String, String, String, Double, Double, Double, String?)
        switch name.lowercased() {
        case "claude code": profile = ("Claude Code", "sparkles", "CL", 0.85, 0.48, 0.32, "claude://")
        case "codex": profile = ("Codex", "terminal", "CX", 0.24, 0.72, 0.52, "codex://")
        case "opencode": profile = ("OpenCode", "chevron.left.forwardslash.chevron.right", "OC", 0.44, 0.51, 0.96, nil)
        case "gemini cli": profile = ("Gemini CLI", "diamond.fill", "GM", 0.27, 0.57, 0.95, nil)
        case "antigravity cli": profile = ("Antigravity CLI", "airplane", "AG", 0.64, 0.42, 0.93, nil)
        case "hermes agent": profile = ("Hermes Agent", "bolt.horizontal.fill", "HM", 0.94, 0.65, 0.22, nil)
        case "qwen code": profile = ("Qwen Code", "hexagon.fill", "QW", 0.54, 0.38, 0.86, nil)
        case "kimi cli": profile = ("Kimi CLI", "moon.stars.fill", "KM", 0.30, 0.68, 0.87, nil)
        case "openclaw": profile = ("OpenClaw", "hand.raised.fingers.spread.fill", "CW", 0.91, 0.36, 0.40, nil)
        case "pi agent": profile = ("Pi Agent", "function", "PI", 0.92, 0.48, 0.65, nil)
        case "oh my pi": profile = ("Oh My Pi", "circle.hexagongrid.fill", "OP", 0.74, 0.43, 0.69, nil)
        case "aider": profile = ("Aider", "wrench.and.screwdriver.fill", "AI", 0.38, 0.73, 0.35, nil)
        case "cursor", "cursor agent": profile = ("Cursor", "cursorarrow", "CU", 0.63, 0.68, 0.76, "cursor://file")
        case "windsurf": profile = ("Windsurf", "wind", "WS", 0.20, 0.78, 0.71, "windsurf://file")
        case "qoder": profile = ("Qoder", "q.circle.fill", "QD", 0.78, 0.57, 0.29, nil)
        case "codebuddy": profile = ("CodeBuddy", "person.2.fill", "CB", 0.36, 0.63, 0.84, nil)
        case "github copilot": profile = ("GitHub Copilot", "figure.wave", "CP", 0.62, 0.49, 0.88, nil)
        case "goose": profile = ("Goose", "bird.fill", "GS", 0.88, 0.72, 0.28, nil)
        case "amp": profile = ("Amp", "bolt.fill", "AM", 0.94, 0.38, 0.27, nil)
        case "droid": profile = ("Droid", "gearshape.2.fill", "DR", 0.42, 0.75, 0.63, nil)
        case "kiro": profile = ("Kiro", "k.circle.fill", "KR", 0.70, 0.40, 0.94, nil)
        default: profile = (String(name.prefix(80)), "cpu", "AI", 0.55, 0.59, 0.65, nil)
        }
        return AgentClientVisualProfile(agentName: profile.0, symbolName: profile.1, badgeLabel: profile.2,
                                        accentRed: profile.3, accentGreen: profile.4, accentBlue: profile.5,
                                        deepLinkScheme: profile.6)
    }

    public func resolveTarget(for agent: AgentObservation) -> SessionJumpTarget? {
        let tty = Self.normalizedTTY(agent.process.tty)
        let hostPID = Self.validPID(agent.terminalPID)
        if let tty, let pane = tmuxPane(for: tty) {
            return .tmuxPane(sessionWindowPane: pane, tty: tty)
        }
        if let app = agent.terminalApp, ["iTerm2", "Terminal"].contains(app), let tty {
            return .terminalTab(app: app, tty: tty, hostPID: hostPID)
        }
        let path = Self.validPath(agent.project?.rootPath) ?? Self.validPath(agent.process.cwd)
        if let app = agent.terminalApp, let scheme = Self.ideSchemes[app] {
            let url = path.flatMap { path -> URL? in
                var components = URLComponents()
                components.scheme = scheme
                components.host = "file"
                components.path = path
                return components.url
            }
            return .ideWorkspace(app: app, deepLinkURL: url, rootPath: path, hostPID: hostPID)
        }
        if let hostPID {
            return .hostProcess(app: agent.terminalApp ?? "Terminal", pid: hostPID)
        }
        if let path { return .finderReveal(path: path) }
        return nil
    }

    public func executeJump(
        for agent: AgentObservation,
        activatePID: (Int) -> Bool = { _ in false },
        openURL: (URL) -> Bool = { _ in false }
    ) -> SessionJumpOutcome {
        let stale = SessionJumpOutcome(succeeded: false, target: nil, summary: "Session jump unavailable",
                                       error: "Selected process or terminal association changed")
        guard verifyProcess(agent) else { return stale }
        guard let target = resolveTarget(for: agent) else {
            return SessionJumpOutcome(succeeded: false, target: nil, summary: "No session target available",
                                      error: "No terminal, workspace or host could be resolved")
        }
        func success(_ summary: String) -> SessionJumpOutcome {
            SessionJumpOutcome(succeeded: true, target: target, summary: summary, error: nil)
        }
        func failure(_ error: String) -> SessionJumpOutcome {
            SessionJumpOutcome(succeeded: false, target: target, summary: "Session jump unavailable", error: error)
        }
        func activateHost(_ pid: Int) -> Bool {
            verifyProcess(agent) && verifyHost(agent, pid) && activatePID(pid)
        }
        guard verifyProcess(agent) else { return stale }
        switch target {
        case let .tmuxPane(pane, _):
            guard let separator = pane.lastIndex(of: ".") else { return failure("Invalid tmux target") }
            let window = String(pane[..<separator])
            guard runSucceeded(Self.tmuxRequest(["select-window", "-t", window])) else {
                return failure("Could not select the tmux window")
            }
            guard verifyProcess(agent) else { return stale }
            guard runSucceeded(Self.tmuxRequest(["select-pane", "-t", pane])) else {
                return failure("Could not select the tmux pane")
            }
            if let pid = Self.validPID(agent.terminalPID) { _ = activateHost(pid) }
            return success("Selected tmux window and pane")
        case let .terminalTab(app, tty, hostPID):
            let script = app == "Terminal" ? Self.terminalScript : Self.iTermScript
            let request = CommandRequest(executable: "/usr/bin/osascript", arguments: ["-e", script, "/dev/" + tty],
                                         timeout: 5, maximumOutputBytes: 4096)
            if runSucceeded(request) { return success("Selected terminal session") }
            if let hostPID, activateHost(hostPID) { return success("Activated terminal host; session selection unavailable") }
            return failure("Could not select the terminal session or activate its host")
        case let .ideWorkspace(_, url, _, hostPID):
            if let hostPID, activateHost(hostPID) { return success("Activated workspace host") }
            if let url, openURL(url) { return success("Opened workspace link") }
            return failure("Could not activate the IDE or open its workspace link")
        case let .hostProcess(_, pid):
            return activateHost(pid) ? success("Activated session host") : failure("Could not activate the session host")
        case let .finderReveal(path):
            let request = CommandRequest(executable: "/usr/bin/open", arguments: ["-R", path],
                                         timeout: 5, maximumOutputBytes: 4096)
            return runSucceeded(request) ? success("Revealed workspace in Finder") : failure("Could not reveal the workspace")
        }
    }

    private static func liveProcessMatches(_ agent: AgentObservation) -> Bool {
        let uid = Int(getuid())
        let identity = agent.process.identity
        guard identity.isActionEligible, identity.uid == uid, let pid = Int32(exactly: identity.pid),
              let live = DarwinProcessReader().process(pid: pid, uid: uid), live.identity == identity,
              !live.isStopped else { return false }
        return live.tty.map { normalizedTTY($0) ?? $0 } == agent.process.tty.map { normalizedTTY($0) ?? $0 }
    }

    private static func liveHostMatches(_ agent: AgentObservation, _ hostPID: Int) -> Bool {
        let reader = DarwinProcessReader()
        let uid = Int(getuid())
        var processes: [Int: ObservedProcess] = [:]
        var pid = agent.process.pid
        for _ in 0..<64 {
            guard processes[pid] == nil, let value = Int32(exactly: pid),
                  let process = reader.process(pid: value, uid: uid) else { break }
            processes[pid] = process
            if pid == hostPID { break }
            pid = process.parentPID
        }
        guard let live = processes[agent.process.pid], live.identity == agent.process.identity,
              let host = AgentRecognizer.terminalHost(for: live, processesByPID: processes),
              host.pid == hostPID, host.name == agent.terminalApp,
              let capturedHost = processes[hostPID], capturedHost.identity.isActionEligible,
              let hostPID = Int32(exactly: hostPID) else { return false }
        return reader.process(pid: hostPID, uid: uid)?.identity == capturedHost.identity
    }

    private static let ideSchemes = [
        "Cursor": "cursor", "VS Code": "vscode", "Windsurf": "windsurf", "Zed": "zed", "Antigravity": "antigravity"
    ]

    private static func normalizedTTY(_ value: String?) -> String? {
        guard let value else { return nil }
        let name = value.hasPrefix("/dev/") ? String(value.dropFirst(5)) : value
        guard name.hasPrefix("tty"), (4...32).contains(name.utf8.count),
              name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }) else { return nil }
        return name
    }

    private static func validPID(_ pid: Int?) -> Int? {
        guard let pid, pid > 0, Int32(exactly: pid) != nil else { return nil }
        return pid
    }

    private static func validPath(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return path
    }

    private static func tmuxRequest(_ arguments: [String]) -> CommandRequest {
        CommandRequest(executable: "/usr/bin/env", arguments: ["tmux"] + arguments,
                       timeout: 2, maximumOutputBytes: 64 * 1024, includeStandardUserPaths: true)
    }

    private func tmuxPane(for tty: String) -> String? {
        let request = Self.tmuxRequest(["list-panes", "-a", "-F", "#{pane_tty}\t#{session_name}:#{window_index}.#{pane_index}"])
        guard let result = try? runner.run(request), Self.commandSucceeded(result),
              result.stdout.count <= request.maximumOutputBytes else { return nil }
        var matches: [String] = []
        for line in result.stdoutText.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let device = fields.first, Self.normalizedTTY(String(device)) == tty else { continue }
            guard fields.count == 2, Self.validTmuxTarget(String(fields[1])) else { return nil }
            matches.append(String(fields[1]))
            if matches.count > 1 { return nil }
        }
        return matches.first
    }

    private static func validTmuxTarget(_ target: String) -> Bool {
        guard target.utf8.count <= 256 else { return false }
        let parts = target.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let session = parts.first, !session.isEmpty, !session.hasPrefix("-"),
              session.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_- ".unicodeScalars.contains($0) }) else { return false }
        let indices = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return indices.count == 2 && indices.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
    }

    private func runSucceeded(_ request: CommandRequest) -> Bool {
        guard let result = try? runner.run(request) else { return false }
        return Self.commandSucceeded(result)
    }

    private static func commandSucceeded(_ result: CommandResult) -> Bool {
        result.exitCode == 0 && !result.timedOut && !result.truncated
    }

    // Fixed scripts receive the device through argv, and select only a unique match.
    private static let terminalScript = """
    on run argv
        set targetTTY to item 1 of argv
        tell application "Terminal"
            set matchCount to 0
            set targetWindow to missing value
            set targetTab to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is targetTTY then
                        set matchCount to matchCount + 1
                        set targetWindow to contents of w
                        set targetTab to contents of t
                    end if
                end repeat
            end repeat
            if matchCount is not 1 then error "Terminal target is unavailable or ambiguous"
            if tty of targetTab is not targetTTY then error "Terminal association changed"
            set selected tab of targetWindow to targetTab
            set miniaturized of targetWindow to false
            set index of targetWindow to 1
            activate
        end tell
    end run
    """

    private static let iTermScript = """
    on run argv
        set targetTTY to item 1 of argv
        tell application "iTerm2"
            set matchCount to 0
            set targetWindow to missing value
            set targetTab to missing value
            set targetSession to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is targetTTY then
                            set matchCount to matchCount + 1
                            set targetWindow to contents of w
                            set targetTab to contents of t
                            set targetSession to contents of s
                        end if
                    end repeat
                end repeat
            end repeat
            if matchCount is not 1 then error "Terminal target is unavailable or ambiguous"
            if tty of targetSession is not targetTTY then error "Terminal association changed"
            tell targetWindow to select
            tell targetTab to select
            tell targetSession to select
            activate
        end tell
    end run
    """
}
