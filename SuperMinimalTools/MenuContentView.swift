//
//  MenuContentView.swift
//  SuperMinimalTools
//

import SwiftUI
import AppKit
import ServiceManagement

/// Dropdown shown when clicking the status bar item.
struct MenuContentView: View {
    @Bindable var stats: SystemStatsStore
    @Bindable var updater: AppUpdater
    @Bindable var clipboard: ClipboardHistory
    @Bindable var vietnamese: VietnameseInput
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("diskCleanerEnabled") private var diskCleanerEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("CPU temperature")
                    Text(stats.cpuTemperature.map { "\(Int($0.rounded())) °C" } ?? "unavailable")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Download")
                    Text(ByteFormatting.rate(stats.bandwidth?.downloadBytesPerSecond ?? 0))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Upload")
                    Text(ByteFormatting.rate(stats.bandwidth?.uploadBytesPerSecond ?? 0))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Divider()

            Toggle("Show CPU temperature", isOn: $stats.showsCPUTemperature)
            Toggle("Show network speed", isOn: $stats.showsBandwidth)

            Divider()

            Toggle("Enable Disk Cleaner", isOn: $diskCleanerEnabled)
                .onChange(of: diskCleanerEnabled) { _, isOn in
                    // Enabling walks the user through Full Disk Access in the
                    // cleaner window before anything is scanned.
                    if isOn {
                        openDiskCleaner()
                    }
                }
            if diskCleanerEnabled {
                Button("Disk Cleaner…") {
                    openDiskCleaner()
                }
            }

            Toggle("Enable Clipboard History", isOn: $clipboard.isEnabled)
            if clipboard.isEnabled {
                Button {
                    dismiss()
                    // After the dropdown is gone, or closing it takes focus from the panel.
                    Task { clipboard.showPanel() }
                } label: {
                    HStack {
                        Text("Clipboard History…")
                        Spacer()
                        Text("⌃⌘V")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Toggle("Enable Vietnamese Typing", isOn: $vietnamese.isEnabled)
            if vietnamese.isEnabled {
                if vietnamese.isTrusted {
                    Toggle(isOn: $vietnamese.isVietnamese) {
                        HStack {
                            Text("Vietnamese (Telex)")
                            Spacer()
                            Text("⌃⇧")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button("Allow Accessibility Access…") {
                        dismiss()
                        vietnamese.openAccessibilitySettings()
                    }
                }
                if let name = vietnamese.conflictingAppName {
                    Text("Quit \(name), or letters get marked twice.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, isOn in
                    updateLaunchAtLogin(isOn)
                }

            Divider()

            if let version = updater.pendingVersion {
                Button("Update to \(version)…") {
                    checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
            }
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
            Button("Check for Updates…") {
                checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)

            Divider()

            Button("Quit SuperMinimalTools") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 250)
    }

    private func openDiskCleaner() {
        openWindow(id: "disk-cleaner")
        NSApp.activate()
        dismiss()
    }

    private func checkForUpdates() {
        dismiss()
        updater.checkForUpdates()
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
