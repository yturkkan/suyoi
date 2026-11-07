import Foundation
import Darwin
import Testing
@testable import SuyoiCore

private struct SafetyCommandStub: CommandRunning {
    let response: CommandResult
    func run(_ request: CommandRequest) throws -> CommandResult {
        #expect(request.executable == "/usr/sbin/lsof")
        #expect(request.arguments == ["-nP", "-a", "-u", "501", "+D", "/fixture/cache", "-Fp"])
        #expect(request.timeout <= 4)
        return response
    }
}

private struct SafetyFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("suyoi-safety-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func directory(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func file(_ relative: String) throws { try Data().write(to: root.appendingPathComponent(relative)) }
    func candidate(_ relative: String, partial: Bool = false, scope: CleanupScope = .projectArtifact, agentName: String? = nil, bytes: Int64 = 12, allocated: Int64? = 16) throws -> CleanupCandidate {
        let url = try directory(relative)
        if scope == .projectArtifact {
            let project = NodeModulesSafety.projectRoot(for: url)
            try Data().write(to: project.appendingPathComponent("package.json"))
        }
        return CleanupCandidate(path: url.path, category: "fixture", bytes: bytes, partial: partial, scope: scope, allocatedBytes: allocated, fileIdentity: FileMetadataReader().identity(at: url), agentName: agentName)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func safetyObservation<T>(_ value: T, status: ObservationStatus = .complete) -> Observation<T> where T: Codable & Equatable & Sendable {
    Observation(value: value, status: status, warnings: [], capturedAt: Date(timeIntervalSince1970: 0))
}

private final class ScanIdentityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    let scenario: String
    init(_ scenario: String) { self.scenario = scenario }

    func read(_ url: URL) throws -> FileIdentity? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        if scenario == "missingBefore" && reads == 1 { return nil }
        if scenario == "missingAfter" && reads == 2 { return nil }
        if scenario == "replaced" && reads == 2 {
            // Swap after measurement but before the scanner's final identity read.
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("saved"))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return FileMetadataReader().identity(at: url)
    }
}

