import AppKit
import Carbon.HIToolbox
import Foundation

/// User settings, read once at launch from ~/.config/mrtab/config.json.
/// Every field has a working default, so a missing or malformed file is not an error.
struct Config {
    var modifier: String = "option"
    var key: String = "tab"

    var includeMinimized = true
    var includeHidden = true
    /// When false, only windows on the currently visible Space are listed.
    var showAllSpaces = true

    var panelWidth: CGFloat = 620
    var rowHeight: CGFloat = 36
    var maxVisibleRows = 12
    /// Seconds between safety-net full rescans. Observers do the real work; this only heals drift.
    var fullRefreshInterval: TimeInterval = 15

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mrtab/config.json")

    static func load() -> Config {
        var config = Config()
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return config }

        if let value = json["modifier"] as? String { config.modifier = value.lowercased() }
        if let value = json["key"] as? String { config.key = value.lowercased() }
        if let value = json["includeMinimized"] as? Bool { config.includeMinimized = value }
        if let value = json["includeHidden"] as? Bool { config.includeHidden = value }
        if let value = json["showAllSpaces"] as? Bool { config.showAllSpaces = value }
        if let value = json["panelWidth"] as? Double { config.panelWidth = CGFloat(value) }
        if let value = json["rowHeight"] as? Double { config.rowHeight = CGFloat(value) }
        if let value = json["maxVisibleRows"] as? Int { config.maxVisibleRows = max(1, value) }
        if let value = json["fullRefreshInterval"] as? Double { config.fullRefreshInterval = max(2, value) }
        return config
    }

    /// Writes the current values out so there is something to edit.
    func writeIfMissing() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: Config.path.path) else { return }
        let json: [String: Any] = [
            "modifier": modifier,
            "key": key,
            "includeMinimized": includeMinimized,
            "includeHidden": includeHidden,
            "showAllSpaces": showAllSpaces,
            "panelWidth": Double(panelWidth),
            "rowHeight": Double(rowHeight),
            "maxVisibleRows": maxVisibleRows,
            "fullRefreshInterval": fullRefreshInterval,
        ]
        try? fileManager.createDirectory(at: Config.path.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: json,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: Config.path)
    }

    // MARK: - Shortcut translation

    /// Carbon modifier mask for the hold-to-browse modifier.
    var carbonModifiers: UInt32 {
        switch modifier {
        case "command", "cmd": return UInt32(cmdKey)
        case "control", "ctrl": return UInt32(controlKey)
        case "shift": return UInt32(shiftKey)
        default: return UInt32(optionKey)
        }
    }

    /// The same modifier expressed as an `NSEvent` flag, used to detect release.
    var cocoaModifier: NSEvent.ModifierFlags {
        switch modifier {
        case "command", "cmd": return .command
        case "control", "ctrl": return .control
        case "shift": return .shift
        default: return .option
        }
    }

    var displayName: String {
        let symbol: String
        switch modifier {
        case "command", "cmd": symbol = "\u{2318}"
        case "control", "ctrl": symbol = "\u{2303}"
        case "shift": symbol = "\u{21E7}"
        default: symbol = "\u{2325}"
        }
        return symbol + " " + key.uppercased()
    }

    var carbonKeyCode: UInt32 {
        switch key {
        case "tab": return UInt32(kVK_Tab)
        case "space": return UInt32(kVK_Space)
        case "`", "grave": return UInt32(kVK_ANSI_Grave)
        case "escape", "esc": return UInt32(kVK_Escape)
        default: return UInt32(kVK_Tab)
        }
    }
}
