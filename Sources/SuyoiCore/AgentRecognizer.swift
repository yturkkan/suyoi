import Foundation

/// Executable-name hints only; never evidence of an agent's task/session state.
public enum AgentRecognizer {
    public static func agentName(for process: ObservedProcess) -> String? {
        guard !process.executable.contains(".app/Contents/Frameworks/") else { return nil }
        if let name = process.agentName { return name }
        switch process.name {
        case "codex", "Codex": return "Codex"
        case "claude": return "Claude Code"
        case "opencode", "opencode-cli", "OpenCode": return "OpenCode"
        case "aider": return "Aider"
        case "gemini": return "Gemini CLI"
        case "cursor-agent": return "Cursor Agent"
        case "goose": return "Goose"
        case "amp": return "Amp"
        case "droid": return "Droid"
        case "qwen": return "Qwen Code"
        case "kiro": return "Kiro"
        case "antigravity", "agy": return "Antigravity CLI"
        case "hermes", "hermes-agent": return "Hermes Agent"
        case "kimi", "kimi-cli": return "Kimi CLI"
        case "openclaw": return "OpenClaw"
        case "pi", "pi-agent": return "Pi Agent"
        case "omp", "oh-my-pi": return "Oh My Pi"
        case "qoder", "qodercli", "qoderclicn": return "Qoder"
        case "codebuddy", "workbuddy": return "CodeBuddy"
        case "copilot", "github-copilot-cli": return "GitHub Copilot"
        case "windsurf-agent": return "Windsurf"
        default: return nil
        }
    }

    public static func isAgent(_ process: ObservedProcess) -> Bool { agentName(for: process) != nil }

    public static func terminalApp(for process: ObservedProcess, processesByPID: [Int: ObservedProcess]) -> String? {
        terminalHost(for: process, processesByPID: processesByPID)?.name
    }

    public static func terminalHost(for process: ObservedProcess, processesByPID: [Int: ObservedProcess]) -> (name: String, pid: Int)? {
        var current: ObservedProcess? = process
        var visited = Set<Int>()
        for _ in 0..<64 {
            guard let item = current, item.uid == process.uid, visited.insert(item.pid).inserted else { break }
            let components = item.executable.split(separator: "/").map(String.init)
            let apps: [(String, String)] = [("Terminal.app", "Terminal"), ("iTerm.app", "iTerm2"),
                ("iTerm2.app", "iTerm2"), ("Ghostty.app", "Ghostty"), ("Warp.app", "Warp"),
                ("WezTerm.app", "WezTerm"), ("Alacritty.app", "Alacritty"), ("Cursor.app", "Cursor"),
                ("Code.app", "VS Code"), ("Zed.app", "Zed"), ("Windsurf.app", "Windsurf"),
                ("kitty.app", "kitty"), ("Antigravity.app", "Antigravity"),
                ("ChatGPT.app", "ChatGPT"), ("OpenCode.app", "OpenCode")]
            if let app = apps.first(where: { components.contains($0.0) }) { return (app.1, item.pid) }
            switch item.name {
            case "iTerm2": return ("iTerm2", item.pid)
            case "ghostty": return ("Ghostty", item.pid)
            case "WezTerm", "wezterm-gui": return ("WezTerm", item.pid)
            case "Alacritty": return ("Alacritty", item.pid)
            case "kitty": return ("kitty", item.pid)
            case "Windsurf": return ("Windsurf", item.pid)
            case "tmux": return ("tmux", item.pid)
            default: break
            }
            current = processesByPID[item.parentPID]
        }
        return nil
    }

    /// Cwd inheritance stops at a user boundary and never uses `/` as a project.
    public static func workingDirectory(for process: ObservedProcess, processesByPID: [Int: ObservedProcess]) -> String? {
        var current: ObservedProcess? = process
        var visited = Set<Int>()
        for _ in 0..<64 {
            guard let item = current, item.uid == process.uid, visited.insert(item.pid).inserted else { break }
            if let cwd = item.cwd {
                let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
                return path == "/" ? nil : path
            }
            current = processesByPID[item.parentPID]
        }
        return nil
    }

    public static func observations(processes: [ObservedProcess], serverGroups: [ServerGroup], projectsByPath: [String: ProjectContext], homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentObservation] {
        let tree = ProcessTree(processes: processes)
        return tree.processesByPID.values.sorted { $0.pid < $1.pid }.compactMap { process in
            guard let name = agentName(for: process) else { return nil }
            let cwd = workingDirectory(for: process, processesByPID: tree.processesByPID)
            let ports = serverGroups.filter { group in
                ([group.rootPID] + group.memberPIDs).contains { pid in
                    pid == process.pid || tree.ancestors(of: pid).contains(process.pid)
                }
            }.flatMap { $0.listeners.map(\.port) }
            let host = terminalHost(for: process, processesByPID: tree.processesByPID)
            let activity = AgentActivityEvaluator().evaluate(process: process, allProcesses: processes)
            let project = cwd.flatMap { projectsByPath[$0] }
            let context = AgentTaskInspector(homeDirectory: homeDirectory).inspect(agentName: name, process: process, projectRoot: project?.rootPath ?? cwd, allProcesses: processes)
            return AgentObservation(id: process.pid, agentName: name, process: process,
                project: project,
                terminalApp: host?.name,
                statusSource: activity.statusSource, childServerPorts: Set(ports).sorted(),
                activityState: activity.state, activityDetail: activity.detail, lastActivityAt: activity.lastActivityAt, terminalPID: host?.pid,
                sessionID: context.sessionID, sessionTitle: context.sessionTitle, currentTask: context.currentTask)
        }
    }
}
