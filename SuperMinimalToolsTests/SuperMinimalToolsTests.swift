//
//  SuperMinimalToolsTests.swift
//  SuperMinimalToolsTests
//

import Testing
import Foundation
@testable import SuperMinimalTools

struct ByteFormattingTests {

    @Test func compactRateFormatsAcrossMagnitudes() {
        #expect(ByteFormatting.compactRate(0) == "0K")
        #expect(ByteFormatting.compactRate(500) == "0K")
        #expect(ByteFormatting.compactRate(1024) == "1K")
        #expect(ByteFormatting.compactRate(210 * 1024) == "210K")
        #expect(ByteFormatting.compactRate(1.4 * 1024 * 1024) == "1.4M")
        #expect(ByteFormatting.compactRate(2.1 * 1024 * 1024 * 1024) == "2.1G")
    }

    @Test func negativeRatesClampToZero() {
        #expect(ByteFormatting.compactRate(-100) == "0K")
    }
}

struct BandwidthMathTests {

    @Test func computesPerSecondRates() {
        let reading = BandwidthMonitor.rate(
            previous: (received: 1_000, sent: 2_000),
            current: (received: 5_000, sent: 3_000),
            elapsedSeconds: 2
        )
        #expect(reading?.downloadBytesPerSecond == 2_000)
        #expect(reading?.uploadBytesPerSecond == 500)
    }

    @Test func counterResetProducesZeroInsteadOfSpike() {
        let reading = BandwidthMonitor.rate(
            previous: (received: 5_000, sent: 5_000),
            current: (received: 100, sent: 100),
            elapsedSeconds: 2
        )
        #expect(reading?.downloadBytesPerSecond == 0)
        #expect(reading?.uploadBytesPerSecond == 0)
    }

    @Test func nonPositiveElapsedReturnsNil() {
        let reading = BandwidthMonitor.rate(
            previous: (received: 0, sent: 0),
            current: (received: 10, sent: 10),
            elapsedSeconds: 0
        )
        #expect(reading == nil)
    }
}

struct CleanupCatalogTests {

    @Test func allPathsStayInsideUserHome() {
        for category in CleanupCategory.catalog {
            for path in category.involvedPaths {
                #expect(path.hasPrefix("~/"), "\(category.id): \(path) must live inside the user home")
            }
        }
    }

    @Test func onlySafeCategoriesAreCheckedByDefault() {
        for category in CleanupCategory.catalog {
            #expect(category.isCheckedByDefault == (category.safety == .safe))
        }
    }

    @Test func externallyManagedToolsAreCleanedViaTheirOwnCLI() {
        for id in ["unavailable-simulators", "homebrew", "docker"] {
            let category = CleanupCategory.catalog.first { $0.id == id }
            #expect(category?.action.isCommand == true, "\(id) must be cleaned via its own CLI, never raw file deletion")
        }
    }

    @Test func riskyCategoriesAreMarkedCaution() {
        for id in ["xcode-archives", "ml-model-caches", "docker", "node-modules", "android-system-images"] {
            let category = CleanupCategory.catalog.first { $0.id == id }
            #expect(category?.safety == .caution, "\(id) must be opt-in")
        }
    }
}

struct CleanupScannerTests {

