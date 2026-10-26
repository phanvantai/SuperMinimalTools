//
//  SuperMinimalToolsTests.swift
//  SuperMinimalToolsTests
//

import Testing
import Foundation
import AppKit
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

@MainActor
struct ClipboardHistoryTests {

    private func makeHistory(storageURL: URL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString).appending(path: "clipboard-history.json")) -> ClipboardHistory {
        let defaults = UserDefaults(suiteName: "ClipboardHistoryTests-\(UUID().uuidString)")!
        return ClipboardHistory(defaults: defaults, storageURL: storageURL)
    }

    @Test func copyingTheSameTextAgainMovesItToTheTop() {
        let history = makeHistory()
        history.record("first", sourceBundleID: nil)
        history.record("second", sourceBundleID: nil)
        history.record("first", sourceBundleID: nil)
        #expect(history.items.map(\.text) == ["first", "second"])
    }

    @Test func blankAndOversizedTextIsSkipped() {
        let history = makeHistory()
        history.record("  \n\t", sourceBundleID: nil)
        history.record(String(repeating: "x", count: ClipboardHistory.maxTextBytes + 1), sourceBundleID: nil)
        #expect(history.items.isEmpty)
    }

    @Test func keepsOnlyTheNewestItems() {
        let history = makeHistory()
        for index in 0...ClipboardHistory.maxItems {
            history.record("item \(index)", sourceBundleID: nil)
        }
        #expect(history.items.count == ClipboardHistory.maxItems)
        #expect(history.items.first?.text == "item \(ClipboardHistory.maxItems)")
        #expect(!history.items.contains { $0.text == "item 0" })
    }

    @Test func passwordManagerContentIsNotRecorded() {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        #expect(ClipboardHistory.shouldRecord(types: [.string]))
        #expect(!ClipboardHistory.shouldRecord(types: [.string, concealed]))
        #expect(!ClipboardHistory.shouldRecord(types: [.png]))
    }

    @Test func historySurvivesARelaunch() {
        let storageURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString).appending(path: "clipboard-history.json")
        makeHistory(storageURL: storageURL).record("kept", sourceBundleID: "com.apple.Safari")
        let reloaded = makeHistory(storageURL: storageURL)
        #expect(reloaded.items.map(\.text) == ["kept"])
        #expect(reloaded.items.first?.sourceBundleID == "com.apple.Safari")
    }
}

struct TelexTests {

    private func type(_ keys: String) -> String {
        Telex.compose(Array(keys))
    }

    @Test func composesMarksAndTones() {
        #expect(type("vieetj") == "việt")
        #expect(type("tieengs") == "tiếng")
        #expect(type("nguwowif") == "người")
        #expect(type("nguowif") == "người")
        #expect(type("dduwowngf") == "đường")
        #expect(type("chuyeenr") == "chuyển")
        #expect(type("muaw") == "mưa")
        #expect(type("cuwux") == "cữu")
        #expect(type("awns") == "ắn")
        #expect(type("baanf") == "bần")
        #expect(type("Ddaauf") == "Đầu")
        #expect(type("VIEETJ") == "VIỆT")
    }

    @Test func tonesTypedAfterTheFinalConsonant() {
        #expect(type("vietej") == "việt")
        #expect(type("tooi") == "tôi")
        #expect(type("toio") == "tôi")
        #expect(type("cacs") == "các")
    }

    @Test func placesTonesTheModernWay() {
        #expect(type("hoaf") == "hoà")
        #expect(type("khoer") == "khoẻ")
        #expect(type("thuys") == "thuý")
        #expect(type("cuar") == "của")
        #expect(type("mias") == "mía")
        #expect(type("hoanf") == "hoàn")
        #expect(type("ngoaif") == "ngoài")
        #expect(type("thuowr") == "thuở")
    }

    @Test func quAndGiBelongToTheInitial() {
        #expect(type("quas") == "quá")
        #expect(type("quyeets") == "quyết")
        #expect(type("gif") == "gì")
        #expect(type("giaf") == "già")
        #expect(type("giuwx") == "giữ")
        #expect(type("gieengs") == "giếng")
    }

    @Test func bareWIsU() {
        #expect(type("w") == "ư")
        #expect(type("nhw") == "như")
        #expect(type("wf") == "ừ")
        #expect(type("ww") == "w")
    }

    @Test func pressingAMarkKeyTwiceTypesIt() {
        #expect(type("ass") == "as")
        #expect(type("aaa") == "aa")
        #expect(type("ddd") == "dd")
        #expect(type("aww") == "aw")
        #expect(type("asz") == "a")
    }

    @Test func wordsThatCannotBeVietnameseStayAsTyped() {
        #expect(type("string") == "string")
        #expect(type("what") == "what")
        #expect(type("class") == "class")
        #expect(type("google") == "google")
        #expect(type("facebook") == "facebook")
        #expect(type("react") == "react")
        #expect(type("hello") == "hello")
        #expect(type("ko") == "ko")
    }

