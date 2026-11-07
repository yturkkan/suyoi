import Foundation
import Testing
@testable import SuyoiCore

@Suite("Agent and server process context")
struct ProcessContextTests {
    private func process(_ pid: Int, _ parent: Int = 1, _ executable: String = "/usr/local/bin/node", cwd: String? = "/projects/app", uid: Int = 501, cpu: Double = 2, rss: Int64 = 100, footprint: Int64? = 150, start: UInt64? = 1_000_000) -> ObservedProcess {
        ObservedProcess(pid: pid, parentPID: parent, uid: uid, cpuPercent: cpu, residentBytes: rss,
            executable: executable, startTimeMicroseconds: start, cwd: cwd, footprintBytes: footprint)
    }
    private func listener(_ pid: Int, _ port: Int, address: String = "127.0.0.1") -> Listener {
        Listener(pid: pid, processName: "node", address: address, port: port)
    }

    @Test func exactAgentNames() {
        let names = ["codex": "Codex", "Codex": "Codex", "claude": "Claude Code", "opencode": "OpenCode",
            "opencode-cli": "OpenCode", "OpenCode": "OpenCode", "aider": "Aider", "gemini": "Gemini CLI",
            "cursor-agent": "Cursor Agent", "goose": "Goose", "amp": "Amp", "droid": "Droid", "qwen": "Qwen Code", "kiro": "Kiro"]
        for (executable, expected) in names {
            #expect(AgentRecognizer.agentName(for: process(1, 0, "/bin/" + executable)) == expected)
        }
        for path in ["/bin/Codex Helper", "/bin/OpenCode Helper", "/bin/claude-worker", "/bin/notcodex", "/bin/GEMINI",
            "/Applications/Codex.app/Contents/Frameworks/Codex Helper", "/Applications/OpenCode.app/Contents/Frameworks/OpenCode Helper (Renderer)",
            "/Applications/Codex.app/Contents/Frameworks/X.framework/codex", "/Applications/OpenCode.app/Contents/Frameworks/OpenCode"] {
            #expect(!AgentRecognizer.isAgent(process(1, 0, path)))
        }
    }

    @Test func terminalParents() {
        let terminals = ["/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal": "Terminal",
            "/Applications/iTerm.app/Contents/MacOS/iTerm2": "iTerm2", "/bin/iTerm2": "iTerm2",
            "/Applications/Ghostty.app/Contents/MacOS/ghostty": "Ghostty", "/bin/ghostty": "Ghostty",
            "/Applications/Warp.app/Contents/MacOS/stable": "Warp", "/bin/WezTerm": "WezTerm", "/bin/wezterm-gui": "WezTerm",
            "/bin/Alacritty": "Alacritty", "/Applications/Cursor.app/Contents/MacOS/Cursor": "Cursor",
            "/Applications/Code.app/Contents/MacOS/Electron": "VS Code", "/Applications/Zed.app/Contents/MacOS/zed": "Zed",
            "/Applications/Antigravity.app/Contents/MacOS/Electron": "Antigravity", "/bin/tmux": "tmux"]
        for (path, name) in terminals {
            let agent = process(3, 2, "/bin/codex")
            let tree = ProcessTree(processes: [process(1, 0, path), process(2, 1, "/bin/zsh"), agent])
            #expect(AgentRecognizer.terminalApp(for: agent, processesByPID: tree.processesByPID) == name)
        }
    }

