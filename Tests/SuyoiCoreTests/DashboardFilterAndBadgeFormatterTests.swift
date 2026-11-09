import Foundation
import Testing
import SuyoiCore

@Suite("Dashboard filter and badge formatter")
struct DashboardFilterAndBadgeFormatterTests {
    @Test func statusBarDisplayStyleCasesMatchExpectedRawValues() {
        #expect(StatusBarDisplayStyle.iconOnly.rawValue == "Icon Only")
        #expect(StatusBarDisplayStyle.agentsAndServers.rawValue == "Agents & Servers")
        #expect(StatusBarDisplayStyle.agentsServersAndQuota.rawValue == "Agents, Servers & Quota %")
        #expect(StatusBarDisplayStyle.agentsAndMemory.rawValue == "Agents & Memory")
        #expect(StatusBarDisplayStyle.allCases.count == 4)
    }

    @Test func iconOnlyStyleHidesTextExceptWhenApprovalsArePending() {
        let agents = [makeAgent(id: 101, activityState: .waiting)]
        let servers = [makeServer(rootPID: 201)]

        #expect(
            DashboardFilterAndBadgeFormatter.formatStatusBarTitle(
                style: .iconOnly,
                agents: agents,
                servers: servers,
                pendingApprovalsCount: 0,
                highestQuotaPercent: 88.0
            ) == ""
        )

