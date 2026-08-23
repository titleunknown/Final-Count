//
//  ContentView.swift
//  Final Count
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Root

struct ContentView: View {
    @StateObject private var store = FolderStore()
    @State private var columnWidths: [UUID: CGFloat] = [:]  // only set once user drags
    @State private var viewWidth: CGFloat = 900
    @State private var showExportSuccess = false
    @State private var showAbout = false
    @State private var showFileTypeCounts = false
    // Expansion and scanned children live here, not in each ColumnView, so every
    // column expands in lockstep and a nested folder can be compared across
    // columns the same way top-level rows are. Keyed by path relative to the
    // column root, so the key is stable across columns and across a re-scan.
    @State private var expandedRelPaths: Set<String> = []
    @State private var childCache: [ChildCacheKey: [SubfolderInfo]] = [:]

    private var columns: [FolderColumn] { store.columns }

    // Fixed narrow strip for the add-folder button (~8% of a typical window)
    private let addButtonWidth: CGFloat = 120
    // Hard minimum a column can be dragged to
    private let minColWidth: CGFloat = 300

    /// Width for a column that the user hasn't explicitly resized — splits available space equally.
    private func defaultColWidth() -> CGFloat {
        let dividerSpace = CGFloat(columns.count) * 8
        let available = viewWidth - addButtonWidth - dividerSpace
        return max(minColWidth, available / max(1, CGFloat(columns.count)))
    }

    /// Overall verdict shown in the status bar. `.notReady` while there's fewer
    /// than two folders, or any is still scanning or failed to load — comparing
    /// then would be meaningless or would falsely flag everything.
    private enum OverallStatus: Equatable {
        case notReady
        case identical
        case differences(Int)
    }

    private var overallStatus: OverallStatus {
        let ready = columns.count > 1
            && columns.allSatisfy { $0.url != nil && !$0.isLoading && $0.loadError == nil }
        guard ready else { return .notReady }
        let mismatchCount = allSubfolderNames(in: columns)
            .filter { statusFor(name: $0, in: columns) != .match }
            .count
        return mismatchCount == 0 ? .identical : .differences(mismatchCount)
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch overallStatus {
        case .notReady:
            EmptyView()
        case .identical:
            StatusBanner(
                icon: "checkmark.seal.fill",
                tint: .green,
                title: "All folders are identical",
                subtitle: "Every subfolder matches on file count and size."
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .differences(let n):
            StatusBanner(
                icon: "exclamationmark.triangle.fill",
                tint: .red,
                title: "\(n) difference\(n == 1 ? "" : "s") found",
                subtitle: "Highlighted subfolders differ or are missing."
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(columns) { col in
                        ColumnView(
                            column: col,
                            allColumns: columns,
                            width: columnWidth(for: col),
                            showFileTypeCounts: showFileTypeCounts,
                            expandedRelPaths: $expandedRelPaths,
                            childCache: $childCache,
                            onRemove: { remove(col) }
                        )
                        ResizeDivider { delta in
                            let current = columnWidth(for: col)
                            columnWidths[col.id] = max(minColWidth, current + delta)
                        }
                    }
                    AddColumnButton(action: addColumn, onDropURL: addColumn(url:))
                        .frame(width: addButtonWidth)
                }
                .frame(minWidth: viewWidth, minHeight: 560, alignment: .leading)
            }
            // Capture window width so defaultColWidth() stays in sync with window resizing
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { viewWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newValue in viewWidth = newValue }
                }
            )
            // This ScrollView is the ONE flexible region: it soaks up all vertical
            // slack and yields to whatever fixed chrome sits below it (the status
            // banner and toolbar). Without this, the ScrollView reports a firm ideal
            // height and any chrome added beneath it overflows the window, clipping
            // the toolbar. Keep this here — it's what lets new chrome coexist safely.
            .frame(maxHeight: .infinity)

            statusBanner

