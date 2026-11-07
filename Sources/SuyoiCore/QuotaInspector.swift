import Foundation
import Darwin
import CoreFoundation
import SQLite3

// Shared allowlist parsers. Never pass source dictionaries or underlying errors to callers.
enum QuotaParsing {
    static func number(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull), CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        let result = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return result.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
    static func count(_ value: Any?) -> UInt64? {
        guard let n = number(value), n.rounded(.down) == n, n < Double(UInt64.max) else { return nil }
        return UInt64(n)
    }
    static func plan(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty, s.count <= 64,
              s.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { return nil }
        return s
    }
    static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) { return parseTimestamp(seconds) }
        guard let s = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: s) ?? ISO8601DateFormatter().date(from: s) else { return nil }
        return parseTimestamp(date.timeIntervalSince1970)
    }
    static func parseTimestamp(_ seconds: Double) -> Date? {
        guard seconds.isFinite, seconds > 0,
              seconds <= Date().timeIntervalSince1970 + 315_360_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
    static func credits(_ value: Any?) -> QuotaCredits? {
        guard let d = value as? [String: Any] else { return nil }
        let result = QuotaCredits(hasCredits: d["has_credits"] as? Bool, unlimited: d["unlimited"] as? Bool, balance: number(d["balance"]))
        return result.hasCredits != nil || result.unlimited != nil || result.balance != nil ? result : nil
    }
    static func kind(minutes: Double?) -> QuotaWindowKind? {
        switch minutes { case 300: return .fiveHour; case 10080: return .sevenDay; default: return nil }
    }
    static func safePath(_ url: URL) -> Bool {
        // Foundation preserves macOS /var and /tmp aliases even after resolving
        // symlinks. Canonicalize those OS roots before rejecting user symlinks.
        var path = url.path
        if path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        if path == "/tmp" || path.hasPrefix("/tmp/") { path = "/private" + path }
        while path != "/" && !path.isEmpty {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return false }
            path = (path as NSString).deletingLastPathComponent
        }
        return true
    }
    /// Bounded regular-file reads; reject symlink components and non-regular files.
    static func read(_ url: URL, limit: Int, tail: Bool = false) -> Data? {
        guard limit > 0 else { return nil }
        guard safePath(url) else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let truncated = info.st_size > limit
        if truncated && !tail { return nil }
        if truncated { guard lseek(fd, info.st_size - off_t(limit), SEEK_SET) >= 0 else { return nil } }
        var data = Data(count: min(limit, Int(info.st_size)))
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count >= 0 else { return nil }
        data.count = count
        if truncated {
            guard let newline = data.firstIndex(of: 10) else { return nil }
            data.removeSubrange(...newline)
        }
        return data
    }
}

