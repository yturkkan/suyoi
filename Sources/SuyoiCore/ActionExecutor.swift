import Foundation
import Darwin

/// Explicit user actions only. Captured identities are revalidated immediately before each action.
public struct ActionExecutor: ActionExecuting, Sendable {
    private let processLookup: @Sendable (Int32, Int) -> ObservedProcess?
    private let signalSender: @Sendable (pid_t, Int32) -> Int32
    private let identityReader: @Sendable (URL) -> FileIdentity?
    private let trashHandler: @Sendable (URL) throws -> URL?

    public init(
        processLookup: (@Sendable (Int32, Int) -> ObservedProcess?)? = nil,
        signalSender: @escaping @Sendable (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) },
        identityReader: @escaping @Sendable (URL) -> FileIdentity? = { FileMetadataReader().identity(at: $0) },
        trashHandler: @escaping @Sendable (URL) throws -> URL? = { url in
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        }
    ) {
        // Native reader is internal, so its default is resolved inside the public initializer.
        self.processLookup = processLookup ?? { DarwinProcessReader().process(pid: $0, uid: $1) }
        self.signalSender = signalSender
        self.identityReader = identityReader
        self.trashHandler = trashHandler
    }

    public func stopProcess(identity: ProcessIdentity, force: Bool = false, uid: Int = Int(getuid())) -> ProcessExecutionReport {
        let signal = force ? SIGKILL : SIGTERM
        func failure(_ error: String) -> ProcessExecutionReport {
            ProcessExecutionReport(outcomes: [ProcessActionOutcome(pid: identity.pid, signal: signal, succeeded: false, error: error)])
        }
        guard identity.isActionEligible, identity.uid == uid, identity.pid > 1,
              identity.pid != Int(getpid()), let pid = Int32(exactly: identity.pid) else {
            return failure("Process identity is not eligible for this user's action")
        }
        guard let live = processLookup(pid, uid), live.identity == identity else {
            return failure("Process identity changed or process already exited")
        }
        let rc = signalSender(pid, signal)
        let error = rc == 0 ? nil : "Signal delivery failed (errno \(errno))"
        return ProcessExecutionReport(outcomes: [ProcessActionOutcome(pid: identity.pid, signal: signal, succeeded: rc == 0, error: error)])
    }

    public func stopServerGroup(group: ServerGroup, processes: [ObservedProcess], force: Bool = false, uid: Int = Int(getuid())) -> ProcessExecutionReport {
        let targets = Set(group.memberPIDs.isEmpty ? [group.rootPID] : group.memberPIDs)
        guard !processes.isEmpty else {
            return ProcessExecutionReport(outcomes: targets.sorted().map {
                ProcessActionOutcome(pid: $0, signal: force ? SIGKILL : SIGTERM, succeeded: false,
                    error: "Process snapshot is empty; identity cannot be verified")
            })
        }
        let byPID = ProcessTree(processes: processes).processesByPID
        // A bounded, cycle-safe parent walk orders descendants before their ancestors.
        func depth(_ pid: Int) -> Int {
            var current = pid
            var seen = Set<Int>()
            var depth = 0
            while seen.insert(current).inserted, let parent = byPID[current]?.parentPID,
                  targets.contains(parent), depth < 64 {
                depth += 1
                current = parent
            }
            return depth
        }
        let ordered = targets.sorted { a, b in
            if a == group.rootPID { return false }
            if b == group.rootPID { return true }
            let da = depth(a), db = depth(b)
            return da == db ? a < b : da > db
        }
        let capturedIdentitiesByPID = Dictionary(group.memberIdentities.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var outcomes: [ProcessActionOutcome] = []
        var warnings: [String] = []
        for pid in ordered {
            guard let process = byPID[pid] else {
                outcomes.append(ProcessActionOutcome(pid: pid, signal: force ? SIGKILL : SIGTERM, succeeded: false,
                    error: "Process identity changed or process already exited"))
                continue
            }
            if !capturedIdentitiesByPID.isEmpty {
                guard let captured = capturedIdentitiesByPID[pid], captured == process.identity else {
                    outcomes.append(ProcessActionOutcome(pid: pid, signal: force ? SIGKILL : SIGTERM, succeeded: false,
                        error: "Process identity changed or PID was reused since group selection"))
                    continue
                }
            }
            if group.stoppedByAgentBoundary && AgentRecognizer.isAgent(process) {
                warnings.append("Skipped coding agent at server boundary (PID \(pid))")
                continue
            }
            let targetIdentity = capturedIdentitiesByPID[pid] ?? process.identity
            outcomes.append(contentsOf: stopProcess(identity: targetIdentity, force: force, uid: uid).outcomes)
        }
        return ProcessExecutionReport(outcomes: outcomes, warnings: warnings)
    }

    public func moveCandidatesToTrash(candidates: [CleanupCandidate],
                                      freshAssessment: @Sendable (CleanupCandidate) -> SafetyAssessment?) -> TrashExecutionReport {
        // Choose ancestors first regardless of input order; never count or execute descendants twice.
        let ordered = candidates.enumerated().sorted {
            let a = URL(fileURLWithPath: $0.element.path).standardizedFileURL.pathComponents.count
            let b = URL(fileURLWithPath: $1.element.path).standardizedFileURL.pathComponents.count
            return a == b ? $0.offset < $1.offset : a < b
        }
        var selectedPaths: [String] = []
        var outcomes: [TrashItemOutcome] = []
        var reclaimedBytes: Int64 = 0
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        for item in ordered {
            let candidate = item.element
            let url = URL(fileURLWithPath: candidate.path).standardizedFileURL
            func failed(_ error: String) -> TrashItemOutcome {
                TrashItemOutcome(candidateID: candidate.id, path: candidate.path, bytes: 0, succeeded: false, error: error)
            }
            if selectedPaths.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) {
                outcomes.append(failed("Candidate overlaps an already selected path"))
                continue
            }
            selectedPaths.append(url.path)
            guard !candidate.partial, let expectedIdentity = candidate.fileIdentity else {
                outcomes.append(failed("Candidate is partial or unidentified"))
                continue
            }
            guard candidate.path.hasPrefix("/"), url.path != "/", candidate.scope != .worktree,
                  !AgentCacheCatalog.isForbiddenPath(url, homeDirectory: URL(fileURLWithPath: "/")),
                  Self.hasNoSymlinkComponents(url) else {
                outcomes.append(failed("Candidate path is unsafe or contains a symlink"))
                continue
            }
            guard let assessment = freshAssessment(candidate), assessment.candidateID == candidate.id else {
                outcomes.append(failed("Live safety assessment is unavailable for this candidate"))
                continue
            }
            guard assessment.isReviewableForTrash, assessment.blockedReasons.isEmpty, assessment.usage == .clear else {
                outcomes.append(failed(assessment.blockedReasons.first ?? "Candidate failed the live safety assessment"))
                continue
            }
            switch assessment.regenerability {
            case .unverified:
                outcomes.append(failed("Candidate regenerability is unverified"))
                continue
            case .cacheDirectory, .lockfileVerified: break
            }
            guard Self.hasNoSymlinkComponents(url), identityReader(url) == expectedIdentity,
                  Self.hasNoSymlinkComponents(url) else {
                outcomes.append(failed("Candidate path is unsafe, contains a symlink, or file identity changed"))
                continue
            }
            if case .lockfileVerified(let lockfile) = assessment.regenerability {
                guard NodeModulesSafety.verifyProjectRegenerability(for: candidate, rootURL: url.deletingLastPathComponent()) == .lockfileVerified(lockfile) else {
                    outcomes.append(failed("Project manifest or lockfile changed since the safety assessment"))
                    continue
                }
            }
            let policyRoot = url.path.hasPrefix(home.path + "/") ? home : URL(fileURLWithPath: "/")
            if let blocker = FileMetadataReader().trashDescendantBlocker(at: url, expectedIdentity: expectedIdentity, homeDirectory: policyRoot) {
                outcomes.append(failed(blocker))
                continue
            }
            do {
                let trashed = try trashHandler(url)
                let bytes = max(0, candidate.bytes)
                reclaimedBytes = reclaimedBytes > Int64.max - bytes ? Int64.max : reclaimedBytes + bytes
                outcomes.append(TrashItemOutcome(candidateID: candidate.id, path: candidate.path,
                    trashedURL: trashed?.path, bytes: bytes, succeeded: true))
            } catch {
                outcomes.append(failed("Could not move candidate to Trash: \(error.localizedDescription)"))
            }
        }
        return TrashExecutionReport(outcomes: outcomes, reclaimedBytes: reclaimedBytes,
            warnings: ["Reported bytes are logical sizes moved to Trash; disk space is not necessarily freed."])
    }

    private static func hasNoSymlinkComponents(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return false }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0, (parentInfo.st_mode & S_IFMT) != S_IFLNK else { return false }
        return parent.resolvingSymlinksInPath().path == parent.path
    }
}