            Divider()
            HStack {
                Button(action: refreshAll) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Re-scan all folders")

                Toggle("File Type Counts", isOn: $showFileTypeCounts)
                    .toggleStyle(.checkbox)
                    .help("Show a breakdown by file extension for loose files")
                    .padding(.leading, 12)

                Spacer()

                Button(action: exportReport) {
                    Label("Export Report", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Button(action: { showAbout = true }) {
                    Label("About", systemImage: "info.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        // minHeight leaves room for the columns (~560) plus the fixed chrome below
        // them (status banner + toolbar) so nothing is clipped at the smallest size.
        .frame(minWidth: 920, minHeight: 700)
        .animation(.easeInOut(duration: 0.2), value: overallStatus)
        // Pointing a column at a different folder invalidates the whole tree.
        .onChange(of: columns.map { $0.url?.path ?? "-" }.joined(separator: "|")) { _, _ in
            expandedRelPaths.removeAll()
            childCache.removeAll()
        }
        // A re-scan (Refresh) keeps the tree open but drops the stale children,
        // which the expanded rows then reload.
        .onChange(of: columns.map(\.reloadCount).reduce(0, +)) { _, _ in
            childCache.removeAll()
        }
        .sheet(isPresented: $showAbout) { AboutView() }
        .task {
            store.setInitial(count: 2)
        }
        .overlay(alignment: .bottom) {
            if showExportSuccess {
                Text("Report saved")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 50)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func columnWidth(for col: FolderColumn) -> CGFloat {
        columnWidths[col.id] ?? defaultColWidth()
    }

    @MainActor private func refreshAll() {
        for col in columns {
            if let url = col.url { col.load(from: url) }
        }
    }

    @MainActor private func addColumn() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        if panel.runModal() == .OK, let url = panel.url {
            addColumn(url: url)
        }
    }

    @MainActor private func addColumn(url: URL) {
        let col = FolderColumn()
        col.load(from: url)
        // New column starts at the current default (no explicit entry),
        // so it shares space equally with the others until dragged.
        store.add(col)
    }

    private func remove(_ col: FolderColumn) {
        columnWidths.removeValue(forKey: col.id)
        childCache = childCache.filter { $0.key.column != col.id }
        store.remove(id: col.id)
    }

    @MainActor private func exportReport() {
        let text = buildReport(columns: columns)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "FinalCount-Report.txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            withAnimation { showExportSuccess = true }
            Task {
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run { withAnimation { showExportSuccess = false } }
            }
        }
    }
}

// MARK: - Status Banner

/// The big at-a-glance verdict bar above the toolbar — readable across the room
/// so you can confirm a backup matches without leaning into the numbers.
struct StatusBanner: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(tint)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.14))
    }
}

// MARK: - Resize Divider

struct ResizeDivider: View {
    let onResize: (CGFloat) -> Void
    @State private var prevTranslation: CGFloat = 0
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(isHovered ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.15))
                .frame(width: 3, height: isHovered ? 44 : 26)
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let delta = value.translation.width - prevTranslation
                    prevTranslation = value.translation.width
                    onResize(delta)
                }
                .onEnded { _ in prevTranslation = 0 }
        )
        .help("Drag to resize column")
    }
}

// MARK: - Column

struct ColumnView: View {
    @ObservedObject var column: FolderColumn
    let allColumns: [FolderColumn]
    let width: CGFloat
    let showFileTypeCounts: Bool
    @Binding var expandedRelPaths: Set<String>
    @Binding var childCache: [ChildCacheKey: [SubfolderInfo]]
    let onRemove: () -> Void

    @State private var isTargeted = false
    @State private var expandedTypeIDs: Set<UUID> = []

