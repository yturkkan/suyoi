import AppKit
import SwiftUI
import SuyoiCore

struct DeepStorageView: View {
    @ObservedObject var model: DashboardModel

    private var accent: Color {
        ThemeStyling.accentColor(for: model.experienceTheme)
    }

    private func categoryTint(_ category: StorageCategory) -> Color {
        switch category {
        case .xcodeAndSimulators: return Color(nsColor: .systemBlue)
        case .dependencies: return Color(nsColor: .systemOrange)
        case .buildOutputs: return Color(nsColor: .systemPurple)
        case .pythonAndEnvs: return Color(nsColor: .systemTeal)
        case .toolchainCaches: return Color(nsColor: .systemIndigo)
        case .aiAgentStorage: return Color(nsColor: .systemPink)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                heroSummaryCard
                filterAndBatchBar
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider().opacity(0.6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if !model.trashedHistory.isEmpty {
                        trashedRecoveryCard
                    }

                    if !model.staleSessionLogs.isEmpty {
                        staleLogsBanner
                    }

                    let items = model.filteredStorageItems
                    if items.isEmpty {
                        emptyStorageState
                    } else {
                        ForEach(items) { item in
                            let rowID = "deep-storage-\(item.id)"
                            DeepStorageItemRow(
                                item: item,
                                categoryTint: categoryTint(item.category),
                                accent: accent,
                                theme: model.experienceTheme,
                                isSelected: model.isStorageItemSelected(item),
                                isPerformingAction: model.isPerformingAction,
                                isHovered: model.hoveredRowID == rowID,
                                onHover: { hovering in
                                    model.hoveredRowID = hovering ? rowID : (model.hoveredRowID == rowID ? nil : model.hoveredRowID)
                                },
                                onToggleSelect: { model.toggleStorageItemSelection(item) },
                                onTrash: { model.trashStorageItem(item) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Hero Summary + Live Progress + Proportional Category Bar

    private var heroSummaryCard: some View {
        let report = model.storageReport
        let totalBytes = report?.totalBytes ?? model.storageProgress.totalBytes
        let readyBytes = report?.readyBytes ?? model.storageProgress.readyBytes
        let cleanableBytes = report?.cleanableBytes ?? readyBytes
        let itemCount = report?.items.count ?? model.storageProgress.discoveredCount
        let dirCount = report?.scannedDirectories ?? model.storageProgress.scannedDirectories

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(formatBytes(cleanableBytes)) Cleanable")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                            .monospacedDigit()

                        Text("· \(formatBytes(readyBytes)) recommended ready · \(formatBytes(totalBytes)) total (\(itemCount) items)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }

                    workspaceRootsSubtitle(dirCount: dirCount, indexedAt: report?.indexedAt)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Button {
                        model.addCustomStorageRoot()
                    } label: {
                        Label("Add Folder", systemImage: "folder.badge.plus")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Add a developer folder or monorepo root to the deep storage index")

                    if model.storageProgress.isIndexing {
                        Button {
                            model.cancelDeepStorageScan()
                        } label: {
                            Label("Stop", systemImage: "xmark.circle")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button {
                            model.startDeepStorageScan(force: true)
                        } label: {
                            Label("Rescan", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(accent)
                    }
                }
            }

            if model.storageProgress.isIndexing {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: max(0.03, model.storageProgress.fractionCompleted))
                        .tint(accent)
                        .controlSize(.small)

                    HStack(spacing: 6) {
                        Text(model.storageProgress.phase)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent)

                        if !model.storageProgress.currentPath.isEmpty {
                            Text("· \(shortenHomePath(model.storageProgress.currentPath))")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Text("\(model.storageProgress.scannedDirectories.formatted()) dirs · \(model.storageProgress.discoveredCount) found · \(formatBytes(model.storageProgress.totalBytes))")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            if let report, report.totalBytes > 0 {
                proportionalCategoryBar(report: report)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    categoryChip(nil, title: "All", bytes: totalBytes)
                    ForEach(StorageCategory.allCases, id: \.self) { category in
                        let catBytes = report?.bytes(for: category) ?? 0
                        if catBytes > 0 || model.selectedStorageCategory == category {
                            categoryChip(category, title: category.shortTitle, bytes: catBytes)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .themedSurfaceCard(theme: model.experienceTheme, isHovered: false)
    }

    private func workspaceRootsSubtitle(dirCount: Int, indexedAt: Date?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            let rootsText = model.scannedWorkspaceRoots.isEmpty
                ? shortenHomePath(model.cleanupRoot.path)
                : model.scannedWorkspaceRoots.prefix(4).map { shortenHomePath($0.path) }.joined(separator: ", ")
                    + (model.scannedWorkspaceRoots.count > 4 ? " +\(model.scannedWorkspaceRoots.count - 4)" : "")

            Text("Roots: \(rootsText) + Xcode, toolchains & AI caches")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if dirCount > 0 {
                Text("· \(dirCount.formatted()) dirs")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if !model.customStorageRoots.isEmpty {
                ForEach(model.customStorageRoots, id: \.path) { customURL in
                    HStack(spacing: 3) {
                        Text(customURL.lastPathComponent)
                            .font(.system(size: 10, weight: .semibold))
                        Button {
                            model.removeCustomStorageRoot(customURL)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help("Remove custom scan root \(customURL.path)")
                    }
                    .foregroundStyle(accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(accent.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    private func proportionalCategoryBar(report: StorageIndexReport) -> some View {
        let total = max(1, Double(report.totalBytes))
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(StorageCategory.allCases, id: \.self) { category in
                    let bytes = report.bytes(for: category)
                    if bytes > 0 {
                        let width = max(6, CGFloat(Double(bytes) / total) * (geo.size.width - 10))
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(categoryTint(category))
                            .opacity(model.selectedStorageCategory == nil || model.selectedStorageCategory == category ? 0.92 : 0.28)
                            .frame(width: width, height: 8)
                            .help("\(category.rawValue): \(formatBytes(bytes))")
                            .onTapGesture {
                                model.selectedStorageCategory = (model.selectedStorageCategory == category) ? nil : category
                            }
                    }
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }

    private func categoryChip(_ category: StorageCategory?, title: String, bytes: Int64) -> some View {
        let selected = model.selectedStorageCategory == category
        let tint = category.map(categoryTint) ?? accent
        return Button {
            model.selectedStorageCategory = category
        } label: {
            HStack(spacing: 4.5) {
                if let category {
                    Circle()
                        .fill(tint)
                        .frame(width: 6.5, height: 6.5)
                }
                Text(title)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                if bytes > 0 {
                    Text(formatBytes(bytes))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .opacity(0.8)
                }
            }
            .foregroundStyle(selected ? tint : .secondary)
            .padding(.horizontal, 8.5)
            .padding(.vertical, 3.5)
            .background(
                selected ? tint.opacity(0.15) : Color.primary.opacity(0.05),
                in: Capsule()
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Age Filter + Sort + Batch Clean Action Bar

    private var filterAndBatchBar: some View {
        let recommended = model.recommendedStorageItems
        let recommendedBytes = recommended.reduce(Int64(0)) { $0 + $1.bytes }
        let selectedItems = model.selectedStorageItems
        let allRecommendedSelected = !recommended.isEmpty && recommended.allSatisfy { model.isStorageItemSelected($0) }

        return HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(StorageAgeFilter.allCases, id: \.self) { age in
                    let active = model.storageAgeFilter == age
                    Button {
                        model.storageAgeFilter = age
                    } label: {
                        Text(age.rawValue)
                            .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                            .foregroundStyle(active ? accent : .secondary)
                            .padding(.horizontal, 7.5)
                            .padding(.vertical, 3)
                            .background(active ? accent.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            Menu {
                ForEach(StorageSortOrder.allCases, id: \.self) { order in
                    Button {
                        model.storageSortOrder = order
                    } label: {
                        if model.storageSortOrder == order {
                            Label("Sort: \(order.rawValue)", systemImage: "checkmark")
                        } else {
                            Text("Sort: \(order.rawValue)")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10))
                    Text(model.storageSortOrder.rawValue)
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if !recommended.isEmpty {
                Button {
                    model.toggleSelectRecommendedStorageItems()
                } label: {
                    Text(allRecommendedSelected ? "Deselect Ready" : "Select Ready (\(recommended.count))")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !selectedItems.isEmpty {
                Button {
                    model.trashSelectedStorageItems()
                } label: {
                    Label(
                        "Move \(selectedItems.count) to Trash (\(formatBytes(model.selectedStorageBytes)))",
                        systemImage: "trash.fill"
                    )
                    .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color(nsColor: .systemRed))
                .disabled(model.isPerformingAction)
            } else if !recommended.isEmpty {
                Button {
                    model.toggleSelectRecommendedStorageItems()
                    model.trashSelectedStorageItems()
                } label: {
                    Label("Clean Ready (\(formatBytes(recommendedBytes)))", systemImage: "trash")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(accent)
                .disabled(model.isPerformingAction)
                .help("Move all recommended Ready build & cache folders in the current view to macOS Trash (with Put Back recovery)")
            }
        }
    }

    // MARK: - Trash Recovery & Stale Logs Strips

    private var trashedRecoveryCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Recently Moved to Trash (\(model.trashedHistory.count)) — Put Back Recovery", systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(accent)
                Spacer()
            }
            ForEach(model.trashedHistory.prefix(3)) { item in
                let restorable = model.canRestoreTrashedItem(item)
                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: item.originalPath).lastPathComponent)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    Text("· \(item.category) · \(formatBytes(item.bytes))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("· \(shortenHomePath(item.originalPath))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        model.restoreTrashedItem(item)
                    } label: {
                        Label("Put Back", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(model.isPerformingAction || !restorable)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedSurfaceCard(theme: model.experienceTheme, isHovered: false)
    }

    private var staleLogsBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemOrange))
            VStack(alignment: .leading, spacing: 1.5) {
                Text("\(model.staleSessionLogs.count) aged agent session log\(model.staleSessionLogs.count == 1 ? "" : "s") (>\(model.sessionLogRetentionDays)d · \(formatBytes(model.totalStaleSessionLogBytes)))")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("Inactive JSONL transcripts safe to move to macOS Trash.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.trashAllStaleSessionLogs()
            } label: {
                Label("Trash Aged Logs", systemImage: "trash")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isPerformingAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedSurfaceCard(theme: model.experienceTheme, isHovered: false)
    }

    private var emptyStorageState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: model.storageProgress.isIndexing ? "magnifyingglass.circle.fill" : "externaldrive.badge.checkmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                Text(
                    model.storageProgress.isIndexing
                        ? "Indexing developer workspaces & caches…"
                        : "No matching storage artifacts in this filter"
                )
                .font(.system(size: 13, weight: .semibold))
            }
            Text(
                model.storageProgress.isIndexing
                    ? "Measuring monorepos, node_modules, Xcode DerivedData, Rust targets, Swift .build directories, Python virtual environments, and AI caches."
                    : "Adjust the category/age filter above, or click Add Folder to include another workspace directory."
            )
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedSurfaceCard(theme: model.experienceTheme, isHovered: false)
    }
}

// MARK: - Deep Storage Item Row

private struct DeepStorageItemRow: View {
    let item: IndexedStorageItem
    let categoryTint: Color
    let accent: Color
    let theme: SuyoiExperienceTheme
    let isSelected: Bool
    let isPerformingAction: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onToggleSelect: () -> Void
    let onTrash: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if item.safety.isCleanable {
                Button(action: onToggleSelect) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(isSelected ? accent : .secondary)
                }
                .buttonStyle(.plain)
                .help(isSelected ? "Deselect" : "Select for batch Trash")
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .help("Currently in use by a running process")
            }

            Image(systemName: item.category.symbolName)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(categoryTint)
                .frame(width: 26, height: 26)
                .background(categoryTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    statusBadge(item.ecosystemLabel, tint: categoryTint)

                    safetyPill

                    if let age = item.ageDays(), age >= 1 {
                        Text("\(age)d old")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                HStack(spacing: 6) {
                    Text(shortenHomePath(item.path))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.path)

                    if item.fileCount > 0 {
                        Text("· \(item.fileCount.formatted()) files")
                            .font(.system(size: 10.5, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(formatBytes(item.bytes))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: true, vertical: false)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                if item.safety.isCleanable {
                    Button(action: onTrash) {
                        HStack(spacing: 3.5) {
                            Image(systemName: "trash")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Trash")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Color.red.opacity(0.11), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isPerformingAction)
                    .help("Move \(item.displayName) safely to macOS Trash")
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8.5)
        .themedSurfaceCard(theme: theme, isHovered: isHovered || isSelected)
        .overlay(
            RoundedRectangle(cornerRadius: ThemeStyling.cardCornerRadius(for: theme), style: .continuous)
                .strokeBorder(isSelected ? accent.opacity(0.8) : Color.clear, lineWidth: isSelected ? 1.2 : 0)
        )
        .onHover(perform: onHover)
    }

    @ViewBuilder
    private var safetyPill: some View {
        switch item.safety {
        case .ready:
            statusBadge("Ready", tint: Color(nsColor: .systemGreen))
                .help("Safe to clean — regenerable artifact with no active process locks")
        case .highImpactReview(let reason):
            statusBadge("Review", tint: Color(nsColor: .systemOrange))
                .help(reason)
        case .inUse(let proc):
            statusBadge("In Use · \(proc)", tint: .secondary)
                .help("Active process (\(proc)) is running in this workspace")
        }
    }
}
