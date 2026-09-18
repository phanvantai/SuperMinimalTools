//
//  SuperMinimalToolsApp.swift
//  SuperMinimalTools
//
//  Created by Tai Phan Van on 17/9/26.
//

import SwiftUI
import AppKit

@main
struct SuperMinimalToolsApp: App {
    @State private var stats = SystemStatsStore()

    init() {
        Self.terminateOlderInstances()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(stats: stats)
        } label: {
            StatusBarLabel(stats: stats)
        }
        .menuBarExtraStyle(.window)

        Window("Disk Cleaner", id: "disk-cleaner") {
            DiskCleanerView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }

    /// A status-bar app should only ever show one item: if an older copy is
    /// still running (e.g. left over from a previous debug session), quit it
    /// so the newest launch wins.
    private static func terminateOlderInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        for instance in instances where instance != NSRunningApplication.current {
            instance.forceTerminate()
        }
    }
}

/// Live readout in the status bar; falls back to an icon when everything is hidden.
///
/// The readout is rendered to an NSImage because the system draws MenuBarExtra
/// text labels as monochrome templates — a plain colored Text would lose its
/// colors in the menu bar.
struct StatusBarLabel: View {
    var stats: SystemStatsStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            .onAppear {
                // Dev/testing hook: `open SuperMinimalTools.app --args --open-cleaner`
                if CommandLine.arguments.contains("--open-cleaner") {
                    openWindow(id: "disk-cleaner")
                    NSApp.activate()
                }
                // Dev/testing hook: exports the live readout as a PNG for docs:
                // `open SuperMinimalTools.app --args --export-menubar /path/out.png`
                if let index = CommandLine.arguments.firstIndex(of: "--export-menubar"),
                   CommandLine.arguments.count > index + 1 {
                    let path = CommandLine.arguments[index + 1]
                    Task {
                        try? await Task.sleep(for: .seconds(7)) // let a few samples arrive
                        exportMenuBarReadout(to: path)
                        exit(0)
                    }
                }
            }
    }

    private func exportMenuBarReadout(to path: String) {
        let reading = stats.bandwidth ?? BandwidthReading(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
        let content = StatusBarReadout(
            temperatureText: stats.cpuTemperature.map { "\(Int($0.rounded()))°" } ?? "--°",
            downloadText: "↓" + ByteFormatting.compactRate(reading.downloadBytesPerSecond),
            uploadText: "↑" + ByteFormatting.compactRate(reading.uploadBytesPerSecond),
            baseColor: .white
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color(red: 0.11, green: 0.11, blue: 0.13))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 4
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    @ViewBuilder
    private var content: some View {
        if stats.statusBarText.isEmpty {
            Image(systemName: "gauge.with.needle")
        } else {
            Image(nsImage: renderedImage)
        }
    }

    private var renderedImage: NSImage {
        let reading = stats.bandwidth ?? BandwidthReading(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
        let content = StatusBarReadout(
            temperatureText: stats.showsCPUTemperature
                ? (stats.cpuTemperature.map { "\(Int($0.rounded()))°" } ?? "--°")
                : nil,
            downloadText: stats.showsBandwidth
                ? "↓" + ByteFormatting.compactRate(reading.downloadBytesPerSecond)
                : nil,
            uploadText: stats.showsBandwidth
                ? "↑" + ByteFormatting.compactRate(reading.uploadBytesPerSecond)
                : nil,
            baseColor: colorScheme == .dark ? .white : .black
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage()
    }
}

private struct StatusBarReadout: View {
    var temperatureText: String?
    var downloadText: String?
    var uploadText: String?
    var baseColor: Color

    var body: some View {
        HStack(spacing: 7) {
            if let temperatureText {
                Text(temperatureText)
                    .foregroundStyle(baseColor)
            }
            if let downloadText {
                Text(downloadText)
                    .foregroundStyle(.blue)
            }
            if let uploadText {
                Text(uploadText)
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .monospacedDigit()
        .padding(.horizontal, 1)
    }
}
