//
//  VietnameseInput.swift
//  SuperMinimalTools
//

import AppKit
import ApplicationServices
import Observation

/// Vietnamese typing (Telex, Unicode) in every app, with Vietnamese or
/// English remembered per app.
///
/// Opt-in: nothing is intercepted until the user enables it from the
/// dropdown and grants the Accessibility permission. ⌃⇧ switches the mode
/// for the frontmost app; switching apps restores that app's mode.
@Observable
@MainActor
final class VietnameseInput {

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.isEnabledKey)
            applyEnabled()
        }
    }

    /// Whether keys are composed into Vietnamese in the frontmost app.
    var isVietnamese: Bool {
        didSet {
            guard isVietnamese != oldValue else { return }
            tap?.isVietnamese = isVietnamese
            if let currentBundleID {
                modes[currentBundleID] = isVietnamese
                defaults.set(modes, forKey: Self.modesKey)
            }
        }
    }

    private(set) var isTrusted = AXIsProcessTrusted()

    /// Another Vietnamese input app that would add a second set of marks.
    var conflictingAppName: String? {
        NSWorkspace.shared.runningApplications.first {
            Self.otherInputApps.contains($0.bundleIdentifier ?? "")
        }?.localizedName
    }

    private static let isEnabledKey = "vietnameseInputEnabled"
    private static let modesKey = "vietnameseInputModes"
    private static let otherInputApps: Set<String> = [
        "com.phamhungtien.phtv", "com.tuyenmai.openkey", "com.lamquangminh.evkey", "com.trankynam.GoTiengViet",
    ]
    /// Apps whose address bar autocompletes inline.
    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "company.thebrowser.dia", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "ai.perplexity.comet", "org.mozilla.firefox", "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
    ]

    private let defaults: UserDefaults
    @ObservationIgnored private var modes: [String: Bool]
    @ObservationIgnored private var currentBundleID: String?
    @ObservationIgnored private var tap: TelexEventTap?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var trustTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let modes = defaults.dictionary(forKey: Self.modesKey) as? [String: Bool] ?? [:]
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let currentBundleID = frontmost == Bundle.main.bundleIdentifier ? nil : frontmost
        self.modes = modes
        self.currentBundleID = currentBundleID
        isVietnamese = currentBundleID.flatMap { modes[$0] } ?? true
        isEnabled = defaults.bool(forKey: Self.isEnabledKey)
        applyEnabled()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Lifecycle

    private func applyEnabled() {
        if isEnabled {
            observeActivations()
            startTap(promptingForPermission: true)
        } else {
            trustTask?.cancel()
            trustTask = nil
            tap?.stop()
            tap = nil
            if let activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
                self.activationObserver = nil
            }
        }
    }

    private func startTap(promptingForPermission: Bool) {
        guard tap == nil else { return }
        isTrusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": promptingForPermission] as CFDictionary)
        guard isTrusted else {
            waitForPermission()
            return
        }
        let tap = TelexEventTap(isVietnamese: isVietnamese) { [weak self] isVietnamese in
            // Capture the weak reference's current value: the task can't read the closure's var.
            Task { @MainActor [self] in self?.isVietnamese = isVietnamese }
        }
        tap.setFixesAutocomplete(currentBundleID.map(Self.browsers.contains) ?? false)
        guard tap.start() else {
            waitForPermission()
            return
        }
        self.tap = tap
    }

    /// The permission is granted in System Settings while the app keeps
    /// running, so poll for it.
    private func waitForPermission() {
        guard trustTask == nil else { return }
        trustTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, AXIsProcessTrusted() else { continue }
                self.trustTask = nil
                self.startTap(promptingForPermission: false)
                return
            }
        }
    }

    private func observeActivations() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.appDidActivate(bundleID)
            }
        }
    }

    private func appDidActivate(_ bundleID: String?) {
        // Opening this app's own dropdown or panels keeps the mode of the app
        // the user came from.
        guard let bundleID, bundleID != Bundle.main.bundleIdentifier else { return }
        currentBundleID = bundleID
        tap?.resetWord()
        tap?.setFixesAutocomplete(Self.browsers.contains(bundleID))
        if let saved = modes[bundleID] {
            isVietnamese = saved
        } else {
            // A new app starts in the current mode.
            modes[bundleID] = isVietnamese
            defaults.set(modes, forKey: Self.modesKey)
        }
    }
}