    // Fixed widths for numeric columns
    private let subW: CGFloat = 60
    private let fileW: CGFloat = 72
    private let sizeW: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if column.isLoading {
                Spacer()
                ProgressView().padding()
                Spacer()
            } else if column.url == nil {
                dropPrompt
            } else if let error = column.loadError {
                accessErrorPrompt(error)
            } else {
                subfolderList
                Divider()
                totalsRow
            }
        }
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.10),
                    lineWidth: 1
                )
        )
        .padding(.horizontal, 5)
        .padding(.vertical, 8)
        .frame(width: width)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted, perform: handleDrop)
        .onChange(of: column.url) { _, _ in
            expandedTypeIDs.removeAll()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                if let url = column.url {
                    Text(url.lastPathComponent)
                        .font(.title2).fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button(action: chooseDifferentFolder) {
                        Text(shortenedPath(url.path))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("Click to change folder")
                    .contextMenu {
                        Button("Reveal in Finder") { column.revealInFinder() }
                        Button("Change Folder…") { chooseDifferentFolder() }
                    }
                } else {
                    Text("Drop a Folder")
                        .font(.title2).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Text(" ")
                        .font(.caption)
                }
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove column")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(height: 68)
        .background(Color.primary.opacity(0.06))
    }

    // MARK: Drop prompt

    private var dropPrompt: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "arrow.down.to.line")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Drop folder here\nor click to browse")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.tertiary)
            Button("Browse…", action: chooseDifferentFolder)
                .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: Access error

    private func accessErrorPrompt(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Browse…", action: chooseDifferentFolder)
                .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
    }

    // MARK: Subfolder list

    private var subfolderList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Column headers
                HStack(spacing: 0) {
                    // indent space for indicator + chevron
                    Spacer().frame(width: 42)
                    Text("Subfolder")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text("Subdirs")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: subW, alignment: .trailing)
                    Text("Files")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: fileW, alignment: .trailing)
                    Text("Size")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: sizeW, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

                Divider()

                ForEach(column.subfolders) { sub in
                    ExpandableSubfolderRow(
                        column: column,
                        allColumns: allColumns,
                        relPath: sub.name,
                        name: sub.name,
                        info: sub,
                        depth: 0,
                        status: statusFor(name: sub.name, in: allColumns),
                        statusDetail: statusDetail(name: sub.name, in: allColumns),
                        // Comparing against a column that is still scanning (url set,
                        // subfolders not yet populated) would flag every row as missing.
                        showStatus: allColumns.count > 1 && allColumns.allSatisfy({ $0.url != nil && !$0.isLoading }),
                        subW: subW, fileW: fileW, sizeW: sizeW,
                        expandedRelPaths: $expandedRelPaths,
                        childCache: $childCache,
                        showFileTypeCounts: showFileTypeCounts,
                        expandedTypeIDs: $expandedTypeIDs
                    )
                    Divider().padding(.leading, 14)
                }
            }
        }
    }

    // MARK: Totals

    private var totalsRow: some View {
        let totalSubdirs = column.subfolders.reduce(0) { $0 + $1.subfolderCount }
        let folderCount = column.subfolders.filter { !$0.isLooseFilesRow }.count
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(folderCount) subfolder\(folderCount == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                Text("Total")
                    .font(.headline).fontWeight(.bold)
                Spacer(minLength: 6)
                Text(totalSubdirs > 0 ? totalSubdirs.formatted() : "—")
                    .font(.headline).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: subW, alignment: .trailing)
                Text(column.totalFiles.formatted())
                    .font(.headline).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: fileW, alignment: .trailing)
                Text(ByteCountFormatter.string(fromByteCount: column.totalBytes, countStyle: .file))
                    .font(.headline).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: sizeW, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 68)
        .background(Color.primary.opacity(0.06))
    }

    // MARK: Helpers

    private func chooseDifferentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        if panel.runModal() == .OK, let url = panel.url {
            column.load(from: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in column.load(from: url) }
        }
        return true
    }

    private func shortenedPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Expandable Subfolder Row

struct ExpandableSubfolderRow: View {
    let column: FolderColumn
    let allColumns: [FolderColumn]
    /// This folder's path relative to its column root ("Capture/LOOK_7185").
    let relPath: String
    let name: String
    let info: SubfolderInfo?
    let depth: Int
    let status: MatchStatus
    var statusDetail: String? = nil
    let showStatus: Bool
    let subW: CGFloat
    let fileW: CGFloat
    let sizeW: CGFloat
    @Binding var expandedRelPaths: Set<String>
    @Binding var childCache: [ChildCacheKey: [SubfolderInfo]]
    var showFileTypeCounts: Bool = false
    @Binding var expandedTypeIDs: Set<UUID>

