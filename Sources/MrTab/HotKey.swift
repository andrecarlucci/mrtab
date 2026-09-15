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
    /// Raised with 1-9 when one of the jump chords is pressed.
    var onJump: ((Int) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var jumpRefs: [EventHotKeyRef] = []

    private static let signature: OSType = 0x4D525442 // 'MRTB'
    private static let hotKeyID: UInt32 = 1
    /// The jump chords take ids 101-109, one per digit, so the handler can tell which was pressed
    /// from the id alone rather than decoding the key code again.
    private static let jumpIDBase: UInt32 = 100

    /// Stepping backwards is handled by the controller as a Shift press while the switcher is
    /// open, not by a second hot key, so only the base shortcut is registered here.
    @discardableResult
    func register(shortcut: Shortcut) -> OSStatus {
        unregisterSwitcher()
        installHandler()
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        return RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id,
                                   GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    /// Registers all nine digit chords at once and reports the first one that would not take.
    /// They share a modifier, so in practice they fail together or not at all.
    @discardableResult
    func register(jump: JumpShortcut) -> OSStatus {
        unregisterJumps()
        guard jump.isEnabled else { return noErr }
        installHandler()

        var failure = noErr
        for (index, keyCode) in JumpShortcut.digitKeyCodes.enumerated() {
            let id = EventHotKeyID(signature: Self.signature,
                                   id: Self.jumpIDBase + UInt32(index + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(keyCode), jump.carbonModifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if let ref { jumpRefs.append(ref) }
            if status != noErr, failure == noErr { failure = status }
        }
        return failure
    }

    func unregister() {
        unregisterSwitcher()
        unregisterJumps()
    }

    private func unregisterSwitcher() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func unregisterJumps() {
        for ref in jumpRefs { UnregisterEventHotKey(ref) }
        jumpRefs.removeAll()
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
            switch hotKeyID.id {
            case HotKeyManager.hotKeyID:
                manager.onTrigger?()
            case let id where id > HotKeyManager.jumpIDBase:
                manager.onJump?(Int(id - HotKeyManager.jumpIDBase))
            default:
                return OSStatus(eventNotHandledErr)
            }
            return noErr
        }, 1, &spec, context, &handlerRef)
    }
}
