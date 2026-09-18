//
//  DiskCleanerView.swift
//  SuperMinimalTools
//

import SwiftUI
import AppKit

@Observable
@MainActor
final class DiskCleanerModel {

    enum Phase: Equatable {
        case idle, scanning, ready, cleaning
    }

    private(set) var phase: Phase = .idle
    private(set) var results: [CategoryScanResult] = []
    /// Paths of individually selected items (files/folders inside categories).
    var selectedItemPaths: Set<String> = []
    /// Command-based categories (simctl, brew, docker) have no items; they are
    /// selected as a whole.
    var selectedCommandCategoryIDs: Set<String> = []
    var deletePermanently = false
    private(set) var lastFreedBytes: Int64?
    private(set) var failures: [String] = []
    private(set) var diskTotalBytes: Int64 = 0
    private(set) var diskFreeBytes: Int64 = 0

    var needsFullDiskAccess: Bool { results.contains(where: \.inaccessible) }

    var groups: [String] {
        var seen = Set<String>()
        return results.compactMap { seen.insert($0.category.group).inserted ? $0.category.group : nil }
    }

    func results(in group: String) -> [CategoryScanResult] {
        results.filter { $0.category.group == group }
    }

    init() {
        refreshDiskStats()
    }

    // MARK: - Selection

    func isSelected(_ item: ScannedItem) -> Bool {
        selectedItemPaths.contains(item.url.path)
    }

    func setSelected(_ selected: Bool, item: ScannedItem) {
        if selected {
            selectedItemPaths.insert(item.url.path)
        } else {
            selectedItemPaths.remove(item.url.path)
        }
    }

    func isCommandSelected(_ result: CategoryScanResult) -> Bool {
        selectedCommandCategoryIDs.contains(result.id)
    }

    func setCommandSelected(_ selected: Bool, result: CategoryScanResult) {
        if selected {
            selectedCommandCategoryIDs.insert(result.id)
        } else {
            selectedCommandCategoryIDs.remove(result.id)
        }
    }

    func isCategoryFullySelected(_ result: CategoryScanResult) -> Bool {
        if result.category.action.isCommand {
            return isCommandSelected(result)
        }
        return !result.items.isEmpty && result.items.allSatisfy { isSelected($0) }
    }

    func setCategorySelected(_ selected: Bool, result: CategoryScanResult) {
        if result.category.action.isCommand {
            setCommandSelected(selected, result: result)
        } else {
            for item in result.items {
                setSelected(selected, item: item)
            }
        }
    }

    func selectedItemCount(in result: CategoryScanResult) -> Int {
        result.items.filter { isSelected($0) }.count
    }

    func selectedBytes(in result: CategoryScanResult) -> Int64 {
        if result.category.action.isCommand {
            return isCommandSelected(result) ? (result.sizeBytes ?? 0) : 0
        }
        return result.items.filter { isSelected($0) }.reduce(0) { $0 + $1.sizeBytes }
    }

    var totalSelectedBytes: Int64 {
        results.reduce(0) { $0 + selectedBytes(in: $1) }
    }

    var totalSelectedItemCount: Int {
        results.reduce(0) { total, result in
            if result.category.action.isCommand {
                return total + (isCommandSelected(result) ? 1 : 0)
            }
            return total + selectedItemCount(in: result)
        }
    }

    var hasSelection: Bool {
        !selectedItemPaths.isEmpty || !selectedCommandCategoryIDs.isEmpty
    }

    private func applyDefaultSelection() {
        selectedItemPaths = Set(
            results
                .filter { $0.category.isCheckedByDefault }
                .flatMap { $0.items.map(\.url.path) }
        )
        selectedCommandCategoryIDs = Set(
            results
                .filter { $0.category.action.isCommand && $0.category.isCheckedByDefault }
                .map(\.id)
        )
    }

    /// The scan results reduced to only what the user checked.
    private func cleaningSelections() -> [CategoryScanResult] {
        results.compactMap { result in
            if result.category.action.isCommand {
                return isCommandSelected(result) ? result : nil
            }
            let chosen = result.items.filter { isSelected($0) }
            guard !chosen.isEmpty else { return nil }
            return CategoryScanResult(
                category: result.category,
                items: chosen,
                sizeBytes: chosen.reduce(0) { $0 + $1.sizeBytes },
                inaccessible: result.inaccessible
            )
        }
    }

    // MARK: - Actions

