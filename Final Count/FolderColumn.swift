//
//  FolderColumn.swift
//  Final Count
//

import Foundation
import AppKit
import Combine

// Owns the columns and re-publishes whenever ANY column changes, so the whole
// view tree re-renders together. Without this, a ColumnView only observes its own
// column and shows stale comparison results when a sibling column reloads.
@MainActor
class FolderStore: ObservableObject {
    @Published private(set) var columns: [FolderColumn] = []
    private var cancellables: [UUID: AnyCancellable] = [:]

    func setInitial(count: Int) {
        guard columns.isEmpty else { return }
        for _ in 0..<count { add(FolderColumn()) }
    }

    func add(_ col: FolderColumn) {
        cancellables[col.id] = col.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        columns.append(col)
    }

    func remove(id: UUID) {
        cancellables[id] = nil
        columns.removeAll { $0.id == id }
    }
}

struct FileTypeCount: Identifiable {
    let id = UUID()
    let ext: String
    let count: Int
    let bytes: Int64

    var formattedSize: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var formattedCount: String { count.formatted() }
}

struct SubfolderInfo: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let fileCount: Int
    let byteSize: Int64
    let subfolderCount: Int  // immediate subdirectories only
    // True when some part of this folder's subtree couldn't be read (permissions,
    // an I/O error on an external drive). The counts above are then only a lower
    // bound, so an apparent match can't be trusted.
    var hadReadError: Bool = false
    // Synthetic row aggregating files that sit directly in the folder rather than
    // in a subfolder — without it, a folder of loose files renders as empty.
    var isLooseFilesRow: Bool = false
    // Breakdown by extension, populated only for loose-files rows (not recursed
    // into subfolder totals), sorted by count descending.
    var typeCounts: [FileTypeCount] = []

    var formattedSize: String { ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file) }
    var formattedCount: String { fileCount.formatted() }
    var formattedSubfolderCount: String { subfolderCount > 0 ? subfolderCount.formatted() : "—" }
}

// Shared so the row compares by name across columns like any real subfolder.
let looseFilesRowName = "Files (not in a subfolder)"

// Resource keys prefetched for every directory listing, so the follow-up
// `resourceValues` calls are served from cache.
private let scanResourceKeys: [URLResourceKey] = [
    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
]
private let scanResourceKeySet = Set(scanResourceKeys)

@MainActor
class FolderColumn: ObservableObject, Identifiable {
    let id = UUID()

    @Published var url: URL?
    @Published var subfolders: [SubfolderInfo] = []
    @Published var isLoading = false
    @Published var totalFiles: Int = 0
    @Published var totalBytes: Int64 = 0
    // Non-nil when the top-level folder couldn't be read (e.g. macOS denied access),
    // so the UI can distinguish an access failure from a genuinely empty folder.
    @Published var loadError: String?
    // Count of subfolders whose subtree was only partially readable. Their totals
    // are a lower bound, so the comparison flags them rather than calling a match.
    @Published var readErrorCount = 0
    // Bumped on every load so views can drop caches keyed to a particular scan.
    @Published private(set) var reloadCount = 0

    var name: String { url?.lastPathComponent ?? "" }
    var path: String { url?.path ?? "" }

