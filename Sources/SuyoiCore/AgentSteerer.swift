import Foundation
import Darwin

/// Explicit, user-initiated steering. Submitted text and subprocess output never enter results.
public struct AgentSteerer: AgentSteering, Sendable {
    private let processLookup: @Sendable (Int32, Int) -> ObservedProcess?
    private let runner: any CommandRunning
    private let executableResolver: (@Sendable (String) -> String?)?
    private let homeDirectory: URL
    private let nativeJobLauncher: any NativeAgentJobLaunching
    private let terminalForegroundVerifier: TerminalForegroundVerifier

    public init(
        processLookup: (@Sendable (Int32, Int) -> ObservedProcess?)? = nil,
        runner: any CommandRunning = CommandRunner(),
        executableResolver: (@Sendable (String) -> String?)? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        nativeJobLauncher: (any NativeAgentJobLaunching)? = nil
    ) {
        self.init(processLookup: processLookup, runner: runner, executableResolver: executableResolver,
                  homeDirectory: homeDirectory,
                  nativeJobLauncher: nativeJobLauncher, terminalForegroundVerifier: TerminalForegroundVerifier())
    }

    init(
        processLookup: (@Sendable (Int32, Int) -> ObservedProcess?)? = nil,
        runner: any CommandRunning = CommandRunner(),
        executableResolver: (@Sendable (String) -> String?)? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        nativeJobLauncher: (any NativeAgentJobLaunching)? = nil,
        terminalForegroundVerifier: TerminalForegroundVerifier
    ) {
        self.processLookup = processLookup ?? { DarwinProcessReader().process(pid: $0, uid: $1) }
        self.runner = runner
        self.executableResolver = executableResolver
        self.homeDirectory = homeDirectory
        self.nativeJobLauncher = nativeJobLauncher ?? NativeAgentJobLauncher(homeDirectory: homeDirectory)
        self.terminalForegroundVerifier = terminalForegroundVerifier
    }

