//
//  FolderBrowserView.swift
//  SuperMinimalTools
//

import SwiftUI
import AppKit

/// Disk-usage browser: lists a folder's children by size, lets the user
/// drill into subfolders and pick items (across folders) to remove.
struct FolderBrowserView: View {
    @Bindable var model: FolderBrowserModel
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(12)
        }
        .confirmationDialog(
            "Remove \(model.selectedCount) selected item(s)?",
            isPresented: $isConfirmingDelete
        ) {
            Button(model.deletePermanently ? "Delete Permanently" : "Move to Trash", role: .destructive) {
                Task { await model.deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var confirmationMessage: String {
        let size = ByteFormatting.size(model.selectedBytes)
        let names = model.selection.values
            .map(\.lastPathComponent)
            .sorted()
            .prefix(5)
            .joined(separator: ", ")
        let more = model.selection.count > 5 ? " …" : ""
        let destination = model.deletePermanently
            ? "They will be deleted permanently and cannot be recovered."
            : "They will be moved to the Trash."
        return "\(names)\(more)\n\nAbout \(size). \(destination)"
    }

    // MARK: - Navigation bar

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button {
                model.goUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Enclosing folder")
            .disabled(!model.canGoUp)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.path) { index, url in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Button(crumbTitle(url)) {
                                model.open(url)
                            }
                            .buttonStyle(.plain)
                            .fontWeight(url == model.currentURL ? .semibold : .regular)
                            .foregroundStyle(url == model.currentURL ? .primary : .secondary)
                            .id(url.path)
                        }
                    }
                }
                .onChange(of: model.currentURL) { _, url in
                    proxy.scrollTo(url.path, anchor: .trailing)
                }
            }

            Spacer(minLength: 4)

            if model.isMeasuring {
                ProgressView()
                    .controlSize(.small)
                    .help("Measuring folder sizes…")
            }
            Text(ByteFormatting.size(model.currentTotalBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Total size of this folder")

            Menu {
                ForEach(Self.quickLocations, id: \.path) { location in
                    Button(location.title) {
                        model.open(CleanupScanner.expand(location.path))
                    }
                }
                Divider()
                Button("Choose Folder…") { chooseFolder() }
            } label: {
                Label("Go to", systemImage: "folder")
            }
            .fixedSize()

            Button {
                model.reload(remeasure: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Measure this folder again")
        }
    }

    private static let quickLocations: [(title: String, path: String)] = [
        ("Home", "~"),
        ("Downloads", "~/Downloads"),
        ("Desktop", "~/Desktop"),
        ("Documents", "~/Documents"),
        ("Developer (projects)", "~/Developer"),
        ("Library", "~/Library"),
        ("Library › Application Support", "~/Library/Application Support"),
        ("Library › Caches", "~/Library/Caches"),
        ("Library › Containers", "~/Library/Containers"),
        ("Library › Developer (Xcode, Simulators)", "~/Library/Developer"),
        ("Applications (view only)", "/Applications"),
        ("System Library (view only)", "/Library"),
    ]

    private func crumbTitle(_ url: URL) -> String {
        if url.path == "/" { return "Macintosh HD" }
        if url.path == NSHomeDirectory() { return "~ " + url.lastPathComponent }
        return url.lastPathComponent
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = model.currentURL
        panel.prompt = "Browse"
        if panel.runModal() == .OK, let url = panel.url {
            model.open(url)
        }
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if let error = model.listingError {
            ContentUnavailableView(
                "Can't Open Folder",
                systemImage: "lock.fill",
                description: Text(error)
            )
        } else if model.entries.isEmpty {
            ContentUnavailableView("Empty Folder", systemImage: "folder")
        } else {
            List(model.entries) { entry in
                row(entry)
            }
            .disabled(model.isDeleting)
        }
    }

    private func row(_ entry: FolderEntry) -> some View {
        let refusal = DeletionGuard.refusalReason(for: entry.url)
        return HStack(spacing: 8) {
            Toggle("", isOn: selectionBinding(entry))
                .labelsHidden()
                .disabled(refusal != nil)
                .help(refusal.map { "Can't be deleted: \($0)" } ?? "Select for removal")

            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .frame(width: 18, height: 18)

            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(entry.name.hasPrefix(".") ? .secondary : .primary)

            if refusal != nil {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            sizeBar(entry)

            Text(entry.sizeBytes.map(ByteFormatting.size) ?? "…")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)

            Button {
                if entry.isBrowsable { model.open(entry.url) }
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(entry.isBrowsable ? 1 : 0)
            .disabled(!entry.isBrowsable)
            .help("Open folder")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.isBrowsable { model.open(entry.url) }
        }
        .contextMenu {
            if entry.isBrowsable {
                Button("Open") { model.open(entry.url) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url.path, forType: .string)
            }
        }
    }

    private func sizeBar(_ entry: FolderEntry) -> some View {
        let total = max(model.currentTotalBytes, 1)
        let fraction = Double(entry.sizeBytes ?? 0) / Double(total)
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(fraction > 0.25 ? Color.orange : Color.accentColor)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(width: 90, height: 5)
        .opacity(entry.sizeBytes == nil ? 0.3 : 1)
    }

    private func selectionBinding(_ entry: FolderEntry) -> Binding<Bool> {
        Binding(
            get: { model.isSelected(entry) },
            set: { model.setSelected($0, entry: entry) }
        )
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.failures.isEmpty {
                Text("\(model.failures.count) item(s) could not be removed: \(model.failures.prefix(2).joined(separator: "; "))\(model.failures.count > 2 ? " …" : "")")
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
                if model.selectedCount > 0 {
                    Button("Clear") { model.clearSelection() }
                        .buttonStyle(.link)
                }
                Text("Selected: \(model.selectedCount) · \(ByteFormatting.size(model.selectedBytes))\(model.selectionHasUnmeasuredItems ? "+" : "")")
                    .monospacedDigit()
                Button(model.isDeleting ? "Removing…" : (model.deletePermanently ? "Delete" : "Move to Trash")) {
                    isConfirmingDelete = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedCount == 0 || model.isDeleting)
            }
        }
    }
}