    func load(from newURL: URL) {
        url = newURL
        subfolders = []
        totalFiles = 0
        totalBytes = 0
        loadError = nil
        readErrorCount = 0
        reloadCount += 1
        isLoading = true

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FolderColumn.analyzeDirectory(url: newURL)
            }.value
            self.subfolders = result.subfolders
            self.totalFiles = result.totalFiles
            self.totalBytes = result.totalBytes
            self.readErrorCount = result.readErrors
            self.loadError = result.error
            self.isLoading = false
        }
    }

    func revealInFinder() {
        guard let url else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    // Public — used for lazy expansion of nested rows
    nonisolated static func loadChildren(at url: URL) -> [SubfolderInfo] {
        analyzeDirectory(url: url).subfolders
    }

    /// Scans one directory: `contentsOfDirectory` for the top level (so loose
    /// files can be split into their own row) and `walk` for each subfolder.
    ///
    /// Both the top level and `walk` share one traversal policy, so a folder's
    /// totals are identical whether it's the column root here or a nested row
    /// reached through expansion — the sum of a folder's child rows always
    /// equals its own total, at every level.
    private nonisolated static func analyzeDirectory(url: URL) -> (subfolders: [SubfolderInfo], totalFiles: Int, totalBytes: Int64, readErrors: Int, error: String?) {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: scanResourceKeys,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return ([], 0, 0, 0, describeAccessError(error))
        }

        var infos: [SubfolderInfo] = []
        var grandTotalFiles = 0
        var grandTotalBytes: Int64 = 0
        var readErrors = 0
        var looseFiles = 0
        var looseBytes: Int64 = 0
        var looseTypeCounts: [String: (count: Int, bytes: Int64)] = [:]

        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? item.resourceValues(forKeys: scanResourceKeySet)
            // Symbolic links are neither followed nor counted — see `walk`.
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                let t = walk(item, fm: fm)
                infos.append(SubfolderInfo(
                    name: item.lastPathComponent,
                    url: item,
                    fileCount: t.files,
                    byteSize: t.bytes,
                    subfolderCount: t.immediateSubdirs,
                    hadReadError: t.readError
                ))
                grandTotalFiles += t.files
                grandTotalBytes += t.bytes
                if t.readError { readErrors += 1 }
            } else if values?.isRegularFile == true {
                looseFiles += 1
                let size = Int64(values?.fileSize ?? 0)
                looseBytes += size
                let ext = item.pathExtension.isEmpty ? "No extension" : item.pathExtension.uppercased()
                looseTypeCounts[ext, default: (0, 0)].count += 1
                looseTypeCounts[ext, default: (0, 0)].bytes += size
            }
        }

        if looseFiles > 0 {
            let typeCounts = looseTypeCounts
                .map { FileTypeCount(ext: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.ext < $1.ext }
            infos.insert(SubfolderInfo(
                name: looseFilesRowName,
                url: url,
                fileCount: looseFiles,
                byteSize: looseBytes,
                subfolderCount: 0,
                isLooseFilesRow: true,
                typeCounts: typeCounts
            ), at: 0)
            grandTotalFiles += looseFiles
            grandTotalBytes += looseBytes
        }

        return (infos, grandTotalFiles, grandTotalBytes, readErrors, nil)
    }

    /// Turns a directory-read failure into a message aimed at the likely cause: a
    /// sandboxed app losing access to a dropped folder. Browse re-grants that access.
    private nonisolated static func describeAccessError(_ error: Error) -> String {
        let nsError = error as NSError
        let isPermission = nsError.domain == NSCocoaErrorDomain
            && [NSFileReadNoPermissionError, NSFileReadUnknownError].contains(nsError.code)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EPERM))
        if isPermission {
            return "macOS denied access to this folder. Click the path above and re-select it with Browse… to grant access."
        }
        return "Couldn't read this folder: \(nsError.localizedDescription)"
    }

    /// Recursively totals a directory subtree. The single traversal policy used
    /// everywhere in the app, applied identically at every depth:
    ///
    ///  • hidden entries are skipped (`.skipsHiddenFiles`);
    ///  • symbolic links are neither followed nor counted — this rules out link
    ///    cycles, keeps out data that lives outside the tree, and makes the total
    ///    independent of which folder the scan started from;
    ///  • a directory that can't be listed contributes whatever was readable and
    ///    sets `readError`, so a scan interrupted by an I/O error on an external
    ///    drive is reported instead of silently passing as a match.
    private nonisolated static func walk(_ url: URL, fm: FileManager) -> (files: Int, bytes: Int64, immediateSubdirs: Int, readError: Bool) {
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: scanResourceKeys,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return (0, 0, 0, true)
        }

        var files = 0
        var bytes: Int64 = 0
        var immediateSubdirs = 0
        var readError = false

        for item in contents {
            let values = try? item.resourceValues(forKeys: scanResourceKeySet)
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                immediateSubdirs += 1
                let sub = walk(item, fm: fm)
                files += sub.files
                bytes += sub.bytes
                readError = readError || sub.readError
            } else if values?.isRegularFile == true {
                files += 1
                bytes += Int64(values?.fileSize ?? 0)
            }
        }
        return (files, bytes, immediateSubdirs, readError)
    }
}

// MARK: - Comparison

enum MatchStatus { case match, mismatch, missing }

/// Identifies one folder's scanned children in the shared expansion cache: which
/// column, and the folder's path relative to that column's root (e.g.
/// "Capture/LOOK_7185"). The relative path lets the same nested folder be matched
/// across columns the way top-level rows are matched by name.
struct ChildCacheKey: Hashable {
    let column: UUID
    let relPath: String
}

/// Folder names that look identical can differ invisibly (trailing spaces, case,
/// width/diacritic variants) across volumes and copy tools; treat those as the same folder.
func canonicalFolderName(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
}

/// Compares the same folder as seen from each column — one optional `SubfolderInfo`
/// per column, `nil` where the folder is absent. Shared by the top-level rows and
/// by nested rows once their children have been scanned.
func compareEntries(_ entries: [SubfolderInfo?], columnCount: Int) -> MatchStatus {
    let found = entries.compactMap { $0 }
    guard found.count == columnCount else { return .missing }
    // A partially-readable subtree makes an apparent match meaningless.
    if found.contains(where: { $0.hadReadError }) { return .mismatch }
    let first = found[0]
    return found.dropFirst().allSatisfy({ $0.fileCount == first.fileCount && $0.byteSize == first.byteSize })
        ? .match : .mismatch
}