    private var isExpanded: Bool { expandedRelPaths.contains(relPath) }
    private var canExpand: Bool { (info?.subfolderCount ?? 0) > 0 }
    private var cacheKey: ChildCacheKey { ChildCacheKey(column: column.id, relPath: relPath) }
    private var loadedChildren: [SubfolderInfo]? { childCache[cacheKey] }

    /// Compares one child against the same child in every column, once all
    /// columns have scanned this folder. `nil` = not enough data yet, so the
    /// child row shows no verdict rather than a wrong one.
    @MainActor private func nestedStatus(_ child: SubfolderInfo) -> MatchStatus? {
        guard allColumns.count > 1,
              allColumns.allSatisfy({ $0.url != nil && !$0.isLoading }) else { return nil }
        let key = canonicalFolderName(child.name)
        var entries: [SubfolderInfo?] = []
        for col in allColumns {
            guard let kids = childCache[ChildCacheKey(column: col.id, relPath: relPath)] else { return nil }
            entries.append(kids.first(where: { canonicalFolderName($0.name) == key }))
        }
        return compareEntries(entries, columnCount: allColumns.count)
    }

    @MainActor private func nestedDetail(_ child: SubfolderInfo) -> String? {
        let key = canonicalFolderName(child.name)
        let entries = allColumns.map { col -> (path: String, info: SubfolderInfo?) in
            let kids = childCache[ChildCacheKey(column: col.id, relPath: relPath)]
            return ("\(col.path)/\(relPath)", kids?.first(where: { canonicalFolderName($0.name) == key }))
        }
        return compareDetail(entries, columnCount: allColumns.count)
    }
    private var canShowTypeCounts: Bool {
        showFileTypeCounts && info?.isLooseFilesRow == true && !(info?.typeCounts.isEmpty ?? true)
    }
    private var typeCountsExpanded: Bool { info.map { expandedTypeIDs.contains($0.id) } ?? false }
    // When the toggle is off, the click-to-expand rows aren't available — offer the
    // same breakdown as a hover tooltip instead so it's never entirely hidden.
    private var hoverTypeCountsTooltip: String? {
        guard !showFileTypeCounts, info?.isLooseFilesRow == true,
              let counts = info?.typeCounts, !counts.isEmpty else { return nil }
        return counts
            .map { "\($0.ext): \($0.formattedCount) (\($0.formattedSize))" }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let hoverTypeCountsTooltip {
                    rowContent.help(hoverTypeCountsTooltip)
                } else {
                    rowContent
                }
            }
            if canShowTypeCounts && typeCountsExpanded, let info {
                ForEach(info.typeCounts) { tc in
                    TypeCountRow(typeCount: tc, depth: depth, subW: subW, fileW: fileW, sizeW: sizeW)
                }
            }
            if isExpanded, let info {
                if let children = loadedChildren {
                    ForEach(children) { child in
                        let st = nestedStatus(child)
                        ExpandableSubfolderRow(
                            column: column,
                            allColumns: allColumns,
                            relPath: relPath + "/" + child.name,
                            name: child.name,
                            info: child,
                            depth: depth + 1,
                            status: st ?? .match,
                            statusDetail: st != nil ? nestedDetail(child) : nil,
                            showStatus: st != nil,
                            subW: subW, fileW: fileW, sizeW: sizeW,
                            expandedRelPaths: $expandedRelPaths,
                            childCache: $childCache,
                            showFileTypeCounts: showFileTypeCounts,
                            expandedTypeIDs: $expandedTypeIDs
                        )
                        Divider().padding(.leading, indentWidth + 14)
                    }
                } else {
                    HStack {
                        Spacer()
                        ProgressView().scaleEffect(0.7)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .task {
                        let url = info.url
                        let key = cacheKey
                        let loaded = await Task.detached(priority: .userInitiated) {
                            FolderColumn.loadChildren(at: url)
                        }.value
                        childCache[key] = loaded
                    }
                }
            }
        }
    }

    private var indentWidth: CGFloat { CGFloat(depth) * 18 }

    private var rowBackground: Color {
        guard showStatus else { return .clear }
        switch status {
        case .match: return .clear
        case .mismatch: return Color.orange.opacity(0.12)
        case .missing: return Color.red.opacity(0.10)
        }
    }

    private var rowContent: some View {
        HStack(spacing: 0) {
            // Depth indent
            if depth > 0 {
                Spacer().frame(width: indentWidth)
            }

            // Status indicator — shown at every depth so a flagged folder can be
            // opened to find exactly which nested folder differs.
            Group {
                if showStatus {
                    switch status {
                    case .match:
                        Spacer().frame(width: 20)
                    case .mismatch:
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                            .frame(width: 20)
                            .help(statusDetail ?? "Contents differ between columns")
                    case .missing:
                        Image(systemName: "minus.circle.fill")
                            .font(.caption2).foregroundStyle(.red)
                            .frame(width: 20)
                            .help(statusDetail ?? "Folder not found in every column")
                    }
                } else {
                    Spacer().frame(width: 20)
                }
            }

            // Expand chevron
            if canExpand {
                Button(action: toggleExpand) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 16)
            }

            // Name
            Text(name)
                .font(.callout)
                .italic(info?.isLooseFilesRow == true)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(info == nil ? Color.secondary : Color.primary)
                .padding(.leading, 4)

            if info?.hadReadError == true {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .padding(.leading, 4)
                    .help("Some items in this folder couldn't be read — its counts are a lower bound.")
            }

            Spacer(minLength: 6)

            // Subdirs count
            if let info {
                Text(info.formattedSubfolderCount)
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: subW, alignment: .trailing)
                // Files
                Group {
                    if canShowTypeCounts {
                        Button(action: toggleTypeCounts) {
                            HStack(spacing: 2) {
                                Text(info.formattedCount)
                                Image(systemName: typeCountsExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Click to \(typeCountsExpanded ? "hide" : "show") the breakdown by file type")
                    } else {
                        Text(info.formattedCount)
                    }
                }
                .font(.callout).monospacedDigit()
                .foregroundStyle(showStatus && status == .mismatch ? Color.orange : Color.primary)
                .frame(width: fileW, alignment: .trailing)
                // Size
                Text(info.formattedSize)
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(showStatus && status == .mismatch ? Color.orange : Color.primary)
                    .frame(width: sizeW, alignment: .trailing)
            } else {
                Text("—")
                    .font(.callout).foregroundStyle(.red.opacity(0.7))
                    .frame(width: subW + fileW + sizeW, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    private func toggleExpand() {
        if isExpanded {
            expandedRelPaths.remove(relPath)
        } else {
            expandedRelPaths.insert(relPath)
        }
    }

    private func toggleTypeCounts() {
        guard let info else { return }
        if typeCountsExpanded {
            expandedTypeIDs.remove(info.id)
        } else {
            expandedTypeIDs.insert(info.id)
        }
    }
}

// MARK: - File Type Count Row

/// Sub-row rendered under a loose-files row when its extension breakdown is expanded.
private struct TypeCountRow: View {
    let typeCount: FileTypeCount
    let depth: Int
    let subW: CGFloat
    let fileW: CGFloat
    let sizeW: CGFloat

    private var indentWidth: CGFloat { CGFloat(depth) * 18 }

    var body: some View {
        HStack(spacing: 0) {
            if depth > 0 {
                Spacer().frame(width: indentWidth)
            }
            Spacer().frame(width: 20 + 16)

            Text("↳ \(typeCount.ext)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 4)

            Spacer(minLength: 6)

            Spacer().frame(width: subW)
            Text(typeCount.formattedCount)
                .font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: fileW, alignment: .trailing)
            Text(typeCount.formattedSize)
                .font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: sizeW, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

// MARK: - About

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var updater = UpdateChecker()

    private static let repoURL = URL(string: "https://github.com/titleunknown/Final-Count")!

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                Text("Final Count")
                    .font(.title).fontWeight(.semibold)
                Text("Version \(appVersion)")
                    .font(.caption).foregroundStyle(.secondary)

                // Check for updates
                VStack(spacing: 6) {
                    Button(action: { updater.check(currentVersion: appVersion) }) {
                        HStack(spacing: 5) {
                            if updater.isChecking {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("Check for Updates")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(updater.isChecking)

                    updateStatusView
                }
                .padding(.top, 4)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("What is Final Count?")
                        .font(.headline)
                    Text("Final Count lets you compare two or more folders side by side, instantly seeing each subfolder's count, file count, and total size, with mismatches highlighted automatically. It replaces the repetitive ⌘ I workflow when verifying that multiple drive locations or backup destinations are identical.")
                        .fixedSize(horizontal: false, vertical: true)

                    Text("How to use it")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        BulletRow("Drop a folder onto any column, or click Browse to pick one.")
                        BulletRow("Add more columns with the + button on the right.")
                        BulletRow("Click the chevron next to a subfolder to expand it — every column expands together, and nested folders carry the same match flags, so you can drill straight down to the folder that differs.")
                        BulletRow("Drag the divider between columns to resize them.")
                        BulletRow("Mismatched subfolders are flagged in orange; folders missing from a column appear in red. Hover the icon for exact file and byte counts — displayed sizes are rounded, so folders can look identical while differing by a few bytes.")
                        BulletRow("A folder marked ⚠︎ couldn't be fully read (a permissions block or a drive error). Its counts are a lower bound, so it's flagged rather than called a match — try Refresh, or check the drive.")
                        BulletRow("Click a folder's path to change it, or right-click to reveal it in Finder.")
                        BulletRow("Export a plain-text report with the Export button when you're done.")
                    }
                }
                .padding(24)
            }

            Divider()

            VStack(spacing: 10) {
                Link(destination: URL(string: "https://buymeacoffee.com/fainimade")!) {
                    HStack(spacing: 7) {
                        Image(systemName: "cup.and.saucer.fill")
                        Text("Buy Me a Coffee")
                    }
                    .font(.callout).fontWeight(.semibold)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(
                        Capsule().fill(Color(red: 1.0, green: 0.86, blue: 0.0))
                    )
                }
                .buttonStyle(.plain)
                .help("Support development on Buy Me a Coffee")

                HStack(spacing: 16) {
                    Link(destination: Self.repoURL) {
                        Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: URL(string: "https://www.fainimade.com/software")!) {
                        Label("fainimade.com", systemImage: "globe")
                    }
                }
                .font(.footnote)
            }
            .padding(.vertical, 12)

            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 18)
        }
        .frame(width: 420, height: 620)
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updater.status {
        case .idle:
            EmptyView()
        case .upToDate:
            Label("You're up to date", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .available(let version, let url):
            Link(destination: url) {
                Label("Download Version \(version)", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

// MARK: - Update Checker

@MainActor
final class UpdateChecker: ObservableObject {
    enum Status: Equatable {
        case idle
        case upToDate
        case available(version: String, url: URL)
        case failed(String)
    }

    @Published var status: Status = .idle
    @Published var isChecking = false

    private let apiURL = URL(string: "https://api.github.com/repos/titleunknown/Final-Count/releases/latest")!

    func check(currentVersion: String) {
        isChecking = true
        status = .idle
        Task {
            defer { isChecking = false }
            do {
                var req = URLRequest(url: apiURL)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    status = .failed("No releases published yet")
                    return
                }
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                let pageURL = URL(string: release.html_url) ?? AboutView_repoFallback
                if Self.isNewer(latest, than: currentVersion) {
                    status = .available(version: latest, url: pageURL)
                } else {
                    status = .upToDate
                }
            } catch {
                status = .failed("Couldn't check for updates")
            }
        }
    }

    /// Compares dotted version strings numerically (e.g. "1.10" > "1.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

private let AboutView_repoFallback = URL(string: "https://github.com/titleunknown/Final-Count/releases/latest")!

private struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
}

struct BulletRow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Add Column Button

struct AddColumnButton: View {
    let action: () -> Void
    let onDropURL: (URL) -> Void
    @State private var isHovered = false
    @State private var isTargeted = false

    private var active: Bool { isHovered || isTargeted }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: isTargeted ? "plus.circle" : "plus.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(active ? Color.accentColor : .secondary)
                Text(isTargeted ? "Drop to Add" : "Add Folder")
                    .font(.callout).fontWeight(.medium)
                    .foregroundStyle(active ? .primary : .secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(active ? 0.07 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        active ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.15),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            )
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in onDropURL(url) }
            }
            return true
        }
    }
}
