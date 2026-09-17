//
//  CleanupCategory.swift
//  SuperMinimalTools
//

import Foundation

nonisolated enum CleanupSafety: Sendable {
    /// Regenerated automatically by its owning tool; checked by default.
    case safe
    /// Has a real cost (large re-download, lost data); unchecked by default.
    case caution
}

nonisolated enum CleanupAction: Sendable {
    /// Move the contents of each directory to the Trash (keeps the directory itself).
    case trashContents([String])
    /// Permanently remove the contents of a directory (used for the Trash itself).
    case removeContents(String)
    /// Run a maintenance command from the tool's own CLI instead of touching files.
    case command(executable: String, arguments: [String], sizeHintPaths: [String])
    /// Find directories with the given name under a root and trash the matches.
    case findAndTrashDirectories(root: String, named: String, maxDepth: Int)

    var isCommand: Bool {
        if case .command = self { return true }
        return false
    }
}

nonisolated struct CleanupCategory: Identifiable, Sendable {
    let id: String
    let group: String
    let title: String
    let explanation: String
    let safety: CleanupSafety
    let action: CleanupAction
    /// Child names skipped when enumerating trashContents directories.
    var excludedNames: [String] = []

    var isCheckedByDefault: Bool { safety == .safe }

    /// Every user-facing path this category touches or measures (for tests/UI).
    var involvedPaths: [String] {
        switch action {
        case .trashContents(let paths): return paths
        case .removeContents(let path): return [path]
        case .command(_, _, let sizeHintPaths): return sizeHintPaths
        case .findAndTrashDirectories(let root, _, _): return [root]
        }
    }
}

extension CleanupCategory {

