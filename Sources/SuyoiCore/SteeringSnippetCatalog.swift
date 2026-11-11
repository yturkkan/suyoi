import Foundation

public struct SteeringSnippet: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let trigger: String
    public let title: String
    public let prompt: String
    public let isBuiltIn: Bool

    public init(
        id: String = UUID().uuidString,
        trigger: String,
        title: String,
        prompt: String,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.trigger = trigger
        self.title = title
        self.prompt = prompt
        self.isBuiltIn = isBuiltIn
    }
}

public enum SteeringSnippetCatalog {
    public static let customSnippetsDefaultsKey = "suyoi.customSteeringSnippets"

    public static let builtInSnippets: [SteeringSnippet] = [
        SteeringSnippet(
            id: "builtin-test",
            trigger: "/test",
            title: "Run Tests & Fix",
            prompt: "Run the relevant test suite, inspect any failures, and fix root causes minimally without breaking existing behavior.",
            isBuiltIn: true
        ),
        SteeringSnippet(
            id: "builtin-diff",
            trigger: "/diff",
            title: "Summarize Diff",
            prompt: "Inspect git status and git diff, then summarize current changes, edge cases, and any remaining risks concisely.",
            isBuiltIn: true
        ),
        SteeringSnippet(
            id: "builtin-review",
            trigger: "/review",
            title: "Bug & Security Review",
            prompt: "Review recent code changes for correctness bugs, race conditions, regressions, and security issues before proceeding.",
            isBuiltIn: true
        ),
        SteeringSnippet(
            id: "builtin-commit",
            trigger: "/commit",
            title: "Stage & Commit",
            prompt: "Review git status and git diff, verify no secrets or temporary artifacts are included, and create a focused commit with a clear message.",
            isBuiltIn: true
        ),
        SteeringSnippet(
            id: "builtin-continue",
            trigger: "/continue",
            title: "Continue Next Step",
            prompt: "Continue with the next planned step and verify the result.",
            isBuiltIn: true
        )
    ]

    public static func normalizeTrigger(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let withSlash = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        let body = withSlash.dropFirst()
        guard (1...24).contains(body.count) else { return nil }
        let valid = body.utf8.allSatisfy { byte in
            (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
        }
        return valid ? withSlash : nil
    }

    public static func sanitizeCustomSnippet(trigger: String, title: String, prompt: String) -> SteeringSnippet? {
        guard let normalizedTrigger = normalizeTrigger(trigger) else { return nil }
        let cleanTitle = String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleanPrompt = AgentSteerer.cleanPrompt(prompt) else { return nil }
        let finalTitle = cleanTitle.isEmpty ? String(normalizedTrigger.dropFirst()).capitalized : String(cleanTitle.prefix(48))
        return SteeringSnippet(
            trigger: normalizedTrigger,
            title: finalTitle,
            prompt: cleanPrompt,
            isBuiltIn: false
        )
    }

    public static func mergedSnippets(custom: [SteeringSnippet]) -> [SteeringSnippet] {
        var byTrigger: [String: SteeringSnippet] = [:]
        var orderedTriggers: [String] = []
        for item in builtInSnippets {
            byTrigger[item.trigger] = item
            orderedTriggers.append(item.trigger)
        }
        for item in custom {
            guard let trig = normalizeTrigger(item.trigger) else { continue }
            let normalized = SteeringSnippet(
                id: item.id,
                trigger: trig,
                title: item.title,
                prompt: item.prompt,
                isBuiltIn: false
            )
            if byTrigger[trig] == nil {
                orderedTriggers.append(trig)
            }
            byTrigger[trig] = normalized
        }
        return orderedTriggers.compactMap { byTrigger[$0] }
    }

    public static func expand(_ input: String, snippets: [SteeringSnippet] = builtInSnippets) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return input }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first else { return input }
        let candidateTrigger = String(first).lowercased()
        guard let matched = snippets.first(where: { $0.trigger.lowercased() == candidateTrigger }) else {
            return input
        }
        if parts.count == 2 {
            let remainder = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                return "\(matched.prompt) \(remainder)"
            }
        }
        return matched.prompt
    }

    public static func matchingSnippets(for input: String, snippets: [SteeringSnippet] = builtInSnippets) -> [SteeringSnippet] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("/") else { return snippets }
        let prefixToken = String(trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace).first ?? Substring(trimmed))
        return snippets.filter { $0.trigger.lowercased().hasPrefix(prefixToken) }
    }

    public static func loadCustomSnippets(from defaults: UserDefaults = .standard) -> [SteeringSnippet] {
        guard let data = defaults.data(forKey: customSnippetsDefaultsKey),
              data.count <= 64 * 1_024,
              let decoded = try? JSONDecoder().decode([SteeringSnippet].self, from: data) else {
            return []
        }
        return decoded.prefix(25).compactMap { item in
            guard let clean = sanitizeCustomSnippet(trigger: item.trigger, title: item.title, prompt: item.prompt) else {
                return nil
            }
            return SteeringSnippet(
                id: item.id,
                trigger: clean.trigger,
                title: clean.title,
                prompt: clean.prompt,
                isBuiltIn: false
            )
        }
    }

    public static func saveCustomSnippets(_ snippets: [SteeringSnippet], to defaults: UserDefaults = .standard) {
        let customOnly = Array(snippets.filter { !$0.isBuiltIn }.prefix(25))
        if let data = try? JSONEncoder().encode(customOnly) {
            defaults.set(data, forKey: customSnippetsDefaultsKey)
        }
    }
}
