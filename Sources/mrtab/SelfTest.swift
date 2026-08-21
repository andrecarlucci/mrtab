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

        let rows = makeRows()
        for (suffix, appearance, backdrop) in [
            ("dark", NSAppearance.Name.darkAqua, NSColor(calibratedWhite: 0.17, alpha: 1)),
            ("light", NSAppearance.Name.aqua, NSColor(calibratedWhite: 0.93, alpha: 1)),
        ] {
            render(rows: rows, config: config, appearance: appearance,
                   backdrop: backdrop, to: "\(base)-\(suffix).png")
        }
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

    private static func render(rows: [SwitcherView.Row], config: Config,
                               appearance: NSAppearance.Name, backdrop: NSColor, to path: String) {
        let view = SwitcherView()
        view.appearance = NSAppearance(named: appearance)
        view.configure(rowHeight: config.rowHeight, maxVisibleRows: config.maxVisibleRows)
        view.setRows(rows, selected: min(1, rows.count - 1))
        view.frame = NSRect(x: 0, y: 0, width: config.panelWidth, height: view.contentHeight)

        // The real panel sits on a blurred backdrop supplied by NSVisualEffectView; stand in for
        // it with a flat fill so contrast is judgeable.
        view.wantsLayer = true
        view.layer?.backgroundColor = backdrop.cgColor
        view.layer?.cornerRadius = 14

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardOutput.write(Data("rendered \(rows.count) rows to \(path)\n".utf8))
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
