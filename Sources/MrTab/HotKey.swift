import AppKit
import Carbon.HIToolbox

/// System-wide shortcut registration via Carbon's `RegisterEventHotKey`.
///
/// Carbon is used rather than a `CGEventTap` deliberately: a hot key is delivered by the window
/// server directly to this process with no interposition on the whole event stream, it needs no
/// Input Monitoring permission, and it keeps firing while the modifier is held — which is exactly
/// the "hold and keep tabbing" behaviour the switcher needs.
final class HotKeyManager {
    var onTrigger: (() -> Void)?

    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    private static let signature: OSType = 0x4D525442 // 'MRTB'
    private static let hotKeyID: UInt32 = 1

    /// Stepping backwards is handled by the controller as a Shift press while the switcher is
    /// open, not by a second hot key, so only the base shortcut is registered here.
    @discardableResult
    func register(shortcut: Shortcut) -> OSStatus {
        unregister()
        installHandler()
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        return RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id,
                                   GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotKeyManager.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.onTrigger?()
            return noErr
        }, 1, &spec, context, &handlerRef)
    }
}
