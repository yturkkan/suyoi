import Foundation
import Testing
import SuyoiCore

@Suite("Server presentation")
struct ServerPresentationTests {
    @Test(arguments: [
        ("My Landing App", "my-landing-app"),
        ("Suyoi Web", "suyoi-web"),
        ("  --API__v2...Server--  ", "api-v2-server"),
        ("app\t\nserver", "app-server"),
        ("APP-123", "app-123"),
        ("123", "123"),
        ("a", "a"),
        ("app/../../server?x=1#test", "app-server-x-1-test"),
        ("app🚀server", "app-server")
    ])
    func sanitizesNames(rawName: String, expected: String) {
        #expect(ServerPresentation.sanitizedSubdomain(from: rawName) == expected)
    }

    @Test(arguments: ["", " \t\n", "---___...", "🚀", "東京", "localhost", "LOCALHOST", " --localhost-- "])
    func rejectsEmptyAndReservedLabels(rawName: String) {
        #expect(ServerPresentation.sanitizedSubdomain(from: rawName) == nil)
    }

    @Test func limitsLabelsTo63ASCIICharactersAndTrimsTruncatedHyphens() {
        let boundary = String(repeating: "a", count: 63)
        #expect(ServerPresentation.sanitizedSubdomain(from: boundary) == boundary)
        #expect(ServerPresentation.sanitizedSubdomain(from: boundary + "extra") == boundary)
        let beforeHyphen = String(repeating: "b", count: 62)
        #expect(ServerPresentation.sanitizedSubdomain(from: beforeHyphen + "-suffix") == beforeHyphen)
    }

    @Test(arguments: ["École café", "İstanbul Web", "ＡＰＰ", "a\u{0000}b", "a\u{202E}b"])
    func unicodeAndControlsCannotEscapeDNSLabel(rawName: String) throws {
        guard let label = ServerPresentation.sanitizedSubdomain(from: rawName) else { return }
        #expect((1...63).contains(label.utf8.count))
        #expect(label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
        #expect(label.first != "-" && label.last != "-")
    }

