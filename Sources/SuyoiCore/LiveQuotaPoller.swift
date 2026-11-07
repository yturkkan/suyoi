import Foundation
import SQLite3

public protocol QuotaHTTPTransport: Sendable {
    func get(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> (statusCode: Int, body: Data)
    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (statusCode: Int, body: Data)
}

public extension QuotaHTTPTransport {
    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (statusCode: Int, body: Data) {
        try await get(url: url, headers: headers, timeout: timeout)
    }
}

private final class QuotaSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // Fail closed on every redirect, including same-origin redirects.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct URLSessionQuotaHTTPTransport: QuotaHTTPTransport, Sendable {
    public init() {}
    public func get(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> (statusCode: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers
        return try await perform(request: request, timeout: timeout)
    }

    public func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (statusCode: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers
        request.httpBody = body
        return try await perform(request: request, timeout: timeout)
    }

    private func perform(request: URLRequest, timeout: TimeInterval) async throws -> (statusCode: Int, body: Data) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = min(max(timeout, 1), 6)
        configuration.timeoutIntervalForResource = min(max(timeout, 1), 6)
        let session = URLSession(configuration: configuration, delegate: QuotaSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            body.append(byte)
        }
        return (response.statusCode, body)
    }
}

public struct LiveQuotaPoller: LiveQuotaPolling, Sendable {
    private let homeDirectory: URL
    private let transport: any QuotaHTTPTransport
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, transport: any QuotaHTTPTransport = URLSessionQuotaHTTPTransport()) {
        self.homeDirectory = homeDirectory
        self.transport = transport
    }

    public func pollQuota(for provider: QuotaProvider, permission: LiveQuotaPermission, at date: Date) async -> ProviderQuotaStatus {
        func unavailable(_ warning: String) -> ProviderQuotaStatus {
            ProviderQuotaStatus(provider: provider, source: .liveAPI, observedAt: date, status: .unavailable, warnings: [warning])
        }
        guard permission == .userInitiated, !Task.isCancelled else { return unavailable("Live polling disabled") }
        if provider == .gemini {
            return await pollAntigravityCloudQuota(for: .gemini, at: date)
        }
        guard provider == .codex || provider == .claude else { return unavailable("Live OAuth usage unsupported") }
        guard let token = token(for: provider) else {
            if provider == .claude, let fallback = await pollAntigravityCloudQuotaIfAvailable(for: .claude, at: date) {
                return fallback
            }
            return unavailable("Local OAuth credential unavailable")
        }
        guard !Task.isCancelled else { return unavailable("Live polling disabled") }
        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        if provider == .claude { headers["anthropic-beta"] = "oauth-2025-04-20" }
        let endpoint = provider == .codex ? "https://chatgpt.com/backend-api/wham/usage" : "https://api.anthropic.com/api/oauth/usage"
        do {
            let response = try await transport.get(url: URL(string: endpoint)!, headers: headers, timeout: 6)
            guard !Task.isCancelled else { return unavailable("Live polling disabled") }
            guard response.statusCode == 200 else { return unavailable("Live usage request failed") }
            guard response.body.count <= 1024 * 1024,
                  let record = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else { return unavailable("Live usage response unavailable") }
            var windows: [QuotaWindow] = []
            var extra: QuotaExtraUsage?
            if provider == .codex {
                let limits = record["rate_limit"] as? [String: Any] ?? [:]
                for key in ["primary_window", "secondary_window"] {
                    guard let w = limits[key] as? [String: Any], let seconds = QuotaParsing.number(w["limit_window_seconds"]), let kind = QuotaParsing.kind(minutes: seconds / 60) else { continue }
                    let reset = QuotaParsing.number(w["reset_at"]).map(Date.init(timeIntervalSince1970:))
                        ?? QuotaParsing.number(w["reset_after_seconds"]).map { date.addingTimeInterval($0) }
                    let percent = QuotaParsing.number(w["used_percent"])
                    guard percent != nil || reset != nil else { continue }
                    // A malformed response cannot introduce duplicate window kinds.
                    windows.removeAll { $0.kind == kind }
                    windows.append(QuotaWindow(kind: kind, windowMinutes: Int(seconds / 60), usedPercent: percent, resetsAt: reset))
                }
            } else {
                for (key, kind) in [("five_hour", QuotaWindowKind.fiveHour), ("seven_day", .sevenDay), ("seven_day_opus", .sevenDayOpus), ("seven_day_sonnet", .sevenDaySonnet)] {
                    guard let w = record[key] as? [String: Any] else { continue }
                    let percent = QuotaParsing.number(w["utilization"])
                    let reset = QuotaParsing.date(w["resets_at"])
                    guard percent != nil || reset != nil else { continue }
                    windows.append(QuotaWindow(kind: kind, windowMinutes: kind == .fiveHour ? 300 : 10080, usedPercent: percent, resetsAt: reset))
                }
                if let e = record["extra_usage"] as? [String: Any] {
                    let value = QuotaExtraUsage(isEnabled: e["is_enabled"] as? Bool, used: QuotaParsing.number(e["used_credits"]), limit: QuotaParsing.number(e["monthly_limit"]))
                    if value.isEnabled != nil || value.used != nil || value.limit != nil { extra = value }
                }
            }
            let plan = QuotaParsing.plan(record["plan_type"])
            let credits = provider == .codex ? QuotaParsing.credits(record["credits"]) : nil
            guard !windows.isEmpty || plan != nil || credits != nil || extra != nil else { return unavailable("Live usage response unavailable") }
            return ProviderQuotaStatus(provider: provider, source: .liveAPI, observedAt: date, status: windows.contains(where: { $0.kind == .fiveHour && $0.usedPercent != nil }) && windows.contains(where: { $0.kind == .sevenDay && $0.usedPercent != nil }) ? .complete : .partial, planType: plan, windows: windows, credits: credits, extraUsage: extra)
        } catch {
            return unavailable(Task.isCancelled ? "Live polling disabled" : "Live usage request failed")
        }
    }

    private func token(for provider: QuotaProvider) -> String? {
        let paths = provider == .codex ? [".codex/auth.json"] : [".claude/.credentials.json", ".claude/credentials.json"]
        for path in paths {
            guard let data = QuotaParsing.read(homeDirectory.appendingPathComponent(path), limit: 64 * 1024),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let container = record[provider == .codex ? "tokens" : "claudeAiOauth"] as? [String: Any]
            let candidate = provider == .codex ? container?["access_token"] : (container?["accessToken"] ?? container?["access_token"] ?? record["access_token"])
            if let token = candidate as? String, !token.isEmpty, token.utf8.count <= 16384, !token.contains(where: { $0.isWhitespace || $0.isNewline }) { return token }
        }
        return nil
    }

    private func antigravityAccessToken() -> (token: String, project: String)? {
        let dbURL = homeDirectory.appendingPathComponent(".local/share/opencode/opencode.db")
        guard QuotaParsing.safePath(dbURL),
              let rv = try? dbURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              rv.isSymbolicLink == false, rv.isRegularFile == true else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let sql = "SELECT value FROM credential WHERE integration_id = 'antigravity-direct-lab' AND active = 1 LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let cText = sqlite3_column_text(stmt, 0) else { return nil }
        let len = Int(sqlite3_column_bytes(stmt, 0))
        guard len > 0, len <= 64 * 1024,
              let obj = (try? JSONSerialization.jsonObject(with: Data(bytes: cText, count: len))) as? [String: Any],
              let access = obj["access"] as? String, !access.isEmpty,
              access.utf8.count <= 16384,
              !access.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        var project = "aicode-consumers"
        let accURL = homeDirectory.appendingPathComponent(".config/opencode/antigravity-accounts.json")
        if let accData = QuotaParsing.read(accURL, limit: 64 * 1024),
           let accObj = (try? JSONSerialization.jsonObject(with: accData)) as? [String: Any],
           let accounts = accObj["accounts"] as? [[String: Any]],
           let first = accounts.first,
           let p = (first["managedProjectId"] as? String) ?? (first["projectId"] as? String),
           !p.isEmpty {
            project = p
        }
        return (access, project)
    }

    private func pollAntigravityCloudQuotaIfAvailable(for provider: QuotaProvider, at date: Date) async -> ProviderQuotaStatus? {
        guard antigravityAccessToken() != nil else { return nil }
        return await pollAntigravityCloudQuota(for: provider, at: date)
    }

    private func pollAntigravityCloudQuota(for provider: QuotaProvider, at date: Date) async -> ProviderQuotaStatus {
        func unavailable(_ warning: String) -> ProviderQuotaStatus {
            ProviderQuotaStatus(provider: provider, source: .liveAPI, observedAt: date, status: .unavailable, warnings: [warning])
        }
        guard !Task.isCancelled else { return unavailable("Live polling disabled") }
        guard let creds = antigravityAccessToken() else { return unavailable("Local OAuth credential unavailable") }
        let headers = [
            "Authorization": "Bearer \(creds.token)",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "antigravity"
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: ["project": creds.project]) else {
            return unavailable("Live usage request failed")
        }
        do {
            let url = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!
            let response = try await transport.post(url: url, headers: headers, body: bodyData, timeout: 6)
            guard !Task.isCancelled else { return unavailable("Live polling disabled") }
            guard response.statusCode == 200,
                  response.body.count <= 1024 * 1024,
                  let record = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
                  let models = record["models"] as? [String: Any] else {
                return unavailable("Live usage response unavailable")
            }
            let windows = parseAntigravityModelWindows(models: models, for: provider, at: date)
            guard !windows.isEmpty else { return unavailable("Live usage response unavailable") }
            return ProviderQuotaStatus(
                provider: provider,
                source: .liveAPI,
                observedAt: date,
                status: .partial,
                planType: "antigravity",
                windows: windows
            )
        } catch {
            return unavailable(Task.isCancelled ? "Live polling disabled" : "Live usage request failed")
        }
    }

    private func parseAntigravityModelWindows(models: [String: Any], for provider: QuotaProvider, at date: Date) -> [QuotaWindow] {
        var windowsByKind: [QuotaWindowKind: QuotaWindow] = [:]
        for (modelID, rawModel) in models {
            let lower = modelID.lowercased()
            let matchesProvider = (provider == .gemini && lower.hasPrefix("gemini-")) ||
                                  (provider == .claude && lower.hasPrefix("claude-"))
            guard matchesProvider,
                  let modelDict = rawModel as? [String: Any],
                  let quotaInfo = modelDict["quotaInfo"] as? [String: Any] else { continue }
            let resetDate = QuotaParsing.date(quotaInfo["resetTime"])
            let remainingFraction = QuotaParsing.number(quotaInfo["remainingFraction"])
            // In Google Cloud Code protobuf JSON, remainingFraction == 0.0 is omitted when resetTime is present.
            let usedPercent: Double?
            if let rem = remainingFraction, rem <= 1.0 {
                usedPercent = max(0, min(100, (1.0 - rem) * 100.0))
            } else if resetDate != nil {
                usedPercent = 100.0
            } else {
                usedPercent = nil
            }
            guard usedPercent != nil || resetDate != nil else { continue }
            let kind: QuotaWindowKind
            if provider == .claude {
                if lower.contains("opus") {
                    kind = .sevenDayOpus
                } else if lower.contains("sonnet") {
                    kind = .sevenDaySonnet
                } else {
                    kind = .fiveHour
                }
                // Also populate primary fiveHour / sevenDay window if not yet set
                let primaryKind: QuotaWindowKind = (resetDate.map { $0.timeIntervalSince(date) <= 8 * 3600 } ?? true) ? .fiveHour : .sevenDay
                if windowsByKind[primaryKind] == nil {
                    windowsByKind[primaryKind] = QuotaWindow(
                        kind: primaryKind,
                        windowMinutes: primaryKind == .fiveHour ? 300 : 10080,
                        usedPercent: usedPercent,
                        resetsAt: resetDate
                    )
                }
            } else {
                let isShortWindow = resetDate.map { $0.timeIntervalSince(date) <= 8 * 3600 } ?? true
                kind = isShortWindow ? .fiveHour : .sevenDay
            }
            if windowsByKind[kind] == nil {
                windowsByKind[kind] = QuotaWindow(
                    kind: kind,
                    windowMinutes: kind == .fiveHour ? 300 : 10080,
                    usedPercent: usedPercent,
                    resetsAt: resetDate
                )
            }
        }
        return windowsByKind.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }
}