struct SafetyEvaluatorTests {
    @Test(arguments: ["stable", "missingBefore", "missingAfter", "replaced"])
    func scannerRequiresMatchingIdentitiesAroundMeasurement(_ scenario: String) throws {
        let fixture = try SafetyFixture(); defer { fixture.remove() }
        let original = try fixture.candidate("app/.turbo")
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: original.path).appendingPathComponent("payload"))
        let probe = ScanIdentityProbe(scenario)
        let scanner = CleanupScanner(identityReader: { try? probe.read($0) })
        let report = scanner.scan(root: fixture.root, entryLimit: 10_000, timeLimit: 10)
        #expect(report.candidates.count == 1)
        let candidate = try #require(report.candidates.first { $0.path.hasSuffix("/app/.turbo") })
        #expect(candidate.bytes == 3)
        let assessment = SafetyEvaluator(homeDirectory: fixture.root).assess(candidate: candidate,
            processes: safetyObservation([]), worktrees: safetyObservation([]))
        if scenario == "stable" {
            #expect(!candidate.partial)
            #expect(candidate.fileIdentity == original.fileIdentity)
            #expect(assessment.isReviewableForTrash)
        } else {
            #expect(candidate.partial)
            #expect(candidate.fileIdentity == nil)
            #expect(report.partial)
            #expect(!assessment.isReviewableForTrash)
        }
    }

    @Test(arguments: ["node_modules", ".build", ".next/cache", "src/__pycache__"])
    func ordinaryServerCwdProtectsProjectArtifacts(_ relative: String) throws {
        let fixture = try SafetyFixture(); defer { fixture.remove() }
        let url = try fixture.directory("app/" + relative)
        try fixture.file("app/package.json")
        try fixture.file("app/package-lock.json")
        let candidate = CleanupCandidate(path: url.path, category: "fixture", bytes: 0, partial: false,
            fileIdentity: FileMetadataReader().identity(at: url))
        let evaluator = SafetyEvaluator(homeDirectory: fixture.root)
        for executable in ["/usr/bin/node", "/usr/bin/python"] {
            for cwd in ["app", "app/src/../src", "app-other"] {
                let process = ObservedProcess(pid: 42, parentPID: 1, uid: Int(getuid()), cpuPercent: 0,
                    residentBytes: 0, executable: executable, cwd: fixture.root.appendingPathComponent(cwd).path)
                #expect(!AgentRecognizer.isAgent(process))
                let assessment = evaluator.assess(candidate: candidate, processes: safetyObservation([process]), worktrees: safetyObservation([]))
                if cwd == "app-other" {
                    #expect(assessment.usage == .clear)
                    #expect(assessment.isReviewableForTrash)
                } else {
                    #expect(assessment.usage == .inUse)
                    #expect(!assessment.isReviewableForTrash)
                    #expect(!assessment.blockedReasons.isEmpty)
                }
            }
        }
    }

    @Test func cacheUsageDoesNotTreatParentAsProjectRoot() throws {
        let fixture = try SafetyFixture(); defer { fixture.remove() }
        let candidate = try fixture.candidate(".codex/cache", scope: .agentCache)
        let process = ObservedProcess(pid: 42, parentPID: 1, uid: Int(getuid()), cpuPercent: 0,
            residentBytes: 0, executable: "/usr/bin/node", cwd: fixture.root.appendingPathComponent(".codex").path)
        let result = SafetyEvaluator(homeDirectory: fixture.root).assess(candidate: candidate,
            processes: safetyObservation([process]), worktrees: safetyObservation([]))
        #expect(result.usage == .clear)
        #expect(result.isReviewableForTrash)
    }

    @Test func nodeModulesRequiresManifestAndLock() throws {
        let fixture = try SafetyFixture(); defer { fixture.remove() }
        let candidate = try fixture.candidate("app/node_modules")
        let safety = NodeModulesSafety()
        let empty: Observation<[ObservedProcess]> = safetyObservation([])
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("app/package.json"))
        let missingManifest = safety.assess(candidate: candidate, processes: empty)
        #expect(missingManifest.regenerability == .unverified("Missing package.json"))
        #expect(missingManifest.blockedReasons.contains("Missing package.json in project root"))
        try fixture.file("app/package.json")
        let missingLock = safety.assess(candidate: candidate, processes: empty)
        #expect(missingLock.regenerability == .unverified("No lockfile"))
        #expect(!missingLock.isReviewableForTrash)
        try fixture.file("app/pnpm-lock.yaml")
        let verified = safety.assess(candidate: candidate, processes: empty)
        #expect(verified.regenerability == .lockfileVerified("pnpm-lock.yaml"))
        #expect(verified.isReviewableForTrash)
    }

    @Test(arguments: ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "npm-shrinkwrap.json"])
    func supportedLocks(_ lock: String) throws {
        let fixture = try SafetyFixture(); defer { fixture.remove() }
        let candidate = try fixture.candidate("app/node_modules")
        try fixture.file("app/package.json"); try fixture.file("app/" + lock)
        #expect(NodeModulesSafety().assess(candidate: candidate, processes: safetyObservation([])).regenerability == .lockfileVerified(lock))
    }

    @Test func projectRootsAndCacheRegeneration() throws {
        let fixture = try SafetyFixture(); defer { fixture.remove() }
        for relative in ["app/.build", "app/.turbo", "app/.vite", "app/.next/cache"] {
            let candidate = try fixture.candidate(relative)
            #expect(NodeModulesSafety().assess(candidate: candidate, processes: safetyObservation([])).regenerability == .cacheDirectory)
        }
        try fixture.file("app/Package.swift")
        let build = try fixture.candidate("app/.build")
        #expect(NodeModulesSafety().assess(candidate: build, processes: safetyObservation([])).regenerability == .cacheDirectory)
        let cache = try fixture.candidate("app/.next/cache")
        let process = ObservedProcess(pid: 42, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0, executable: "/usr/bin/node", cwd: fixture.root.appendingPathComponent("app/.next/cache").path)
        let busy = NodeModulesSafety().assess(candidate: cache, processes: safetyObservation([process]))
        #expect(busy.usage == .inUse)
        #expect(busy.blockedReasons.contains("Project is in use by node (PID 42)"))
        let unknown = NodeModulesSafety().assess(candidate: cache, processes: safetyObservation([], status: .partial))
        #expect(unknown.usage == .clear)
        #expect(unknown.blockedReasons.isEmpty)
        #expect(!NodeModulesSafety.contains(fixture.root.path + "/app-other", in: fixture.root.path + "/app"))
    }

    @Test func recursiveOpenFileTriState() {
        func check(_ exit: Int32, _ out: String = "", _ err: String = "", timeout: Bool = false, truncated: Bool = false) -> UsageState {
            OpenFileInspector(runner: SafetyCommandStub(response: CommandResult(exitCode: exit, stdout: Data(out.utf8), stderr: Data(err.utf8), timedOut: timeout, truncated: truncated))).checkPathInUse("/fixture/cache", uid: 501)
        }
        #expect(check(1) == .clear)
        #expect(check(0, "p999999\n") == .inUse)
        #expect(check(0, "p\(getpid())\n") == .clear)
        #expect(check(0) == .unknown)
        #expect(check(1, "p12\n") == .unknown)
        #expect(check(2) == .unknown)
        #expect(check(0, "p12\n", "warning") == .unknown)
        #expect(check(1, "", "warning") == .unknown)
        #expect(check(1, timeout: true) == .unknown)
        #expect(check(0, "p12\n", truncated: true) == .unknown)
        #expect(check(0, "garbage") == .unknown)
        #expect(check(0, "p12\ngarbage\n") == .unknown)
    }

    @Test func evaluatorRejectsPartialMissingChangedIdentityAndSensitivePaths() throws {
        let fixture = try SafetyFixture(); defer { fixture.remove() }
        let evaluator = SafetyEvaluator(homeDirectory: fixture.root)
        func assess(_ candidate: CleanupCandidate) -> SafetyAssessment {
            evaluator.assess(candidate: candidate, processes: safetyObservation([]), worktrees: safetyObservation([]))
        }
        let partial = try fixture.candidate("app/.vite", partial: true)
        #expect(assess(partial).blockedReasons.contains("Candidate measurement is partial"))
        let valid = try fixture.candidate("app/.turbo")
        #expect(assess(valid).isReviewableForTrash)
        let noIdentity = CleanupCandidate(path: valid.path, category: "cache", bytes: 0, partial: false)
        #expect(assess(noIdentity).blockedReasons.contains("Missing file identity (device/inode)"))
        let changed = CleanupCandidate(path: valid.path, category: "cache", bytes: 0, partial: false, fileIdentity: FileIdentity(device: -1, inode: 0))
        #expect(assess(changed).blockedReasons.contains("Candidate file identity changed"))
        let forbidden = try fixture.candidate(".codex/sessions", scope: .agentCache)
        #expect(assess(forbidden).blockedReasons.contains("Forbidden or sensitive path"))
        let outside = SafetyEvaluator(homeDirectory: fixture.root.appendingPathComponent("other")).assess(candidate: valid, processes: safetyObservation([]), worktrees: safetyObservation([]))
        #expect(!outside.isReviewableForTrash)
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: valid.path).deletingLastPathComponent())
        let linked = CleanupCandidate(path: link.appendingPathComponent(".turbo").path, category: "cache", bytes: 0, partial: false, fileIdentity: valid.fileIdentity)
        #expect(!assess(linked).isReviewableForTrash)
    }

    @Test func agentUsageAndUnavailableEvidenceFailClosed() throws {
        let fixture = try SafetyFixture(); defer { fixture.remove() }
        let candidate = try fixture.candidate(".codex/cache", scope: .agentCache, agentName: "Codex")
        let evaluator = SafetyEvaluator(homeDirectory: fixture.root, openFileCheck: { _ in .clear })
        let running = ObservedProcess(pid: 44, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0, executable: "/bin/codex")
        let busy = evaluator.assess(candidate: candidate, processes: safetyObservation([running]), worktrees: safetyObservation([]))
        #expect(busy.usage == .inUse)
        #expect(busy.blockedReasons.contains("Codex is currently running"))
        #expect(!busy.isReviewableForTrash)
        #expect(evaluator.assess(candidate: candidate, processes: safetyObservation([]), worktrees: safetyObservation([])).isReviewableForTrash)
        #expect(!evaluator.assess(candidate: candidate, processes: safetyObservation([], status: .unavailable), worktrees: safetyObservation([])).isReviewableForTrash)
        #expect(SafetyEvaluator(homeDirectory: fixture.root).assess(candidate: candidate, processes: safetyObservation([]), worktrees: safetyObservation([])).usage == .clear)
    }

    @Test func worktreeEvidenceIsPropagated() throws {
        let fixture = try SafetyFixture(); defer { fixture.remove() }
        let candidate = try fixture.candidate("app/.vite")
        let tree = WorktreeRecord(path: fixture.root.appendingPathComponent("app").path, branch: "feature", headCommit: "abc", isMain: false, isDirty: true, isLocked: false, isMergedToDefault: false, usage: .inUse, blockedReasons: ["fixture blocked"])
        let evaluator = SafetyEvaluator(homeDirectory: fixture.root)
        let result = evaluator.assess(candidate: candidate, processes: safetyObservation([]), worktrees: safetyObservation([tree]))
        #expect(result.usage == .inUse)
        #expect(result.blockedReasons.contains("Candidate is inside a dirty worktree"))
        #expect(!result.isReviewableForTrash)
        #expect(evaluator.assess(candidate: candidate, processes: safetyObservation([]), worktrees: safetyObservation([], status: .partial)).isReviewableForTrash)
        let partialMatch = evaluator.assess(candidate: candidate, processes: safetyObservation([]), worktrees: safetyObservation([tree], status: .partial))
        #expect(partialMatch.blockedReasons.contains("Worktree inventory could not be fully verified"))
        #expect(!partialMatch.isReviewableForTrash)
        let worktree = try fixture.candidate("app", scope: .worktree)
        let assessment = evaluator.assess(candidate: worktree, processes: safetyObservation([]), worktrees: safetyObservation([tree]))
        #expect(assessment.blockedReasons.contains("fixture blocked"))
        #expect(assessment.usage == .inUse)
    }

    @Test(arguments: [".build", ".next", "target", "dist", ".turbo", ".parcel-cache", ".svelte-kit", ".nuxt", ".astro", ".pytest_cache", ".ruff_cache", ".mypy_cache", "__pycache__", ".venv", "venv"])
    func generatedFoldersNeedRecognizedProject(_ name: String) throws {
        let fixture = try SafetyFixture(); defer { fixture.remove() }
        let candidate = try fixture.candidate("app/" + name)
        let evaluator = SafetyEvaluator(homeDirectory: fixture.root)
        let result = evaluator.assess(candidate: candidate, processes: safetyObservation([], status: .partial), worktrees: safetyObservation([], status: .unavailable))
        #expect(result.regenerability == .cacheDirectory)
        #expect(result.isReviewableForTrash)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("app/package.json"))
        #expect(!evaluator.assess(candidate: candidate, processes: safetyObservation([]), worktrees: safetyObservation([])).isReviewableForTrash)
    }

    @Test func nestedPythonCacheUsesRecognizedAncestorProject() throws {
        let fixture = try SafetyFixture(); defer { fixture.remove() }
        let url = try fixture.directory("app/src/__pycache__")
        try fixture.file("app/pyproject.toml")
        let candidate = CleanupCandidate(path: url.path, category: "Python cache", bytes: 10, partial: false,
            fileIdentity: FileMetadataReader().identity(at: url))
        let result = SafetyEvaluator(homeDirectory: fixture.root).assess(candidate: candidate,
            processes: safetyObservation([], status: .partial), worktrees: safetyObservation([], status: .unavailable))
        #expect(result.isReviewableForTrash)
    }

    @Test func partialObservationsUseCandidateSpecificEvidenceAndAgentAncestry() throws {
        let fixture = try SafetyFixture(); defer { fixture.remove() }
        let candidate = try fixture.candidate("app/dist")
        let url = URL(fileURLWithPath: candidate.path)
        let unrelated = ObservedProcess(pid: 50, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0, executable: "/bin/node", cwd: fixture.root.appendingPathComponent("elsewhere").path)
        let inside = ObservedProcess(pid: 51, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0, executable: "/bin/node", cwd: url.path)
        #expect(NodeModulesSafety().assess(candidate: candidate, processes: safetyObservation([unrelated], status: .partial)).usage == .clear)
        #expect(NodeModulesSafety().assess(candidate: candidate, processes: safetyObservation([inside], status: .partial)).usage == .inUse)
        let terminal = ObservedProcess(pid: 52, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0, executable: "/bin/zsh", cwd: url.deletingLastPathComponent().path)
        let agent = ObservedProcess(pid: 53, parentPID: 52, uid: 501, cpuPercent: 0, residentBytes: 0, executable: "/bin/codex")
        #expect(NodeModulesSafety().assess(candidate: candidate, processes: safetyObservation([terminal, agent], status: .partial)).usage == .inUse)
        let unavailable = NodeModulesSafety.workingDirectoryUsage(root: url, processes: safetyObservation([], status: .unavailable))
        #expect(unavailable.0 == .unknown)
        #expect(unavailable.1 == ["Process observation is unavailable"])
    }

    @Test func unallowlistedCachesAndInjectedOpenFileEvidence() throws {
        let fixture = try SafetyFixture(); defer { fixture.remove() }
        let invalid = try fixture.candidate("arbitrary/cache", scope: .agentCache)
        let valid = try fixture.candidate(".codex/cache", scope: .agentCache)
        let processes: Observation<[ObservedProcess]> = safetyObservation([], status: .partial)
        let worktrees: Observation<[WorktreeRecord]> = safetyObservation([], status: .unavailable)
        #expect(!SafetyEvaluator(homeDirectory: fixture.root).assess(candidate: invalid, processes: processes, worktrees: worktrees).isReviewableForTrash)
        #expect(SafetyEvaluator(homeDirectory: fixture.root).assess(candidate: valid, processes: processes, worktrees: worktrees).isReviewableForTrash)
        for state in [UsageState.unknown, .inUse] {
            let result = SafetyEvaluator(homeDirectory: fixture.root, openFileCheck: { _ in state }).assess(candidate: valid, processes: processes, worktrees: worktrees)
            #expect(result.usage == state)
            #expect(!result.isReviewableForTrash)
        }
        let artifact = try fixture.candidate("app/dist")
        let result = SafetyEvaluator(homeDirectory: fixture.root, openFileCheck: { _ in .unknown }).assess(candidate: artifact, processes: processes, worktrees: worktrees)
        #expect(result.usage == .unknown)
        #expect(!result.isReviewableForTrash)
    }

    @Test func previewCountsOnlyEligibleAndPreservesUnknownAllocation() throws {
        let fixture = try SafetyFixture(); defer { fixture.remove() }
        let a = try fixture.candidate("a/.vite", bytes: 10, allocated: 8)
        let b = try fixture.candidate("b/.vite", bytes: 20, allocated: nil)
        let blocked = try fixture.candidate("c/.vite", partial: true, bytes: 999)
        let evaluator = SafetyEvaluator(homeDirectory: fixture.root)
        let candidates = [a, b, blocked]
        let assessments = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, evaluator.assess(candidate: $0, processes: safetyObservation([]), worktrees: safetyObservation([]))) })
        let now = Date(timeIntervalSince1970: 123)
        let preview = ActionPreviewBuilder().build(candidates: candidates, assessments: assessments, now: now)
        #expect(preview.createdAt == now)
        #expect(preview.candidates == candidates)
        #expect(preview.eligibleCount == 2)
        #expect(preview.blockedCount == 1)
        #expect(preview.totalLogicalBytes == 30)
        #expect(preview.totalAllocatedBytes == nil)
        let single = ActionPreviewBuilder().build(candidates: [a], assessments: assessments)
        #expect(single.totalAllocatedBytes == 8)
        let missing = ActionPreviewBuilder().build(candidates: [a], assessments: [:])
        #expect(missing.blockedCount == 1)
        #expect(missing.totalLogicalBytes == 0)
        #expect(missing.totalAllocatedBytes == 0)
    }
}
