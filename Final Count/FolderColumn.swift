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
    /// Scan option shared by every column, so all sides of a comparison are
    /// always counted the same way.
    var includeHiddenFiles = false {
        didSet { columns.forEach { $0.includeHiddenFiles = includeHiddenFiles } }
    }

    func setInitial(count: Int) {
        guard columns.isEmpty else { return }
        for _ in 0..<count { add(FolderColumn()) }
    }

    func add(_ col: FolderColumn) {
        col.includeHiddenFiles = includeHiddenFiles
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

struct LooseFile {
    let name: String
    let size: Int64
}

struct SubfolderInfo: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let fileCount: Int
    let byteSize: Int64
    let subfolderCount: Int  // immediate subdirectories only
    // Order-independent digest of every name, kind, and size in the subtree, so
    // two folders with equal totals but a renamed or moved file still differ.
    // Built with a per-launch `Hasher` seed: only comparable within one run.
    var fingerprint: UInt64 = 0
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
    // Every loose file's name and size (loose-files rows only), so a mismatch
    // can name the exact files that are missing or differ.
    var looseFiles: [LooseFile] = []

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

/// Which folder on disk a column points to, independent of the path used to
/// reach it (aliases, symlinks, firmlinks, differing capitalization).
struct FolderIdentity: Equatable {
    let fileID: NSObject?
    let volumeID: NSObject?
    let volumeName: String?
    let resolvedPath: String

    func isSameFolder(as other: FolderIdentity) -> Bool {
        if let a = fileID, let b = other.fileID {
            // File IDs are inode-based, so also require the same volume.
            let sameVolume = volumeID == nil || other.volumeID == nil
                || volumeID!.isEqual(other.volumeID!)
            return a.isEqual(b) && sameVolume
        }
        // Some network volumes don't vend file IDs; fall back to the real path.
        return resolvedPath == other.resolvedPath
    }

    func isSameVolume(as other: FolderIdentity) -> Bool {
        guard let a = volumeID, let b = other.volumeID else { return false }
        return a.isEqual(b)
    }
}

/// Groups of column indices (2+) that point at the same folder on disk.
func duplicateFolderGroups(_ ids: [FolderIdentity?]) -> [[Int]] {
    groupIndices(ids) { $0.isSameFolder(as: $1) }
}

/// Groups of column indices (2+) that are distinct folders on the same volume —
/// a copy that won't survive that drive failing. Duplicates count once.
func sameVolumeGroups(_ ids: [FolderIdentity?]) -> [[Int]] {
    let redundant = Set(duplicateFolderGroups(ids).flatMap { $0.dropFirst() })
    let pruned = ids.enumerated().map { redundant.contains($0.offset) ? nil : $0.element }
    return groupIndices(pruned) { $0.isSameVolume(as: $1) }
}

private func groupIndices(_ ids: [FolderIdentity?], _ same: (FolderIdentity, FolderIdentity) -> Bool) -> [[Int]] {
    var groups: [[Int]] = []
    var assigned = Set<Int>()
    for i in ids.indices where !assigned.contains(i) {
        guard let a = ids[i] else { continue }
        var group = [i]
        for j in ids.indices where j > i && !assigned.contains(j) {
            if let b = ids[j], same(a, b) {
                group.append(j)
                assigned.insert(j)
            }
        }
        if group.count > 1 { groups.append(group) }
    }
    return groups
}

/// "column 2" / "columns 1 and 3", from 0-based indices.
func columnList(_ indices: [Int]) -> String {
    let numbers = indices.map { String($0 + 1) }
    let joined = ListFormatter.localizedString(byJoining: numbers)
    return (numbers.count == 1 ? "column " : "columns ") + joined
}

/// True for folders (and packages), following a symlink to one; false for
/// plain files or unreadable items.
func isFolder(_ url: URL) -> Bool {
    (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
}

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
    // Published ahead of the scan, so a folder picked twice is flagged at once.
    @Published private(set) var identity: FolderIdentity?
    var includeHiddenFiles = false

    var name: String { url?.lastPathComponent ?? "" }
    var path: String { url?.path ?? "" }

    func load(from pickedURL: URL) {
        // Scan the real folder behind a symlink; listing the link itself fails.
        let newURL = pickedURL.resolvingSymlinksInPath()
        if newURL != url { identity = nil }
        url = newURL
        subfolders = []
        totalFiles = 0
        totalBytes = 0
        loadError = nil
        readErrorCount = 0
        reloadCount += 1
        isLoading = true
        let generation = reloadCount
        let includeHidden = includeHiddenFiles

        Task {
            let id = await Task.detached(priority: .userInitiated) {
                FolderColumn.identify(newURL)
            }.value
            guard generation == self.reloadCount else { return }
            self.identity = id

            let result = await Task.detached(priority: .userInitiated) {
                FolderColumn.analyzeDirectory(url: newURL, includeHidden: includeHidden)
            }.value
            // A newer load (a different folder, or Refresh) started while this
            // scan ran. Its results win; applying these would show one folder's
            // path with another folder's numbers.
            guard generation == self.reloadCount else { return }
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
    nonisolated static func loadChildren(at url: URL, includeHidden: Bool) -> [SubfolderInfo] {
        analyzeDirectory(url: url, includeHidden: includeHidden).subfolders
    }

    nonisolated static func identify(_ url: URL) -> FolderIdentity {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [
            .fileResourceIdentifierKey, .volumeIdentifierKey, .volumeLocalizedNameKey
        ])
        return FolderIdentity(
            fileID: values?.fileResourceIdentifier as? NSObject,
            volumeID: values?.volumeIdentifier as? NSObject,
            volumeName: values?.volumeLocalizedName,
            resolvedPath: url.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    private nonisolated static func scanOptions(includeHidden: Bool) -> FileManager.DirectoryEnumerationOptions {
        includeHidden ? [] : [.skipsHiddenFiles]
    }

    /// One entry's contribution to its parent's fingerprint. Names are
    /// canonicalized the same way folder rows are matched across columns.
    private nonisolated static func entryHash(_ name: String, isDirectory: Bool, _ value: UInt64) -> UInt64 {
        var h = Hasher()
        h.combine(canonicalFolderName(name))
        h.combine(isDirectory)
        h.combine(value)
        return UInt64(bitPattern: Int64(h.finalize()))
    }

    /// Scans one directory: `contentsOfDirectory` for the top level (so loose
    /// files can be split into their own row) and `walk` for each subfolder.
    ///
    /// Both the top level and `walk` share one traversal policy, so a folder's
    /// totals are identical whether it's the column root here or a nested row
    /// reached through expansion — the sum of a folder's child rows always
    /// equals its own total, at every level.
    private nonisolated static func analyzeDirectory(url: URL, includeHidden: Bool) -> (subfolders: [SubfolderInfo], totalFiles: Int, totalBytes: Int64, readErrors: Int, error: String?) {
        let fm = FileManager.default
        let options = scanOptions(includeHidden: includeHidden)
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: scanResourceKeys,
                options: options
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
        var looseList: [LooseFile] = []
        var looseFingerprint: UInt64 = 0

        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? item.resourceValues(forKeys: scanResourceKeySet)
            // Symbolic links are neither followed nor counted — see `walk`.
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                let t = walk(item, fm: fm, options: options)
                infos.append(SubfolderInfo(
                    name: item.lastPathComponent,
                    url: item,
                    fileCount: t.files,
                    byteSize: t.bytes,
                    subfolderCount: t.immediateSubdirs,
                    fingerprint: t.fingerprint,
                    hadReadError: t.readError
                ))
                grandTotalFiles += t.files
                grandTotalBytes += t.bytes
                if t.readError { readErrors += 1 }
            } else if values?.isRegularFile == true {
                looseFiles += 1
                let size = Int64(values?.fileSize ?? 0)
                looseBytes += size
                looseList.append(LooseFile(name: item.lastPathComponent, size: size))
                looseFingerprint &+= entryHash(item.lastPathComponent, isDirectory: false, UInt64(bitPattern: size))
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
                fingerprint: looseFingerprint,
                isLooseFilesRow: true,
                typeCounts: typeCounts,
                looseFiles: looseList
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
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        if underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOTDIR) {
            return "This is a file, not a folder. Click the path above and choose a folder with Browse…"
        }
        if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError)
            || (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT)) {
            return "This folder is no longer available. If it's on an external drive, check that the drive is connected, then Refresh."
        }
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
    ///  • hidden entries are skipped unless the user opts in (`options`);
    ///  • symbolic links are neither followed nor counted — this rules out link
    ///    cycles, keeps out data that lives outside the tree, and makes the total
    ///    independent of which folder the scan started from;
    ///  • a directory that can't be listed contributes whatever was readable and
    ///    sets `readError`, so a scan interrupted by an I/O error on an external
    ///    drive is reported instead of silently passing as a match.
    private nonisolated static func walk(_ url: URL, fm: FileManager, options: FileManager.DirectoryEnumerationOptions) -> (files: Int, bytes: Int64, immediateSubdirs: Int, fingerprint: UInt64, readError: Bool) {
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: scanResourceKeys,
                options: options
            )
        } catch {
            return (0, 0, 0, 0, true)
        }

        var files = 0
        var bytes: Int64 = 0
        var immediateSubdirs = 0
        var fingerprint: UInt64 = 0
        var readError = false

        for item in contents {
            let values = try? item.resourceValues(forKeys: scanResourceKeySet)
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                immediateSubdirs += 1
                let sub = walk(item, fm: fm, options: options)
                files += sub.files
                bytes += sub.bytes
                fingerprint &+= entryHash(item.lastPathComponent, isDirectory: true, sub.fingerprint)
                readError = readError || sub.readError
            } else if values?.isRegularFile == true {
                let size = Int64(values?.fileSize ?? 0)
                files += 1
                bytes += size
                fingerprint &+= entryHash(item.lastPathComponent, isDirectory: false, UInt64(bitPattern: size))
            }
        }
        return (files, bytes, immediateSubdirs, fingerprint, readError)
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
    return found.dropFirst().allSatisfy({
        $0.fileCount == first.fileCount && $0.byteSize == first.byteSize && $0.fingerprint == first.fingerprint
    }) ? .match : .mismatch
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
    let totalsDiffer = found.dropFirst().contains { $0.fileCount != first.fileCount || $0.byteSize != first.byteSize }
    let layoutDiffers = found.dropFirst().contains { $0.fingerprint != first.fingerprint }
    let unreadable = found.contains { $0.hadReadError }
    guard totalsDiffer || layoutDiffers || unreadable else { return nil }
    var text = entries.map { e -> String in
        guard let i = e.info else { return "\(e.path): —" }
        return "\(e.path): \(i.fileCount.formatted()) file\(i.fileCount == 1 ? "" : "s"), \(i.byteSize.formatted()) byte\(i.byteSize == 1 ? "" : "s")"
            + (i.hadReadError ? "  ⚠︎ some items unreadable" : "")
    }.joined(separator: "\n")
    if found.allSatisfy(\.isLooseFilesRow), let names = looseFileDifferences(entries) {
        text += "\n\n" + names
    } else if layoutDiffers && !totalsDiffer {
        text += "\n\nSame number of files and total size, but file names or folder layout differ."
            + (found.contains { $0.subfolderCount > 0 } ? " Expand the folder to find where."
               : " Export a report to see which files.")
    }
    if unreadable {
        text += "\n\nCounts are a lower bound — some items couldn't be read, so a match can't be confirmed."
    }
    return text
}

