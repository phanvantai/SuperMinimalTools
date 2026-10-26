//
//  MenuContentView.swift
//  SuperMinimalTools
//

import SwiftUI
import AppKit

/// Dropdown shown when clicking the status bar item: live readouts, the
/// actions of the features that are on, and Settings. Every on/off choice
/// lives in SettingsView.
struct MenuContentView: View {
    var stats: SystemStatsStore
    @Bindable var updater: AppUpdater
    var clipboard: ClipboardHistory
    @Bindable var vietnamese: VietnameseInput
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @AppStorage("diskCleanerEnabled") private var diskCleanerEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            readouts
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            if diskCleanerEnabled || clipboard.isEnabled || vietnamese.isEnabled {
                Divider()
                VStack(spacing: 0) {
                    if vietnamese.isEnabled {
                        vietnameseRow
                    }
                    if clipboard.isEnabled {
                        MenuRow("Clipboard History…", systemImage: "list.clipboard", shortcut: "⌃⌘V") {
                            dismiss()
                            // After the dropdown is gone, or closing it takes focus from the panel.
                            Task { clipboard.showPanel() }
                        }
                    }
                    if diskCleanerEnabled {
                        MenuRow("Disk Cleaner…", systemImage: "externaldrive") {
                            open("disk-cleaner")
                        }
                    }
                }
            }

            Divider()

            if let version = updater.pendingVersion {
                Button("Update to \(version)…") {
                    dismiss()
                    updater.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: 0) {
                MenuRow("Settings…", systemImage: "gearshape", shortcut: "⌘,") {
                    open("settings")
                }
                .keyboardShortcut(",")
                MenuRow("Quit SuperMinimalTools", systemImage: "power", shortcut: "⌘Q") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(6)
        .frame(width: 250)
    }

    private var readouts: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
            ReadoutRow(
                title: "CPU", systemImage: "thermometer.medium", tint: .secondary,
                value: stats.cpuTemperature.map { "\(Int($0.rounded())) °C" } ?? "unavailable"
            )
            ReadoutRow(
                title: "Download", systemImage: "arrow.down", tint: .blue,
                value: ByteFormatting.rate(stats.bandwidth?.downloadBytesPerSecond ?? 0)
            )
            ReadoutRow(
                title: "Upload", systemImage: "arrow.up", tint: .red,
                value: ByteFormatting.rate(stats.bandwidth?.uploadBytesPerSecond ?? 0)
            )
        }
    }

    @ViewBuilder
    private var vietnameseRow: some View {
        if vietnamese.isTrusted {
            HStack(spacing: 8) {
                Image(systemName: "character.cursor.ibeam")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text("Vietnamese")
                Spacer()
                Text("⌃⇧")
                    .foregroundStyle(.secondary)
                Toggle("Vietnamese", isOn: $vietnamese.isVietnamese)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        } else {
            MenuRow("Allow Accessibility Access…", systemImage: "exclamationmark.triangle") {
                dismiss()
                vietnamese.openAccessibilitySettings()
            }
        }
        if let name = vietnamese.conflictingAppName {
            Text("Quit \(name), or letters get marked twice.")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
    }

    private func open(_ windowID: String) {
        openWindow(id: windowID)
        NSApp.activate()
        dismiss()
    }
}

private struct ReadoutRow: View {
    var title: String
    var systemImage: String
    var tint: Color
    var value: String

    var body: some View {
        GridRow {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// A button that looks and highlights like a menu item.
private struct MenuRow: View {
    var title: String
    var systemImage: String
    var shortcut: String?
    var action: () -> Void
    @State private var isHovered = false

    init(_ title: String, systemImage: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(isHovered ? .white : .secondary)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(isHovered ? .white.opacity(0.8) : .secondary)
                }
            }
            .foregroundStyle(isHovered ? .white : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.accentColor : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
