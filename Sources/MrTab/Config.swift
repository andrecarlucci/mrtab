import AppKit
import Foundation

/// User settings, read at launch from ~/.config/mrtab/config.json and rewritten whenever the
/// settings window changes something. Every field has a working default, so a missing or
/// malformed file is not an error.
struct Config: Equatable {
    var shortcut: Shortcut = .default

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

        if let raw = json["shortcut"] as? [String: Any], let shortcut = Shortcut.from(json: raw) {
            config.shortcut = shortcut
        } else if let legacy = Shortcut.fromLegacy(modifier: json["modifier"] as? String,
                                                   key: json["key"] as? String) {
            config.shortcut = legacy
        }
        if !config.shortcut.isValid { config.shortcut = .default }

        if let value = json["includeMinimized"] as? Bool { config.includeMinimized = value }
        if let value = json["includeHidden"] as? Bool { config.includeHidden = value }
        if let value = json["showAllSpaces"] as? Bool { config.showAllSpaces = value }
        if let value = json["panelWidth"] as? Double { config.panelWidth = CGFloat(value) }
        if let value = json["rowHeight"] as? Double { config.rowHeight = CGFloat(value) }
        if let value = json["maxVisibleRows"] as? Int { config.maxVisibleRows = max(1, value) }
        if let value = json["fullRefreshInterval"] as? Double { config.fullRefreshInterval = max(2, value) }
        return config
    }

    func save() {
        let json: [String: Any] = [
            "shortcut": shortcut.json,
            "includeMinimized": includeMinimized,
            "includeHidden": includeHidden,
            "showAllSpaces": showAllSpaces,
            "panelWidth": Double(panelWidth),
            "rowHeight": Double(rowHeight),
            "maxVisibleRows": maxVisibleRows,
            "fullRefreshInterval": fullRefreshInterval,
        ]
        try? FileManager.default.createDirectory(at: Config.path.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: json,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: Config.path)
    }

    func writeIfMissing() {
        guard !FileManager.default.fileExists(atPath: Config.path.path) else { return }
        save()
    }

    var displayName: String { shortcut.displayString }

    // MARK: - Bounds for the settings sliders

    static let panelWidthRange: ClosedRange<Double> = 420...1000
    static let rowHeightRange: ClosedRange<Double> = 28...52
    static let visibleRowsRange: ClosedRange<Double> = 5...25
}
