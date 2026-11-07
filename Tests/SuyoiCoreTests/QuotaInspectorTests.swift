import Foundation
import Testing
@testable import SuyoiCore

struct QuotaFixture {
    let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("suyoi-quota-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
    func write(_ records: [[String: Any]], to path: String) throws {
        let data = try records.reduce(into: Data()) { result, record in
            result.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            result.append(10)
        }
        try write(data, to: path)
    }
    func write(_ data: Data, to path: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    func clean() { try? FileManager.default.removeItem(at: home) }
    func status(_ provider: QuotaProvider, at date: Date, files: Int = 24, bytes: Int = 2 * 1024 * 1024) -> ProviderQuotaStatus {
        LocalQuotaInspector(homeDirectory: home, maxFilesPerProvider: files, maxBytesPerFile: bytes).inspectQuotas(at: date).providers.first { $0.provider == provider }!
    }
}

@Suite("Local quota allowlist and bounded rolling consumption")
struct QuotaInspectorTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    func counts(_ input: Int, cached: Int = 20, output: Int = 10) -> [String: Any] {
        ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "reasoning_output_tokens": 2, "total_tokens": input + output]
    }
    func codex(_ date: Date, last: [String: Any], total: [String: Any]? = nil, limits: [String: Any]? = nil) -> [String: Any] {
        var info: [String: Any] = ["last_token_usage": last]
        info["total_token_usage"] = total
        var payload: [String: Any] = ["type": "token_count", "info": info]
        payload["rate_limits"] = limits
        return ["type": "event_msg", "timestamp": stamp(date), "payload": payload]
    }

