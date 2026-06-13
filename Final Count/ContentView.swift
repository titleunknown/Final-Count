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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(columns) { col in
                        ColumnView(
                            column: col,
                            allColumns: columns,
                            width: columnWidth(for: col),
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
                        .onChange(of: proxy.size.width) { viewWidth = $0 }
                }
            )

            Divider()
            HStack {
                Button(action: refreshAll) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Re-scan all folders")

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
        .frame(minWidth: 920, minHeight: 620)
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

// MARK: - Resize Divider

struct ResizeDivider: View {
    let onResize: (CGFloat) -> Void
    @State private var prevTranslation: CGFloat = 0
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(isHovered ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .frame(width: 8)
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
    let onRemove: () -> Void

    @State private var isTargeted = false
    @State private var expandedIDs: Set<UUID> = []
    @State private var childrenCache: [UUID: [SubfolderInfo]] = [:]

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
            } else {
                subfolderList
                Divider()
                totalsRow
            }
        }
        .frame(width: width)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted, perform: handleDrop)
        .onChange(of: column.url) { _ in
            expandedIDs.removeAll()
            childrenCache.removeAll()
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
        .background(Color.primary.opacity(0.04))
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
                        name: sub.name,
                        info: sub,
                        depth: 0,
                        status: statusFor(name: sub.name, in: allColumns),
                        showStatus: allColumns.count > 1 && allColumns.allSatisfy({ $0.url != nil }),
                        subW: subW, fileW: fileW, sizeW: sizeW,
                        expandedIDs: $expandedIDs,
                        childrenCache: $childrenCache
                    )
                    Divider().padding(.leading, 14)
                }
            }
        }
    }

    // MARK: Totals

    private var totalsRow: some View {
        let totalSubdirs = column.subfolders.reduce(0) { $0 + $1.subfolderCount }
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(column.subfolders.count) subfolder\(column.subfolders.count == 1 ? "" : "s")")
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
        .background(Color.primary.opacity(0.04))
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
    let name: String
    let info: SubfolderInfo?
    let depth: Int
    let status: MatchStatus
    let showStatus: Bool
    let subW: CGFloat
    let fileW: CGFloat
    let sizeW: CGFloat
    @Binding var expandedIDs: Set<UUID>
    @Binding var childrenCache: [UUID: [SubfolderInfo]]

    private var isExpanded: Bool { info.map { expandedIDs.contains($0.id) } ?? false }
    private var canExpand: Bool { (info?.subfolderCount ?? 0) > 0 }

    var body: some View {
        VStack(spacing: 0) {
            rowContent
            if isExpanded, let info {
                if let children = childrenCache[info.id] {
                    ForEach(children) { child in
                        ExpandableSubfolderRow(
                            name: child.name,
                            info: child,
                            depth: depth + 1,
                            status: .match,
                            showStatus: false,
                            subW: subW, fileW: fileW, sizeW: sizeW,
                            expandedIDs: $expandedIDs,
                            childrenCache: $childrenCache
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
                        let loaded = await Task.detached(priority: .userInitiated) {
                            FolderColumn.loadChildren(at: url)
                        }.value
                        childrenCache[info.id] = loaded
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

            // Status indicator (only depth 0)
            if depth == 0 {
                Group {
                    if showStatus {
                        switch status {
                        case .match:
                            Spacer().frame(width: 20)
                        case .mismatch:
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.caption2).foregroundStyle(.orange)
                                .frame(width: 20)
                        case .missing:
                            Image(systemName: "minus.circle.fill")
                                .font(.caption2).foregroundStyle(.red)
                                .frame(width: 20)
                        }
                    } else {
                        Spacer().frame(width: 20)
                    }
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
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(info == nil ? Color.secondary : Color.primary)
                .padding(.leading, 4)

            Spacer(minLength: 6)

            // Subdirs count
            if let info {
                Text(info.formattedSubfolderCount)
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: subW, alignment: .trailing)
                // Files
                Text(info.formattedCount)
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
        guard let info else { return }
        if isExpanded {
            expandedIDs.remove(info.id)
        } else {
            expandedIDs.insert(info.id)
        }
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
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
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
                        BulletRow("Click the chevron next to a subfolder to expand and inspect its contents.")
                        BulletRow("Drag the divider between columns to resize them.")
                        BulletRow("Mismatched subfolders are flagged in orange; folders missing from a column appear in red.")
                        BulletRow("Click a folder's path to change it, or right-click to reveal it in Finder.")
                        BulletRow("Export a plain-text report with the Export button when you're done.")
                    }
                }
                .padding(24)
            }

            Divider()

            VStack(spacing: 10) {
                HStack(spacing: 16) {
                    Link(destination: Self.repoURL) {
                        Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: URL(string: "https://www.fainimade.com")!) {
                        Label("fainimade.com", systemImage: "globe")
                    }
                }
                .font(.footnote)

                HStack(spacing: 4) {
                    Text("Made by").foregroundStyle(.secondary)
                    Link("Faini Made", destination: URL(string: "https://www.fainimade.com")!)
                        .foregroundStyle(Color.accentColor)
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
                Label("Version \(version) available — download", systemImage: "arrow.down.circle.fill")
                    .font(.caption).fontWeight(.medium)
            }
            .foregroundStyle(Color.accentColor)
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
