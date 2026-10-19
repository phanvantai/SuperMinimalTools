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
            return removingDuplicateItems(results.compactMap { $0 })
        }
    }

    /// Locations can overlap (a large .dmg is also an installer); an item is
    /// kept only in the first category that found it so it is never counted
    /// or deleted twice.
    static func removingDuplicateItems(_ results: [CategoryScanResult]) -> [CategoryScanResult] {
        var seenPaths = Set<String>()
        return results.map { result in
            guard !result.category.action.isCommand else { return result }
            let unique = result.items.filter { seenPaths.insert($0.url.path).inserted }
            guard unique.count != result.items.count else { return result }
            return Self.result(result.category, items: unique, inaccessible: result.inaccessible)
        }
    }

    static func scanCategory(_ category: CleanupCategory) -> CategoryScanResult {
        switch category.action {
        case .trashContents(let paths):
            var childURLs: [URL] = []
            var inaccessible = false
            for path in paths {
                let (children, denied) = children(of: expand(path), excluding: category.excludedNames)
                childURLs.append(contentsOf: children)
                inaccessible = inaccessible || denied
            }
            return result(category, items: sizedItems(childURLs), inaccessible: inaccessible)

        case .removeContents(let path):
            let (childURLs, denied) = children(of: expand(path), excluding: [])
            return result(category, items: sizedItems(childURLs), inaccessible: denied)

        case .command(_, _, let sizeHintPaths):
            let hintURLs = sizeHintPaths.map(expand).filter { FileManager.default.fileExists(atPath: $0.path) }
            let size = hintURLs.map { allocatedSize(at: $0) }.reduce(0, +)
            return CategoryScanResult(
                category: category,
                items: [],
                sizeBytes: hintURLs.isEmpty ? nil : size,
                inaccessible: false
            )

        case .findProjectArtifacts(let roots, let rules, let maxDepth):
            var found: [URL] = []
            var seen = Set<String>()
            for root in roots {
                for url in findProjectArtifacts(under: expand(root), rules: rules, maxDepth: maxDepth)
                where seen.insert(url.resolvingSymlinksInPath().path).inserted {
                    found.append(url)
                }
            }
            return result(category, items: sizedItems(found), inaccessible: false)

        case .findFiles(let roots, let extensions, let minBytes, let maxDepth):
            var items: [ScannedItem] = []
            for root in roots {
                items += findFiles(under: expand(root), extensions: extensions, minBytes: minBytes, maxDepth: maxDepth)
            }
            return result(category, items: items, inaccessible: false)
        }
    }

    /// Sizes many items in parallel; a single cache folder can hold hundreds
    /// of children and walking them one by one dominates the scan time.
    static func sizedItems(_ urls: [URL]) -> [ScannedItem] {
        guard !urls.isEmpty else { return [] }
        let sizes = UnsafeMutableBufferPointer<Int64>.allocate(capacity: urls.count)
        defer { sizes.deallocate() }
        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            sizes[index] = allocatedSize(at: urls[index])
        }
        return urls.indices.map { ScannedItem(url: urls[$0], sizeBytes: sizes[$0]) }
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

    /// Finds project artifact directories (node_modules, Flutter build, Rust
    /// target…), pruning below maxDepth and never descending into a match.
    /// Hidden folders are only entered when no rule matches them and they are
    /// not a hidden tool folder (.git etc.), which keeps the walk fast.
    static func findProjectArtifacts(under root: URL, rules: [ProjectArtifactRule], maxDepth: Int) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        let rulesByName = Dictionary(grouping: rules, by: \.directoryName)
        var found: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let name = item.lastPathComponent

            if let candidates = rulesByName[name] {
                let parent = item.deletingLastPathComponent()
                let matches = candidates.contains { rule in
                    rule.markers.isEmpty || rule.markers.contains {
                        fileManager.fileExists(atPath: parent.appendingPathComponent($0).path)
                    }
                }
                if matches {
                    found.append(item)
                    enumerator.skipDescendants()
                    continue
                }
            }
            // Never search inside dependency trees or hidden tool folders.
            if name.hasPrefix(".") || name == "node_modules" || name == "Pods" || enumerator.level >= maxDepth {
                enumerator.skipDescendants()
            }
        }
        return found
    }

    /// Regular files under root whose extension is in `extensions` (empty
    /// means any) and whose allocated size is at least `minBytes`.
    static func findFiles(under root: URL, extensions: Set<String>, minBytes: Int64, maxDepth: Int) -> [ScannedItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var found: [ScannedItem] = []
        while let item = enumerator.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if item.lastPathComponent == "node_modules" || enumerator.level >= maxDepth {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            if !extensions.isEmpty, !extensions.contains(item.pathExtension.lowercased()) { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            if size >= minBytes {
                found.append(ScannedItem(url: item, sizeBytes: size))
            }
        }
        return found
    }
}
