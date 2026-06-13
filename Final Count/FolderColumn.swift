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

    var formattedSize: String { ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file) }
    var formattedCount: String { fileCount.formatted() }
    var formattedSubfolderCount: String { subfolderCount > 0 ? subfolderCount.formatted() : "—" }
}

@MainActor
class FolderColumn: ObservableObject, Identifiable {
    let id = UUID()

    @Published var url: URL?
    @Published var subfolders: [SubfolderInfo] = []
    @Published var isLoading = false
    @Published var totalFiles: Int = 0
    @Published var totalBytes: Int64 = 0

    var name: String { url?.lastPathComponent ?? "" }
    var path: String { url?.path ?? "" }

    func load(from newURL: URL) {
        url = newURL
        subfolders = []
        totalFiles = 0
        totalBytes = 0
        isLoading = true

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                FolderColumn.analyzeDirectory(url: newURL)
            }.value
            self.subfolders = result.subfolders
            self.totalFiles = result.totalFiles
            self.totalBytes = result.totalBytes
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

    private nonisolated static func analyzeDirectory(url: URL) -> (subfolders: [SubfolderInfo], totalFiles: Int, totalBytes: Int64) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], 0, 0) }

        var infos: [SubfolderInfo] = []
        var grandTotalFiles = 0
        var grandTotalBytes: Int64 = 0

        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
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
        }

        return (infos, grandTotalFiles, grandTotalBytes)
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

@MainActor func statusFor(name: String, in columns: [FolderColumn]) -> MatchStatus {
    let entries = columns.compactMap { $0.subfolders.first(where: { $0.name == name }) }
    guard entries.count == columns.count else { return .missing }
    let first = entries[0]
    return entries.dropFirst().allSatisfy({ $0.fileCount == first.fileCount && $0.byteSize == first.byteSize })
        ? .match : .mismatch
}

@MainActor func allSubfolderNames(in columns: [FolderColumn]) -> [String] {
    Array(Set(columns.flatMap { $0.subfolders.map(\.name) })).sorted()
}

// MARK: - Export

private func rpad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
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
        let totalLabel = "TOTAL (\(col.subfolders.count) folders)"
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
