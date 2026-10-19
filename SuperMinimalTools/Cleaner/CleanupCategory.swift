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
    /// Find project build folders (e.g. Flutter `build`, Rust `target`) under
    /// several roots. A folder only matches when its project marker file sits
    /// next to it, so an unrelated folder that happens to be called "build" is
    /// never touched.
    case findProjectArtifacts(roots: [String], rules: [ProjectArtifactRule], maxDepth: Int)
    /// Find files under the roots that match an extension and/or a minimum size.
    case findFiles(roots: [String], extensions: Set<String>, minBytes: Int64, maxDepth: Int)

    var isCommand: Bool {
        if case .command = self { return true }
        return false
    }
}

nonisolated struct ProjectArtifactRule: Sendable {
    /// Directory name to match, e.g. "build", "target", ".dart_tool".
    let directoryName: String
    /// At least one of these files must exist next to the directory; empty
    /// means the name alone is enough (only used for unambiguous names).
    let markers: [String]
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
        case .findProjectArtifacts(let roots, _, _): return roots
        case .findFiles(let roots, _, _, _): return roots
        }
    }
}

extension CleanupCategory {

    /// Common places people keep code; missing ones are simply skipped.
    static let projectRoots = [
        "~/Developer", "~/Projects", "~/Documents", "~/Desktop", "~/code",
        "~/src", "~/workspace", "~/StudioProjects", "~/AndroidStudioProjects",
        "~/repos", "~/git",
    ]

