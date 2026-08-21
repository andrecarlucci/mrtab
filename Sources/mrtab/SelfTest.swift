import AppKit

/// Development affordance: renders the switcher list to PNGs and exits.
///
/// Useful because it exercises the real drawing code with no Accessibility or Screen Recording
/// permission involved — running applications supply plausible names and icons on their own.
/// Both appearances are rendered, since the row text uses dynamic system colours that resolve
/// against the effective appearance at draw time.
///
///     MRTAB_RENDER=/tmp/switcher.png build/mrtab.app/Contents/MacOS/mrtab
///     # writes /tmp/switcher-dark.png and /tmp/switcher-light.png
enum SelfTest {
    static func renderIfRequested(config: Config) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["MRTAB_RENDER"] else { return false }
        let base = URL(fileURLWithPath: path).deletingPathExtension().path

        render(rows: makeRows(), config: config, to: "\(base).png")
        return true
    }

    private static func makeRows() -> [SwitcherView.Row] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        IconCache.shared.warm(pids: apps.map(\.processIdentifier))

        let rows = apps.enumerated().map { index, app in
            SwitcherView.Row(appName: app.localizedName ?? "Unknown",
                             title: sampleTitles[index % sampleTitles.count],
                             pid: app.processIdentifier,
                             isMinimized: index % 5 == 3,
                             isAppHidden: app.isHidden)
        }
        return rows.isEmpty
            ? [SwitcherView.Row(appName: "Finder", title: "Downloads", pid: 0,
                                isMinimized: false, isAppHidden: false)]
            : rows
    }

    private static func render(rows: [SwitcherView.Row], config: Config, to path: String) {
        let view = SwitcherView()
        view.configure(rowHeight: config.rowHeight, maxVisibleRows: config.maxVisibleRows)
        view.setRows(rows, selected: min(1, rows.count - 1))
        view.frame = NSRect(x: 0, y: 0, width: config.panelWidth, height: view.contentHeight)

        // Render over a stand-in for blurred wallpaper rather than a flat fill. Flat backdrops
        // flatter the design: the contrast that actually matters is against whatever colours
        // happen to be behind the panel.
        let backdrop = BackdropView(frame: view.bounds)
        backdrop.appearance = NSAppearance(named: SwitcherPanel.appearanceName)
        backdrop.addSubview(view)

        guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { return }
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardOutput.write(Data("rendered \(rows.count) rows to \(path)\n".utf8))
    }

    /// Approximates a colourful desktop seen through the panel's vibrancy material.
    private final class BackdropView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSGradient(colors: [
                NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.80, alpha: 1),
                NSColor(calibratedRed: 0.92, green: 0.55, blue: 0.20, alpha: 1),
                NSColor(calibratedRed: 0.97, green: 0.94, blue: 0.70, alpha: 1),
                NSColor(calibratedRed: 0.20, green: 0.15, blue: 0.40, alpha: 1),
            ])?.draw(in: bounds, angle: 25)
            NSColor.black.withAlphaComponent(0.55).setFill()
            bounds.fill(using: .sourceOver)
        }
    }

    private static let sampleTitles = [
        "Hacker News: front page",
        "",
        "mrtab — SwitcherView.swift — a really long window title that has to be truncated somewhere",
        "#general",
        "Inbox (2,417)",
        "~/dev/mrtab — zsh — 120×40",
    ]
}