    func refreshDiskStats() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]) else { return }
        diskTotalBytes = Int64(values.volumeTotalCapacity ?? 0)
        diskFreeBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func scan() async {
        guard phase != .scanning, phase != .cleaning else { return }
        phase = .scanning
        // Task.detached keeps the heavy directory walking off the main thread.
        let scanned = await Task.detached(priority: .userInitiated) {
            await CleanupScanner.scan(CleanupCategory.catalog)
        }.value
        results = scanned.filter { ($0.sizeBytes ?? 0) > 0 || $0.sizeBytes == nil || $0.inaccessible }
        applyDefaultSelection()
        refreshDiskStats()
        phase = .ready
    }

    func clean() async {
        guard phase == .ready else { return }
        let selections = cleaningSelections()
        guard !selections.isEmpty else { return }
        phase = .cleaning
        let permanently = deletePermanently
        let outcomes = await Task.detached(priority: .userInitiated) {
            CleanupEngine.clean(selections, permanently: permanently)
        }.value
        lastFreedBytes = outcomes.reduce(0) { $0 + $1.freedBytes }
        failures = outcomes.flatMap(\.failures)
        refreshDiskStats()
        phase = .ready
        await scan()
    }
}

struct DiskCleanerView: View {
    @State private var model = DiskCleanerModel()
    @State private var isConfirmingClean = false
    @AppStorage("diskCleanerEnabled") private var diskCleanerEnabled = false
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted

    private var isUsable: Bool { diskCleanerEnabled && hasFullDiskAccess }