    @Test func missingProvidersAreUnavailableAndNeverZero() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let snapshot = LocalQuotaInspector(homeDirectory: fixture.home).inspectQuotas(at: now)
        #expect(snapshot.providers.count == QuotaProvider.allCases.count)
        #expect(snapshot.providers.allSatisfy { $0.source == .localTelemetry && $0.status == .unavailable && $0.tokenUsage.isEmpty && $0.windows.isEmpty })
    }

    @Test func codexWindowsMapByDurationAndNormalizeCachedInput() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let limits: [String: Any] = ["plan_type": "pro", "limit_id": "test", "primary": ["window_minutes": 10080, "used_percent": 31.5, "resets_at": now.timeIntervalSince1970 + 100], "secondary": ["window_minutes": 300, "used_percent": 15], "credits": ["has_credits": true, "unlimited": false, "balance": "12.5"]]
        try fixture.write([codex(now, last: counts(100), total: counts(100), limits: limits)], to: ".codex/sessions/2027/01/15/a.jsonl")
        let result = fixture.status(.codex, at: now)
        #expect(result.planType == "pro")
        #expect(result.credits?.balance == 12.5)
        #expect(result.windows.first { $0.kind == .sevenDay }?.usedPercent == 31.5)
        #expect(result.windows.first { $0.kind == .fiveHour }?.usedPercent == 15)
        // Codex input_tokens includes cached_input_tokens; reasoning is already in output.
        #expect(result.tokenUsage.first?.inputTokens == 80)
        #expect(result.tokenUsage.first?.cacheReadTokens == 20)
        #expect(result.tokenUsage.first?.totalTokens == 110)
        #expect(result.tokenUsage.first?.reasoningTokens == 2)
        #expect(result.status == .partial)
    }

    @Test func cumulativeTotalsAreNotSummedAndRepeatedLastUsageIsIgnored() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let old = now.addingTimeInterval(-20000)
        try fixture.write([
            codex(old, last: counts(100), total: counts(100)),
            codex(now.addingTimeInterval(-100), last: counts(100), total: counts(200, cached: 40, output: 20)),
            codex(now, last: counts(100), total: counts(200, cached: 40, output: 20))
        ], to: ".codex/sessions/2027/01/15/a.jsonl")
        let result = fixture.status(.codex, at: now)
        #expect(result.tokenUsage.first { $0.windowMinutes == 300 }?.totalTokens == 110)
        #expect(result.tokenUsage.first { $0.windowMinutes == 10080 }?.totalTokens == 220)
    }

    @Test func rollingBoundariesAndFutureRecords() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let times: [Double] = [-604801, -604800, -18001, -18000, 0, 1]
        try fixture.write(times.map { codex(now.addingTimeInterval($0), last: counts(100)) }, to: ".codex/sessions/2027/01/15/a.jsonl")
        let result = fixture.status(.codex, at: now)
        #expect(result.tokenUsage.first { $0.windowMinutes == 300 }?.totalTokens == 220)
        #expect(result.tokenUsage.first { $0.windowMinutes == 10080 }?.totalTokens == 440)
    }

    @Test func latestQuotaEvidenceWinsIndependentOfFileOrder() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        for (name, offset, percent) in [("a", -10.0, 12), ("b", -100.0, 90)] {
            try fixture.write([codex(now.addingTimeInterval(offset), last: counts(1, cached: 0), limits: ["primary": ["window_minutes": 300, "used_percent": percent]])], to: ".codex/sessions/2027/01/15/\(name).jsonl")
        }
        #expect(fixture.status(.codex, at: now).windows.first?.usedPercent == 12)
        #expect(fixture.status(.codex, at: now, files: 1).tokenUsage.first?.totalTokens == 11)
        #expect(fixture.status(.codex, at: now, files: 0).status == .unavailable)
    }

    @Test func claudeDeduplicatesMessageIDsAcrossFilesAndKeepsWindowsSeparate() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        func record(_ id: String, _ time: Date) -> [String: Any] {
            ["timestamp": stamp(time), "message": ["id": id, "model": "claude-sonnet-4", "content": "PRIVATE_BODY_SENTINEL", "usage": ["input_tokens": 100, "output_tokens": 10, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 5]]]
        }
        let recent = record("message-1", now)
        try fixture.write([recent, record("message-2", now.addingTimeInterval(-20000))], to: ".claude/projects/project/a.jsonl")
        try fixture.write([recent], to: ".claude/projects/project/b.jsonl")
        try fixture.write(Data(#"{"dailyModelTokens":{"today":999999}}"#.utf8), to: ".claude/stats-cache.json")
        let result = fixture.status(.claude, at: now)
        #expect(result.tokenUsage.first { $0.windowMinutes == 300 }?.totalTokens == 135)
        #expect(result.tokenUsage.first { $0.windowMinutes == 10080 }?.totalTokens == 270)
        #expect(result.tokenUsage.first?.inputTokens == 100)
        #expect(result.tokenUsage.first?.cacheCreationTokens == 5)
        #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("PRIVATE_BODY_SENTINEL"))
    }

    @Test func malformedUnknownTextAndInvalidNumericFieldsAreNotExposed() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        var record = codex(now, last: ["input_tokens": -1, "output_tokens": true, "total_tokens": "NaN"], limits: ["plan_type": "PRIVATE TEXT", "primary": ["window_minutes": 300, "used_percent": -12]])
        record["private"] = "SECRET_SENTINEL"
        try fixture.write([record, ["type": "event_msg", "timestamp": stamp(now), "payload": ["type": "agent_message", "message": "SECRET_SENTINEL"]]], to: ".codex/sessions/2027/01/15/a.jsonl")
        let result = fixture.status(.codex, at: now)
        #expect(result.planType == nil)
        #expect(result.windows.isEmpty)
        #expect(result.tokenUsage.allSatisfy { $0.inputTokens == nil && $0.outputTokens == nil && $0.totalTokens == nil })
        #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("SECRET_SENTINEL"))
    }

    @Test func boundedTailSkipsPartialFirstRecordAndSymlinks() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let record = codex(now, last: counts(100))
        let valid = try JSONSerialization.data(withJSONObject: record)
        var content = Data(repeating: 120, count: 2000); content.append(10); content.append(valid); content.append(10)
        try fixture.write(content, to: ".codex/sessions/2027/01/15/a.jsonl")
        #expect(fixture.status(.codex, at: now, bytes: valid.count + 50).tokenUsage.first?.totalTokens == 110)
        try fixture.write([record], to: "outside.jsonl")
        try FileManager.default.createSymbolicLink(at: fixture.home.appendingPathComponent(".codex/sessions/2027/01/15/link.jsonl"), withDestinationURL: fixture.home.appendingPathComponent("outside.jsonl"))
        #expect(fixture.status(.codex, at: now).tokenUsage.first?.totalTokens == 110)
    }

    @Test func cumulativeResetUsesLastUsageAndTotalOnlyRecordsUseDifferences() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        var baseline = codex(now.addingTimeInterval(-20000), last: counts(100), total: counts(100))
        baseline["payload"] = ["type": "token_count", "info": ["total_token_usage": counts(100)]]
        var delta = codex(now.addingTimeInterval(-100), last: counts(100), total: counts(200, cached: 40, output: 20))
        delta["payload"] = ["type": "token_count", "info": ["total_token_usage": counts(200, cached: 40, output: 20)]]
        try fixture.write([baseline, delta, codex(now, last: counts(50, cached: 10), total: counts(50, cached: 10))], to: ".codex/sessions/2027/01/15/a.jsonl")
        #expect(fixture.status(.codex, at: now).tokenUsage.first?.totalTokens == 170)
    }

    @Test func claudeRepeatedMessageUsesLatestUsageSnapshot() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        func record(_ date: Date, _ output: Int) -> [String: Any] {
            ["timestamp": stamp(date), "message": ["id": "same-message", "usage": ["input_tokens": 100, "output_tokens": output, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]]]
        }
        try fixture.write([record(now.addingTimeInterval(-1), 1), record(now, 20)], to: ".claude/projects/project/a.jsonl")
        let result = fixture.status(.claude, at: now)
        #expect(result.tokenUsage.first?.totalTokens == 120)
        #expect(result.tokenUsage.first?.outputTokens == 20)
    }

    @Test func unsupportedMetadataDoesNotFabricateUsage() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        for path in [".gemini", ".local/share/opencode", ".cursor"] {
            try FileManager.default.createDirectory(at: fixture.home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for provider in [QuotaProvider.gemini, .openCode, .cursor] {
            let result = fixture.status(provider, at: Date().addingTimeInterval(1))
            #expect(result.status == .partial && result.lastActivityAt != nil)
            #expect(result.tokenUsage.isEmpty && result.windows.isEmpty)
        }
    }

    @Test func geminiChatJSONLDeduplicatesAndNormalizesCachedTokens() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let msg1: [String: Any] = [
            "id": "gem-1",
            "timestamp": stamp(now.addingTimeInterval(-60)),
            "type": "gemini",
            "model": "gemini-3-flash-preview",
            "tokens": ["input": 1000, "output": 100, "cached": 400, "thoughts": 50, "total": 1150]
        ]
        let msg1Updated: [String: Any] = [
            "id": "gem-1",
            "timestamp": stamp(now),
            "type": "gemini",
            "model": "gemini-3-flash-preview",
            "tokens": ["input": 1200, "output": 200, "cached": 400, "thoughts": 50, "total": 1450]
        ]
        try fixture.write([msg1, msg1Updated], to: ".gemini/tmp/proj/chats/session-1.jsonl")
        let result = fixture.status(.gemini, at: now)
        #expect(result.status == .partial)
        #expect(result.tokenUsage.first { $0.windowMinutes == 300 }?.inputTokens == 800)
        #expect(result.tokenUsage.first { $0.windowMinutes == 300 }?.cacheReadTokens == 400)
        #expect(result.tokenUsage.first { $0.windowMinutes == 300 }?.outputTokens == 200)
        #expect(result.tokenUsage.first { $0.windowMinutes == 300 }?.reasoningTokens == 50)
        #expect(result.tokenUsage.first { $0.windowMinutes == 300 }?.totalTokens == 1450)
    }
}