        #expect(
            DashboardFilterAndBadgeFormatter.formatStatusBarTitle(
                style: .iconOnly,
                agents: agents,
                servers: servers,
                pendingApprovalsCount: 2,
                highestQuotaPercent: 88.0
            ) == " ⏳2"
        )
    }

    @Test func agentsAndServersStyleFormatsCountsAndWaitingIndicators() {
        #expect(
            DashboardFilterAndBadgeFormatter.formatStatusBarTitle(
                style: .agentsAndServers,
                agents: [],
                servers: [],
                pendingApprovalsCount: 0,
                highestQuotaPercent: nil
            ) == ""
        )

        let agents = [
            makeAgent(id: 101, activityState: .active),
            makeAgent(id: 102, activityState: .waiting)
        ]
        let servers = [makeServer(rootPID: 201)]

        #expect(
            DashboardFilterAndBadgeFormatter.formatStatusBarTitle(
                style: .agentsAndServers,
                agents: agents,
                servers: servers,
                pendingApprovalsCount: 0,
                highestQuotaPercent: nil
            ) == " 2A·1⏳ 1S"
        )

        let activeOnly = [
            makeAgent(id: 101, activityState: .active),
            makeAgent(id: 102, activityState: .idle)
        ]
        #expect(
            DashboardFilterAndBadgeFormatter.formatStatusBarTitle(
                style: .agentsAndServers,
                agents: activeOnly,
                servers: servers,
                pendingApprovalsCount: 1,
                highestQuotaPercent: nil
            ) == " 2A·1⏳ 1S"
        )

        #expect(
            DashboardFilterAndBadgeFormatter.formatStatusBarTitle(
                style: .agentsAndServers,
                agents: activeOnly,
                servers: [],
                pendingApprovalsCount: 0,
                highestQuotaPercent: nil
            ) == " 2A"
        )

        #expect(
            DashboardFilterAndBadgeFormatter.formatStatusBarTitle(
                style: .agentsAndServers,
                agents: [],
                servers: [],
                pendingApprovalsCount: 3,
                highestQuotaPercent: nil
            ) == " ⏳3"
        )
    }

    @Test func agentsServersAndQuotaStyleAppendsRoundedPercentage() {
        let agents = [
            makeAgent(id: 101, activityState: .active),
            makeAgent(id: 102, activityState: .waiting)
        ]
        let servers = [makeServer(rootPID: 201)]

        #expect(
            DashboardFilterAndBadgeFormatter.formatStatusBarTitle(
                style: .agentsServersAndQuota,
                agents: agents,
                servers: servers,
                pendingApprovalsCount: 0,
                highestQuotaPercent: 74.6
            ) == " 2A·1⏳ 1S · 75%"
        )

        #expect(
            DashboardFilterAndBadgeFormatter.formatStatusBarTitle(
                style: .agentsServersAndQuota,
                agents: agents,
                servers: servers,
                pendingApprovalsCount: 0,
                highestQuotaPercent: nil
            ) == " 2A·1⏳ 1S"
        )
    }

    @Test func agentsAndMemoryStyleAppendsConciseFootprintOrResidentMemory() {
        let agentsMegabytes = [
            makeAgent(id: 101, residentBytes: 200 * 1_048_576, footprintBytes: 250 * 1_048_576),
            makeAgent(id: 102, residentBytes: 200 * 1_048_576, footprintBytes: nil)
        ]
        #expect(
            DashboardFilterAndBadgeFormatter.formatStatusBarTitle(
                style: .agentsAndMemory,
                agents: agentsMegabytes,
                servers: [],
                pendingApprovalsCount: 0,
                highestQuotaPercent: nil
            ) == " 2A · 450M"
        )

        let agentsGigabytes = [
            makeAgent(id: 101, residentBytes: 500 * 1_048_576, footprintBytes: Int64(1.2 * 1_073_741_824.0))
        ]
        #expect(
            DashboardFilterAndBadgeFormatter.formatStatusBarTitle(
                style: .agentsAndMemory,
                agents: agentsGigabytes,
                servers: [makeServer(rootPID: 201)],
                pendingApprovalsCount: 0,
                highestQuotaPercent: nil
            ) == " 1A 1S · 1.2G"
        )
    }

    @Test func filterAgentsMatchesAllSupportedFieldsCaseInsensitively() {
        let first = makeAgent(
            id: 4101,
            agentName: "Claude Code",
            cwd: "/workspace/alpha-service",
            tty: "ttys004",
            projectName: "AlphaService",
            gitBranch: "feature/oauth-flow",
            rootPath: "/workspace/alpha-service",
            sessionTitle: "Refactor token verifier",
            currentTask: "Running unit suite"
        )
        let second = makeAgent(
            id: 8202,
            agentName: "Codex",
            cwd: "/workspace/billing-web",
            tty: "ttys019",
            projectName: "BillingWeb",
            gitBranch: "main",
            rootPath: "/workspace/billing-web",
            sessionTitle: "Fix invoice table",
            currentTask: "Editing components"
        )
        let agents = [first, second]

        #expect(DashboardFilterAndBadgeFormatter.filterAgents(agents, query: "") == agents)
        #expect(DashboardFilterAndBadgeFormatter.filterAgents(agents, query: "   \n\t ") == agents)
        #expect(DashboardFilterAndBadgeFormatter.filterAgents(agents, query: "claude").map(\.id) == [4101])
        #expect(DashboardFilterAndBadgeFormatter.filterAgents(agents, query: "ALPHASERVICE").map(\.id) == [4101])
        #expect(DashboardFilterAndBadgeFormatter.filterAgents(agents, query: "oauth-flow").map(\.id) == [4101])
        #expect(DashboardFilterAndBadgeFormatter.filterAgents(agents, query: "/workspace/billing-web").map(\.id) == [8202])
        #expect(DashboardFilterAndBadgeFormatter.filterAgents(agents, query: "token verifier").map(\.id) == [4101])
        #expect(DashboardFilterAndBadgeFormatter.filterAgents(agents, query: "editing components").map(\.id) == [8202])
        #expect(DashboardFilterAndBadgeFormatter.filterAgents(agents, query: "ttys019").map(\.id) == [8202])
        #expect(DashboardFilterAndBadgeFormatter.filterAgents(agents, query: "4101").map(\.id) == [4101])
        #expect(DashboardFilterAndBadgeFormatter.filterAgents(agents, query: "nonexistent").isEmpty)
    }

    @Test func filterServersMatchesProjectFrameworkBranchPortPIDAndNamedLocalhost() {
        let first = makeServer(
            id: "srv-1",
            rootPID: 5501,
            name: "vite",
            ports: [5173],
            projectName: "My Landing App",
            framework: "Vite",
            gitBranch: "feat/hero-banner"
        )
        let second = makeServer(
            id: "srv-2",
            rootPID: 6602,
            name: "next-server",
            ports: [3000, 3001],
            projectName: "Docs Portal",
            framework: "Next.js",
            gitBranch: "release/v2"
        )
        let groups = [first, second]

        #expect(DashboardFilterAndBadgeFormatter.filterServers(groups, query: "") == groups)
        #expect(DashboardFilterAndBadgeFormatter.filterServers(groups, query: "  ") == groups)
        #expect(DashboardFilterAndBadgeFormatter.filterServers(groups, query: "next-server").map(\.id) == ["srv-2"])
        #expect(DashboardFilterAndBadgeFormatter.filterServers(groups, query: "landing app").map(\.id) == ["srv-1"])
        #expect(DashboardFilterAndBadgeFormatter.filterServers(groups, query: "next.js").map(\.id) == ["srv-2"])
        #expect(DashboardFilterAndBadgeFormatter.filterServers(groups, query: "hero-banner").map(\.id) == ["srv-1"])
        #expect(DashboardFilterAndBadgeFormatter.filterServers(groups, query: "6602").map(\.id) == ["srv-2"])
        #expect(DashboardFilterAndBadgeFormatter.filterServers(groups, query: "3000").map(\.id) == ["srv-2"])
        #expect(DashboardFilterAndBadgeFormatter.filterServers(groups, query: ":5173").map(\.id) == ["srv-1"])
        #expect(DashboardFilterAndBadgeFormatter.filterServers(groups, query: "my-landing-app.localhost").map(\.id) == ["srv-1"])
        #expect(DashboardFilterAndBadgeFormatter.filterServers(groups, query: "9999").isEmpty)
    }

    @Test func filterCleanupCandidatesMatchesPathCategoryAndAgentName() {
        let candidates = [
            CleanupCandidate(
                path: "/workspace/app/node_modules",
                category: "Node Dependencies",
                bytes: 120_000,
                partial: false,
                scope: .projectArtifact,
                agentName: nil
            ),
            CleanupCandidate(
                path: "/tmp/caches/codex/logs",
                category: "Session Logs",
                bytes: 64_000,
                partial: false,
                scope: .agentCache,
                agentName: "Codex"
            )
        ]

        #expect(DashboardFilterAndBadgeFormatter.filterCleanupCandidates(candidates, query: "") == candidates)
        #expect(DashboardFilterAndBadgeFormatter.filterCleanupCandidates(candidates, query: "   ") == candidates)
        #expect(DashboardFilterAndBadgeFormatter.filterCleanupCandidates(candidates, query: "node_modules").map(\.path) == ["/workspace/app/node_modules"])
        #expect(DashboardFilterAndBadgeFormatter.filterCleanupCandidates(candidates, query: "session logs").map(\.path) == ["/tmp/caches/codex/logs"])
        #expect(DashboardFilterAndBadgeFormatter.filterCleanupCandidates(candidates, query: "CODEX").map(\.path) == ["/tmp/caches/codex/logs"])
        #expect(DashboardFilterAndBadgeFormatter.filterCleanupCandidates(candidates, query: "missing").isEmpty)
    }

    // MARK: - Fixtures

    private func makeAgent(
        id: Int,
        agentName: String = "Codex",
        residentBytes: Int64 = 100 * 1_048_576,
        footprintBytes: Int64? = nil,
        cwd: String? = "/workspace/project",
        tty: String? = "ttys001",
        projectName: String? = "Project",
        gitBranch: String? = "main",
        rootPath: String? = "/workspace/project",
        activityState: AgentActivityState? = .active,
        sessionTitle: String? = nil,
        currentTask: String? = nil
    ) -> AgentObservation {
        let proc = ObservedProcess(
            pid: id,
            parentPID: 1,
            uid: 501,
            cpuPercent: 4.0,
            residentBytes: residentBytes,
            executable: "/usr/local/bin/codex",
            startTimeMicroseconds: 1_000_000,
            cwd: cwd,
            tty: tty,
            isStopped: false,
            footprintBytes: footprintBytes
        )
        let project = projectName.map {
            ProjectContext(
                rootPath: rootPath ?? "/workspace/project",
                name: $0,
                framework: "SwiftPM",
                gitBranch: gitBranch,
                gitCommit: "abc1234",
                isWorktree: false
            )
        }
        return AgentObservation(
            id: id,
            agentName: agentName,
            process: proc,
            project: project,
            terminalApp: "Terminal",
            statusSource: .processOnly,
            childServerPorts: [],
            activityState: activityState,
            sessionTitle: sessionTitle,
            currentTask: currentTask
        )
    }

    private func makeServer(
        id: String = "server-1",
        rootPID: Int,
        name: String = "node",
        ports: [Int] = [3000],
        projectName: String? = "WebApp",
        framework: String? = "Vite",
        gitBranch: String? = "main"
    ) -> ServerGroup {
        let project = projectName.map {
            ProjectContext(
                rootPath: "/workspace/\($0.lowercased())",
                name: $0,
                framework: framework,
                gitBranch: gitBranch,
                gitCommit: "def5678",
                isWorktree: false
            )
        }
        let listeners = ports.map {
            Listener(pid: rootPID, processName: name, address: "127.0.0.1", port: $0)
        }
        return ServerGroup(
            id: id,
            rootPID: rootPID,
            name: name,
            memberPIDs: [rootPID],
            listeners: listeners,
            project: project,
            cpuPercent: 1.0,
            residentBytes: 50 * 1_048_576,
            footprintBytes: nil,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            stoppedByAgentBoundary: false
        )
    }
}