    @Test func behavesLikePHTV() {
        // A d anywhere in the word.
        #expect(type("did") == "đi")
        #expect(type("dieend") == "điên")
        #expect(type("ddid") == "did")
        // ưo before more letters becomes ươ.
        #expect(type("dduwong") == "đương")
        #expect(type("dduwongf") == "đường")
        #expect(type("nguwoif") == "người")
        // Repeating a letter stretches the word.
        #expect(type("ddepjppp") == "đẹpppp")
        #expect(type("ddiii") == "điii")
        #expect(type("ddifii") == "đìii")
        #expect(type("khoongggg") == "khôngggg")
        #expect(type("quasaa") == "quáaa")
        #expect(type("owiii") == "ơiii")
        // No ư after loanword initials.
        #expect(type("fw") == "fw")
        #expect(type("jw") == "jw")
    }

    @Test func abbreviationsKeepTheirD() {
        #expect(type("ddc") == "đc")
        #expect(type("ddt") == "đt")
        #expect(type("Ddhs") == "Đhs")
        #expect(type("DDC") == "ĐC")
        #expect(Telex.compose(Telex.keys(for: "đc")) == "đc")
    }

    @Test func keysRoundTripThroughText() {
        for word in ["người", "tiếng", "đường", "thuở", "quyết", "giữ", "ăn", "Việt", "hoà", "mưa", "string"] {
            #expect(Telex.compose(Telex.keys(for: word)) == word, "\(word)")
        }
    }

    @Test func composesEveryWordOfARealSentence() {
        let sentence = """
            Tôi yêu tiếng nước tôi từ khi mới ra đời người ơi mẹ hiền ru những câu xa vời \
            khuỷu tay huýt sáo khuếch tán nghiêng ngả quyển truyện giường chiếu oẳn tù tì \
            thuở xưa hươu nai khuya rồi ngoẵng ngoéo dặn dò bướm lượn cửa sổ giặt giũ \
            quốc gia Đà Nẵng Huế Sài Gòn những ngày xưa thân ái khoẻ không đấy
            """
        for word in sentence.split(separator: " ").map(String.init) {
            #expect(Telex.compose(Telex.keys(for: word)) == word, "\(word)")
        }
    }
}

struct TelexSessionTests {

    @Test func plainKeysPassThroughAndMarksRewriteTheWord() {
        var session = TelexSession()
        #expect(session.type("v") == .init(backspaces: 0, text: "v"))
        #expect(session.type("i") == .init(backspaces: 0, text: "i"))
        #expect(session.type("e") == .init(backspaces: 0, text: "e"))
        #expect(session.type("e") == .init(backspaces: 1, text: "ê"))
        #expect(session.type("t") == .init(backspaces: 0, text: "t"))
        #expect(session.type("j") == .init(backspaces: 2, text: "ệt"))
        #expect(session.text == "việt")
    }

    @Test func nonLettersEndTheWord() {
        var session = TelexSession()
        _ = session.type("a")
        #expect(session.type(" ") == nil)
        #expect(session.type("s") == .init(backspaces: 0, text: "s"))
    }

    @Test func backspaceKeepsTheRestOfTheWordEditable() {
        var session = TelexSession()
        for key in "tieengs" { _ = session.type(key) }
        #expect(session.deleteBackward() == nil)
        #expect(session.text == "tiến")
        #expect(session.type("j") == .init(backspaces: 2, text: "ện"))
    }

    @Test func backspaceInAWordShownAsTypedComposesItAgain() {
        var session = TelexSession()
        for key in "vieetj" { _ = session.type(key) }
        #expect(session.type("n") == .init(backspaces: 2, text: "eetjn"))
        #expect(session.deleteBackward() == .init(backspaces: 5, text: "ệt"))
        #expect(session.text == "việt")
    }

    @Test func backspacingOverASpaceGoesBackToThePreviousWord() {
        var session = TelexSession()
        for key in "vieet  " { _ = session.type(key) }
        #expect(session.deleteBackward() == nil)
        #expect(session.deleteBackward() == nil)
        #expect(session.type("j") == .init(backspaces: 2, text: "ệt"))
    }

    @Test func otherKeysForgetThePreviousWord() {
        var session = TelexSession()
        for key in "viet ." { _ = session.type(key) }
        _ = session.deleteBackward()
        _ = session.deleteBackward()
        #expect(session.type("j") == .init(backspaces: 0, text: "j"))
    }

    @Test func fallingBackToTheTypedKeysRewritesTheWord() {
        var session = TelexSession()
        #expect(session.type("w") == .init(backspaces: 0, text: "ư"))
        #expect(session.type("h") == .init(backspaces: 1, text: "wh"))
    }
}
