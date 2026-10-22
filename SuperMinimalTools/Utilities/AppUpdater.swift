//
//  AppUpdater.swift
//  SuperMinimalTools
//

import AppKit
import Observation
import Sparkle

/// In-app updates through Sparkle. Each GitHub release carries the zip and
/// `appcast.xml` (`SUFeedURL` in Config/Info.plist points at the latest one),
/// and every update is signed with the owner's EdDSA key, whose public half is
/// `SUPublicEDKey`. Sparkle checks daily and asks before installing.
///
/// As a menu bar app we have no Dock icon or main window, so an update found in
/// the background isn't pushed in front of whatever the user is doing: it shows
/// up in the dropdown instead (Sparkle's "gentle reminders").
@Observable
final class AppUpdater: NSObject {
    private(set) var canCheckForUpdates = false
    /// Version of an update found by a scheduled check that the user hasn't looked at yet.
    private(set) var pendingVersion: String?
    var automaticallyChecksForUpdates = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    override init() {
        super.init()
        // Unit tests run inside the app; they must not offer to replace the build under test.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            // SPUUpdater lives on the main thread, so its KVO fires there.
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Right after launch Sparkle may show it up front; otherwise the dropdown does.
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate {
            pendingVersion = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
