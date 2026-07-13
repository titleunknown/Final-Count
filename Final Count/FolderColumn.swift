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

struct SubfolderInfo: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let fileCount: Int
    let byteSize: Int64
    let subfolderCount: Int  // immediate subdirectories only
    // Synthetic row aggregating files that sit directly in the folder rather than
    // in a subfolder — without it, a folder of loose files renders as empty.
    var isLooseFilesRow: Bool = false

    var formattedSize: String { ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file) }
    var formattedCount: String { fileCount.formatted() }
    var formattedSubfolderCount: String { subfolderCount > 0 ? subfolderCount.formatted() : "—" }
}

// Shared so the row compares by name across columns like any real subfolder.
let looseFilesRowName = "Files (not in a subfolder)"

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

    var name: String { url?.lastPathComponent ?? "" }
    var path: String { url?.path ?? "" }

    func load(from newURL: URL) {
        url = newURL
        subfolders = []
        totalFiles = 0
        totalBytes = 0
        loadError = nil
        isLoading = true

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FolderColumn.analyzeDirectory(url: newURL)
            }.value
            self.subfolders = result.subfolders
            self.totalFiles = result.totalFiles
            self.totalBytes = result.totalBytes
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

    private nonisolated static func analyzeDirectory(url: URL) -> (subfolders: [SubfolderInfo], totalFiles: Int, totalBytes: Int64, error: String?) {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return ([], 0, 0, describeAccessError(error))
        }

        var infos: [SubfolderInfo] = []
        var grandTotalFiles = 0
        var grandTotalBytes: Int64 = 0
        var looseFiles = 0
        var looseBytes: Int64 = 0

        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values?.isDirectory == true {
                let (fileCount, bytes) = deepCount(at: item, fm: fm)
                let subfolderCount = immediateSubdirCount(at: item, fm: fm)
                infos.append(SubfolderInfo(
                    name: item.lastPathComponent,
                    url: item,
                    fileCount: fileCount,
                    byteSize: bytes,
                    subfolderCount: subfolderCount
                ))
                grandTotalFiles += fileCount
                grandTotalBytes += bytes
            } else if values?.isRegularFile == true {
                looseFiles += 1
                looseBytes += Int64(values?.fileSize ?? 0)
            }
        }

        if looseFiles > 0 {
            infos.insert(SubfolderInfo(
                name: looseFilesRowName,
                url: url,
                fileCount: looseFiles,
                byteSize: looseBytes,
                subfolderCount: 0,
                isLooseFilesRow: true
            ), at: 0)
            grandTotalFiles += looseFiles
            grandTotalBytes += looseBytes
        }

        return (infos, grandTotalFiles, grandTotalBytes, nil)
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

    private nonisolated static func deepCount(at url: URL, fm: FileManager) -> (Int, Int64) {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }

        var count = 0
        var bytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                count += 1
                bytes += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return (count, bytes)
    }

    private nonisolated static func immediateSubdirCount(at url: URL, fm: FileManager) -> Int {
        let contents = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        return contents?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.count ?? 0
    }
}

// MARK: - Comparison

enum MatchStatus { case match, mismatch, missing }

/// Folder names that look identical can differ invisibly (trailing spaces, case,
/// width/diacritic variants) across volumes and copy tools; treat those as the same folder.
func canonicalFolderName(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
}

@MainActor func statusFor(name: String, in columns: [FolderColumn]) -> MatchStatus {
    let key = canonicalFolderName(name)
    let entries = columns.compactMap { $0.subfolders.first(where: { canonicalFolderName($0.name) == key }) }
    guard entries.count == columns.count else { return .missing }
    let first = entries[0]
    return entries.dropFirst().allSatisfy({ $0.fileCount == first.fileCount && $0.byteSize == first.byteSize })
        ? .match : .mismatch
}

/// Explains a non-matching row with exact numbers, since the displayed sizes are
/// rounded and can look identical while the byte counts differ. Returns nil for matches.
@MainActor func statusDetail(name: String, in columns: [FolderColumn]) -> String? {
    let key = canonicalFolderName(name)
    let entries = columns.map { col in
        col.subfolders.first(where: { canonicalFolderName($0.name) == key })
    }
    let missingFrom = zip(columns, entries).filter { $0.1 == nil }.map { $0.0.path }
    if !missingFrom.isEmpty {
        return "Not found in:\n" + missingFrom.joined(separator: "\n")
    }
    let found = entries.compactMap { $0 }
    guard let first = found.first,
          found.dropFirst().contains(where: { $0.fileCount != first.fileCount || $0.byteSize != first.byteSize })
    else { return nil }
    return zip(columns, found).map { col, e in
        "\(col.path): \(e.fileCount.formatted()) files, \(e.byteSize.formatted()) bytes"
    }.joined(separator: "\n")
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
            lines.append("  " + rpad(sub.name, 32) + " " + lpad(sub.formattedSubfolderCount, 8) + "  " + lpad(sub.formattedCount, 8) + "  " + lpad(sub.formattedSize, 12))
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
    }

    return lines.joined(separator: "\n")
}
