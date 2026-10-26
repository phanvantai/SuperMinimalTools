//
//  TelexEventTap.swift
//  SuperMinimalTools
//

import AppKit
import Carbon.HIToolbox
import Synchronization

/// Rewrites keystrokes system-wide: each key goes through a TelexSession,
/// and when a word changes, the key is swallowed and replaced by backspaces
/// plus the new text. ⌃⇧ (pressed and released on their own) switches
/// between Vietnamese and English.
///
/// The tap runs on its own thread so a busy main thread never delays typing.
/// Needs the Accessibility permission.
nonisolated final class TelexEventTap: @unchecked Sendable {

    /// Pauses between the events that rewrite a word. Terminals and editors
    /// read input asynchronously; sent back to back, the new text can arrive
    /// before the backspaces and get deleted (`ca` + `s` leaving `c`).
    struct Pacing: Equatable {
        /// After each backspace and each character.
        var betweenKeys: TimeInterval
        /// After the last backspace, before the new text.
        var afterDeleting: TimeInterval

        static let none = Pacing(betweenKeys: 0, afterDeleting: 0)
        static let editor = Pacing(betweenKeys: 0.008, afterDeleting: 0.025)
        /// Slow enough for a TUI like Claude Code running in the terminal.
        static let terminal = Pacing(betweenKeys: 0.015, afterDeleting: 0.048)
    }

    private struct Shared {
        var isVietnamese: Bool
        var fixesAutocomplete = false
        var pacing = Pacing.none
        var needsReset = false
    }

    /// Marks the events this tap posts, so it never rewrites its own output.
    private static let marker: Int64 = 0x534D_5456 // "SMTV"
    /// Typed and deleted again before rewriting a word, so a browser's
    /// address-bar autocompletion (selected text) isn't what gets deleted.
    private static let autocompleteBreaker = "\u{202F}"

    private let shared: Mutex<Shared>
    private let onSwitch: @Sendable (Bool) -> Void
    private let source = CGEventSource(stateID: .privateState)

    // Touched only on the tap thread (or before it starts).
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var session = TelexSession()
    private var switchArmed = false

    /// `onSwitch` is called on the tap thread after ⌃⇧ switches the mode.
    init(isVietnamese: Bool, onSwitch: @escaping @Sendable (Bool) -> Void) {
        shared = Mutex(Shared(isVietnamese: isVietnamese))
        self.onSwitch = onSwitch
    }

    var isVietnamese: Bool {
        get { shared.withLock { $0.isVietnamese } }
        set { shared.withLock { $0.isVietnamese = newValue; $0.needsReset = true } }
    }

    /// Turns on the empty-character workaround for apps with inline autocompletion.
    func setFixesAutocomplete(_ fixes: Bool) {
        shared.withLock { $0.fixesAutocomplete = fixes }
    }

    func setPacing(_ pacing: Pacing) {
        shared.withLock { $0.pacing = pacing }
    }

    /// Forgets the current word, e.g. after switching apps.
    func resetWord() {
        shared.withLock { $0.needsReset = true }
    }

    /// Returns false when the tap can't be created (no Accessibility permission).
    func start() -> Bool {
        guard tap == nil else { return true }
        let events: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<TelexEventTap>.fromOpaque(refcon).takeUnretainedValue()
                    .handle(type, event, proxy: proxy)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap

        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            // Read the port through self: CFMachPort isn't Sendable.
            guard let tap = self.tap else {
                started.signal()
                return
            }
            runLoop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "Telex event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
        return true
    }

    /// Must be called before the last reference goes away: the tap points at
    /// this object without retaining it.
    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop { CFRunLoopStop(runLoop) }
        self.tap = nil
        runLoop = nil
    }

    // MARK: - Event handling

    private func handle(_ type: CGEventType, _ event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        let unchanged = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return unchanged
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A click can move the cursor anywhere.
            session.reset()
            switchArmed = false
            return unchanged
        case .flagsChanged:
            handleModifiers(event.flags)
            return unchanged
        case .keyDown:
            break
        default:
            return unchanged
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return unchanged }
        switchArmed = false

        let state = shared.withLock { shared in
            defer { shared.needsReset = false }
            return shared
        }
        if state.needsReset { session.reset() }
        guard state.isVietnamese else { return unchanged }

        // Shortcuts end the word.
        guard event.flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]) else {
            session.reset()
            return unchanged
        }
        if event.getIntegerValueField(.keyboardEventKeycode) == kVK_Delete {
            guard let edit = session.deleteBackward() else { return unchanged }
            post(edit, like: event, state: state, proxy: proxy)
            return nil
        }
        guard let key = Self.character(of: event) else {
            session.reset()
            return unchanged
        }
        guard let edit = session.type(key),
              edit != TelexSession.Edit(backspaces: 0, text: String(key)) else { return unchanged }
        post(edit, like: event, state: state, proxy: proxy)
        return nil
    }

    /// ⌃⇧ switches on release, and only if no other key was pressed meanwhile,
    /// so shortcuts like ⌃⇧Tab still work.
    private func handleModifiers(_ flags: CGEventFlags) {
        let switchKeys: CGEventFlags = [.maskControl, .maskShift]
        let modifiers = flags.intersection([.maskControl, .maskShift, .maskAlternate, .maskCommand])
        if modifiers == switchKeys {
            switchArmed = true
        } else if modifiers.isEmpty {
            if switchArmed {
                let isVietnamese = shared.withLock { shared in
                    shared.isVietnamese.toggle()
                    return shared.isVietnamese
                }
                session.reset()
                onSwitch(isVietnamese)
            }
            switchArmed = false
        } else if !switchKeys.isSuperset(of: modifiers) {
            switchArmed = false
        }
    }

    private static func character(of event: CGEvent) -> Character? {
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length, unicodeString: &characters)
        guard length == 1, let scalar = Unicode.Scalar(characters[0]) else { return nil }
        return Character(scalar)
    }

    // MARK: - Output

    /// Posts the edit right after the swallowed key `original`, from the tap
    /// thread: the user's next keys wait until it is done, so they can't
    /// slip in between.
    private func post(_ edit: TelexSession.Edit, like original: CGEvent, state: Shared, proxy: CGEventTapProxy) {
        let keyboardType = original.getIntegerValueField(.keyboardEventKeyboardType)
        let pacing = state.pacing
        var backspaces = edit.backspaces
        if backspaces > 0, state.fixesAutocomplete {
            postKey(0, text: Self.autocompleteBreaker, keyboardType: keyboardType, proxy: proxy)
            backspaces += 1
        }
        for _ in 0..<backspaces {
            postKey(CGKeyCode(kVK_Delete), text: nil, keyboardType: keyboardType, proxy: proxy)
            pause(pacing.betweenKeys)
        }
        if backspaces > 0 {
            pause(pacing.afterDeleting)
        }
        // One character per event: some apps drop the rest of a longer string.
        for character in edit.text {
            postKey(0, text: String(character), keyboardType: keyboardType, proxy: proxy)
            pause(pacing.betweenKeys)
        }
    }

    private func pause(_ interval: TimeInterval) {
        if interval > 0 { Thread.sleep(forTimeInterval: interval) }
    }

    private func postKey(_ keyCode: CGKeyCode, text: String?, keyboardType: Int64, proxy: CGEventTapProxy) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { continue }
            // Don't let held modifiers (e.g. ⇧ for a capital) change what's
            // typed. Non-coalesced, like real key presses, so nothing merges
            // or reorders them.
            event.flags = .maskNonCoalesced
            event.setIntegerValueField(.keyboardEventKeyboardType, value: keyboardType)
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            if let text {
                let utf16 = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            }
            event.tapPostEvent(proxy)
        }
    }
}
