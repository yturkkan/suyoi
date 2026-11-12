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
        case "Claude Code": return .claudeResume
        default: return nil
        }
    }

    public static func preferredMode(for agent: AgentObservation) -> AgentSteerMode? {
        guard agent.process.identity.isActionEligible, !agent.process.isStopped,
              let tty = agent.process.tty, isValidTTY(tty) else { return nil }
        switch agent.terminalApp {
        case "Terminal", "iTerm2":
            return .terminalTTY
        case "tmux":
            return .tmuxPane
        case "WezTerm":
            return .weztermPane
        case "kitty":
            return .kittyWindow
        default:
            return nil
        }
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
        let name: String
        switch target.mode {
        case .openCodeSession: name = "opencode"
        case .codexResume: name = "codex"
        case .claudeResume: name = "claude"
        case .terminalTTY, .tmuxPane, .weztermPane, .kittyWindow, .geminiResume:
            return failure("Native session target is invalid")
        }
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
            arguments = ["run", "--session", target.sessionID, "--", clean]
        case .codexResume:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            guard let bytes = try? encoder.encode(catalog.codexHome.path),
                  let path = String(data: bytes, encoding: .utf8) else {
                return failure("Codex session store path is unavailable")
            }
            arguments = ["exec", "-c", "sqlite_home=" + path, "resume", target.sessionID, "--", clean]
        case .claudeResume:
            arguments = ["--print", "--resume", target.sessionID, "--", clean]
        case .terminalTTY, .tmuxPane, .weztermPane, .kittyWindow, .geminiResume:
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
        let metadata = NativeContinuationMetadata(
            agentID: agent.id,
            agentName: agent.agentName,
            sessionID: target.sessionID,
            projectPath: target.projectPath
        )
        do {
            try nativeJobLauncher.launch(
                executable: executable,
                arguments: arguments,
                workingDirectory: directory,
                metadata: metadata
            )
            return AgentSteerOutcome(agentID: agent.id, mode: target.mode, succeeded: true,
                detail: "Started continuation of the selected \(agent.agentName) session")
        } catch let NativeAgentJobLauncher.Error.startupExited(code) {
            return failure("Local continuation process exited immediately (code \(code)). Check CLI authentication and setup.")
        } catch {
            return failure("Unable to start local continuation process")
        }
    }

    private func verifiedDatabasePath(_ output: String, catalog: NativeSessionCatalog) -> Bool {
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return SessionFileEvidence.filesystemPath(URL(fileURLWithPath: path)) == catalog.openCodeDB.path
    }

    private static let lineBreakScalars: Set<Unicode.Scalar> = [
        "\n", "\r", "\u{0085}", "\u{2028}", "\u{2029}"
    ]

    static func cleanPrompt(_ prompt: String) -> String? {
        var result = String.UnicodeScalarView()
        var pendingLineBreakSpace = false
        for scalar in prompt.unicodeScalars {
            if lineBreakScalars.contains(scalar) {
                pendingLineBreakSpace = true
                continue
            }
            guard scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar) else {
                continue
            }
            if pendingLineBreakSpace {
                result.append(" ")
                pendingLineBreakSpace = false
            }
            result.append(scalar)
        }
        let clean = String(result).trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && clean.count <= 2000 ? clean : nil
    }

    public func steer(agent: AgentObservation, prompt: String, uid: Int = Int(getuid())) -> AgentSteerOutcome {
        let terminalMode = Self.preferredMode(for: agent)
        let mode = terminalMode ?? Self.nativeMode(for: agent) ?? .codexResume
        func failure(_ error: String) -> AgentSteerOutcome {
            AgentSteerOutcome(agentID: agent.id, mode: mode, succeeded: false, error: error)
        }
        guard let terminalMode else {
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
        guard let tty = agent.process.tty, Self.isValidTTY(tty), live.tty == tty else {
            return failure("Terminal association changed or is unavailable")
        }
        let device = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
        switch terminalMode {
        case .tmuxPane:
            return steerTmux(agent: agent, pid: pid, uid: uid, live: live, tty: tty, device: device, clean: clean)
        case .weztermPane:
            return steerWezTerm(agent: agent, pid: pid, uid: uid, live: live, tty: tty, device: device, clean: clean)
        case .kittyWindow:
            return steerKitty(agent: agent, pid: pid, uid: uid, live: live, tty: tty, device: device, clean: clean)
        case .terminalTTY:
            break
        case .openCodeSession, .codexResume, .claudeResume, .geminiResume:
            return failure("Terminal association changed or is unavailable")
        }
        guard let terminal = agent.terminalApp, ["Terminal", "iTerm2"].contains(terminal) else {
            return failure("Terminal association changed or is unavailable")
        }
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

    private func steerTmux(
        agent: AgentObservation,
        pid: Int32,
        uid: Int,
        live: ObservedProcess,
        tty: String,
        device: String,
        clean: String
    ) -> AgentSteerOutcome {
        func failure(_ error: String) -> AgentSteerOutcome {
            AgentSteerOutcome(agentID: agent.id, mode: .tmuxPane, succeeded: false, error: error)
        }
        guard agent.terminalApp == "tmux" else {
            return failure("Terminal association changed or is unavailable")
        }
        guard terminalForegroundVerifier.verify(agent: agent, live: live, device: device) else {
            return failure("Selected agent is not the verified foreground receiver of this terminal")
        }
        let listRequest = CommandRequest(
            executable: "/usr/bin/env",
            arguments: ["tmux", "list-panes", "-a", "-F", "#{pane_tty}\t#{pane_id}\t#{pane_dead}\t#{pane_in_mode}"],
            timeout: 3,
            maximumOutputBytes: 64 * 1_024,
            includeStandardUserPaths: true
        )
        let listResult: CommandResult
        do {
            listResult = try runner.run(listRequest)
        } catch {
            return failure("Unable to inspect tmux panes")
        }
        guard listResult.exitCode == 0, !listResult.timedOut, !listResult.truncated else {
            return failure(listResult.timedOut ? "tmux pane lookup timed out" : "tmux server or pane list is unavailable")
        }
        var matches: [(paneID: String, paneDead: String, paneInMode: String)] = []
        for rawLine in listResult.stdoutText.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else {
                return failure("tmux pane target is unavailable or ambiguous")
            }
            let rowDevice = parts[0].hasPrefix("/dev/") ? parts[0] : "/dev/" + parts[0]
            if rowDevice == device {
                matches.append((parts[1], parts[2], parts[3]))
            }
        }
        guard matches.count == 1, let pane = matches.first, Self.isValidTmuxPaneID(pane.paneID) else {
            return failure("tmux pane target is unavailable or ambiguous")
        }
        guard pane.paneDead == "0" else {
            return failure("Selected tmux pane is no longer active")
        }
        guard pane.paneInMode == "0" else {
            return failure("Selected tmux pane is in copy or view mode")
        }
        guard let current = processLookup(pid, uid), current.identity == agent.process.identity,
              !current.isStopped, current.tty == tty,
              terminalForegroundVerifier.verify(agent: agent, live: current, device: device) else {
            return failure("Selected agent is not the verified foreground receiver of this terminal")
        }
        let sendLiteral = CommandRequest(
            executable: "/usr/bin/env",
            arguments: ["tmux", "send-keys", "-t", pane.paneID, "-l", "--", clean],
            timeout: 5,
            maximumOutputBytes: 16 * 1_024,
            includeStandardUserPaths: true
        )
        let sendEnter = CommandRequest(
            executable: "/usr/bin/env",
            arguments: ["tmux", "send-keys", "-t", pane.paneID, "Enter"],
            timeout: 5,
            maximumOutputBytes: 16 * 1_024,
            includeStandardUserPaths: true
        )
        do {
            let literalResult = try runner.run(sendLiteral)
            guard literalResult.exitCode == 0, !literalResult.timedOut, !literalResult.truncated else {
                return failure(literalResult.timedOut ? "Steering command timed out; delivery is unconfirmed" : "Steering command did not confirm delivery")
            }
            let enterResult = try runner.run(sendEnter)
            guard enterResult.exitCode == 0, !enterResult.timedOut, !enterResult.truncated else {
                return failure(enterResult.timedOut ? "Steering command timed out; delivery is unconfirmed" : "Steering command did not confirm delivery")
            }
            return AgentSteerOutcome(agentID: agent.id, mode: .tmuxPane, succeeded: true, detail: "Sent instruction to tmux (\(tty))")
        } catch {
            return failure("Unable to execute steering command")
        }
    }

    private struct WezTermPaneRow: Decodable {
        let pane_id: Int
        let tty_name: String?
    }

    private func steerWezTerm(
        agent: AgentObservation,
        pid: Int32,
        uid: Int,
        live: ObservedProcess,
        tty: String,
        device: String,
        clean: String
    ) -> AgentSteerOutcome {
        func failure(_ error: String) -> AgentSteerOutcome {
            AgentSteerOutcome(agentID: agent.id, mode: .weztermPane, succeeded: false, error: error)
        }
        guard agent.terminalApp == "WezTerm" else {
            return failure("Terminal association changed or is unavailable")
        }
        guard terminalForegroundVerifier.verify(agent: agent, live: live, device: device) else {
            return failure("Selected agent is not the verified foreground receiver of this terminal")
        }
        guard let executable = resolveTerminalCLI("wezterm") else {
            return failure("WezTerm CLI executable is unavailable")
        }
        let listRequest = CommandRequest(
            executable: executable,
            arguments: ["cli", "list", "--format", "json"],
            timeout: 3,
            maximumOutputBytes: 128 * 1_024,
            includeStandardUserPaths: true
        )
        let listResult: CommandResult
        do {
            listResult = try runner.run(listRequest)
        } catch {
            return failure("Unable to inspect WezTerm panes")
        }
        guard listResult.exitCode == 0, !listResult.timedOut, !listResult.truncated,
              let panes = try? JSONDecoder().decode([WezTermPaneRow].self, from: listResult.stdout) else {
            return failure(listResult.timedOut ? "WezTerm pane lookup timed out" : "WezTerm CLI or pane list is unavailable")
        }
        let matches = panes.filter { row in
            guard row.pane_id >= 0, let rawTTY = row.tty_name, !rawTTY.isEmpty else { return false }
            let normalized = rawTTY.hasPrefix("/dev/") ? rawTTY : "/dev/" + rawTTY
            return normalized == device
        }
        guard matches.count == 1, let pane = matches.first else {
            return failure("WezTerm pane target is unavailable or ambiguous")
        }
        guard let current = processLookup(pid, uid), current.identity == agent.process.identity,
              !current.isStopped, current.tty == tty,
              terminalForegroundVerifier.verify(agent: agent, live: current, device: device) else {
            return failure("Selected agent is not the verified foreground receiver of this terminal")
        }
        let paneIDText = String(pane.pane_id)
        let sendText = CommandRequest(
            executable: executable,
            arguments: ["cli", "send-text", "--pane-id", paneIDText, "--no-paste", "--", clean],
            timeout: 5,
            maximumOutputBytes: 16 * 1_024,
            includeStandardUserPaths: true
        )
        let sendEnter = CommandRequest(
            executable: executable,
            arguments: ["cli", "send-text", "--pane-id", paneIDText, "--no-paste", "--", "\r"],
            timeout: 5,
            maximumOutputBytes: 16 * 1_024,
            includeStandardUserPaths: true
        )
        do {
            let textResult = try runner.run(sendText)
            guard textResult.exitCode == 0, !textResult.timedOut, !textResult.truncated else {
                return failure(textResult.timedOut ? "Steering command timed out; delivery is unconfirmed" : "Steering command did not confirm delivery")
            }
            let enterResult = try runner.run(sendEnter)
            guard enterResult.exitCode == 0, !enterResult.timedOut, !enterResult.truncated else {
                return failure(enterResult.timedOut ? "Steering command timed out; delivery is unconfirmed" : "Steering command did not confirm delivery")
            }
            return AgentSteerOutcome(agentID: agent.id, mode: .weztermPane, succeeded: true, detail: "Sent instruction to WezTerm (\(tty))")
        } catch {
            return failure("Unable to execute steering command")
        }
    }

    private struct KittyOSWindowRow: Decodable {
        struct TabRow: Decodable {
            struct WindowRow: Decodable {
                struct ForegroundProcessRow: Decodable {
                    let pid: Int?
                }
                let id: Int
                let is_self: Bool?
                let foreground_processes: [ForegroundProcessRow]?
            }
            let windows: [WindowRow]
        }
        let tabs: [TabRow]
    }

    private func steerKitty(
        agent: AgentObservation,
        pid: Int32,
        uid: Int,
        live: ObservedProcess,
        tty: String,
        device: String,
        clean: String
    ) -> AgentSteerOutcome {
        func failure(_ error: String) -> AgentSteerOutcome {
            AgentSteerOutcome(agentID: agent.id, mode: .kittyWindow, succeeded: false, error: error)
        }
        guard agent.terminalApp == "kitty" else {
            return failure("Terminal association changed or is unavailable")
        }
        guard terminalForegroundVerifier.verify(agent: agent, live: live, device: device) else {
            return failure("Selected agent is not the verified foreground receiver of this terminal")
        }
        guard let executable = resolveTerminalCLI("kitty") else {
            return failure("kitty CLI executable is unavailable")
        }
        let listRequest = CommandRequest(
            executable: executable,
            arguments: ["@", "ls"],
            timeout: 3,
            maximumOutputBytes: 256 * 1_024,
            includeStandardUserPaths: true
        )
        let listResult: CommandResult
        do {
            listResult = try runner.run(listRequest)
        } catch {
            return failure("Unable to inspect kitty windows")
        }
        guard listResult.exitCode == 0, !listResult.timedOut, !listResult.truncated,
              let osWindows = try? JSONDecoder().decode([KittyOSWindowRow].self, from: listResult.stdout) else {
            return failure(
                listResult.timedOut
                    ? "kitty window lookup timed out"
                    : "kitty remote control is unavailable; enable allow_remote_control in kitty.conf"
            )
        }
        let targetPID = Int(pid)
        var matchingWindowIDs: [Int] = []
        for osWindow in osWindows {
            for tab in osWindow.tabs {
                for window in tab.windows where window.id >= 0 && window.is_self != true {
                    let fgPIDs = (window.foreground_processes ?? []).compactMap(\.pid)
                    if fgPIDs.contains(targetPID) {
                        matchingWindowIDs.append(window.id)
                    }
                }
            }
        }
        guard matchingWindowIDs.count == 1, let windowID = matchingWindowIDs.first else {
            return failure("kitty window target is unavailable or ambiguous")
        }
        guard let current = processLookup(pid, uid), current.identity == agent.process.identity,
              !current.isStopped, current.tty == tty,
              terminalForegroundVerifier.verify(agent: agent, live: current, device: device) else {
            return failure("Selected agent is not the verified foreground receiver of this terminal")
        }
        let escapedClean = clean.replacingOccurrences(of: "\\", with: "\\\\")
        let matchSpec = "id:\(windowID)"
        let sendText = CommandRequest(
            executable: executable,
            arguments: ["@", "send-text", "--match", matchSpec, "--", escapedClean],
            timeout: 5,
            maximumOutputBytes: 16 * 1_024,
            includeStandardUserPaths: true
        )
        let sendEnter = CommandRequest(
            executable: executable,
            arguments: ["@", "send-text", "--match", matchSpec, "\\r"],
            timeout: 5,
            maximumOutputBytes: 16 * 1_024,
            includeStandardUserPaths: true
        )
        do {
            let textResult = try runner.run(sendText)
            guard textResult.exitCode == 0, !textResult.timedOut, !textResult.truncated else {
                return failure(textResult.timedOut ? "Steering command timed out; delivery is unconfirmed" : "Steering command did not confirm delivery")
            }
            let enterResult = try runner.run(sendEnter)
            guard enterResult.exitCode == 0, !enterResult.timedOut, !enterResult.truncated else {
                return failure(enterResult.timedOut ? "Steering command timed out; delivery is unconfirmed" : "Steering command did not confirm delivery")
            }
            return AgentSteerOutcome(agentID: agent.id, mode: .kittyWindow, succeeded: true, detail: "Sent instruction to kitty (\(tty))")
        } catch {
            return failure("Unable to execute steering command")
        }
    }

    private static func isValidTmuxPaneID(_ value: String) -> Bool {
        guard value.hasPrefix("%"), (2...16).contains(value.utf8.count) else { return false }
        return value.dropFirst().utf8.allSatisfy { (48...57).contains($0) }
    }

    private func resolveTerminalCLI(_ name: String) -> String? {
        if let executableResolver {
            guard let path = executableResolver(name), path.hasPrefix("/"), URL(fileURLWithPath: path).lastPathComponent == name else { return nil }
            return path
        }
        var candidates: [String] = []
        if name == "wezterm" {
            candidates.append("/Applications/WezTerm.app/Contents/MacOS/wezterm")
            candidates.append(homeDirectory.appendingPathComponent("Applications/WezTerm.app/Contents/MacOS/wezterm").path)
        } else if name == "kitty" {
            candidates.append("/Applications/kitty.app/Contents/MacOS/kitty")
            candidates.append(homeDirectory.appendingPathComponent("Applications/kitty.app/Contents/MacOS/kitty").path)
        }
        candidates += ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") where dir.hasPrefix("/") && dir != "/" {
            candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func resolve(_ name: String, agent: AgentObservation) -> String? {
        resolveCLIExecutable(name, preferredExecutable: agent.process.executable)
    }

    private func resolveCLIExecutable(_ name: String, preferredExecutable: String? = nil) -> String? {
        if let executableResolver {
            guard let path = executableResolver(name), path.hasPrefix("/"), URL(fileURLWithPath: path).lastPathComponent == name else { return nil }
            return path
        }
        var candidates: [String] = []
        if let preferredExecutable, preferredExecutable.hasSuffix("/" + name) {
            candidates.append(preferredExecutable)
        }
        for dir in AgentChatStreamRunner.searchDirectories(homeDirectory: homeDirectory) {
            candidates.append(URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(name).path)
        }
        if name == "codex" { candidates.append("/Applications/Codex.app/Contents/Resources/codex") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func cleanMultilinePrompt(_ prompt: String) -> String? {
        let normalized = prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            if scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar) {
                scalars.append(scalar)
            }
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return (!cleaned.isEmpty && cleaned.count <= 4_000) ? cleaned : nil
    }

    public func steerIndexedSession(
        session: IndexedAgentSession,
        prompt: String,
        preferLiveTerminal: Bool = true,
        uid: Int = Int(getuid())
    ) -> AgentSteerOutcome {
        if preferLiveTerminal,
           let obs = session.liveObservation,
           let liveMode = Self.preferredMode(for: obs),
           liveMode.isLiveTerminalDelivery {
            return steer(agent: obs, prompt: prompt, uid: uid)
        }

        let agentID = session.liveObservation?.id ?? 0
        if let obs = session.liveObservation,
           let pid = Int32(exactly: obs.process.pid), pid > 1,
           let current = processLookup(pid, uid), current.identity == obs.process.identity, !current.isStopped {
            // The session is still owned by a running process. Never start a second writer
            // via unvalidated CLI resume; only the validated live paths may deliver.
            return steer(agent: obs, prompt: prompt, uid: uid)
        }
        guard let mode = session.nativeSteerMode, session.canResumeNatively else {
            if let obs = session.liveObservation {
                return steer(agent: obs, prompt: prompt, uid: uid)
            }
            return AgentSteerOutcome(
                agentID: agentID,
                mode: session.liveSteerMode ?? .claudeResume,
                succeeded: false,
                error: "This session does not support background CLI continuation"
            )
        }

        func failure(_ error: String) -> AgentSteerOutcome {
            AgentSteerOutcome(agentID: agentID, mode: mode, succeeded: false, error: error)
        }

        guard uid == Int(getuid()) else {
            return failure("User identity mismatch for local session continuation")
        }
        guard let clean = Self.cleanMultilinePrompt(prompt) else {
            return failure("Instruction must contain 1 to 4000 characters")
        }
        guard let rawSessionID = session.sessionID,
              let validSessionID = AgentContextValidation.sessionID(rawSessionID) else {
            return failure("Session identifier is missing or invalid")
        }
        guard let rawProjectPath = session.projectPath,
              rawProjectPath.hasPrefix("/"),
              rawProjectPath != "/" else {
            return failure("Workspace folder is unavailable for this session")
        }

        let projectURL = URL(fileURLWithPath: rawProjectPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let homeResolved = homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        var isDir: ObjCBool = false
        guard projectURL.path != "/",
              projectURL.path != homeResolved,
              FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDir),
              isDir.boolValue else {
            return failure("Workspace directory no longer exists on disk")
        }

        let cliName: String
        switch mode {
        case .claudeResume:
            guard UUID(uuidString: validSessionID) != nil else {
                return failure("Claude Code session ID must be a valid UUID")
            }
            cliName = "claude"
        case .codexResume:
            guard UUID(uuidString: validSessionID) != nil else {
                return failure("Codex session ID must be a valid UUID")
            }
            cliName = "codex"
        case .openCodeSession:
            cliName = "opencode"
        case .geminiResume:
            cliName = "gemini"
        case .terminalTTY, .tmuxPane, .weztermPane, .kittyWindow:
            return failure("Invalid continuation mode")
        }

        guard let executable = resolveCLIExecutable(cliName, preferredExecutable: session.liveObservation?.process.executable) else {
            return failure("\(session.agentName) CLI executable was not found in PATH or standard install locations")
        }

        let catalog = NativeSessionCatalog(homeDirectory: homeDirectory)
        let arguments: [String]
        switch mode {
        case .claudeResume:
            arguments = ["--print", "--resume", validSessionID, "--", clean]
        case .codexResume:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            guard let bytes = try? encoder.encode(catalog.codexHome.path),
                  let quotedHome = String(data: bytes, encoding: .utf8) else {
                return failure("Codex home path could not be encoded")
            }
            arguments = ["exec", "-c", "sqlite_home=" + quotedHome, "resume", validSessionID, "--", clean]
        case .openCodeSession:
            arguments = ["run", "--session", validSessionID, "--", clean]
        case .geminiResume:
            arguments = ["--resume", validSessionID, "--prompt=" + clean]
        case .terminalTTY, .tmuxPane, .weztermPane, .kittyWindow:
            return failure("Invalid continuation mode")
        }

        let metadata = NativeContinuationMetadata(
            agentID: agentID,
            agentName: session.agentName,
            sessionID: validSessionID,
            projectPath: projectURL.path
        )
        do {
            try nativeJobLauncher.launch(
                executable: executable,
                arguments: arguments,
                workingDirectory: projectURL,
                metadata: metadata
            )
            return AgentSteerOutcome(
                agentID: agentID,
                mode: mode,
                succeeded: true,
                detail: "Resumed \(session.agentName) session in \(projectURL.lastPathComponent)"
            )
        } catch let NativeAgentJobLauncher.Error.startupExited(code) {
            return failure("\(session.agentName) exited immediately (code \(code)). Check CLI login or session status.")
        } catch {
            return failure("Unable to launch \(session.agentName) continuation process")
        }
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
            set atShell to false
            try
                set atShell to (is at shell prompt of s)
            end try
            if atShell then error "Terminal target is at a shell"
            tell s to write text promptText
        end tell
    end run
    """
}
