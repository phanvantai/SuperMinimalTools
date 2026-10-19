//
//  FolderBrowser.swift
//  SuperMinimalTools
//

import Foundation

/// Decides which paths may ever be deleted. Browsing is allowed anywhere, but
/// deletion is limited to items inside the user's home that are not part of
/// its standard skeleton (~/Library, ~/Documents, ~/Library/Preferences…).
nonisolated enum DeletionGuard {

    /// Folders directly in home that must never be removed as a whole.
    static let protectedHomeChildren: Set<String> = [
        "Applications", "Desktop", "Developer", "Documents", "Downloads", "Library",
        "Movies", "Music", "Pictures", "Public", ".Trash",
    ]

    /// Folders (inside home) that must not be touched at all, including their contents.
    static let protectedSubtrees = [".ssh", ".gnupg", "Library/Keychains", "Library/Mobile Documents"]

    static func refusalReason(for url: URL, home: String = NSHomeDirectory()) -> String? {
        let path = url.standardizedFileURL.path
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(homePrefix) else { return "outside your home folder" }

        let relative = String(path.dropFirst(homePrefix.count))
        let components = relative.split(separator: "/").map(String.init)
        guard let first = components.first else { return "your home folder" }

        if components.count == 1, protectedHomeChildren.contains(first) {
            return "a standard macOS folder"
        }
        // ~/Library/Caches, ~/Library/Preferences… are system-managed
        // containers; their contents may go, the folders themselves may not.
        if components.count == 2, first == "Library" {
            return "a standard Library folder"
        }
        for subtree in protectedSubtrees where relative == subtree || relative.hasPrefix(subtree + "/") {
            return "protected (\(subtree))"
        }
        return nil
    }

    static func canDelete(_ url: URL) -> Bool {
        refusalReason(for: url) == nil
    }
}

/// Measures directory trees and remembers the size of every sizable
/// directory it walked, so drilling into a subfolder is instant.
nonisolated enum FolderSizer {

    /// Directories smaller than this are not cached; re-measuring them is cheap.
    static let cacheThreshold: Int64 = 1024 * 1024

    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isVolumeKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    /// Runs off the caller's actor. Returns nil when the task was cancelled.
    @concurrent
    static func measure(_ url: URL) async -> (size: Int64, directoryTotals: [String: Int64])? {
        var totals: [String: Int64] = [:]
        guard let size = measure(url, into: &totals) else { return nil }
        return (size, totals)
    }

    /// Allocated size of a directory tree. Symlinks and other mounted volumes
    /// are not followed, so "/" or "~" never count anything twice.
    static func measure(_ url: URL, into totals: inout [String: Int64]) -> Int64? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for child in children {
            if Task.isCancelled { return nil }
            guard let values = try? child.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true, values.isSymbolicLink != true {
                if values.isVolume == true { continue }
                guard let childSize = measure(child, into: &totals) else { return nil }
                total += childSize
            } else {
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
        }
        if total >= cacheThreshold {
            totals[url.standardizedFileURL.path] = total
        }
        return total
    }
}

