import AppKit
import Carbon.HIToolbox

/// System-wide shortcut registration via Carbon's `RegisterEventHotKey`.
///
/// Carbon is used rather than a `CGEventTap` deliberately: a hot key is delivered by the window
/// server directly to this process with no interposition on the whole event stream, it needs no
/// Input Monitoring permission, and it keeps firing while the modifier is held — which is exactly
/// the "hold and keep tabbing" behaviour the switcher needs.
final class HotKeyManager {
    /// Called with `true` to step forward, `false` to step backward.
    var onTrigger: ((Bool) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var forwardRef: EventHotKeyRef?
    private var backwardRef: EventHotKeyRef?

    private static let signature: OSType = 0x4D525442 // 'MRTB'
    private static let forwardID: UInt32 = 1
    private static let backwardID: UInt32 = 2

    struct Result {
        let forward: OSStatus
        let backward: OSStatus
        var ok: Bool { forward == noErr }
    }

    @discardableResult
    func register(config: Config) -> Result {
        installHandler()

        let keyCode = config.carbonKeyCode
        let modifiers = config.carbonModifiers

        let forward = register(id: Self.forwardID, keyCode: keyCode,
                               modifiers: modifiers, into: &forwardRef)
        // Shift is the universal "go the other way" convention, so pair it with the base shortcut.
        let backward = register(id: Self.backwardID, keyCode: keyCode,
                                modifiers: modifiers | UInt32(shiftKey), into: &backwardRef)
        return Result(forward: forward, backward: backward)
    }

    func unregister() {
        if let forwardRef { UnregisterEventHotKey(forwardRef) }
        if let backwardRef { UnregisterEventHotKey(backwardRef) }
        forwardRef = nil
        backwardRef = nil
    }

    private func register(id: UInt32, keyCode: UInt32, modifiers: UInt32,
                          into ref: inout EventHotKeyRef?) -> OSStatus {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        return RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                   GetApplicationEventTarget(), 0, &ref)
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
            manager.onTrigger?(hotKeyID.id == HotKeyManager.forwardID)
            return noErr
        }, 1, &spec, context, &handlerRef)
    }
}