    public static func isValidSessionID(_ value: String) -> Bool { AgentContextValidation.sessionID(value) != nil }
    public static func isValidTTY(_ value: String) -> Bool {
        let name = value.hasPrefix("/dev/") ? String(value.dropFirst(5)) : value
        guard name.hasPrefix("tty"), name.count > 3, name.count <= 32 else { return false }
        return name.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }
    }

    /// Native continuation availability still depends on an exact target selected in the composer.
    public static func nativeMode(for agent: AgentObservation) -> AgentSteerMode? {
        guard agent.process.identity.isActionEligible, !agent.process.isStopped else { return nil }
        switch agent.agentName {
        case "OpenCode": return .openCodeSession
        case "Codex": return .codexResume
        default: return nil
        }
    }

    public static func preferredMode(for agent: AgentObservation) -> AgentSteerMode? {
        guard agent.process.identity.isActionEligible else { return nil }
        if let tty = agent.process.tty, isValidTTY(tty), ["Terminal", "iTerm2"].contains(agent.terminalApp) { return .terminalTTY }
        return nil
    }
    public static func canSteer(_ agent: AgentObservation) -> Bool {
        preferredMode(for: agent) != nil
    }

    public func steer(agent: AgentObservation, target: NativeSessionTarget, prompt: String, uid: Int = Int(getuid())) -> AgentSteerOutcome {
        continueSession(agent: agent, target: target, prompt: prompt, uid: uid, requireLiveFile: false)
    }

    private func continueSession(agent: AgentObservation, target: NativeSessionTarget, prompt: String,
                                 uid: Int, requireLiveFile: Bool) -> AgentSteerOutcome {
        func failure(_ error: String) -> AgentSteerOutcome {
            AgentSteerOutcome(agentID: agent.id, mode: target.mode, succeeded: false, error: error)
        }
        let identity = agent.process.identity
        guard target.rowIdentity == identity, Self.nativeMode(for: agent) == target.mode else {
            return failure("Selected session does not match this provider or process")
        }
        guard identity.isActionEligible, uid == identity.uid, identity.pid > 1, identity.pid != Int(getpid()),
              let pid = Int32(exactly: identity.pid),
              let live = processLookup(pid, uid), live.identity == identity, !live.isStopped else {
            return failure("Process identity changed, is stopped or process already exited")
        }
        guard let clean = Self.cleanPrompt(prompt) else { return failure("Instruction must contain 1 to 2000 characters") }
        let catalog = NativeSessionCatalog(homeDirectory: homeDirectory)
        let name = target.mode == .openCodeSession ? "opencode" : "codex"
        guard let executable = resolve(name, agent: agent) else { return failure("Agent executable is unavailable") }
        let directory = URL(fileURLWithPath: target.projectPath, isDirectory: true)
        let arguments: [String]
        switch target.mode {
        case .openCodeSession:
            guard catalog.validate(target, for: agent, live: live) else {
                return failure("Selected session or workspace changed")
            }
            let request = CommandRequest(executable: executable, arguments: ["debug", "paths", "db"],
                environment: NativeAgentJobLauncher.environment(for: executable, catalog: catalog),
                timeout: 3, maximumOutputBytes: 4_096, workingDirectory: directory)
            guard let result = try? runner.run(request), result.exitCode == 0, !result.timedOut, !result.truncated,
                  verifiedDatabasePath(result.stdoutText, catalog: catalog) else {
                return failure("This OpenCode executable cannot verify its session store. Update OpenCode and try again.")
            }
            arguments = ["--standalone", "run", "--session", target.sessionID, "--", clean]
        case .codexResume:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            guard let bytes = try? encoder.encode(catalog.codexHome.path),
                  let path = String(data: bytes, encoding: .utf8) else {
                return failure("Codex session store path is unavailable")
            }
            arguments = ["exec", "-c", "sqlite_home=" + path, "resume", target.sessionID, "--", clean]
        case .terminalTTY:
            return failure("Native session target is invalid")
        }
        guard catalog.validate(target, for: agent, live: live) else {
            return failure("Selected session or workspace changed")
        }
        guard let current = processLookup(pid, uid), current.identity == identity, !current.isStopped,
              current.cwd == live.cwd, catalog.projectIsCurrent(target) else {
            return failure("Process identity or workspace changed")
        }
        if requireLiveFile, catalog.verifiedCodexTarget(for: agent) != target {
            return failure("Live process ownership of this session could not be verified")
        }
        do {
            try nativeJobLauncher.launch(executable: executable, arguments: arguments,
                workingDirectory: directory)
            return AgentSteerOutcome(agentID: agent.id, mode: target.mode, succeeded: true,
                detail: "Started continuation of the selected \(agent.agentName) session")
        } catch { return failure("Unable to start local continuation process") }
    }

    private func verifiedDatabasePath(_ output: String, catalog: NativeSessionCatalog) -> Bool {
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return SessionFileEvidence.filesystemPath(URL(fileURLWithPath: path)) == catalog.openCodeDB.path
    }

    private static func cleanPrompt(_ prompt: String) -> String? {
        let clean = String(prompt.unicodeScalars.filter { $0 == "\t" || !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && clean.count <= 2000 ? clean : nil
    }

    public func steer(agent: AgentObservation, prompt: String, uid: Int = Int(getuid())) -> AgentSteerOutcome {
        let terminalMode = Self.preferredMode(for: agent)
        let mode = terminalMode ?? Self.nativeMode(for: agent) ?? .codexResume
        func failure(_ error: String) -> AgentSteerOutcome {
            AgentSteerOutcome(agentID: agent.id, mode: mode, succeeded: false, error: error)
        }
        guard terminalMode != nil else {
            let catalog = NativeSessionCatalog(homeDirectory: homeDirectory)
            guard let target = catalog.verifiedCodexTarget(for: agent) else {
                return failure("No verified steering target is available")
            }
            return continueSession(agent: agent, target: target, prompt: prompt, uid: uid, requireLiveFile: true)
        }
        guard let clean = Self.cleanPrompt(prompt) else { return failure("Instruction must contain 1 to 2000 characters") }
        let identity = agent.process.identity
        guard identity.isActionEligible, uid == identity.uid, identity.pid > 1, identity.pid != Int(getpid()),
              let pid = Int32(exactly: identity.pid) else { return failure("Process identity is not eligible for this user's action") }
        guard let live = processLookup(pid, uid), live.identity == identity, !live.isStopped else {
            return failure("Process identity changed, is stopped or process already exited")
        }
        guard let tty = agent.process.tty, Self.isValidTTY(tty), live.tty == tty,
              let terminal = agent.terminalApp, ["Terminal", "iTerm2"].contains(terminal) else {
            return failure("Terminal association changed or is unavailable")
        }
        let device = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
        let request = CommandRequest(executable: "/usr/bin/osascript", arguments: ["-e", terminal == "Terminal" ? Self.terminalScript : Self.iTermScript, device, clean], timeout: 8)
        // Apple Events cannot atomically bind delivery to the kernel's foreground process.
        guard terminalForegroundVerifier.verify(agent: agent, live: live, device: device) else {
            return failure("Selected agent is not the verified foreground receiver of this terminal")
        }
        do {
            let result = try runner.run(request)
            guard result.exitCode == 0, !result.timedOut, !result.truncated else {
                return failure(result.timedOut ? "Steering command timed out; delivery is unconfirmed" : "Steering command did not confirm delivery")
            }
            return AgentSteerOutcome(agentID: agent.id, mode: mode, succeeded: true, detail: "Sent instruction to \(terminal) (\(tty))")
        } catch { return failure("Unable to execute steering command") }
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
            if not (exists s) then error "Terminal target no longer exists"
            if tty of s is not targetTTY then error "Terminal association changed"
            tell s to write text promptText
        end tell
    end run
    """
}