/// Names the loose files that are missing from a column or differ in size.
private func looseFileDifferences(_ entries: [(path: String, info: SubfolderInfo?)]) -> String? {
    let maps = entries.map { e in
        Dictionary((e.info?.looseFiles ?? []).map { (canonicalFolderName($0.name), $0) },
                   uniquingKeysWith: { a, _ in a })
    }
    var displayName: [String: String] = [:]
    for map in maps { for (key, file) in map where displayName[key] == nil { displayName[key] = file.name } }
    let allKeys = displayName.keys.sorted()

    func list(_ keys: [String]) -> String {
        let limit = 8
        let names = keys.prefix(limit).compactMap { displayName[$0] }.joined(separator: ", ")
        return keys.count > limit ? names + " and \(keys.count - limit) more" : names
    }

    var sections: [String] = []
    for (i, e) in entries.enumerated() {
        let missing = allKeys.filter { maps[i][$0] == nil }
        if !missing.isEmpty { sections.append("Missing from \(e.path):\n  " + list(missing)) }
    }
    let sizeDiffers = allKeys.filter { key in
        let sizes = maps.compactMap { $0[key]?.size }
        return sizes.count == maps.count && Set(sizes).count > 1
    }
    if !sizeDiffers.isEmpty { sections.append("Different size:\n  " + list(sizeDiffers)) }
    return sections.isEmpty ? nil : sections.joined(separator: "\n")
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

// MARK: - Verdict

/// The overall verdict, shared by the status banner and the exported report so
/// the two can never disagree.
enum ComparisonState: Equatable {
    /// Comparing now would be meaningless or would falsely flag everything.
    case notReady(String)
    /// Two or more columns point at the same folder, so they can't verify each other.
    case sameFolder([[Int]])
    case identical
    case differences(Int)
}

@MainActor func comparisonState(for columns: [FolderColumn]) -> ComparisonState {
    guard columns.count > 1 else { return .notReady("Add at least two folders to compare.") }
    // Checked before scanning finishes: no scan result can make this valid.
    let duplicates = duplicateFolderGroups(columns.map(\.identity))
    if !duplicates.isEmpty { return .sameFolder(duplicates) }
    if let i = columns.firstIndex(where: { $0.url == nil }) {
        return .notReady("No folder has been chosen for column \(i + 1).")
    }
    if columns.contains(where: \.isLoading) { return .notReady("Folders are still being scanned.") }
    if let i = columns.firstIndex(where: { $0.loadError != nil }) {
        return .notReady("Column \(i + 1) couldn't be read.")
    }
    let mismatchCount = allSubfolderNames(in: columns)
        .filter { statusFor(name: $0, in: columns) != .match }
        .count
    return mismatchCount == 0 ? .identical : .differences(mismatchCount)
}

/// One difference located as deep as it goes, for the report.
struct FolderDifference {
    let relPath: String
    let detail: String
}

/// Walks down every mismatched branch until it reaches the folders that
/// actually differ. Only mismatched branches are re-scanned, and a mismatch is
/// reported at its own level when none of its children explain it.
func findDifferences(roots: [URL], children: [[SubfolderInfo]], relPath: String,
                                 includeHidden: Bool, into out: inout [FolderDifference]) {
    var seen = Set<String>()
    var names: [String] = []
    for list in children {
        for sub in list where seen.insert(canonicalFolderName(sub.name)).inserted { names.append(sub.name) }
    }
    for name in names.sorted() {
        let key = canonicalFolderName(name)
        let entries = children.map { $0.first(where: { canonicalFolderName($0.name) == key }) }
        guard compareEntries(entries, columnCount: roots.count) != .match else { continue }

        let isLoose = entries.contains { $0?.isLooseFilesRow == true }
        let childPath = relPath.isEmpty ? name : relPath + "/" + name
        let found = entries.compactMap { $0 }
        // Descend even into folders without subfolders: their loose-files row
        // names the exact files that differ.
        if !isLoose, found.count == roots.count {
            let before = out.count
            let grandchildren = found.map { FolderColumn.loadChildren(at: $0.url, includeHidden: includeHidden) }
            findDifferences(roots: roots, children: grandchildren, relPath: childPath,
                            includeHidden: includeHidden, into: &out)
            if out.count > before { continue }
        }

        let folderPath = isLoose ? relPath : childPath
        let detail = compareDetail(
            zip(roots, entries).map { (path: folderPath.isEmpty ? $0.path : $0.path + "/" + folderPath, info: $1) },
            columnCount: roots.count
        )
        let label = isLoose ? (relPath.isEmpty ? "Top level" : relPath) + " — files not in a subfolder" : childPath
        out.append(FolderDifference(relPath: label, detail: detail ?? ""))
    }
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

/// Everything the report needs, captured on the main actor so the (possibly
/// slow) drill-down into differences can run in the background.
struct ReportInput {
    struct Column {
        let name: String
        let url: URL?
        let subfolders: [SubfolderInfo]
        let totalFiles: Int
        let totalBytes: Int64
        let readErrorCount: Int
        let loadError: String?
        let identity: FolderIdentity?
    }
    let columns: [Column]
    let state: ComparisonState
    let includeHidden: Bool
    let appVersion: String

    @MainActor init(columns: [FolderColumn], includeHidden: Bool, appVersion: String) {
        self.columns = columns.map {
            Column(name: $0.name, url: $0.url, subfolders: $0.subfolders, totalFiles: $0.totalFiles,
                   totalBytes: $0.totalBytes, readErrorCount: $0.readErrorCount,
                   loadError: $0.loadError, identity: $0.identity)
        }
        self.state = comparisonState(for: columns)
        self.includeHidden = includeHidden
        self.appVersion = appVersion
    }
}

func buildReport(_ input: ReportInput) -> String {
    let columns = input.columns
    var lines: [String] = []
    lines.append("Final Count — Folder Comparison Report")
    lines.append("Generated: \(Date().formatted(date: .abbreviated, time: .standard))  ·  Final Count \(input.appVersion)")
    lines.append("Compared: file names, folder layout, file counts, and sizes. File contents are not checksummed.")
    lines.append("Hidden files: \(input.includeHidden ? "included" : "excluded")")
    lines.append(String(repeating: "─", count: 80))

    for (i, col) in columns.enumerated() {
        lines.append("")
        lines.append("▸ Column \(i + 1): \(col.url == nil ? "(no folder)" : col.name)")
        guard let url = col.url else { continue }
        lines.append("  \(url.path)" + (col.identity?.volumeName.map { "  [\($0)]" } ?? ""))
        if let error = col.loadError {
            lines.append("  ✗ \(error)")
            continue
        }
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

    switch input.state {
    case .notReady(let reason):
        lines.append("– Not compared: \(reason)")
    case .sameFolder(let groups):
        lines.append("✗ NOT VERIFIED — the same folder was selected more than once:")
        for g in groups {
            lines.append("  • \(columnList(g).uppercasingFirst) are the same folder on disk.")
        }
        lines.append("  A folder can't verify itself. Choose the other copy (e.g. the backup drive) and export again.")
    case .identical:
        lines.append("✓ All folders are identical.")
    case .differences:
        var diffs: [FolderDifference] = []
        findDifferences(roots: columns.compactMap(\.url), children: columns.map(\.subfolders),
                        relPath: "", includeHidden: input.includeHidden, into: &diffs)
        lines.append("✗ Differences found (\(diffs.count)):")
        for d in diffs {
            lines.append("")
            lines.append("  • \(d.relPath)")
            for detailLine in d.detail.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(detailLine.isEmpty ? "" : "      " + detailLine)
            }
        }
    }

    let volumeGroups = sameVolumeGroups(columns.map(\.identity))
    if !volumeGroups.isEmpty {
        lines.append("")
        for g in volumeGroups {
            let volume = g.first.flatMap { columns[$0].identity?.volumeName }.map { " (\($0))" } ?? ""
            lines.append("ⓘ \(columnList(g).uppercasingFirst) are on the same drive\(volume); that copy")
            lines.append("  won't protect against the drive itself failing.")
        }
    }
    if columns.contains(where: { $0.readErrorCount > 0 }) {
        lines.append("")
        lines.append("⚠︎ Some folders (marked ⚠︎ above) could not be fully read; their counts are")
        lines.append("  a lower bound and any match involving them is unconfirmed.")
    }

    return lines.joined(separator: "\n")
}

extension String {
    var uppercasingFirst: String { prefix(1).uppercased() + dropFirst() }
}
