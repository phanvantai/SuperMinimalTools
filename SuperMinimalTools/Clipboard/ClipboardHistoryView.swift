//
//  ClipboardHistoryView.swift
//  SuperMinimalTools
//

import SwiftUI
import AppKit

/// Search field over the history. ↑/↓ move the selection, Return (or a
/// double-click) copies the selected item and closes, Esc closes.
struct ClipboardHistoryView: View {
    var history: ClipboardHistory
    var onPick: (ClipboardItem) -> Void
    var onClose: () -> Void

    @State private var query = ""
    @State private var selection: ClipboardItem.ID?
    @FocusState private var searchIsFocused: Bool

    private var filteredItems: [ClipboardItem] {
        guard !query.isEmpty else { return history.items }
        return history.items.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchIsFocused)
                    .onSubmit(pickSelection)
                    .onKeyPress(.downArrow) { moveSelection(by: 1) }
                    .onKeyPress(.upArrow) { moveSelection(by: -1) }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            if filteredItems.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Nothing copied yet" : "No matches",
                    systemImage: "doc.on.clipboard",
                    description: Text(query.isEmpty ? "Text you copy shows up here." : "No copied text contains “\(query)”.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(filteredItems, selection: $selection) { item in
                        ClipboardRow(item: item)
                            .tag(item.id)
                            .id(item.id)
                    }
                    .listStyle(.plain)
                    .contextMenu(forSelectionType: ClipboardItem.ID.self) { ids in
                        Button("Copy") { pick(ids.first) }
                        Button("Delete") {
                            for item in filteredItems where ids.contains(item.id) {
                                history.remove(item)
                            }
                        }
                    } primaryAction: { ids in
                        pick(ids.first)
                    }
                    .onChange(of: selection) { _, id in
                        if let id {
                            proxy.scrollTo(id)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text("\(history.items.count) items")
                Spacer()
                Text("↩ copy   esc close")
                Button("Clear All") {
                    history.clear()
                }
                .disabled(history.items.isEmpty)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
        .onAppear {
            selection = filteredItems.first?.id
            searchIsFocused = true
        }
        .onChange(of: query) {
            selection = filteredItems.first?.id
        }
        .onExitCommand(perform: onClose)
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let ids = filteredItems.map(\.id)
        guard !ids.isEmpty else { return .handled }
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? -offset
        selection = ids[min(max(current + offset, 0), ids.count - 1)]
        return .handled
    }

    private func pickSelection() {
        pick(selection ?? filteredItems.first?.id)
    }

    private func pick(_ id: ClipboardItem.ID?) {
        guard let item = filteredItems.first(where: { $0.id == id }) else { return }
        onPick(item)
    }
}

private struct ClipboardRow: View {
    var item: ClipboardItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: sourceIcon)
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(preview)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(item.copiedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    /// Leading indentation and blank lines waste the two lines a row has.
    private var preview: String {
        item.text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ⏎ ")
    }

    private var sourceIcon: NSImage {
        if let bundleID = item.sourceBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil) ?? NSImage()
    }
}