public struct LocalQuotaInspector: QuotaInspecting, Sendable {
    private let homeDirectory: URL
    private let maxFilesPerProvider: Int
    private let maxBytesPerFile: Int

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, maxFilesPerProvider: Int = 24, maxBytesPerFile: Int = 2 * 1024 * 1024) {
        self.homeDirectory = homeDirectory
        self.maxFilesPerProvider = max(0, min(maxFilesPerProvider, 256))
        self.maxBytesPerFile = max(0, min(maxBytesPerFile, 8 * 1024 * 1024))
    }

    public func inspectQuotas(at date: Date) -> QuotaSnapshot {
        let openCodeRecords = readOpenCodeAssistantUsages(at: date)
        return QuotaSnapshot(capturedAt: date, providers: QuotaProvider.allCases.map { provider in
            switch provider {
            case .codex:
                return inspect(.codex, extraUsages: [], at: date)
            case .claude:
                return inspect(.claude, extraUsages: openCodeRecords.claude, at: date)
            case .gemini:
                return inspectGemini(extraUsages: openCodeRecords.gemini, at: date)
            case .openCode:
                return inspectOpenCode(records: openCodeRecords, at: date)
            case .cursor:
                return metadata(provider, paths: [".cursor"], at: date)
            }
        })
    }

    // Fixed traversal depths, entry and elapsed-work caps; symlinks are never followed.
    private func files(root: URL, depth: Int) -> [(URL, Date)] {
        guard maxFilesPerProvider > 0, maxBytesPerFile > 0 else { return [] }
        var found: [(URL, Date)] = []
        var remaining = 10000
        let deadline = Date().addingTimeInterval(2)
        func visit(_ directory: URL, _ level: Int) {
            guard level <= depth, remaining > 0, Date() < deadline, QuotaParsing.safePath(directory),
                  let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  values.isSymbolicLink == false, values.isDirectory == true,
                  let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsSubdirectoryDescendants]) else { return }
            while remaining > 0, Date() < deadline, let url = enumerator.nextObject() as? URL {
                remaining -= 1
                guard QuotaParsing.safePath(url), let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]), v.isSymbolicLink == false else { continue }
                if v.isDirectory == true, level < depth {
                    if depth == 3 {
                        let name = url.lastPathComponent
                        guard name.utf8.allSatisfy({ (48...57).contains($0) }),
                              name.count == (level == 0 ? 4 : 2), let value = Int(name),
                              level == 0 || (1...(level == 1 ? 12 : 31)).contains(value) else { continue }
                    }
                    visit(url, level + 1)
                } else if level == depth, v.isRegularFile == true, url.pathExtension == "jsonl" {
                    found.append((url, v.contentModificationDate ?? .distantPast))
                }
            }
        }
        visit(root, 0)
        return Array(found.sorted { $0.1 > $1.1 }.prefix(maxFilesPerProvider))
    }

    private struct Usage {
        var values: [UInt64?]
        let date: Date
    }
    private func inspect(_ provider: QuotaProvider, extraUsages: [Usage], at date: Date) -> ProviderQuotaStatus {
        let codex = provider == .codex
        let deadline = Date().addingTimeInterval(4)
        let selected = files(root: homeDirectory.appendingPathComponent(codex ? ".codex/sessions" : ".claude/projects"), depth: codex ? 3 : 1)
        var usages: [Usage] = extraUsages
        var seen: [String: Int] = [:]
        var windows: [QuotaWindowKind: (Date, QuotaWindow)] = [:]
        var plan: (Date, String)?
        var credits: (Date, QuotaCredits)?
        var last: Date? = extraUsages.map(\.date).max()
        for (url, _) in selected {
            guard Date() < deadline, !Task.isCancelled else { break }
            guard let data = QuotaParsing.read(url, limit: maxBytesPerFile, tail: true) else { continue }
            var previousTotal: [UInt64?]?
            for line in data.split(separator: 10) where line.count <= 512 * 1024 {
                guard Date() < deadline, !Task.isCancelled else { break }
                guard let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                // Inspect timestamp/usage only after the record matches the allowlist.
                if codex {
                    guard record["type"] as? String == "event_msg",
                          (record["payload"] as? [String: Any])?["type"] as? String == "token_count" else { continue }
                } else {
                    guard ((record["message"] as? [String: Any])?["usage"] as? [String: Any]) != nil else { continue }
                }
                guard let timestamp = QuotaParsing.date(record["timestamp"]), timestamp <= date else { continue }
                let usage: [String: Any]
                if codex {
                    guard record["type"] as? String == "event_msg", let payload = record["payload"] as? [String: Any], payload["type"] as? String == "token_count" else { continue }
                    last = max(last ?? timestamp, timestamp)
                    if let limits = payload["rate_limits"] as? [String: Any] {
                        if let p = QuotaParsing.plan(limits["plan_type"]), timestamp >= (plan?.0 ?? .distantPast) { plan = (timestamp, p) }
                        if let c = QuotaParsing.credits(limits["credits"]), timestamp >= (credits?.0 ?? .distantPast) { credits = (timestamp, c) }
                        for key in ["primary", "secondary"] {
                            guard let w = limits[key] as? [String: Any], let kind = QuotaParsing.kind(minutes: QuotaParsing.number(w["window_minutes"])) else { continue }
                            let percent = QuotaParsing.number(w["used_percent"])
                            let reset = QuotaParsing.number(w["resets_at"]).flatMap(QuotaParsing.parseTimestamp)
                            guard percent != nil || reset != nil, timestamp >= (windows[kind]?.0 ?? .distantPast) else { continue }
                            windows[kind] = (timestamp, QuotaWindow(kind: kind, windowMinutes: kind == .fiveHour ? 300 : 10080, usedPercent: percent, resetsAt: reset))
                        }
                    }
                    guard let info = payload["info"] as? [String: Any] else { continue }
                    let total = (info["total_token_usage"] as? [String: Any]).map { counters($0, codex: true) }
                    // Repeated quota events often repeat last_token_usage. Cumulative totals
                    // identify those repeats; use deltas after the first observed event.
                    if let total, let previousTotal {
                        appendDelta(total, previousTotal, fallback: info["last_token_usage"] as? [String: Any], at: timestamp, into: &usages)
                    } else if let u = info["last_token_usage"] as? [String: Any] {
                        usages.append(Usage(values: counters(u, codex: true), date: timestamp))
                    }
                    previousTotal = total ?? previousTotal
                    continue
                } else {
                    guard let message = record["message"] as? [String: Any], let u = message["usage"] as? [String: Any] else { continue }
                    usage = u
                    last = max(last ?? timestamp, timestamp)
                    if let id = message["id"] as? String ?? record["requestId"] as? String ?? record["uuid"] as? String {
                        let candidate = Usage(values: counters(u, codex: false), date: timestamp)
                        if let index = seen[id] {
                            if timestamp >= usages[index].date { usages[index] = candidate }
                        } else {
                            seen[id] = usages.count
                            usages.append(candidate)
                        }
                        continue
                    }
                }
                usages.append(Usage(values: counters(usage, codex: false), date: timestamp))
            }
        }
        let summaries = [300, 10080].compactMap { minutes -> TokenUsageSummary? in
            let start = date.addingTimeInterval(-Double(minutes * 60))
            let relevant = usages.filter { $0.date >= start && $0.date <= date }
            guard !relevant.isEmpty else { return nil }
            let sums: [UInt64?] = (0..<6).map { index in
                let values = relevant.compactMap { $0.values[index] }
                guard values.count == relevant.count else { return nil }
                return values.reduce(UInt64(0)) { saturatingAdd($0, $1) }
            }
            return TokenUsageSummary(windowMinutes: minutes, startedAt: start, endedAt: date, inputTokens: sums[0], outputTokens: sums[1], cacheReadTokens: sums[2], cacheCreationTokens: sums[3], reasoningTokens: sums[4], totalTokens: sums[5], status: .partial)
        }
        return ProviderQuotaStatus(provider: provider, source: .localTelemetry, observedAt: date, status: last == nil ? .unavailable : .partial, planType: plan?.1, windows: windows.values.map(\.1).sorted { $0.kind.rawValue < $1.kind.rawValue }, tokenUsage: summaries, credits: credits?.1, lastActivityAt: last, warnings: [last == nil ? "Local usage unavailable" : "Bounded local telemetry; account-wide quota and local consumption are separate"])
    }

    private func appendDelta(_ total: [UInt64?], _ previous: [UInt64?], fallback: [String: Any]?, at date: Date, into usages: inout [Usage]) {
        guard total != previous else { return }
        // A reset (for example after compaction) starts a new cumulative baseline.
        if zip(total, previous).contains(where: { current, old in
            guard let current, let old else { return false }; return current < old
        }) {
            if let fallback { usages.append(Usage(values: counters(fallback, codex: true), date: date)) }
            return
        }
        let delta = zip(total, previous).map { current, old -> UInt64? in
            guard let current, let old, current >= old else { return nil }
            return current - old
        }
        if delta.contains(where: { $0 != nil }) { usages.append(Usage(values: delta, date: date)) }
    }
    private func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 { let r = a.addingReportingOverflow(b); return r.overflow ? .max : r.partialValue }
    private func counters(_ d: [String: Any], codex: Bool) -> [UInt64?] {
        let input = QuotaParsing.count(d["input_tokens"])
        let output = QuotaParsing.count(d["output_tokens"])
        let cache = QuotaParsing.count(d[codex ? "cached_input_tokens" : "cache_read_input_tokens"])
        let creation = codex ? nil : QuotaParsing.count(d["cache_creation_input_tokens"])
        let normalized = codex ? input.flatMap { raw -> UInt64? in
            guard let cache else { return raw }
            return raw >= cache ? raw - cache : nil
        } : input
        let total = codex ? QuotaParsing.count(d["total_tokens"]) : [input, output, cache, creation].reduce(Optional(UInt64(0))) { sum, value in
            guard let sum, let value else { return nil }; return saturatingAdd(sum, value)
        }
        return [normalized, output, cache, creation, codex ? QuotaParsing.count(d["reasoning_output_tokens"]) : nil, total]
    }
    private func metadata(_ provider: QuotaProvider, paths: [String], at date: Date) -> ProviderQuotaStatus {
        let last = paths.compactMap { path -> Date? in
            let url = homeDirectory.appendingPathComponent(path)
            guard QuotaParsing.safePath(url), let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .contentModificationDateKey]), v.isSymbolicLink == false else { return nil }
            return v.contentModificationDate
        }.filter { $0 <= date }.max()
        return ProviderQuotaStatus(provider: provider, source: .localTelemetry, observedAt: date, status: last == nil ? .unavailable : .partial, lastActivityAt: last, warnings: ["Local usage counters unavailable"])
    }

    private struct OpenCodeUsageBuckets {
        var openCodeOnly: [Usage] = []
        var gemini: [Usage] = []
        var claude: [Usage] = []
        var openCodeLastActivityAt: Date?
    }

    private func readOpenCodeAssistantUsages(at date: Date) -> OpenCodeUsageBuckets {
        guard maxFilesPerProvider > 0, maxBytesPerFile > 0 else { return OpenCodeUsageBuckets() }
        let dbURL = homeDirectory.appendingPathComponent(".local/share/opencode/opencode.db")
        guard QuotaParsing.safePath(dbURL),
              let rv = try? dbURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              rv.isSymbolicLink == false, rv.isRegularFile == true else {
            return OpenCodeUsageBuckets()
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return OpenCodeUsageBuckets()
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let minMs = Int64(date.addingTimeInterval(-10080 * 60).timeIntervalSince1970 * 1000)
        let maxMs = Int64(date.timeIntervalSince1970 * 1000)
        var buckets = OpenCodeUsageBuckets()

        let sql = """
        SELECT sm.time_created, sm.data, s.model
        FROM session_message sm
        LEFT JOIN session_v2 s ON s.id = sm.session_id
        WHERE sm.type = 'assistant' AND sm.time_created >= ?1 AND sm.time_created <= ?2
        ORDER BY sm.time_created DESC
        LIMIT 8000
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, minMs)
            sqlite3_bind_int64(stmt, 2, maxMs)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let timeMs = sqlite3_column_int64(stmt, 0)
                let msgDate = Date(timeIntervalSince1970: Double(timeMs) / 1000.0)
                guard let cData = sqlite3_column_text(stmt, 1) else { continue }
                let dataLen = Int(sqlite3_column_bytes(stmt, 1))
                guard dataLen > 0, dataLen <= 512 * 1024 else { continue }
                let rawData = Data(bytes: cData, count: dataLen)
                guard let obj = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any],
                      let tok = obj["tokens"] as? [String: Any] else { continue }
                let cacheDict = tok["cache"] as? [String: Any]
                let inp = QuotaParsing.count(tok["input"]) ?? 0
                let out = QuotaParsing.count(tok["output"]) ?? 0
                let reas = QuotaParsing.count(tok["reasoning"]) ?? 0
                let cread = QuotaParsing.count(cacheDict?["read"]) ?? 0
                let cwrite = QuotaParsing.count(cacheDict?["write"]) ?? 0
                let total = [inp, out, reas, cread, cwrite].reduce(UInt64(0)) { saturatingAdd($0, $1) }
                guard total > 0 else { continue }
                let usage = Usage(values: [inp, out, cread, cwrite, reas, total], date: msgDate)

                let sessionModelRaw = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let sessionModelDict = sessionModelRaw.data(using: .utf8).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                let msgModelDict = obj["model"] as? [String: Any]
                let providerID = ((msgModelDict?["providerID"] as? String) ?? (sessionModelDict?["providerID"] as? String) ?? (obj["providerID"] as? String) ?? "").lowercased()
                let modelID = ((msgModelDict?["modelID"] as? String) ?? (msgModelDict?["id"] as? String) ?? (sessionModelDict?["id"] as? String) ?? (obj["modelID"] as? String) ?? "").lowercased()

                if modelID.contains("gemini") || modelID.contains("argon") {
                    buckets.gemini.append(usage)
                } else if modelID.contains("claude") {
                    buckets.claude.append(Usage(values: [inp, out, cread, cwrite, nil, total], date: msgDate))
                } else if providerID.hasPrefix("opencode") {
                    buckets.openCodeOnly.append(usage)
                    buckets.openCodeLastActivityAt = max(buckets.openCodeLastActivityAt ?? msgDate, msgDate)
                }
            }
        }
        return buckets
    }

    private func inspectOpenCode(records: OpenCodeUsageBuckets, at date: Date) -> ProviderQuotaStatus {
        guard !records.openCodeOnly.isEmpty else {
            return metadata(.openCode, paths: [".local/share/opencode", ".config/opencode"], at: date)
        }
        let summaries = summarizeUsages(records.openCodeOnly, at: date)
        return ProviderQuotaStatus(
            provider: .openCode,
            source: .localTelemetry,
            observedAt: date,
            status: .partial,
            planType: "free",
            tokenUsage: summaries,
            lastActivityAt: records.openCodeLastActivityAt,
            warnings: ["OpenCode free provider local token usage (no paid subscription quota)"]
        )
    }

    private func inspectGemini(extraUsages: [Usage], at date: Date) -> ProviderQuotaStatus {
        var usages: [Usage] = extraUsages
        var seen: [String: Int] = [:]
        var last: Date? = extraUsages.map(\.date).max()
        let chatRoot = homeDirectory.appendingPathComponent(".gemini/tmp")
        if maxFilesPerProvider > 0, maxBytesPerFile > 0, QuotaParsing.safePath(chatRoot),
           let topDirs = try? FileManager.default.contentsOfDirectory(at: chatRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            var chatFiles: [(URL, Date)] = []
            for dir in topDirs.prefix(32) {
                let chatsDir = dir.appendingPathComponent("chats")
                guard QuotaParsing.safePath(chatsDir),
                      let items = try? FileManager.default.contentsOfDirectory(at: chatsDir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
                for file in items {
                    guard QuotaParsing.safePath(file),
                          let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                          v.isSymbolicLink == false, v.isRegularFile == true,
                          file.pathExtension == "jsonl" || file.pathExtension == "json" else { continue }
                    chatFiles.append((file, v.contentModificationDate ?? .distantPast))
                }
            }
            for (url, mtime) in chatFiles.sorted(by: { $0.1 > $1.1 }).prefix(maxFilesPerProvider) {
                if mtime <= date { last = max(last ?? mtime, mtime) }
                guard let data = QuotaParsing.read(url, limit: maxBytesPerFile, tail: url.pathExtension == "jsonl") else { continue }
                if url.pathExtension == "jsonl" {
                    for line in data.split(separator: 10) where line.count <= 512 * 1024 {
                        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                        appendGeminiMessage(obj, upTo: date, into: &usages, seen: &seen, last: &last)
                    }
                } else if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let messages = obj["messages"] as? [[String: Any]] {
                    for msg in messages {
                        appendGeminiMessage(msg, upTo: date, into: &usages, seen: &seen, last: &last)
                    }
                }
            }
        }
        guard !usages.isEmpty else {
            return metadata(.gemini, paths: [".gemini"], at: date)
        }
        let summaries = summarizeUsages(usages, at: date)
        return ProviderQuotaStatus(
            provider: .gemini,
            source: .localTelemetry,
            observedAt: date,
            status: .partial,
            tokenUsage: summaries,
            lastActivityAt: last,
            warnings: ["Bounded local telemetry; account-wide quota and local consumption are separate"]
        )
    }

    private func appendGeminiMessage(_ obj: [String: Any], upTo date: Date, into usages: inout [Usage], seen: inout [String: Int], last: inout Date?) {
        guard let tok = obj["tokens"] as? [String: Any],
              let ts = QuotaParsing.date(obj["timestamp"]), ts <= date else { return }
        last = max(last ?? ts, ts)
        let rawInput = QuotaParsing.count(tok["input"])
        let cached = QuotaParsing.count(tok["cached"])
        let normalizedInput = rawInput.flatMap { raw -> UInt64? in
            guard let cached else { return raw }
            return raw >= cached ? raw - cached : raw
        }
        let output = QuotaParsing.count(tok["output"])
        let thoughts = QuotaParsing.count(tok["thoughts"])
        let total = QuotaParsing.count(tok["total"])
        let candidate = Usage(values: [normalizedInput, output, cached, nil, thoughts, total], date: ts)
        if let id = obj["id"] as? String {
            if let idx = seen[id] {
                if ts >= usages[idx].date { usages[idx] = candidate }
            } else {
                seen[id] = usages.count
                usages.append(candidate)
            }
        } else {
            usages.append(candidate)
        }
    }

    private func summarizeUsages(_ usages: [Usage], at date: Date) -> [TokenUsageSummary] {
        [300, 10080].compactMap { minutes -> TokenUsageSummary? in
            let start = date.addingTimeInterval(-Double(minutes * 60))
            let relevant = usages.filter { $0.date >= start && $0.date <= date }
            guard !relevant.isEmpty else { return nil }
            let sums: [UInt64?] = (0..<6).map { index in
                let values = relevant.compactMap { $0.values[index] }
                guard !values.isEmpty else { return nil }
                return values.reduce(UInt64(0)) { saturatingAdd($0, $1) }
            }
            return TokenUsageSummary(
                windowMinutes: minutes,
                startedAt: start,
                endedAt: date,
                inputTokens: sums[0],
                outputTokens: sums[1],
                cacheReadTokens: sums[2],
                cacheCreationTokens: sums[3],
                reasoningTokens: sums[4],
                totalTokens: sums[5],
                status: .partial
            )
        }
    }
}