nonisolated struct FolderEntry: Identifiable, Sendable {
    let url: URL
    /// Can be opened in the browser (a directory that is not an app/bundle).
    let isBrowsable: Bool
    let isDirectory: Bool
    /// nil while the folder is still being measured.
    var sizeBytes: Int64?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

@Observable
@MainActor
final class FolderBrowserModel {

    private(set) var currentURL: URL
    private(set) var entries: [FolderEntry] = []
    private(set) var listingError: String?
    private(set) var isMeasuring = false
    private(set) var isDeleting = false
    /// Selected items keyed by path; the selection survives navigation so
    /// items from several folders can be removed in one go.
    private(set) var selection: [String: URL] = [:]
    var deletePermanently = false
    private(set) var lastFreedBytes: Int64?
    private(set) var failures: [String] = []
    /// Bumped after every deletion so other views can refresh.
    private(set) var deletionCount = 0

    private var sizeCache: [String: Int64] = [:]
    private var measureTask: Task<Void, Never>?

    init(startAt url: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        currentURL = url.standardizedFileURL
    }

    // MARK: - Navigation

    var breadcrumbs: [URL] {
        var crumbs: [URL] = []
        var url = currentURL
        while true {
            crumbs.insert(url, at: 0)
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent.path == url.path { break }
            url = parent
        }
        return crumbs
    }

    var canGoUp: Bool { currentURL.path != "/" }

    func open(_ url: URL) {
        currentURL = url.standardizedFileURL
        reload()
    }

    func goUp() {
        guard canGoUp else { return }
        open(currentURL.deletingLastPathComponent())
    }

    /// Lists the current folder, reusing cached sizes and measuring the rest
    /// in the background. `remeasure` drops the cache for this folder first.
    func reload(remeasure: Bool = false) {
        measureTask?.cancel()
        if remeasure {
            forgetCachedSizes(under: currentURL.path)
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
            listingError = nil
        } catch {
            entries = []
            listingError = error.localizedDescription
            isMeasuring = false
            return
        }

        entries = contents
            .filter { $0.lastPathComponent != ".DS_Store" }
            .map { url in
                let values = try? url.resourceValues(forKeys: keys)
                let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
                let path = url.standardizedFileURL.path
                let size: Int64? = isDirectory
                    ? sizeCache[path]
                    : Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
                if !isDirectory, let size { sizeCache[path] = size }
                return FolderEntry(
                    url: url.standardizedFileURL,
                    isBrowsable: isDirectory && values?.isPackage != true,
                    isDirectory: isDirectory,
                    sizeBytes: size
                )
            }
        sortEntries()
        measureMissingSizes()
    }

    private func measureMissingSizes() {
        let pending = entries.filter { $0.sizeBytes == nil }.map(\.url)
        guard !pending.isEmpty else {
            isMeasuring = false
            return
        }
        isMeasuring = true
        measureTask = Task { [weak self] in
            await withTaskGroup(of: (URL, (size: Int64, directoryTotals: [String: Int64])?).self) { group in
                var queue = pending.makeIterator()
                // A few walkers in parallel keep the disk busy without
                // starving the rest of the system.
                for _ in 0..<4 {
                    guard let url = queue.next() else { break }
                    group.addTask { (url, await FolderSizer.measure(url)) }
                }
                for await (url, measured) in group {
                    if let measured {
                        self?.apply(measured.size, directoryTotals: measured.directoryTotals, to: url)
                    }
                    if let next = queue.next() {
                        group.addTask { (next, await FolderSizer.measure(next)) }
                    }
                }
            }
            if !Task.isCancelled {
                self?.isMeasuring = false
            }
        }
    }

    private func apply(_ size: Int64, directoryTotals: [String: Int64], to url: URL) {
        sizeCache.merge(directoryTotals) { _, new in new }
        sizeCache[url.path] = size
        guard let index = entries.firstIndex(where: { $0.url == url }) else { return }
        entries[index].sizeBytes = size
        sortEntries()
    }

    private func sortEntries() {
        entries.sort { lhs, rhs in
            switch (lhs.sizeBytes, rhs.sizeBytes) {
            case let (left?, right?) where left != right: return left > right
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    var currentTotalBytes: Int64 {
        entries.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    func cachedSize(of url: URL) -> Int64? {
        sizeCache[url.standardizedFileURL.path]
    }

    /// Drops cached sizes for a path and everything below it.
    private func forgetCachedSizes(under path: String) {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        sizeCache = sizeCache.filter { $0.key != path && !$0.key.hasPrefix(prefix) }
    }

    func invalidateAllSizes() {
        sizeCache.removeAll()
    }

    // MARK: - Selection

    func isSelected(_ entry: FolderEntry) -> Bool {
        selection[entry.url.path] != nil
    }

    func setSelected(_ selected: Bool, entry: FolderEntry) {
        guard DeletionGuard.canDelete(entry.url) else { return }
        selection[entry.url.path] = selected ? entry.url : nil
    }

    func clearSelection() {
        selection.removeAll()
    }

    /// Selected items without the ones already covered by a selected ancestor.
    private var effectiveSelection: [URL] {
        let paths = selection.keys.sorted()
        var kept: [String] = []
        for path in paths where !kept.contains(where: { path.hasPrefix($0 + "/") }) {
            kept.append(path)
        }
        return kept.compactMap { selection[$0] }
    }

    var selectedCount: Int { effectiveSelection.count }

    /// Known size of the selection; items still being measured count as 0.
    var selectedBytes: Int64 {
        effectiveSelection.reduce(0) { $0 + (cachedSize(of: $1) ?? 0) }
    }

    var selectionHasUnmeasuredItems: Bool {
        effectiveSelection.contains { cachedSize(of: $0) == nil }
    }

    // MARK: - Deletion

    func deleteSelected() async {
        guard !isDeleting else { return }
        let items = effectiveSelection.map { ScannedItem(url: $0, sizeBytes: cachedSize(of: $0) ?? 0) }
        guard !items.isEmpty else { return }
        isDeleting = true
        measureTask?.cancel()
        let permanently = deletePermanently
        let outcome = await Task.detached(priority: .userInitiated) {
            CleanupEngine.remove(items, permanently: permanently)
        }.value

        for path in outcome.removedPaths {
            let removedSize = sizeCache[path] ?? 0
            forgetCachedSizes(under: path)
            // Keep ancestors' cached totals honest without re-walking them.
            var ancestor = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
            while true {
                if let total = sizeCache[ancestor.path] {
                    sizeCache[ancestor.path] = max(0, total - removedSize)
                }
                let parent = ancestor.deletingLastPathComponent().standardizedFileURL
                if parent.path == ancestor.path { break }
                ancestor = parent
            }
            selection = selection.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        }
        lastFreedBytes = outcome.freedBytes
        failures = outcome.failures
        deletionCount += 1
        isDeleting = false
        reload()
    }
}
