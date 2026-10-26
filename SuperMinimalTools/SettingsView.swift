//
//  SettingsView.swift
//  SuperMinimalTools
//

import SwiftUI
import AppKit
import ServiceManagement

/// Every on/off choice, so the dropdown can stay a short list of readouts
/// and actions.
struct SettingsView: View {
    @Bindable var stats: SystemStatsStore
    @Bindable var updater: AppUpdater
    @Bindable var clipboard: ClipboardHistory
    @Bindable var vietnamese: VietnameseInput
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("diskCleanerEnabled") private var diskCleanerEnabled = false

    var body: some View {
        Form {
            Section("Menu Bar") {
                Toggle("Show CPU temperature", isOn: $stats.showsCPUTemperature)
                Toggle("Show network speed", isOn: $stats.showsBandwidth)
            }

            Section("Features") {
                Toggle(isOn: $diskCleanerEnabled) {
                    Text("Disk Cleaner")
                    Text("Finds caches and build folders to move to the Trash. Needs Full Disk Access.")
                }
                .onChange(of: diskCleanerEnabled) { _, isOn in
                    // Enabling walks the user through Full Disk Access in the
                    // cleaner window before anything is scanned.
                    if isOn {
                        openWindow(id: "disk-cleaner")
                        NSApp.activate()
                    }
                }

                Toggle(isOn: $clipboard.isEnabled) {
                    Text("Clipboard History")
                    Text("Remembers copied text. Press ⌃⌘V anywhere to pick an item.")
                }

                Toggle(isOn: $vietnamese.isEnabled) {
                    Text("Vietnamese Typing")
                    Text("Telex in every app. Press ⌃⇧ to switch between Vietnamese and English; each app remembers its own.")
                }
                if vietnamese.isEnabled {
                    VietnameseStatus(vietnamese: vietnamese)
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, isOn in
                        updateLaunchAtLogin(isOn)
                    }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                LabeledContent("Version \(Self.version)") {
                    Button("Check Now") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private func updateLaunchAtLogin(_ isOn: Bool) {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle if registration failed (e.g. running from DerivedData).
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// What still stands between the user and Vietnamese typing, if anything.
private struct VietnameseStatus: View {
    var vietnamese: VietnameseInput

    var body: some View {
        if !vietnamese.isTrusted {
            LabeledContent {
                Button("Open Settings…") {
                    vietnamese.openAccessibilitySettings()
                }
            } label: {
                Label("Allow SuperMinimalTools under Accessibility", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        if let name = vietnamese.conflictingAppName {
            Label("Quit \(name), or letters get marked twice.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