/// Explains a non-matching row with exact numbers, since the displayed sizes are
/// rounded and can look identical while the byte counts differ. Returns nil for matches.
/// `entries` pairs each column's path (for the message) with its folder, if present.
func compareDetail(_ entries: [(path: String, info: SubfolderInfo?)], columnCount: Int) -> String? {
    let missingFrom = entries.filter { $0.info == nil }.map { $0.path }
    if !missingFrom.isEmpty {
        return "Not found in:\n" + missingFrom.joined(separator: "\n")
    }
    let found = entries.compactMap { $0.info }
    guard let first = found.first else { return nil }
    let differs = found.dropFirst().contains { $0.fileCount != first.fileCount || $0.byteSize != first.byteSize }
    let unreadable = found.contains { $0.hadReadError }
    guard differs || unreadable else { return nil }
    var text = entries.map { e -> String in
        guard let i = e.info else { return "\(e.path): —" }
        return "\(e.path): \(i.fileCount.formatted()) files, \(i.byteSize.formatted()) bytes"
            + (i.hadReadError ? "  ⚠︎ some items unreadable" : "")
    }.joined(separator: "\n")
    if unreadable {
        text += "\n\nCounts are a lower bound — some items couldn't be read, so a match can't be confirmed."
    }
    return text
}

@MainActor func statusFor(name: String, in columns: [FolderColumn]) -> MatchStatus {
    let key = canonicalFolderName(name)
    let entries = columns.map { $0.subfolders.first(where: { canonicalFolderName($0.name) == key }) }
    return compareEntries(entries, columnCount: columns.count)
}

@MainActor func statusDetail(name: String, in columns: [FolderColumn]) -> String? {
    let key = canonicalFolderName(name)
    let entries = columns.map { col in
        (path: col.path, info: col.subfolders.first(where: { canonicalFolderName($0.name) == key }))
    }
    return compareDetail(entries, columnCount: columns.count)
}

@MainActor func allSubfolderNames(in columns: [FolderColumn]) -> [String] {
    var seenKeys = Set<String>()
    var names: [String] = []
    for name in columns.flatMap({ $0.subfolders.map(\.name) }) {
        if seenKeys.insert(canonicalFolderName(name)).inserted { names.append(name) }
    }
    return names.sorted()
}

// MARK: - Export

private func rpad(_ s: String, _ w: Int) -> String {
    if s.count == w { return s }
    if s.count > w { return String(s.prefix(max(0, w - 1))) + "…" }
    return s + String(repeating: " ", count: w - s.count)
}
private func lpad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
}

@MainActor func buildReport(columns: [FolderColumn]) -> String {
    var lines: [String] = []
    lines.append("Final Count — Folder Comparison Report")
    lines.append("Generated: \(Date().formatted(date: .abbreviated, time: .standard))")
    lines.append(String(repeating: "─", count: 80))

    for col in columns {
        lines.append("")
        lines.append("▸ \(col.name)")
        lines.append("  \(col.path)")
        lines.append("    " + String(repeating: "─", count: 68))
        lines.append("  " + rpad("Subfolder", 32) + " " + lpad("Subdirs", 8) + "  " + lpad("Files", 8) + "  " + lpad("Size", 12))
        lines.append("    " + String(repeating: "─", count: 68))
        for sub in col.subfolders {
            let flag = sub.hadReadError ? " ⚠︎" : ""
            lines.append("  " + rpad(sub.name + flag, 32) + " " + lpad(sub.formattedSubfolderCount, 8) + "  " + lpad(sub.formattedCount, 8) + "  " + lpad(sub.formattedSize, 12))
        }
        lines.append("    " + String(repeating: "─", count: 68))
        let totalLabel = "TOTAL (\(col.subfolders.filter { !$0.isLooseFilesRow }.count) folders)"
        let totalSize = ByteCountFormatter.string(fromByteCount: col.totalBytes, countStyle: .file)
        lines.append("  " + rpad(totalLabel, 32) + " " + lpad("—", 8) + "  " + lpad(col.totalFiles.formatted(), 8) + "  " + lpad(totalSize, 12))
    }

    lines.append("")
    lines.append(String(repeating: "─", count: 80))

    if columns.count > 1 {
        let names = allSubfolderNames(in: columns)
        let mismatches = names.filter { statusFor(name: $0, in: columns) != .match }
        if mismatches.isEmpty {
            lines.append("✓ All folders are identical.")
        } else {
            lines.append("✗ Mismatches found (\(mismatches.count)):")
            for m in mismatches { lines.append("  • \(m)") }
        }
        if columns.contains(where: { $0.readErrorCount > 0 }) {
            lines.append("")
            lines.append("⚠︎ Some folders (marked ⚠︎ above) could not be fully read; their counts are")
            lines.append("  a lower bound and any match involving them is unconfirmed.")
        }
    }

    return lines.joined(separator: "\n")
}
