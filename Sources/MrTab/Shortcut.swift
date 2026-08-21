import AppKit
import Carbon.HIToolbox

/// A hold-to-browse shortcut: one or more modifiers plus a key.
///
/// The modifiers are not decoration. They are what keeps the switcher open — it stays up until
/// they are released — so a shortcut without a holdable modifier cannot work, which `isValid`
/// enforces.
struct Shortcut: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    static let `default` = Shortcut(keyCode: UInt16(kVK_Tab), modifiers: .option)

    /// Shift alone will not do: it is the gesture for stepping backwards, and pairing it with
    /// itself would make the two meanings collide.
    var isValid: Bool {
        !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    /// True once every modifier this shortcut needs has been let go.
    func isReleased(in flags: NSEvent.ModifierFlags) -> Bool {
        !flags.contains(modifiers)
    }

    /// Shift can double as "step backwards" only when it is not part of the shortcut itself.
    var canUseShiftToGoBack: Bool {
        !modifiers.contains(.shift)
    }

    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Rendered in the order Apple uses in menus: control, option, shift, command.
    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "\u{2303}" }
        if modifiers.contains(.option) { result += "\u{2325}" }
        if modifiers.contains(.shift) { result += "\u{21E7}" }
        if modifiers.contains(.command) { result += "\u{2318}" }
        return result + KeyNames.name(for: keyCode)
    }

    // MARK: - Persistence

    private static let modifierNames: [(NSEvent.ModifierFlags, String)] = [
        (.control, "control"), (.option, "option"), (.shift, "shift"), (.command, "command"),
    ]

    var json: [String: Any] {
        ["keyCode": Int(keyCode),
         "modifiers": Self.modifierNames.filter { modifiers.contains($0.0) }.map(\.1)]
    }

    static func from(json: [String: Any]) -> Shortcut? {
        guard let keyCode = json["keyCode"] as? Int,
              let names = json["modifiers"] as? [String] else { return nil }
        var flags = NSEvent.ModifierFlags()
        for (flag, name) in modifierNames where names.contains(name) { flags.insert(flag) }
        return Shortcut(keyCode: UInt16(keyCode), modifiers: flags)
    }

    /// Reads the original `{"modifier": "option", "key": "tab"}` form, so a config file written
    /// by an earlier version keeps working.
    static func fromLegacy(modifier: String?, key: String?) -> Shortcut? {
        guard modifier != nil || key != nil else { return nil }
        let flags: NSEvent.ModifierFlags
        switch modifier?.lowercased() {
        case "command", "cmd": flags = .command
        case "control", "ctrl": flags = .control
        case "shift": flags = .shift
        default: flags = .option
        }
        let keyCode: Int
        switch key?.lowercased() {
        case "space": keyCode = kVK_Space
        case "`", "grave": keyCode = kVK_ANSI_Grave
        case "escape", "esc": keyCode = kVK_Escape
        default: keyCode = kVK_Tab
        }
        return Shortcut(keyCode: UInt16(keyCode), modifiers: flags)
    }
}

/// Virtual key code to display name. Key codes are positional, so this is the layout-independent
/// mapping used by every shortcut UI on the platform.
enum KeyNames {
    static func name(for keyCode: UInt16) -> String {
        table[Int(keyCode)] ?? "Key \(keyCode)"
    }

    private static let table: [Int: String] = {
        var names: [Int: String] = [
            kVK_Tab: "Tab", kVK_Space: "Space", kVK_Return: "Return", kVK_Escape: "Esc",
            kVK_Delete: "Delete", kVK_ForwardDelete: "Fwd Del", kVK_Help: "Help",
            kVK_LeftArrow: "\u{2190}", kVK_RightArrow: "\u{2192}",
            kVK_UpArrow: "\u{2191}", kVK_DownArrow: "\u{2193}",
            kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
            kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
            kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
            kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        ]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
            (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
            (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
            (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
        ]
        let digits: [(Int, String)] = [
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
        ]
        let functions: [(Int, String)] = [
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"),
            (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"),
            (kVK_F11, "F11"), (kVK_F12, "F12"),
        ]
        for (code, name) in letters + digits + functions { names[code] = name }
        return names
    }()
}