    /// The curated catalog. Only these locations are ever scanned or cleaned.
    static let catalog: [CleanupCategory] = [

        // MARK: Xcode & Simulators
        CleanupCategory(
            id: "xcode-derived-data",
            group: "Xcode & Simulators",
            title: "DerivedData",
            explanation: "Build intermediates and indexes. Xcode rebuilds them on the next build.",
            safety: .safe,
            action: .trashContents(["~/Library/Developer/Xcode/DerivedData"])
        ),
        CleanupCategory(
            id: "xcode-device-support",
            group: "Xcode & Simulators",
            title: "Device Support",
            explanation: "Debug symbols copied from connected iPhones and Watches. Recreated when a device is reconnected.",
            safety: .safe,
            action: .trashContents([
                "~/Library/Developer/Xcode/iOS DeviceSupport",
                "~/Library/Developer/Xcode/watchOS DeviceSupport",
                "~/Library/Developer/Xcode/tvOS DeviceSupport",
            ])
        ),
        CleanupCategory(
            id: "unavailable-simulators",
            group: "Xcode & Simulators",
            title: "Unavailable Simulators",
            explanation: "Simulator devices and runtimes orphaned by Xcode updates, removed with 'xcrun simctl delete unavailable'.",
            safety: .safe,
            action: .command(executable: "xcrun", arguments: ["simctl", "delete", "unavailable"], sizeHintPaths: [])
        ),
        CleanupCategory(
            id: "xcode-archives",
            group: "Xcode & Simulators",
            title: "Archives",
            explanation: "App archives with dSYM files. Keep them if you need to symbolicate crash reports from released builds.",
            safety: .caution,
            action: .trashContents(["~/Library/Developer/Xcode/Archives"])
        ),

        // MARK: Package caches
        CleanupCategory(
            id: "js-package-caches",
            group: "Package Caches",
            title: "JavaScript (npm, pnpm, Yarn)",
            explanation: "Package tarball caches. Package managers re-download what they need.",
            safety: .safe,
            action: .trashContents([
                "~/.npm",
                "~/Library/Caches/pnpm",
                "~/Library/pnpm/store",
                "~/Library/Caches/Yarn",
            ])
        ),
        CleanupCategory(
            id: "apple-package-caches",
            group: "Package Caches",
            title: "Swift PM & CocoaPods",
            explanation: "Dependency caches for Swift Package Manager and CocoaPods.",
            safety: .safe,
            action: .trashContents([
                "~/Library/Caches/org.swift.swiftpm",
                "~/Library/Caches/CocoaPods",
            ])
        ),
        CleanupCategory(
            id: "gradle-cache",
            group: "Package Caches",
            title: "Gradle",
            explanation: "Gradle build cache and downloaded dependencies. Re-downloaded on the next Android build.",
            safety: .safe,
            action: .trashContents(["~/.gradle/caches"])
        ),
        CleanupCategory(
            id: "build-tool-caches",
            group: "Package Caches",
            title: "Go, node-gyp, TypeScript",
            explanation: "Compiler and build-tool caches; rebuilt automatically.",
            safety: .safe,
            action: .trashContents([
                "~/Library/Caches/go-build",
                "~/Library/Caches/node-gyp",
                "~/Library/Caches/typescript",
            ])
        ),
        CleanupCategory(
            id: "homebrew",
            group: "Package Caches",
            title: "Homebrew",
            explanation: "Old downloads and outdated formula versions, removed with 'brew cleanup -s'.",
            safety: .safe,
            action: .command(executable: "brew", arguments: ["cleanup", "-s"], sizeHintPaths: ["~/Library/Caches/Homebrew"])
        ),

        // MARK: System & app caches
        CleanupCategory(
            id: "user-caches",
            group: "System & App Caches",
            title: "App & browser caches",
            explanation: "Per-app caches in ~/Library/Caches (browsers are usually the biggest). Apps rebuild them — close browsers first.",
            safety: .safe,
            action: .trashContents(["~/Library/Caches"]),
            excludedNames: ["Homebrew", "pnpm", "Yarn", "org.swift.swiftpm", "CocoaPods", "go-build", "node-gyp", "typescript"]
        ),
        CleanupCategory(
            id: "dot-cache",
            group: "System & App Caches",
            title: "Tool caches (~/.cache)",
            explanation: "Caches from command-line tools (Copilot, Firebase, Prisma…).",
            safety: .safe,
            action: .trashContents(["~/.cache"]),
            excludedNames: ["huggingface", "codex-runtimes"]
        ),
        CleanupCategory(
            id: "logs",
            group: "System & App Caches",
            title: "Logs",
            explanation: "Old application log files in ~/Library/Logs.",
            safety: .safe,
            action: .trashContents(["~/Library/Logs"])
        ),
        CleanupCategory(
            id: "trash",
            group: "System & App Caches",
            title: "Trash",
            explanation: "Permanently empties the Trash.",
            safety: .safe,
            action: .removeContents("~/.Trash")
        ),

        // MARK: Heavyweights
        CleanupCategory(
            id: "ml-model-caches",
            group: "Heavyweights",
            title: "AI model caches",
            explanation: "Downloaded machine-learning models (HuggingFace, Codex runtimes). Deleting forces a re-download on next use.",
            safety: .caution,
            action: .trashContents(["~/.cache/huggingface", "~/.cache/codex-runtimes"])
        ),
        CleanupCategory(
            id: "android-system-images",
            group: "Heavyweights",
            title: "Android emulator images",
            explanation: "Emulator system images in the Android SDK. Re-download via SDK Manager if needed.",
            safety: .caution,
            action: .trashContents(["~/Library/Android/sdk/system-images"])
        ),
        CleanupCategory(
            id: "docker",
            group: "Heavyweights",
            title: "Docker",
            explanation: "Runs 'docker system prune' to remove unused containers, networks and dangling images. Size shown is Docker's total footprint — pruning frees only the unused part.",
            safety: .caution,
            action: .command(executable: "docker", arguments: ["system", "prune", "-f"], sizeHintPaths: ["~/Library/Containers/com.docker.docker/Data"])
        ),
        CleanupCategory(
            id: "node-modules",
            group: "Heavyweights",
            title: "Project node_modules",
            explanation: "node_modules folders under ~/Developer. Restore per project with 'npm install' / 'pnpm install'.",
            safety: .caution,
            action: .findAndTrashDirectories(root: "~/Developer", named: "node_modules", maxDepth: 5)
        ),
    ]
}
