import Foundation
import Darwin

/// Explicit, user-initiated steering. Submitted text and subprocess output never enter results.
public struct AgentSteerer: AgentSteering, Sendable {
    private let processLookup: @Sendable (Int32, Int) -> ObservedProcess?
    private let runner: any CommandRunning
    private let executableResolver: (@Sendable (String) -> String?)?
    private let homeDirectory: URL

    public init(processLookup: (@Sendable (Int32, Int) -> ObservedProcess?)? = nil, runner: any CommandRunning = CommandRunner(), executableResolver: (@Sendable (String) -> String?)? = nil, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.processLookup = processLookup ?? { DarwinProcessReader().process(pid: $0, uid: $1) }
        self.runner = runner
        self.executableResolver = executableResolver
        self.homeDirectory = homeDirectory
    }

    public static func isValidSessionID(_ value: String) -> Bool { AgentContextValidation.sessionID(value) != nil }
    public static func isValidTTY(_ value: String) -> Bool {
        let name = value.hasPrefix("/dev/") ? String(value.dropFirst(5)) : value
        guard name.hasPrefix("tty"), name.count > 3, name.count <= 32 else { return false }
        return name.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }
    }

    public static func preferredMode(for agent: AgentObservation) -> AgentSteerMode? {
        guard agent.process.identity.isActionEligible else { return nil }
        if let tty = agent.process.tty, isValidTTY(tty), ["Terminal", "iTerm2"].contains(agent.terminalApp) { return .terminalTTY }
        if agent.agentName == "OpenCode", let sid = agent.sessionID, isValidSessionID(sid) { return .openCodeSession }
        if agent.agentName == "Codex", let sid = agent.sessionID, isValidSessionID(sid) { return .codexResume }
        return nil
    }
    public static func canSteer(_ agent: AgentObservation) -> Bool { preferredMode(for: agent) != nil }

    public func steer(agent: AgentObservation, prompt: String, uid: Int = Int(getuid())) -> AgentSteerOutcome {
        let selected = Self.preferredMode(for: agent)
        // The contract requires a mode even for a rejected, unsupported target.
        let mode = selected ?? (agent.agentName == "OpenCode" ? .openCodeSession : .codexResume)
        func failure(_ error: String) -> AgentSteerOutcome {
            AgentSteerOutcome(agentID: agent.id, mode: mode, succeeded: false, error: error)
        }
        guard selected != nil else { return failure("No verified steering target is available") }
        let clean = String(prompt.unicodeScalars.filter { $0 == "\t" || !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 2000 else { return failure("Instruction must contain 1 to 2000 characters") }
        let identity = agent.process.identity
        guard identity.isActionEligible, uid == identity.uid, identity.pid > 1, identity.pid != Int(getpid()),
              let pid = Int32(exactly: identity.pid) else { return failure("Process identity is not eligible for this user's action") }
        guard let live = processLookup(pid, uid), live.identity == identity, !live.isStopped else {
            return failure("Process identity changed, is stopped or process already exited")
        }
        let request: CommandRequest
        let detail: String
        switch mode {
        case .terminalTTY:
            guard let tty = agent.process.tty, Self.isValidTTY(tty), live.tty == tty,
                  let terminal = agent.terminalApp, ["Terminal", "iTerm2"].contains(terminal) else {
                return failure("Terminal association changed or is unavailable")
            }
            let device = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
            request = CommandRequest(executable: "/usr/bin/osascript", arguments: ["-e", terminal == "Terminal" ? Self.terminalScript : Self.iTermScript, device, clean], timeout: 8)
            detail = "Sent instruction to \(terminal) (\(tty))"
        case .openCodeSession, .codexResume:
            guard let sid = agent.sessionID, Self.isValidSessionID(sid) else { return failure("Session identifier is invalid") }
            let name = mode == .openCodeSession ? "opencode" : "codex"
            guard let executable = resolve(name, agent: agent) else { return failure("Agent executable is unavailable") }
            // The explicit option terminator also protects prompts beginning with '-'.
            let arguments = mode == .openCodeSession ? ["run", "--session", sid, "--", clean] : ["exec", "resume", sid, "--", clean]
            request = CommandRequest(executable: executable, arguments: arguments, timeout: 60,
                                     workingDirectory: workingDirectory(for: agent), includeStandardUserPaths: true)
            detail = mode == .openCodeSession ? "Sent instruction to OpenCode session" : "Resumed Codex session"
        }
        do {
            let result = try runner.run(request)
            guard result.exitCode == 0, !result.timedOut, !result.truncated else {
                return failure(result.timedOut ? "Steering command timed out; delivery is unconfirmed" : "Steering command did not confirm delivery")
            }
            return AgentSteerOutcome(agentID: agent.id, mode: mode, succeeded: true, detail: detail)
        } catch { return failure("Unable to execute steering command") }
    }

    private func workingDirectory(for agent: AgentObservation) -> URL? {
        for path in [agent.project?.rootPath, agent.process.cwd].compactMap({ $0 }) where path.hasPrefix("/") {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }

    private func resolve(_ name: String, agent: AgentObservation) -> String? {
        if let executableResolver {
            guard let path = executableResolver(name), path.hasPrefix("/"), URL(fileURLWithPath: path).lastPathComponent == name else { return nil }
            return path
        }
        var candidates: [String] = []
        if agent.process.executable.hasSuffix("/" + name) { candidates.append(agent.process.executable) }
        candidates += ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        candidates += [".opencode/bin", ".local/bin", ".npm-global/bin", ".bun/bin", "Library/pnpm", ".volta/bin", ".asdf/shims", ".local/share/mise/shims"].map {
            homeDirectory.appendingPathComponent($0).appendingPathComponent(name).path
        }
        if name == "codex" { candidates.append("/Applications/Codex.app/Contents/Resources/codex") }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") where dir.hasPrefix("/") && dir != "/" {
            candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Fixed scripts: all untrusted values arrive via argv. Count matches before sending.
    private static let terminalScript = """
    on run argv
        set targetTTY to item 1 of argv
        set promptText to item 2 of argv
        tell application "Terminal"
            set matches to {}
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is targetTTY then set end of matches to contents of t
                end repeat
            end repeat
            if (count of matches) is not 1 then error "Terminal target is unavailable or ambiguous"
            set t to item 1 of matches
            if not (exists t) then error "Terminal target no longer exists"
            if tty of t is not targetTTY then error "Terminal association changed"
            if not busy of t then error "Terminal target is at a shell"
            do script promptText in t
        end tell
    end run
    """
    private static let iTermScript = """
    on run argv
        set targetTTY to item 1 of argv
        set promptText to item 2 of argv
        tell application "iTerm2"
            set matches to {}
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is targetTTY then set end of matches to contents of s
                    end repeat
                end repeat
            end repeat
            if (count of matches) is not 1 then error "Terminal target is unavailable or ambiguous"
            set s to item 1 of matches
            tell s to write text promptText
        end tell
    end run
    """
}