    /// Chromium/Electron cache folders inside an app's Application Support folder.
    nonisolated private static func electronCaches(_ appFolders: [String]) -> [String] {
        appFolders.flatMap { app in
            ["Cache", "Code Cache", "GPUCache", "CachedData", "CachedExtensionVSIXs", "DawnGraphiteCache", "DawnWebGPUCache"]
                .map { "~/Library/Application Support/\(app)/\($0)" }
        }
    }

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
        CleanupCategory(
            id: "xcode-caches",
            group: "Xcode & Simulators",
            title: "Previews, simulator & doc caches",
            explanation: "SwiftUI preview builds, CoreSimulator caches, documentation caches and device logs. Rebuilt on demand.",
            safety: .safe,
            action: .trashContents([
                "~/Library/Developer/Xcode/UserData/Previews",
                "~/Library/Developer/CoreSimulator/Caches",
                "~/Library/Developer/Xcode/DocumentationCache",
                "~/Library/Developer/Xcode/iOS Device Logs",
            ])
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
            id: "flutter-dart-cache",
            group: "Package Caches",
            title: "Flutter & Dart (pub cache)",
            explanation: "Downloaded pub packages. 'flutter pub get' re-downloads what each project needs.",
            safety: .safe,
            action: .trashContents(["~/.pub-cache/hosted", "~/.pub-cache/git"])
        ),
        CleanupCategory(
            id: "other-package-caches",
            group: "Package Caches",
            title: "Cargo, Bun, Maven, CocoaPods specs",
            explanation: "Dependency download caches for Rust, Bun, Maven and the legacy CocoaPods specs repo.",
            safety: .safe,
            action: .trashContents([
                "~/.cargo/registry/cache",
                "~/.cargo/registry/src",
                "~/.cargo/git/checkouts",
                "~/.bun/install/cache",
                "~/.m2/repository",
                "~/.cocoapods/repos",
            ])
        ),
        CleanupCategory(
            id: "android-tool-caches",
            group: "Package Caches",
            title: "Android tooling",
            explanation: "Old Gradle wrapper distributions and Android build caches. Re-downloaded when a project needs them.",
            safety: .safe,
            action: .trashContents([
                "~/.gradle/wrapper/dists",
                "~/.android/cache",
                "~/.android/build-cache",
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
            id: "electron-app-caches",
            group: "System & App Caches",
            title: "Editor & chat app caches",
            explanation: "Chromium caches of VS Code, Cursor, Slack, Discord, Teams. Quit those apps first; settings and data are untouched.",
            safety: .safe,
            action: .trashContents(electronCaches([
                "Code", "Cursor", "Windsurf", "Slack", "discord", "Microsoft Teams", "Notion", "Postman",
            ]))
        ),
        CleanupCategory(
            id: "device-updates",
            group: "System & App Caches",
            title: "iOS updates & Mail attachments",
            explanation: "Downloaded iPhone/iPad firmware and attachments Mail saved when you opened them.",
            safety: .safe,
            action: .trashContents([
                "~/Library/iTunes/iPhone Software Updates",
                "~/Library/iTunes/iPad Software Updates",
                "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
            ])
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
            id: "android-avds",
            group: "Heavyweights",
            title: "Android emulators (AVDs)",
            explanation: "Virtual devices with their disk images. Deleting removes the emulator and its data.",
            safety: .caution,
            action: .trashContents(["~/.android/avd"])
        ),
        CleanupCategory(
            id: "ios-backups",
            group: "Heavyweights",
            title: "iPhone & iPad backups",
            explanation: "Local device backups made by Finder. Delete only backups you no longer need.",
            safety: .caution,
            action: .trashContents(["~/Library/Application Support/MobileSync/Backup"])
        ),

        // MARK: Project folders
        CleanupCategory(
            id: "node-modules",
            group: "Project Folders",
            title: "Project node_modules",
            explanation: "node_modules folders in your project folders (~/Developer, ~/Projects, ~/Documents…). Restore with 'npm install' / 'pnpm install'.",
            safety: .caution,
            action: .findProjectArtifacts(
                roots: projectRoots,
                rules: [ProjectArtifactRule(directoryName: "node_modules", markers: [])],
                maxDepth: 6
            )
        ),
        CleanupCategory(
            id: "project-build-outputs",
            group: "Project Folders",
            title: "Build outputs",
            explanation: "Flutter/Dart build & .dart_tool, Rust target, Gradle build, Next.js .next — only next to the matching project file. Rebuilt on the next build.",
            safety: .safe,
            action: .findProjectArtifacts(
                roots: projectRoots,
                rules: [
                    ProjectArtifactRule(directoryName: "build", markers: ["pubspec.yaml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]),
                    ProjectArtifactRule(directoryName: ".dart_tool", markers: ["pubspec.yaml"]),
                    ProjectArtifactRule(directoryName: "target", markers: ["Cargo.toml"]),
                    ProjectArtifactRule(directoryName: ".gradle", markers: ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"]),
                    ProjectArtifactRule(directoryName: ".next", markers: ["package.json"]),
                ],
                maxDepth: 6
            )
        ),
        CleanupCategory(
            id: "project-pods",
            group: "Project Folders",
            title: "CocoaPods Pods",
            explanation: "Pods folders next to a Podfile. Restore with 'pod install'.",
            safety: .caution,
            action: .findProjectArtifacts(
                roots: projectRoots,
                rules: [ProjectArtifactRule(directoryName: "Pods", markers: ["Podfile"])],
                maxDepth: 7
            )
        ),

        // MARK: Personal files
        CleanupCategory(
            id: "installers",
            group: "Personal Files",
            title: "Installers & disk images",
            explanation: "Leftover .dmg, .pkg, .xip, .ipsw and .iso files in Downloads and Desktop.",
            safety: .caution,
            action: .findFiles(
                roots: ["~/Downloads", "~/Desktop"],
                extensions: ["dmg", "pkg", "xip", "ipsw", "iso"],
                minBytes: 0,
                maxDepth: 3
            )
        ),
        CleanupCategory(
            id: "large-files",
            group: "Personal Files",
            title: "Large files (over 500 MB)",
            explanation: "Big files in Downloads, Desktop, Documents and Movies. Review each one before deleting.",
            safety: .caution,
            action: .findFiles(
                roots: ["~/Downloads", "~/Desktop", "~/Documents", "~/Movies"],
                extensions: [],
                minBytes: 500 * 1024 * 1024,
                maxDepth: 8
            )
        ),
    ]
}