    var body: some View {
        Group {
            if !diskCleanerEnabled {
                disabledView
            } else if !hasFullDiskAccess {
                permissionRequestView
            } else {
                cleanerBody
            }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 560, idealHeight: 700)
        .task(id: isUsable) {
            if isUsable, model.phase == .idle {
                await model.scan()
            }
        }
        .onAppear {
            hasFullDiskAccess = FullDiskAccess.isGranted
            // Dev/testing hook: renders the window to a PNG once the scan is done:
            // `open SuperMinimalTools.app --args --open-cleaner --export-window /path/out.png`
            if Self.windowExportPath != nil {
                diskCleanerEnabled = true
                hasFullDiskAccess = true
            }
        }
        .onChange(of: model.phase) { _, newPhase in
            guard newPhase == .ready, let path = Self.windowExportPath else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                Self.exportWindow(to: path)
                exit(0)
            }
        }
    }

    private static var windowExportPath: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--export-window"),
              CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }

    /// Renders the cleaner window's view hierarchy to a PNG. Unlike
    /// screencapture, this needs no Screen Recording permission.
    private static func exportWindow(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.title == "Disk Cleaner" }),
              let contentView = window.contentView,
              let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { return }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private var disabledView: some View {
        VStack(spacing: 12) {
            Image(systemName: "internaldrive")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Disk Cleaner is turned off")
                .font(.title3.bold())
            Text("Enable it to scan caches and developer junk and reclaim disk space.\nYou will be asked to grant Full Disk Access first.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Enable Disk Cleaner") {
                diskCleanerEnabled = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    private var permissionRequestView: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Full Disk Access Required")
                .font(.title3.bold())
            Text("The Disk Cleaner scans locations that macOS protects (Trash, browser caches, logs). It stays read-only until you press Clean, but it needs Full Disk Access to see them.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click “Open System Settings” below.")
                Text("2. Turn on “SuperMinimalTools” in the Full Disk Access list (use + to add it if missing).")
                Text("3. Come back and click “Check Again” — if macOS hasn't applied it yet, “Relaunch App” will.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Open System Settings") {
                    FullDiskAccess.openSystemSettings()
                }
                .buttonStyle(.borderedProminent)
                Button("Check Again") {
                    hasFullDiskAccess = FullDiskAccess.isGranted
                }
                Button("Relaunch App") {
                    AppRelauncher.relaunch()
                }
            }
        }
        .padding(24)
    }

    private var cleanerBody: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Clean \(model.totalSelectedItemCount) selected item(s)?",
            isPresented: $isConfirmingClean
        ) {
            Button(model.deletePermanently ? "Delete Permanently" : "Move to Trash & Clean", role: .destructive) {
                Task { await model.clean() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("About \(ByteFormatting.size(model.totalSelectedBytes)) will be reclaimed. Caches are rebuilt automatically; command-based cleanups use their official tools (simctl, brew, docker).")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Startup Disk")
                    .font(.headline)
                ProgressView(value: usedFraction)
                    .tint(model.diskFreeBytes < model.diskTotalBytes / 10 ? .red : .accentColor)
                Text("\(ByteFormatting.size(model.diskTotalBytes - model.diskFreeBytes)) used · \(ByteFormatting.size(model.diskFreeBytes)) free")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(model.phase == .scanning ? "Scanning…" : "Rescan") {
                Task { await model.scan() }
            }
            .disabled(model.phase == .scanning || model.phase == .cleaning)
        }
    }

    private var usedFraction: Double {
        guard model.diskTotalBytes > 0 else { return 0 }
        return Double(model.diskTotalBytes - model.diskFreeBytes) / Double(model.diskTotalBytes)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            ContentUnavailableView(
                "Ready to Scan",
                systemImage: "internaldrive",
                description: Text("Scanning finds caches and developer junk that can be reclaimed safely.")
            )
        case .scanning:
            VStack(spacing: 12) {
                ProgressView()
                Text("Scanning known cache locations…")
                    .foregroundStyle(.secondary)
            }
        case .ready, .cleaning:
            if model.results.isEmpty {
                ContentUnavailableView(
                    "Nothing to Clean",
                    systemImage: "checkmark.circle",
                    description: Text("No reclaimable space found in the known locations.")
                )
            } else {
                categoryList
            }
        }
    }

    private var categoryList: some View {
        List {
            ForEach(model.groups, id: \.self) { group in
                Section(group) {
                    ForEach(model.results(in: group)) { result in
                        categoryRow(result)
                    }
                }
            }
        }
        .disabled(model.phase == .cleaning)
    }

    @ViewBuilder
    private func categoryRow(_ result: CategoryScanResult) -> some View {
        if result.category.action.isCommand || result.items.isEmpty {
            categoryHeader(result)
        } else {
            DisclosureGroup {
                ForEach(result.items.sorted { $0.sizeBytes > $1.sizeBytes }, id: \.url.path) { item in
                    itemRow(item)
                }
            } label: {
                categoryHeader(result)
            }
        }
    }

    private func categoryHeader(_ result: CategoryScanResult) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: categoryBinding(result)) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(result.category.title)
                        if result.category.safety == .caution {
                            Text("caution")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.yellow.opacity(0.25), in: Capsule())
                        }
                        if result.inaccessible {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.orange)
                                .help("Needs Full Disk Access")
                        }
                    }
                    Text(result.category.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailingSizeText(result)
        }
        .padding(.vertical, 2)
    }

    private func trailingSizeText(_ result: CategoryScanResult) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(result.sizeBytes.map(ByteFormatting.size) ?? "size varies")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if !result.category.action.isCommand {
                let selectedCount = model.selectedItemCount(in: result)
                let selectedBytes = model.selectedBytes(in: result)
                if selectedCount == 0 {
                    Text("none of \(result.items.count) selected")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if selectedCount < result.items.count {
                    Text("\(selectedCount) of \(result.items.count) · \(ByteFormatting.size(selectedBytes))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text("all \(result.items.count) selected")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func itemRow(_ item: ScannedItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: itemBinding(item)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(abbreviatedPath(item.url))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Show in Finder")
            Text(ByteFormatting.size(item.sizeBytes))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.leading, 6)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }

    private func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func categoryBinding(_ result: CategoryScanResult) -> Binding<Bool> {
        Binding(
            get: { model.isCategoryFullySelected(result) },
            set: { model.setCategorySelected($0, result: result) }
        )
    }

    private func itemBinding(_ item: ScannedItem) -> Binding<Bool> {
        Binding(
            get: { model.isSelected(item) },
            set: { model.setSelected($0, item: item) }
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.needsFullDiskAccess {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.orange)
                    Text("Some locations need Full Disk Access.")
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
            }
            if !model.failures.isEmpty {
                Text("\(model.failures.count) item(s) could not be cleaned: \(model.failures.prefix(2).joined(separator: "; "))\(model.failures.count > 2 ? " …" : "")")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            HStack {
                Toggle("Delete permanently instead of moving to Trash", isOn: $model.deletePermanently)
                    .font(.caption)
                Spacer()
                if let freed = model.lastFreedBytes {
                    Text("Reclaimed \(ByteFormatting.size(freed))")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
                Text("Selected: \(ByteFormatting.size(model.totalSelectedBytes))")
                    .monospacedDigit()
                Button(model.phase == .cleaning ? "Cleaning…" : "Clean") {
                    isConfirmingClean = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasSelection || model.phase != .ready)
            }
        }
    }
}

#Preview {
    DiskCleanerView()
}
