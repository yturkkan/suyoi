import Foundation
import Testing
@testable import SuyoiCore

private actor QuotaMockTransport: QuotaHTTPTransport {
    struct Request: Sendable { let url: URL; let headers: [String: String]; let timeout: TimeInterval }
    let status: Int
    let body: Data
    let fails: Bool
    let cancels: Bool
    private(set) var requests: [Request] = []
    init(_ record: [String: Any] = [:], status: Int = 200, raw: Data? = nil, fails: Bool = false, cancels: Bool = false) throws {
        self.status = status
        self.body = try raw ?? JSONSerialization.data(withJSONObject: record)
        self.fails = fails
        self.cancels = cancels
    }
    func get(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> (statusCode: Int, body: Data) {
        requests.append(Request(url: url, headers: headers, timeout: timeout))
        if cancels { withUnsafeCurrentTask { $0?.cancel() } }
        if fails { throw NSError(domain: "SECRET_ERROR_BODY", code: 1) }
        return (status, body)
    }
}

@Suite("Explicit opt-in live quota polling")
struct LiveQuotaPollerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func credentials(_ fixture: QuotaFixture, claude: Bool = false) throws {
        let value: [String: Any] = claude ? ["claudeAiOauth": ["accessToken": "fixture-private-token"]] : ["tokens": ["access_token": "fixture-private-token"]]
        try fixture.write(try JSONSerialization.data(withJSONObject: value), to: claude ? ".claude/.credentials.json" : ".codex/auth.json")
    }

    @Test func disabledPermissionDoesNotCallTransportEvenWithCredentials() async throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        try credentials(fixture)
        let transport = try QuotaMockTransport()
        let poller = LiveQuotaPoller(homeDirectory: fixture.home, transport: transport)
        for provider in QuotaProvider.allCases {
            let result = await poller.pollQuota(for: provider, permission: .disabled, at: now)
            #expect(result.status == .unavailable && result.source == .liveAPI)
            #expect(result.warnings == ["Live polling disabled"])
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func missingAndUnsupportedCredentialsRemainUnavailable() async throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let transport = try QuotaMockTransport()
        let poller = LiveQuotaPoller(homeDirectory: fixture.home, transport: transport)
        for provider in QuotaProvider.allCases {
            #expect(await poller.pollQuota(for: provider, permission: .userInitiated, at: now).status == .unavailable)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func codexMapsReversedWindowsCreditsAndFixedRequest() async throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        try credentials(fixture)
        let transport = try QuotaMockTransport([
            "plan_type": "pro", "private": "PRIVATE_RESPONSE_SENTINEL",
            "rate_limit": ["primary_window": ["limit_window_seconds": 604800, "used_percent": 33.5, "reset_at": now.timeIntervalSince1970 + 60], "secondary_window": ["limit_window_seconds": 18000, "used_percent": 15, "reset_after_seconds": 120]],
            "credits": ["has_credits": true, "unlimited": false, "balance": "6.25"]
        ])
        let result = await LiveQuotaPoller(homeDirectory: fixture.home, transport: transport).pollQuota(for: .codex, permission: .userInitiated, at: now)
        #expect(result.status == .complete && result.planType == "pro")
        #expect(result.tokenUsage.isEmpty)
        #expect(result.windows.first { $0.kind == .sevenDay }?.usedPercent == 33.5)
        #expect(result.windows.first { $0.kind == .fiveHour }?.resetsAt == now.addingTimeInterval(120))
        #expect(result.credits?.balance == 6.25)
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(requests.first?.headers["Authorization"] == "Bearer fixture-private-token")
        #expect(requests.first?.headers["Accept"] == "application/json")
        #expect(requests.first?.timeout == 6)
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!encoded.contains("fixture-private-token") && !encoded.contains("PRIVATE_RESPONSE_SENTINEL"))
    }

    @Test func claudeWindowsAndExtraUsageRetainProviderUnits() async throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        try credentials(fixture, claude: true)
        let reset = "2027-01-15T12:00:00.000Z"
        let transport = try QuotaMockTransport([
            "five_hour": ["utilization": 10, "resets_at": reset], "seven_day": ["utilization": 20, "resets_at": reset],
            "seven_day_opus": ["utilization": 30], "seven_day_sonnet": ["utilization": 40],
            "extra_usage": ["is_enabled": true, "used_credits": 12.5, "monthly_limit": 100]
        ])
        let result = await LiveQuotaPoller(homeDirectory: fixture.home, transport: transport).pollQuota(for: .claude, permission: .userInitiated, at: now)
        #expect(result.status == .complete && result.windows.count == 4)
        #expect(result.windows.first?.resetsAt != nil)
        #expect(result.extraUsage?.isEnabled == true)
        #expect(result.extraUsage?.used == 12.5 && result.extraUsage?.limit == 100)
        #expect(result.extraUsage?.currency == nil)
        let requests = await transport.requests
        #expect(requests.first?.url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(requests.first?.headers["anthropic-beta"] == "oauth-2025-04-20")
    }

    @Test func alternateClaudeCredentialsAndPartialResponses() async throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        try fixture.write(Data(#"{"claudeAiOauth":{"access_token":"fixture-alternate"}}"#.utf8), to: ".claude/credentials.json")
        let transport = try QuotaMockTransport(["seven_day": ["utilization": 0]])
        let result = await LiveQuotaPoller(homeDirectory: fixture.home, transport: transport).pollQuota(for: .claude, permission: .userInitiated, at: now)
        #expect(result.status == .partial)
        #expect(result.windows.first?.usedPercent == 0)
    }

    @Test func failuresMalformedResponsesAndErrorsAreSanitized() async throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        try credentials(fixture)
        let transports = try [
            QuotaMockTransport(["error": "SECRET_ERROR_BODY"], status: 401),
            QuotaMockTransport(raw: Data("SECRET_ERROR_BODY".utf8)),
            QuotaMockTransport(fails: true),
            QuotaMockTransport(["plan_type": "SECRET ERROR BODY", "rate_limit": ["primary_window": ["used_percent": -1, "limit_window_seconds": 18000]]]),
            QuotaMockTransport(raw: Data(repeating: 65, count: 1024 * 1024 + 1))
        ]
        for transport in transports {
            let result = await LiveQuotaPoller(homeDirectory: fixture.home, transport: transport).pollQuota(for: .codex, permission: .userInitiated, at: now)
            #expect(result.status == .unavailable && result.windows.isEmpty)
            let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            #expect(!encoded.contains("SECRET_ERROR_BODY") && !encoded.contains("fixture-private-token"))
        }
    }

    @Test func cancellationBeforeAndAfterTransportDiscardsResults() async throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        try credentials(fixture)
        let before = try QuotaMockTransport()
        let poller = LiveQuotaPoller(homeDirectory: fixture.home, transport: before)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await poller.pollQuota(for: .codex, permission: .userInitiated, at: now)
        }
        #expect(await task.value.warnings == ["Live polling disabled"])
        #expect(await before.requests.isEmpty)
        let after = try QuotaMockTransport(["plan_type": "pro"], cancels: true)
        let afterPoller = LiveQuotaPoller(homeDirectory: fixture.home, transport: after)
        let inFlight = Task { await afterPoller.pollQuota(for: .codex, permission: .userInitiated, at: now) }
        #expect(await inFlight.value.warnings == ["Live polling disabled"])
        #expect(await inFlight.value.planType == nil)
    }

    @Test func unsafeCredentialSymlinkDoesNotReachNetwork() async throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        try fixture.write(Data(#"{"tokens":{"access_token":"fixture-secret"}}"#.utf8), to: "outside.json")
        try FileManager.default.createDirectory(at: fixture.home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.home.appendingPathComponent(".codex/auth.json"), withDestinationURL: fixture.home.appendingPathComponent("outside.json"))
        let transport = try QuotaMockTransport()
        let result = await LiveQuotaPoller(homeDirectory: fixture.home, transport: transport).pollQuota(for: .codex, permission: .userInitiated, at: now)
        #expect(result.status == .unavailable)
        #expect(await transport.requests.isEmpty)
    }
}
