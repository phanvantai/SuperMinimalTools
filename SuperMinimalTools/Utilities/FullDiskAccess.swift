//
//  FullDiskAccess.swift
//  SuperMinimalTools
//

import Foundation
import AppKit

nonisolated enum FullDiskAccess {

    /// macOS has no public API to query Full Disk Access, so probe a
    /// TCC-protected location: listing it succeeds only when access is granted.
    static var isGranted: Bool {
        let protectedPaths = [
            NSHomeDirectory() + "/Library/Safari",
            NSHomeDirectory() + "/Library/Mail",
            NSHomeDirectory() + "/.Trash",
        ]
        for path in protectedPaths where FileManager.default.fileExists(atPath: path) {
            if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil {
                return true
            }
        }
        return false
    }

    @MainActor
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}

nonisolated enum AppRelauncher {

    /// Launches a fresh instance of the app; the single-instance guard in
    /// SuperMinimalToolsApp makes the new copy terminate this one, so this
    /// works as a clean relaunch (needed for Full Disk Access to take effect).
    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    }
}
