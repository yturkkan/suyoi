import Foundation
import Testing
@testable import SuyoiCore

@Suite struct AgentCacheCatalogTests {
    @Test func projectsWorkspaceIsAllowedButHiddenProjectHistoryIsForbidden() {
        let home = URL(fileURLWithPath: "/Users/cache-test")
        for path in ["Projects/demo/.build", "projects/demo/.build", "Projects/demo/projects/.build"] {
            #expect(!AgentCacheCatalog.isForbiddenPath(home.appendingPathComponent(path), homeDirectory: home))
        }
        for path in [".claude/projects/demo", ".cache/projects", "Projects/.agent/projects/demo"] {
            #expect(AgentCacheCatalog.isForbiddenPath(home.appendingPathComponent(path), homeDirectory: home))
        }
    }

    @Test func highImpactCacheClassificationUsesNormalizedPathsAndKnownRoots() {
        let home = URL(fileURLWithPath: "/Users/cache-test")
        for path in [".cache/huggingface", ".cache/huggingface/hub", ".cache/uv", "Library/Developer/CoreSimulator",
                     "Library/Developer/CoreSimulator/Caches", "Projects/demo/.venv", "Projects/demo/venv",
                     ".cache/custom", ".cache/custom/nested", ".cache/other/../custom"] {
            #expect(AgentCacheCatalog.isHighImpactCachePath(home.appendingPathComponent(path).path, homeDirectory: home))
        }
        for path in [".cache", ".cache/opencode", ".cache/opencode/nested", ".cache/puppeteer", "Projects/demo/.build",
                     "Projects/demo/venv-other", "Library/Developer/CoreSimulator-other", ".npm/_cacache"] {
            #expect(!AgentCacheCatalog.isHighImpactCachePath(home.appendingPathComponent(path).path, homeDirectory: home))
        }
    }

