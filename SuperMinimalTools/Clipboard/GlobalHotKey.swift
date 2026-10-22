//
//  GlobalHotKey.swift
//  SuperMinimalTools
//

import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Carbon's RegisterEventHotKey is still the
/// only API for this that needs no Accessibility or Input Monitoring permission.
@MainActor
final class GlobalHotKey {

    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Returns nil when the shortcut can't be registered (e.g. another app owns it).
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                // Carbon delivers hot key events on the main thread.
                MainActor.assumeIsolated {
                    Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
                }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        let hotKeyID = EventHotKeyID(signature: OSType(0x534D_5448), id: 1) // "SMTH"
        let registered = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard installed == noErr, registered == noErr else {
            unregister()
            return nil
        }
    }

    /// Must be called before the last reference goes away: the event handler
    /// points at this object without retaining it.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
