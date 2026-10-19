//
//  CleanupEngine.swift
//  SuperMinimalTools
//

import Foundation

nonisolated struct CleanupOutcome: Sendable {
    let categoryID: String
    let freedBytes: Int64
    let failures: [String]
}

/// Performs the actual cleanup. Acts on items resolved by CleanupScanner from
/// the curated catalog, or on items the user picked in the folder browser.
/// Every file deletion passes through DeletionGuard first.
nonisolated enum CleanupEngine {

    /// Synchronous on purpose: callers run it via Task.detached so the file
    /// operations and child processes never block the main thread.
    static func clean(_ selections: [CategoryScanResult], permanently: Bool) -> [CleanupOutcome] {
        selections.map { cleanCategory($0, permanently: permanently) }
    }

    private static func cleanCategory(_ selection: CategoryScanResult, permanently: Bool) -> CleanupOutcome {
        let fileManager = FileManager.default
        var freed: Int64 = 0
        var failures: [String] = []

        switch selection.category.action {
        case .command(let executable, let arguments, _):
            if let error = runCommand(executable, arguments) {
                failures.append(error)
            } else {
                freed = selection.sizeBytes ?? 0
            }

        case .removeContents:
            // Emptying the Trash is permanent by definition.
            for item in selection.items {
                do {
                    try fileManager.removeItem(at: item.url)
                    freed += item.sizeBytes
                } catch {
                    failures.append("\(item.url.lastPathComponent): \(error.localizedDescription)")
                }
            }

        case .trashContents, .findProjectArtifacts, .findFiles:
            let outcome = remove(selection.items, permanently: permanently)
            freed = outcome.freedBytes
            failures = outcome.failures
        }

        return CleanupOutcome(categoryID: selection.id, freedBytes: freed, failures: failures)
    }

    /// Trashes (or permanently deletes) the given items. Items DeletionGuard
    /// protects are refused, whatever their origin.
    static func remove(_ items: [ScannedItem], permanently: Bool) -> (freedBytes: Int64, failures: [String], removedPaths: [String]) {
        let fileManager = FileManager.default
        var freed: Int64 = 0
        var failures: [String] = []
        var removed: [String] = []
        for item in items {
            if let reason = DeletionGuard.refusalReason(for: item.url) {
                failures.append("\(item.url.lastPathComponent): \(reason)")
                continue
            }
            do {
                if permanently {
                    try fileManager.removeItem(at: item.url)
                } else {
                    try fileManager.trashItem(at: item.url, resultingItemURL: nil)
                }
                freed += item.sizeBytes
                removed.append(item.url.path)
            } catch {
                failures.append("\(item.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (freed, failures, removed)
    }

    /// Runs a maintenance CLI (xcrun, brew, docker). Returns an error message,
    /// or nil on success. Resolved via /usr/bin/env with an explicit PATH since
    /// GUI apps don't inherit the shell's PATH.
    static func runCommand(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return "\(executable): \(error.localizedDescription)"
        }
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(executable) exited with status \(process.terminationStatus)"
            + (message.isEmpty ? "" : ": \(message)")
    }
}
