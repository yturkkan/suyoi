import AppKit
import SwiftUI
import SuyoiCore

struct CleanupPreviewView: View {
    let report: CleanupReport
    let recheckingCandidateIDs: Set<String>
    let trashedHistory: [TrashedItemRecord]
    let onTrashCandidate: ((CleanupCandidate) -> Void)?
    let onRecheckCandidate: ((CleanupCandidate) -> Void)?
    let onTrashWorktree: ((WorktreeRecord) -> Void)?
    let onRestoreTrashedItem: ((TrashedItemRecord) -> Void)?
    let onTrashAllEligible: (() -> Void)?
    let onDismiss: () -> Void
    private let leafGreen = Color(red: 0.22, green: 0.53, blue: 0.39)

    init(
        report: CleanupReport,
        recheckingCandidateIDs: Set<String> = [],
        trashedHistory: [TrashedItemRecord] = [],
        onTrashCandidate: ((CleanupCandidate) -> Void)? = nil,
        onRecheckCandidate: ((CleanupCandidate) -> Void)? = nil,
        onTrashWorktree: ((WorktreeRecord) -> Void)? = nil,
        onRestoreTrashedItem: ((TrashedItemRecord) -> Void)? = nil,
        onTrashAllEligible: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.report = report
        self.recheckingCandidateIDs = recheckingCandidateIDs
        self.trashedHistory = trashedHistory
        self.onTrashCandidate = onTrashCandidate
        self.onRecheckCandidate = onRecheckCandidate
        self.onTrashWorktree = onTrashWorktree
        self.onRestoreTrashedItem = onRestoreTrashedItem
        self.onTrashAllEligible = onTrashAllEligible
        self.onDismiss = onDismiss
    }

