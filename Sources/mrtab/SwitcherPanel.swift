import AppKit

/// The floating switcher window.
///
/// Created once at launch and never destroyed — showing it is an `orderFront`, not a window
/// instantiation. A borderless `NSPanel` is used so it can appear over full-screen apps and on
/// every Space without disturbing the current app's window ordering.
final class SwitcherPanel: NSPanel {
    let switcherView = SwitcherView()

    private let visualEffect = NSVisualEffectView()
    private let cornerRadius: CGFloat = 14

    init(config: Config) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: config.panelWidth, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        // Above full-screen apps and the Dock, but below system alerts.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        // The panel is shown and hidden constantly; never let it end up in the window menu
        // or the Dock's window list.
        isExcludedFromWindowsMenu = true

        // Explicit frames matter: a subview added at zero size with an autoresizing mask stays
        // at zero size, because autoresizing scales proportionally from what it starts with.
        let contentRect = NSRect(x: 0, y: 0, width: config.panelWidth, height: 100)
        visualEffect.frame = contentRect
        switcherView.frame = contentRect

        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = cornerRadius
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.layer?.masksToBounds = true
        visualEffect.autoresizingMask = [.width, .height]

        switcherView.autoresizingMask = [.width, .height]
        switcherView.configure(rowHeight: config.rowHeight, maxVisibleRows: config.maxVisibleRows)
        visualEffect.addSubview(switcherView)

        contentView = visualEffect
    }

    /// A borderless panel refuses key status by default, which would leave arrow keys and Escape
    /// going to whatever app is frontmost.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Forces the window server to allocate the backing store and run one full draw pass, so the
    /// first real invocation is not paying for it. Called once, off-screen, at launch.
    func prewarm() {
        switcherView.setRows([SwitcherView.Row(appName: "\u{200B}", title: "", pid: 0,
                                               isMinimized: false, isAppHidden: false)],
                             selected: 0)
        setFrame(NSRect(x: -10_000, y: -10_000, width: frame.width, height: 100), display: true)
        orderFront(nil)
        displayIfNeeded()
        orderOut(nil)
        switcherView.setRows([], selected: 0)
    }

    /// Sizes to the current row count and centres on the screen holding the pointer.
    func positionForDisplay(width: CGFloat) {
        let height = switcherView.contentHeight
        let screen = Self.activeScreen()
        let visible = screen.visibleFrame
        let clampedWidth = min(width, visible.width - 40)
        let clampedHeight = min(height, visible.height - 40)

        let origin = NSPoint(x: visible.midX - clampedWidth / 2,
                             y: visible.midY - clampedHeight / 2)
        setFrame(NSRect(origin: origin, size: NSSize(width: clampedWidth, height: clampedHeight)),
                 display: false)
    }

    private static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