    @Test func multiRootScanDeduplicatesCachesAndReassessmentRejectsChangedIdentity() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let roots = [home.appendingPathComponent("Projects/one"), home.appendingPathComponent("Projects/two")]
        for root in roots {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".build"), withIntermediateDirectories: true)
            try Data("// fixture".utf8).write(to: root.appendingPathComponent("Package.swift"))
        }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/cache"), withIntermediateDirectories: true)
        let service = InventoryService(processInspector: CacheCatalogProcessFixture(), listenerInspector: CacheCatalogListenerFixture(),
            safetyEvaluator: SafetyEvaluator(homeDirectory: home, openFileCheck: { _ in .clear }))
        let report = service.scanCleanup(roots: roots + [roots[0].appendingPathComponent("../one")], homeDirectory: home)
        #expect(!report.partial)
        #expect(report.candidates.count == 2)
        #expect(report.agentCacheCandidates.count == 1)
        #expect(report.discoveredCount == 3)
        #expect(report.assessments.count == 3)
        #expect(report.assessments.values.allSatisfy { $0.isReviewableForTrash })
        let candidate = try #require(report.candidates.first)
        #expect(service.reassessCandidatesForTrash([candidate], homeDirectory: home)[candidate.id]?.isReviewableForTrash == true)
        let original = URL(fileURLWithPath: candidate.path)
        try FileManager.default.moveItem(at: original, to: original.appendingPathExtension("old"))
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let assessment = try #require(service.reassessCandidatesForTrash([candidate], homeDirectory: home)[candidate.id])
        #expect(!assessment.isReviewableForTrash)
        #expect(assessment.blockedReasons.contains("Candidate file identity changed"))

        let busyService = InventoryService(processInspector: CacheCatalogProcessFixture(), listenerInspector: CacheCatalogListenerFixture(),
            safetyEvaluator: SafetyEvaluator(homeDirectory: home, openFileCheck: { _ in .inUse }))
        let cache = try #require(report.agentCacheCandidates.first)
        #expect(busyService.reassessCandidatesForTrash([cache], homeDirectory: home)[cache.id]?.usage == .inUse)
    }

    @Test func allCatalogLocationsAreDiscoveredAndRecognizedBySafetyEvaluator() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(AgentCacheCatalog.locations.count == 50)
        #expect(Set(AgentCacheCatalog.locations.map(\.0)).count == 50)
        for (path, _) in AgentCacheCatalog.locations {
            let directory = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("data"))
        }
        let result = AgentCacheCatalog().scanAgentCaches(homeDirectory: home)
        #expect(!result.partial)
        #expect(result.candidates.count == AgentCacheCatalog.locations.count)
        let evaluator = SafetyEvaluator(homeDirectory: home, openFileCheck: { _ in .clear })
        let processes = Observation<[ObservedProcess]>(value: [], status: .complete, warnings: [], capturedAt: Date())
        let worktrees = Observation<[WorktreeRecord]>(value: [], status: .complete, warnings: [], capturedAt: Date())
        for (path, name) in AgentCacheCatalog.locations {
            let url = home.appendingPathComponent(path)
            let candidate = try #require(result.candidates.first { $0.path == url.path })
            #expect(candidate.agentName == name)
            #expect(candidate.bytes == 3)
            #expect(!candidate.partial)
            let assessment = evaluator.assess(candidate: candidate, processes: processes, worktrees: worktrees)
            #expect(assessment.regenerability == .cacheDirectory)
            #expect(assessment.isReviewableForTrash)
            #expect(!AgentCacheCatalog.isAllowlisted(url: url.appendingPathComponent("nested"), homeDirectory: home))
            let sibling = URL(fileURLWithPath: url.path + "-other")
            #expect(AgentCacheCatalog.isAllowlisted(url: sibling, homeDirectory: home) == (url.deletingLastPathComponent() == home.appendingPathComponent(".cache")))
        }
    }

    @Test func largerCacheCanUseUnspentBudgetWithoutExceedingTotalLimit() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        // Missing Codex roots and a tiny earlier cache leave budget for the larger npm cache.
        for (path, count) in [(".claude/cache", 1), (".npm/_cacache", 30), (".gradle/caches", 1)] {
            let directory = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<count {
                try Data([1]).write(to: directory.appendingPathComponent("data-\(index)"))
            }
        }
        let result = AgentCacheCatalog().scanAgentCaches(homeDirectory: home, entryLimit: 50)
        #expect(!result.partial)
        #expect(result.candidates.count == 3)
        #expect(result.candidates.first { $0.agentName == "npm" }?.bytes == 30)
        #expect(result.candidates.reduce(Int64(0)) { $0 + $1.bytes } == 32)

        let limited = AgentCacheCatalog().scanAgentCaches(homeDirectory: home, entryLimit: 10)
        #expect(limited.partial)
        #expect(limited.candidates.reduce(Int64(0)) { $0 + $1.bytes } == 10)
        #expect(limited.candidates.first { $0.agentName == "npm" }?.partial == true)
        #expect(limited.candidates.first { $0.agentName == "Gradle" }?.partial == true)
    }

    @Test func discoversDirectCacheDirectoriesWithoutDuplicatesOrUnsafePaths() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        for path in [".cache/custom-tool/nested", ".cache/huggingface/hub", ".cache/huggingface/xet", ".cache/opencode", ".cache/projects", ".cache/credentials", ".cache/private.db", ".cache/.hidden", "real"] {
            let directory = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("data"))
        }
        try Data([9]).write(to: home.appendingPathComponent(".cache/regular-file"))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".cache/linked"), withDestinationURL: home.appendingPathComponent("real"))

        let result = AgentCacheCatalog().scanAgentCaches(homeDirectory: home, entryLimit: 1_000_000)
        #expect(!result.partial)
        let actualPaths = Set(result.candidates.map(\.path))
        let expectedPaths = Set([".cache/custom-tool", ".cache/huggingface", ".cache/opencode"].map { home.appendingPathComponent($0).path })
        #expect(actualPaths == expectedPaths)
        #expect(result.candidates.count == 3)
        #expect(result.candidates.first { $0.agentName == "HuggingFace" }?.bytes == 6)
        let custom = try #require(result.candidates.first { $0.agentName == "custom-tool" })
        #expect(custom.bytes == 3)
        let evaluator = SafetyEvaluator(homeDirectory: home, openFileCheck: { _ in .clear })
        let assessment = evaluator.assess(candidate: custom,
                                          processes: Observation(value: [], status: .complete, warnings: [], capturedAt: Date()),
                                          worktrees: Observation(value: [], status: .complete, warnings: [], capturedAt: Date()))
        #expect(assessment.regenerability == .cacheDirectory)
        #expect(assessment.isReviewableForTrash)
        for path in [".cache", ".cache/custom-tool/nested", ".cache/projects", ".cache/credentials", ".cache/private.db", "real"] {
            #expect(!AgentCacheCatalog.isAllowlisted(url: home.appendingPathComponent(path), homeDirectory: home))
        }
    }

    @Test func allowlistAndForbiddenLocations() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        for path in [".codex/cache", ".codex/sessions", ".claude/projects", "Library/Application Support/Cursor/User", ".gemini"] {
            let directory = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("data"))
        }
        try Data([1]).write(to: home.appendingPathComponent(".gemini/settings.json"))
        try Data(repeating: 9, count: 20).write(to: home.appendingPathComponent(".codex/cache/settings.json"))
        let result = AgentCacheCatalog().scanAgentCaches(homeDirectory: home)
        #expect(result.candidates.count == 1)
        #expect(result.candidates.first?.path == home.appendingPathComponent(".codex/cache").path)
        #expect(result.candidates.first?.scope == .agentCache)
        #expect(result.candidates.first?.agentName == "Codex")
        #expect(result.candidates.first?.bytes == 3)
        #expect(result.candidates.first?.partial == true)
        #expect(result.candidates.first?.allocatedBytes != nil)
        #expect(result.candidates.first?.fileIdentity != nil)
        for path in [".codex/sessions/log.jsonl", ".claude/projects/project", "Library/Application Support/Cursor/User/settings.json", ".gemini/settings.json", ".ssh/key"] {
            #expect(AgentCacheCatalog.isForbiddenPath(home.appendingPathComponent(path), homeDirectory: home))
            #expect(!result.candidates.contains { $0.path == home.appendingPathComponent(path).path })
        }
    }

    @Test func rejectsSymlinkedCandidateAndAncestor() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let real = home.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".codex/cache"), withDestinationURL: real)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude"), withDestinationURL: real)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".cache"), withDestinationURL: real)
        try FileManager.default.createDirectory(at: real.appendingPathComponent("cache"), withIntermediateDirectories: true)
        #expect(AgentCacheCatalog().scanAgentCaches(homeDirectory: home).candidates.isEmpty)
    }
}

private struct CacheCatalogProcessFixture: ProcessInspecting {
    func inspectProcesses(uid: Int) -> Observation<[ObservedProcess]> {
        Observation(value: [], status: .complete, warnings: [], capturedAt: Date())
    }
}

private struct CacheCatalogListenerFixture: ListenerInspecting {
    func inspectListeners(uid: Int) -> Observation<[Listener]> {
        Observation(value: [], status: .complete, warnings: [], capturedAt: Date())
    }
}