    private var allCandidates: [CleanupCandidate] {
        (report.candidates + report.agentCacheCandidates).sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.path < $1.path
        }
    }

    private var eligibleCandidates: [CleanupCandidate] {
        allCandidates.filter { candidate in
            report.assessments[candidate.id]?.isReviewableForTrash == true
        }
    }

    private var blockedCandidates: [CleanupCandidate] {
        allCandidates.filter { candidate in
            report.assessments[candidate.id]?.isReviewableForTrash != true
        }
    }

    private var totalEligibleLogicalBytes: Int64 {
        eligibleCandidates.reduce(0) { $0 + $1.bytes }
    }

    private var totalEligibleAllocatedBytes: Int64? {
        let values = eligibleCandidates.compactMap(\.allocatedBytes)
        return values.count == eligibleCandidates.count && !values.isEmpty ? values.reduce(0, +) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Cleanup Safety Preview", systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(leafGreen)
                Spacer()
                if !eligibleCandidates.isEmpty, let onTrashAllEligible {
                    Button {
                        onTrashAllEligible()
                        onDismiss()
                    } label: {
                        Label("Move \(eligibleCandidates.count) to Trash (\(bytes(totalEligibleLogicalBytes)))", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Button("Done") { onDismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                metricPill("Reviewable", value: "\(eligibleCandidates.count)", detail: bytes(totalEligibleLogicalBytes) + " logical")
                if let allocated = totalEligibleAllocatedBytes {
                    metricPill("Allocated", value: bytes(allocated), detail: "APFS blocks")
                }
                metricPill("Protected", value: "\(blockedCandidates.count)", detail: "Kept safe")
            }

            Divider().opacity(0.6)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !eligibleCandidates.isEmpty {
                        sectionHeader("Ready for macOS Trash (\(eligibleCandidates.count))")
                        ForEach(eligibleCandidates, id: \.id) { candidate in
                            candidateCard(candidate, blocked: false)
                        }
                    }

                    if !blockedCandidates.isEmpty {
                        sectionHeader("Protected Candidates (\(blockedCandidates.count))")
                        ForEach(blockedCandidates, id: \.id) { candidate in
                            candidateCard(candidate, blocked: true)
                        }
                    }

                    if !report.worktrees.isEmpty {
                        sectionHeader("Git Worktrees (\(report.worktrees.count))")
                        ForEach(report.worktrees, id: \.path) { wt in
                            worktreeCard(wt)
                        }
                    }

                    if !trashedHistory.isEmpty {
                        sectionHeader("Recently Moved to Trash (\(trashedHistory.count))")
                        ForEach(trashedHistory) { item in
                            trashedItemCard(item)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().opacity(0.6)

            HStack(spacing: 6) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(leafGreen)
                Text("Items are moved to macOS Trash after re-verifying inode/device identity and non-symlink path.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 440, height: 470)
    }

    private func metricPill(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13.5, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    private func candidateCard(_ candidate: CleanupCandidate, blocked: Bool) -> some View {
        let assessment = report.assessments[candidate.id]
        let diagnostic = assessment.map { SafetyDiagnostics.explain(assessment: $0, candidate: candidate) }
        let isRechecking = recheckingCandidateIDs.contains(candidate.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(candidate.agentName.map { "\($0) · \(candidate.category)" } ?? candidate.category)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(candidate.partial ? "≥ " : "")\(bytes(candidate.bytes))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                Text(displayPath(candidate.path))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.path)])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(leafGreen)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                if blocked, diagnostic?.canRecheck == true, let onRecheckCandidate {
                    Button {
                        onRecheckCandidate(candidate)
                    } label: {
                        HStack(spacing: 3) {
                            if isRechecking {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 9.5, weight: .semibold))
                            }
                            Text("Recheck")
                                .font(.system(size: 9.5, weight: .medium))
                        }
                        .foregroundStyle(leafGreen)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRechecking)
                    .help(diagnostic?.remediationHint ?? "Recheck safety for this item")
                }

                if !blocked, let onTrashCandidate {
                    Button {
                        onTrashCandidate(candidate)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Move to Trash")
                }
            }

            if blocked, let diagnostic {
                Text("\(diagnostic.headline) (\(diagnostic.checkName)) — \(diagnostic.remediationHint)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let reasons = assessment?.blockedReasons, !reasons.isEmpty {
                Text(reasons.joined(separator: " · "))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let assessment {
                Text(regenerabilityText(assessment.regenerability))
                    .font(.system(size: 9))
                    .foregroundStyle(leafGreen)
            }
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func worktreeCard(_ wt: WorktreeRecord) -> some View {
        let isEligible = !wt.isMain && wt.blockedReasons.isEmpty && wt.isMergedToDefault == true && !wt.isDirty && !wt.isLocked && wt.usage == .clear
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(wt.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? wt.headCommit ?? "Detached worktree")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer()
                Text(isEligible ? "Clean & merged" : "Protected")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isEligible ? leafGreen : .secondary)
            }
            HStack(spacing: 8) {
                Text(displayPath(wt.path))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wt.path)])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(leafGreen)
                }
                .buttonStyle(.plain)
                .help("Reveal worktree in Finder")

                if isEligible, let onTrashWorktree {
                    Button {
                        onTrashWorktree(wt)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                            Text("Trash")
                                .font(.system(size: 9.5, weight: .medium))
                        }
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Move clean, merged secondary worktree to macOS Trash")
                }
            }
            if !wt.blockedReasons.isEmpty {
                Text(wt.blockedReasons.joined(separator: " · "))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func trashedItemCard(_ item: TrashedItemRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.category)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if item.bytes > 0 {
                    Text(bytes(item.bytes))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let onRestoreTrashedItem {
                    Button {
                        onRestoreTrashedItem(item)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .font(.system(size: 10.5))
                            Text("Put Back")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .foregroundStyle(leafGreen)
                    }
                    .buttonStyle(.plain)
                    .help("Restore \(displayPath(item.originalPath)) from macOS Trash")
                }
            }
            Text(displayPath(item.originalPath))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func regenerabilityText(_ reg: Regenerability) -> String {
        switch reg {
        case .lockfileVerified(let lock): return "Reproducible (\(lock))"
        case .cacheDirectory: return "Regenerable cache"
        case .unverified(let reason): return "Unverified (\(reason))"
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
