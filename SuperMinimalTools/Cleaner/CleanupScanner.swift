//
//  CleanupScanner.swift
//  SuperMinimalTools
//

import Foundation

/// One concrete item (file or directory) a cleanup will act on.
nonisolated struct ScannedItem: Sendable {
    let url: URL
    let sizeBytes: Int64
}

nonisolated struct CategoryScanResult: Identifiable, Sendable {
    let category: CleanupCategory
    let items: [ScannedItem]
    /// nil means unknown (command-based cleanup with no size hint).
    let sizeBytes: Int64?
    /// True when a location exists but can't be read (usually missing Full Disk Access).
    let inaccessible: Bool

    var id: String { category.id }
}

/// Read-only: resolves each category to concrete items and sizes. Never deletes.
nonisolated enum CleanupScanner {

    static func scan(_ categories: [CleanupCategory]) async -> [CategoryScanResult] {
        await withTaskGroup(of: (Int, CategoryScanResult).self) { taskGroup in
            for (index, category) in categories.enumerated() {
                taskGroup.addTask { (index, scanCategory(category)) }
            }
            var results = [CategoryScanResult?](repeating: nil, count: categories.count)
            for await (index, result) in taskGroup {
                results[index] = result
            }
            return results.compactMap { $0 }
        }
    }

    static func scanCategory(_ category: CleanupCategory) -> CategoryScanResult {
        switch category.action {
        case .trashContents(let paths):
            var items: [ScannedItem] = []
            var inaccessible = false
            for path in paths {
                let (childURLs, denied) = children(of: expand(path), excluding: category.excludedNames)
                items.append(contentsOf: childURLs.map { ScannedItem(url: $0, sizeBytes: allocatedSize(at: $0)) })
                inaccessible = inaccessible || denied
            }
            return result(category, items: items, inaccessible: inaccessible)

        case .removeContents(let path):
            let (childURLs, denied) = children(of: expand(path), excluding: [])
            let items = childURLs.map { ScannedItem(url: $0, sizeBytes: allocatedSize(at: $0)) }
            return result(category, items: items, inaccessible: denied)

        case .command(_, _, let sizeHintPaths):
            let hintURLs = sizeHintPaths.map(expand).filter { FileManager.default.fileExists(atPath: $0.path) }
            let size = hintURLs.map { allocatedSize(at: $0) }.reduce(0, +)
            return CategoryScanResult(
                category: category,
                items: [],
                sizeBytes: hintURLs.isEmpty ? nil : size,
                inaccessible: false
            )

        case .findAndTrashDirectories(let root, let name, let maxDepth):
            let found = findDirectories(named: name, under: expand(root), maxDepth: maxDepth)
            let items = found.map { ScannedItem(url: $0, sizeBytes: allocatedSize(at: $0)) }
            return result(category, items: items, inaccessible: false)
        }
    }

    private static func result(_ category: CleanupCategory, items: [ScannedItem], inaccessible: Bool) -> CategoryScanResult {
        CategoryScanResult(
            category: category,
            items: items,
            sizeBytes: items.reduce(0) { $0 + $1.sizeBytes },
            inaccessible: inaccessible
        )
    }

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Immediate children of a directory. `denied` is true when the directory
    /// exists but can't be read.
    static func children(of url: URL, excluding excludedNames: [String]) -> (children: [URL], denied: Bool) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return ([], false) }
        do {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
            let filtered = contents.filter {
                !excludedNames.contains($0.lastPathComponent) && $0.lastPathComponent != ".DS_Store"
            }
            return (filtered, false)
        } catch {
            return ([], true)
        }
    }

    /// Allocated size of a file or directory tree, in bytes.
    static func allocatedSize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]

        func fileSize(_ fileURL: URL) -> Int64 {
            let values = try? fileURL.resourceValues(forKeys: keys)
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }

        guard isDirectory.boolValue else { return fileSize(url) }

        var total: Int64 = 0
        let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        )
        while let item = enumerator?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Finds directories with the given name (e.g. node_modules), pruning below
    /// maxDepth and never descending into a match.
    static func findDirectories(named name: String, under root: URL, maxDepth: Int) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var found: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if item.lastPathComponent == name {
                found.append(item)
                enumerator.skipDescendants()
            } else if enumerator.level >= maxDepth {
                enumerator.skipDescendants()
            }
        }
        return found
    }
}