    @Test func namedURLPrefersProjectNameAndPreservesPort() throws {
        let url = try #require(ServerPresentation.namedLocalhostURL(
            for: group(name: "node", projectName: "My Landing App", ports: [5173, 3000])))
        #expect(url.absoluteString == "http://my-landing-app.localhost:5173")
        #expect(url.scheme == "http")
        #expect(url.host == "my-landing-app.localhost")
        #expect(url.port == 5173)
        #expect(url.user == nil && url.password == nil && url.query == nil && url.fragment == nil)
    }

    @Test func namedURLUsesServerNameWithoutProject() {
        #expect(ServerPresentation.namedLocalhostURL(for: group(name: "Suyoi Web"))?.absoluteString
            == "http://suyoi-web.localhost:3000")
    }

    @Test(arguments: ["", "localhost", "---"])
    func invalidProjectNameDoesNotFallBackToServerName(projectName: String) {
        #expect(ServerPresentation.namedLocalhostURL(for: group(name: "Valid Server", projectName: projectName)) == nil)
    }

    @Test func invalidServerNameDoesNotPreventStandardURL() {
        let server = group(name: "localhost")
        #expect(ServerPresentation.namedLocalhostURL(for: server) == nil)
        #expect(ServerPresentation.standardLocalhostURL(for: server)?.absoluteString == "http://localhost:3000")
    }

    @Test(arguments: [1, 65535])
    func bothURLsAcceptBoundaryPorts(port: Int) {
        let server = group(ports: [port])
        #expect(ServerPresentation.namedLocalhostURL(for: server)?.absoluteString == "http://dev-server.localhost:\(port)")
        #expect(ServerPresentation.standardLocalhostURL(for: server)?.absoluteString == "http://localhost:\(port)")
    }

    @Test(arguments: [Int.min, -1, 0, 65536, Int.max])
    func bothURLsRejectInvalidFirstPortWithoutSkippingIt(port: Int) {
        let server = group(ports: [port, 3000])
        #expect(ServerPresentation.namedLocalhostURL(for: server) == nil)
        #expect(ServerPresentation.standardLocalhostURL(for: server) == nil)
    }

    @Test func bothURLsRequireListenerAndUseFirstListener() {
        #expect(ServerPresentation.namedLocalhostURL(for: group(ports: [])) == nil)
        #expect(ServerPresentation.standardLocalhostURL(for: group(ports: [])) == nil)
        #expect(ServerPresentation.standardLocalhostURL(for: group(ports: [8080, 3000]))?.absoluteString
            == "http://localhost:8080")
    }

    @Test func badgeRequiresKnownStartTime() {
        #expect(ServerPresentation.healthBadge(for: group(), now: now) == nil)
    }

    @Test(arguments: [-60.0, 0.0, 59.999])
    func noBadgeForFutureOrNewServer(uptime: TimeInterval) {
        #expect(ServerPresentation.healthBadge(for: group(uptime: uptime), now: now) == nil)
    }

    @Test(arguments: [
        (60.0, "Up 1m"), (119.0, "Up 1m"), (3599.0, "Up 59m"),
        (3600.0, "Up 1h"), (7199.0, "Up 1h"), (90000.0, "Up 25h")
    ])
    func activeBadgeFormatsWholeMinutesOrHours(uptime: TimeInterval, expected: String) throws {
        let badge = try #require(ServerPresentation.healthBadge(for: group(cpu: 2, uptime: uptime), now: now))
        #expect(badge.state == .active)
        #expect(badge.label == expected)
        #expect(!badge.detail.isEmpty)
    }

    @Test(arguments: [0.0, 0.199, 0.2, 1.0])
    func recentServerSeparatesWarmAndActiveCPU(cpu: Double) throws {
        let badge = try #require(ServerPresentation.healthBadge(for: group(cpu: cpu, uptime: 120), now: now))
        #expect(badge.state == (cpu < 0.2 ? .warm : .active))
        #expect(badge.label == "Up 2m")
    }

    @Test func missingCPUUsesZeroForClassification() {
        #expect(ServerPresentation.healthBadge(for: group(cpu: nil, uptime: 120), now: now)?.state == .warm)
        #expect(ServerPresentation.healthBadge(for: group(cpu: nil, uptime: 7200), now: now)?.state == .idleStale)
    }

    @Test(arguments: [0.0, 0.199])
    func staleThresholdIsInclusiveForLowCPU(cpu: Double) throws {
        #expect(ServerPresentation.healthBadge(for: group(cpu: cpu, uptime: 7199), now: now)?.state == .warm)
        let badge = try #require(ServerPresentation.healthBadge(for: group(cpu: cpu, uptime: 7200), now: now))
        #expect(badge.state == .idleStale)
        #expect(badge.label == "Idle 2h")
        #expect(badge.detail.contains("2 hours"))
        #expect(badge.detail.lowercased().contains("idle"))
    }

    @Test(arguments: [0.2, 5.0])
    func oldBusyServerRemainsActive(cpu: Double) {
        let badge = ServerPresentation.healthBadge(for: group(cpu: cpu, uptime: 10800), now: now)
        #expect(badge?.state == .active)
        #expect(badge?.label == "Up 3h")
    }

    @Test func customStaleThresholdIsRespected() {
        let server = group(cpu: 0, uptime: 10800)
        #expect(ServerPresentation.healthBadge(for: server, now: now, staleThresholdSeconds: 14400)?.state == .warm)
        #expect(ServerPresentation.healthBadge(for: server, now: now, staleThresholdSeconds: 10800)?.label == "Idle 3h")
        #expect(ServerPresentation.healthBadge(for: group(cpu: 0, uptime: 600), now: now,
            staleThresholdSeconds: 600)?.label == "Idle 10m")
    }

    @Test func staleLabelRoundsDownWholeHours() {
        let badge = ServerPresentation.healthBadge(for: group(cpu: 0, uptime: 10799), now: now)
        #expect(badge?.state == .idleStale)
        #expect(badge?.label == "Idle 2h")
    }

    @Test func nonFiniteTimesDoNotProduceBadges() {
        #expect(ServerPresentation.healthBadge(for: group(uptime: .infinity), now: now) == nil)
        #expect(ServerPresentation.healthBadge(for: group(uptime: .nan), now: now) == nil)
        #expect(ServerPresentation.healthBadge(for: group(uptime: 120), now: Date(timeIntervalSince1970: .infinity)) == nil)
    }

    private var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    private func group(
        name: String = "Dev Server", projectName: String? = nil, ports: [Int] = [3000],
        cpu: Double? = 0, uptime: TimeInterval? = nil
    ) -> ServerGroup {
        let project = projectName.map {
            ProjectContext(rootPath: "/fixture/project", name: $0, framework: nil,
                gitBranch: nil, gitCommit: nil, isWorktree: false)
        }
        return ServerGroup(id: "server", rootPID: 42, name: name, memberPIDs: [42],
            listeners: ports.map { Listener(pid: 42, processName: "node", address: "127.0.0.1", port: $0) },
            project: project, cpuPercent: cpu, residentBytes: 0, footprintBytes: nil,
            startedAt: uptime.map { now.addingTimeInterval(-$0) }, stoppedByAgentBoundary: false)
    }
}
