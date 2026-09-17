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

        let found = CleanupScanner.findDirectories(named: "node_modules", under: fixture, maxDepth: 5)
        #expect(found.map(\.lastPathComponent) == ["node_modules"])
        #expect(found.first?.deletingLastPathComponent().lastPathComponent == "project")
    }
}