    @Test func multiplePortsAndWorkersCountEachProcessOnce() throws {
        let processes = [process(10, 1), process(11, 10, "/bin/node", cpu: 3, rss: 200), process(12, 10, "/bin/node", cpu: 4, rss: 300)]
        let groups = ProcessTree(processes: processes).groupServers(listeners: [listener(10, 3000), listener(11, 3000), listener(11, 3001), listener(12, 3001), listener(10, 3000, address: "::1")])
        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group.rootPID == 10)
        #expect(group.memberPIDs == [10, 11, 12])
        #expect(Set(group.listeners.map(\.port)) == [3000, 3001])
        #expect(group.cpuPercent == 9)
        #expect(group.residentBytes == 600)
        #expect(group.footprintBytes == 450)
        #expect(group.startedAt == Date(timeIntervalSince1970: 1))
        let aggregate = ServerResources.aggregate(groups: groups + groups, processes: processes + processes)
        #expect(aggregate.residentBytes == 600)
        #expect(aggregate.cpuPercent == 9)
        #expect(aggregate.footprintBytes == 450)
    }

    @Test func agentBoundaryAndIndependentSiblingServers() throws {
        for agent in ["claude", "codex", "gemini", "opencode", "aider"] {
            let processes = [process(10, 1, "/bin/" + agent), process(11, 10), process(12, 10)]
            let groups = ProcessTree(processes: processes).groupServers(listeners: [listener(11, 3000), listener(12, 4000)])
            #expect(groups.count == 2)
            #expect(groups.allSatisfy { $0.stoppedByAgentBoundary })
            #expect(groups.allSatisfy { !$0.memberPIDs.contains(10) })
            let observations = AgentRecognizer.observations(processes: processes, serverGroups: groups, projectsByPath: [:])
            #expect(observations.first?.childServerPorts == [3000, 4000])
            #expect(observations.first?.statusSource == .processOnly)
        }
        let shellProcesses = [process(20, 1, "/bin/zsh"), process(21, 20), process(22, 20)]
        let groups = ProcessTree(processes: shellProcesses).groupServers(listeners: [listener(21, 3000), listener(22, 4000)])
        #expect(groups.map(\.rootPID) == [21, 22])
        // Even the same port number does not join unrelated sibling services.
        #expect(ProcessTree(processes: shellProcesses).groupServers(listeners: [listener(21, 3000), listener(22, 3000, address: "::1")]).count == 2)
    }

    @Test func launchersAndProjectBoundaries() throws {
        let processes = [process(10, 1, "/bin/pnpm"), process(11, 10, "/bin/sh"), process(12, 11)]
        #expect(ProcessTree(processes: processes).groupServers(listeners: [listener(12, 3000)]).first?.rootPID == 12)
        let different = [process(10, 1, "/bin/node", cwd: "/projects/other"), process(11, 10)]
        #expect(ProcessTree(processes: different).groupServers(listeners: [listener(11, 3000)]).first?.rootPID == 11)
        let gui = [process(10, 1, "/Applications/Example.app/Contents/MacOS/node"), process(11, 10)]
        #expect(ProcessTree(processes: gui).groupServers(listeners: [listener(11, 3000)]).first?.rootPID == 11)
        let unknownLauncher = [process(10, 1, "/bin/npm", cwd: nil), process(11, 10)]
        #expect(ProcessTree(processes: unknownLauncher).groupServers(listeners: [listener(11, 3000)]).first?.rootPID == 10)
        let custom = ProcessTree(processes: processes, agentBoundary: { $0.pid == 11 }).groupServers(listeners: [listener(12, 3000)])
        #expect(custom.first?.rootPID == 12)
        #expect(custom.first?.stoppedByAgentBoundary == true)
        let agent = [process(10, 1, "/bin/codex"), process(11, 10)]
        #expect(ProcessTree(processes: agent, agentBoundary: { _ in false }).groupServers(listeners: [listener(11, 3000)]).first?.stoppedByAgentBoundary == true)
        let python = [process(10, 1, "/bin/python313"), process(11, 10, "/bin/worker")]
        #expect(ProcessTree(processes: python).groupServers(listeners: [listener(11, 8000)]).first?.rootPID == 10)
    }

    @Test func transitiveSharedPortReloaderGrouping() throws {
        // Non-runner worker names prevent upward root coalescing; shared sockets
        // still join the ancestor-related components, transitively.
        let processes = [process(10, 1, "/bin/reloader"), process(11, 10, "/bin/worker"), process(12, 11, "/bin/worker")]
        let groups = ProcessTree(processes: processes).groupServers(listeners: [listener(10, 3000), listener(11, 3000), listener(11, 3001), listener(12, 3001)])
        #expect(groups.count == 1)
        #expect(groups.first?.rootPID == 10)
        #expect(groups.first?.residentBytes == 300)
    }

    @Test func cyclesAndDepthBounds() {
        let processes = [process(10, 11), process(11, 12), process(12, 10)]
        let tree = ProcessTree(processes: processes)
        #expect(tree.ancestors(of: 10) == [11, 12])
        #expect(tree.descendants(of: 10) == [12, 11])
        #expect(tree.groupServers(listeners: [listener(10, 3000), listener(12, 4000)]).count >= 1)
        let longChain = (1...100).map { process($0, $0 + 1) }
        #expect(ProcessTree(processes: longChain).ancestors(of: 1).count == 64)
        #expect(ProcessTree(processes: longChain).descendants(of: 100).count == 64)
    }

    @Test func projectInheritanceAndUserBoundaries() throws {
        let context = ProjectContext(rootPath: "/projects/app", name: "app", framework: nil, gitBranch: nil, gitCommit: nil, isWorktree: false)
        let agent = process(3, 2, "/bin/codex", cwd: nil)
        let processes = [process(1, 0, "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"), process(2, 1, "/bin/zsh"), agent]
        let observations = AgentRecognizer.observations(processes: processes, serverGroups: [], projectsByPath: ["/projects/app": context])
        #expect(observations.first?.project == context)
        #expect(observations.first?.terminalApp == "Terminal")
        let otherUser = ProcessTree(processes: [agent, process(2, 1, "/bin/zsh", uid: 0)])
        #expect(AgentRecognizer.workingDirectory(for: agent, processesByPID: otherUser.processesByPID) == nil)
        let rootDirectory = ProcessTree(processes: [agent, process(2, 1, "/bin/zsh", cwd: "/"), processes[0]])
        #expect(AgentRecognizer.workingDirectory(for: agent, processesByPID: rootDirectory.processesByPID) == nil)
    }

    @Test func resourceIdentityAndUnknownFootprint() {
        let first = process(10, start: 1)
        let reused = process(10, start: 2)
        #expect(ServerResources(processes: [first, first, reused]).residentBytes == 200)
        #expect(ServerResources(processes: [first, process(11, footprint: nil)]).footprintBytes == nil)
        #expect(ServerResources(processes: []).cpuPercent == nil)
        #expect(ProcessTree(processes: [first, reused, first]).processesByPID[10]?.startTimeMicroseconds == 2)
        let unknown = ProcessTree(processes: []).groupServers(listeners: [listener(99, 3000)])
        #expect(unknown.first?.cpuPercent == nil)
        #expect(unknown.first?.startedAt == nil)
    }
}

@Test func wrapperAgentAndTerminalPID() throws {
    let host = ObservedProcess(pid: 10, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0, executable: "/Applications/Windsurf.app/Contents/MacOS/Electron")
    let agent = ObservedProcess(pid: 11, parentPID: 10, uid: 501, cpuPercent: 3, residentBytes: 0, executable: "/bin/node", agentInvocation: AgentInvocation(agentName: "Codex", runtime: "node", entrypoint: "codex"))
    #expect(AgentRecognizer.isAgent(agent))
    let observation = try #require(AgentRecognizer.observations(processes: [host, agent], serverGroups: [], projectsByPath: [:]).first)
    #expect(observation.terminalApp == "Windsurf")
    #expect(observation.terminalPID == 10)
    #expect(observation.activityState == .active)
}