    @Test func measuresFixtureDirectorySize() throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory
            .appendingPathComponent("smt-fixture-\(UUID().uuidString)")
        try fileManager.createDirectory(
            at: fixture.appendingPathComponent("nested"),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: fixture) }
        try Data(repeating: 1, count: 4096).write(to: fixture.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 4096).write(to: fixture.appendingPathComponent("nested/b.bin"))

        #expect(CleanupScanner.allocatedSize(at: fixture) >= 8_192)
    }

    @Test func listsChildrenAndHonorsExclusions() throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory
            .appendingPathComponent("smt-children-\(UUID().uuidString)")
        try fileManager.createDirectory(
            at: fixture.appendingPathComponent("skipme"),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: fixture) }
        try Data(repeating: 0, count: 16).write(to: fixture.appendingPathComponent("keep.txt"))

        let (children, denied) = CleanupScanner.children(of: fixture, excluding: ["skipme"])
        #expect(!denied)
        #expect(children.map(\.lastPathComponent) == ["keep.txt"])
    }

    @Test func missingDirectoryYieldsNoChildrenAndNoDenial() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let (children, denied) = CleanupScanner.children(of: missing, excluding: [])
        #expect(children.isEmpty)
        #expect(!denied)
    }

    @Test func findsNamedDirectoriesAndPrunesInsideMatches() throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory
            .appendingPathComponent("smt-find-\(UUID().uuidString)")
        // project/node_modules/nested/node_modules must NOT be reported twice.
        let outer = fixture.appendingPathComponent("project/node_modules")
        try fileManager.createDirectory(
            at: outer.appendingPathComponent("nested/node_modules"),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: fixture) }

        let found = CleanupScanner.findProjectArtifacts(
            under: fixture,
            rules: [ProjectArtifactRule(directoryName: "node_modules", markers: [])],
            maxDepth: 5
        )
        #expect(found.map(\.lastPathComponent) == ["node_modules"])
        #expect(found.first?.deletingLastPathComponent().lastPathComponent == "project")
    }

    @Test func buildFoldersOnlyMatchNextToTheirProjectMarker() throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory
            .appendingPathComponent("smt-artifacts-\(UUID().uuidString)")
        for folder in ["flutter_app/build", "flutter_app/.dart_tool", "notes/build", "rust/target"] {
            try fileManager.createDirectory(at: fixture.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: fixture) }
        try Data().write(to: fixture.appendingPathComponent("flutter_app/pubspec.yaml"))
        try Data().write(to: fixture.appendingPathComponent("rust/Cargo.toml"))

        let found = CleanupScanner.findProjectArtifacts(
            under: fixture,
            rules: [
                ProjectArtifactRule(directoryName: "build", markers: ["pubspec.yaml"]),
                ProjectArtifactRule(directoryName: ".dart_tool", markers: ["pubspec.yaml"]),
                ProjectArtifactRule(directoryName: "target", markers: ["Cargo.toml"]),
            ],
            maxDepth: 4
        )
        let relative = Set(found.map { "\($0.deletingLastPathComponent().lastPathComponent)/\($0.lastPathComponent)" })
        #expect(relative == ["flutter_app/build", "flutter_app/.dart_tool", "rust/target"])
    }

    @Test func findsFilesByExtensionAndSize() throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory
            .appendingPathComponent("smt-files-\(UUID().uuidString)")
        try fileManager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixture) }
        try Data(repeating: 1, count: 64 * 1024).write(to: fixture.appendingPathComponent("Big.DMG"))
        try Data(repeating: 1, count: 16).write(to: fixture.appendingPathComponent("small.dmg"))
        try Data(repeating: 1, count: 64 * 1024).write(to: fixture.appendingPathComponent("movie.mov"))

        let installers = CleanupScanner.findFiles(under: fixture, extensions: ["dmg"], minBytes: 0, maxDepth: 2)
        #expect(Set(installers.map(\.url.lastPathComponent)) == ["Big.DMG", "small.dmg"])

        let large = CleanupScanner.findFiles(under: fixture, extensions: [], minBytes: 32 * 1024, maxDepth: 2)
        #expect(Set(large.map(\.url.lastPathComponent)) == ["Big.DMG", "movie.mov"])
    }

    @Test func overlappingItemsAreKeptOnlyInTheFirstCategory() {
        let shared = ScannedItem(url: URL(fileURLWithPath: "/tmp/x.dmg"), sizeBytes: 10)
        let first = CategoryScanResult(category: CleanupCategory.catalog[0], items: [shared], sizeBytes: 10, inaccessible: false)
        let second = CategoryScanResult(category: CleanupCategory.catalog[1], items: [shared], sizeBytes: 10, inaccessible: false)

        let deduped = CleanupScanner.removingDuplicateItems([first, second])
        #expect(deduped[0].items.count == 1)
        #expect(deduped[1].items.isEmpty)
        #expect(deduped[1].sizeBytes == 0)
    }
}

struct DeletionGuardTests {
    let home = "/Users/tester"

    private func reason(_ path: String) -> String? {
        DeletionGuard.refusalReason(for: URL(fileURLWithPath: path), home: home)
    }

    @Test func refusesEverythingOutsideHome() {
        #expect(reason("/Applications/Xcode.app") != nil)
        #expect(reason("/Library/Developer") != nil)
        #expect(reason("/Users/other/file") != nil)
        #expect(reason("/Users/tester") != nil)
    }

    @Test func refusesStandardFoldersButAllowsTheirContents() {
        #expect(reason("/Users/tester/Library") != nil)
        #expect(reason("/Users/tester/Downloads") != nil)
        #expect(reason("/Users/tester/Library/Caches") != nil)
        #expect(reason("/Users/tester/Library/Application Support") != nil)
        #expect(reason("/Users/tester/Downloads/big.dmg") == nil)
        #expect(reason("/Users/tester/Library/Caches/com.google.Chrome") == nil)
        #expect(reason("/Users/tester/Library/Developer/CoreSimulator/Devices/ABC") == nil)
        #expect(reason("/Users/tester/.gradle") == nil)
    }

    @Test func refusesSensitiveSubtrees() {
        #expect(reason("/Users/tester/.ssh") != nil)
        #expect(reason("/Users/tester/.ssh/id_ed25519") != nil)
        #expect(reason("/Users/tester/Library/Keychains/login.keychain-db") != nil)
    }

    @Test func pathTricksCannotEscapeTheGuard() {
        #expect(reason("/Users/tester/Downloads/../Library") != nil)
        #expect(reason("/Users/testerX/file") != nil)
    }
}

struct FolderSizerTests {

    @Test func measuresTreeAndCachesLargeSubfolders() throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory
            .appendingPathComponent("smt-sizer-\(UUID().uuidString)")
        let big = fixture.appendingPathComponent("big")
        try fileManager.createDirectory(at: big, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fixture.appendingPathComponent("small"), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixture) }
        try Data(repeating: 1, count: 2 * 1024 * 1024).write(to: big.appendingPathComponent("blob"))
        try Data(repeating: 1, count: 10).write(to: fixture.appendingPathComponent("small/tiny"))

        var totals: [String: Int64] = [:]
        let size = FolderSizer.measure(fixture, into: &totals)
        #expect((size ?? 0) >= 2 * 1024 * 1024)
        #expect(totals[big.standardizedFileURL.path] != nil)
        #expect(totals[fixture.appendingPathComponent("small").standardizedFileURL.path] == nil)
    }
}
