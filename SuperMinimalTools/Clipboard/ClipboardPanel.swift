//
//  ClipboardPanel.swift
//  SuperMinimalTools
//

import SwiftUI
import AppKit

/// The floating picker opened by ⌃⌘V or from the dropdown. It is a
/// non-activating panel, like Spotlight: the app the user is typing in stays
/// frontmost, so after picking an item ⌘V pastes it right there.
@MainActor
final class ClipboardPanel: NSObject, NSWindowDelegate {

    private unowned let history: ClipboardHistory
    private var panel: NSPanel?
    /// Set when the panel was opened from the dropdown, which activates this
    /// app; focus goes back there after picking.
    private var previousApp: NSRunningApplication?

    init(history: ClipboardHistory) {
        self.history = history
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost == .current ? previousApp : frontmost
        let panel = panel ?? makePanel()
        self.panel = panel
        // A fresh view each time: empty search, first item selected.
        let hostingView = NSHostingView(rootView: ClipboardHistoryView(
            history: history,
            onPick: { [weak self] item in self?.pick(item) },
            onClose: { [weak self] in self?.close() }
        ))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else dismisses the picker.
        close()
    }

    private func pick(_ item: ClipboardItem) {
        history.copy(item)
        close()
        if NSApp.isActive {
            previousApp?.activate()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = PickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 380, height: 260)
        panel.delegate = self
        return panel
    }

    /// Centered on the screen with the mouse, in its upper part, like Spotlight.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - visible.height * 0.15 - size.height
        ))
    }
}

/// A non-activating panel only takes keyboard focus if it says it can.
private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
