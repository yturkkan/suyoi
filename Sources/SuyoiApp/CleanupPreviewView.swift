import AppKit
import SwiftUI
import SuyoiCore

struct CleanupPreviewView: View {
    let report: CleanupReport
    var theme: SuyoiExperienceTheme = .nativeGlass
    let recheckingCandidateIDs: Set<String>
    let trashedHistory: [TrashedItemRecord]
    let canRestoreItem: ((TrashedItemRecord) -> Bool)?
    let onTrashCandidate: ((CleanupCandidate) -> Void)?
    let onRecheckCandidate: ((CleanupCandidate) -> Void)?
    let onTrashWorktree: ((WorktreeRecord) -> Void)?
    let onRestoreTrashedItem: ((TrashedItemRecord) -> Void)?
    let onTrashAllEligible: (() -> Void)?
    let onDismiss: () -> Void

    private var accent: Color {
        ThemeStyling.accentColor(for: theme)
    }

    init(
        report: CleanupReport,
        theme: SuyoiExperienceTheme = .nativeGlass,
        recheckingCandidateIDs: Set<String> = [],
        trashedHistory: [TrashedItemRecord] = [],
        canRestoreItem: ((TrashedItemRecord) -> Bool)? = nil,
        onTrashCandidate: ((CleanupCandidate) -> Void)? = nil,
        onRecheckCandidate: ((CleanupCandidate) -> Void)? = nil,
        onTrashWorktree: ((WorktreeRecord) -> Void)? = nil,
        onRestoreTrashedItem: ((TrashedItemRecord) -> Void)? = nil,
        onTrashAllEligible: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.report = report
        self.theme = theme
        self.recheckingCandidateIDs = recheckingCandidateIDs
        self.trashedHistory = trashedHistory
        self.canRestoreItem = canRestoreItem
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
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(accent)
                Spacer()
                if !eligibleCandidates.isEmpty, let onTrashAllEligible {
                    Button {
                        onTrashAllEligible()
                        onDismiss()
                    } label: {
                        Label("Move \(eligibleCandidates.count) to Trash (\(bytes(totalEligibleLogicalBytes)))", systemImage: "trash")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(accent)
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
                    .font(.system(size: 12))
                    .foregroundStyle(accent)
                Text("Items are moved to macOS Trash after re-verifying inode/device identity and non-symlink path.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 560, height: 500)
    }

    private func metricPill(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
            Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedSurfaceCard(theme: theme, isHovered: false)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }

    private func candidateCard(_ candidate: CleanupCandidate, blocked: Bool) -> some View {
        let assessment = report.assessments[candidate.id]
        let diagnostic = assessment.map { SafetyDiagnostics.explain(assessment: $0, candidate: candidate) }
        let isRechecking = recheckingCandidateIDs.contains(candidate.id)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(candidate.agentName.map { "\($0) · \(candidate.category)" } ?? candidate.category)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("\(candidate.partial ? "≥ " : "")\(bytes(candidate.bytes))")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                Text(displayPath(candidate.path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(candidate.path)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.path)])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11.5))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                if blocked, diagnostic?.canRecheck == true, let onRecheckCandidate {
                    Button {
                        onRecheckCandidate(candidate)
                    } label: {
                        HStack(spacing: 4) {
                            if isRechecking {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            Text("Recheck")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRechecking)
                    .help(diagnostic?.remediationHint ?? "Recheck safety for this item")
                }

                if !blocked, let onTrashCandidate {
                    Button {
                        onTrashCandidate(candidate)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 10.5))
                            Text("Trash")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Move to Trash")
                }
            }

            if blocked, let diagnostic {
                Text(diagnostic.headline)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(diagnostic.remediationHint)
            } else if let reasons = assessment?.blockedReasons, !reasons.isEmpty {
                Text(reasons.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let assessment {
                Text(regenerabilityText(assessment.regenerability))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent)
            }
        }
        .padding(10)
        .themedSurfaceCard(theme: theme, isHovered: false)
    }

    private func worktreeCard(_ wt: WorktreeRecord) -> some View {
        let isEligible = !wt.isMain && wt.blockedReasons.isEmpty && wt.isMergedToDefault == true && !wt.isDirty && !wt.isLocked && wt.usage == .clear
        let branchTitle = wt.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? wt.headCommit ?? "Detached worktree"
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(isEligible ? accent : .secondary)
                    Text(branchTitle)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    if wt.isMain {
                        Text("Primary")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
                Spacer()
                Text(isEligible ? "Clean & merged" : "Protected")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isEligible ? accent : .secondary)
            }

            HStack(spacing: 8) {
                Text(displayPath(wt.path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(wt.path)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wt.path)])
                } label: {
                    Label("Finder", systemImage: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .help("Reveal \(wt.path) in Finder")

                if isEligible, let onTrashWorktree {
                    Button {
                        onTrashWorktree(wt)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 10.5))
                            Text("Trash")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Move clean, merged secondary worktree to macOS Trash")
                }
            }

            if !wt.blockedReasons.isEmpty {
                Text(wt.blockedReasons.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(wt.blockedReasons.joined(separator: "\n"))
            }
        }
        .padding(10)
        .themedSurfaceCard(theme: theme, isHovered: false)
    }

    private func trashedItemCard(_ item: TrashedItemRecord) -> some View {
        let restorable = canRestoreItem?(item) ?? (item.fileIdentity != nil)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.category)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if item.bytes > 0 {
                    Text(bytes(item.bytes))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let onRestoreTrashedItem {
                    Button {
                        onRestoreTrashedItem(item)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: restorable ? "arrow.uturn.backward.circle.fill" : "exclamationmark.circle")
                                .font(.system(size: 11))
                            Text(restorable ? "Put Back" : "Unavailable")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(restorable ? accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!restorable)
                    .help(
                        restorable
                            ? "Restore \(displayPath(item.originalPath)) from macOS Trash"
                            : "Put Back unavailable: original and trashed item identity evidence was not captured"
                    )
                }
            }
            Text(displayPath(item.originalPath))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.originalPath)
            if !restorable {
                Text("Put Back requires verified file identity evidence captured when moved to Trash.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .themedSurfaceCard(theme: theme, isHovered: false)
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
