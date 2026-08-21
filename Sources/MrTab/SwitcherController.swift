import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Drives the switcher: shows the panel, moves the selection while the modifier is held, and
/// focuses the chosen window on release.
///
/// The show path is deliberately trivial — read an array the store already published, hand it to
/// the view, order the panel front. No Accessibility calls, no allocation of windows or views.
final class SwitcherController {
    private let config: Config
    private let store: WindowStore
    private let panel: SwitcherPanel

    private var entries: [WindowEntry] = []
    private var isVisible = false
    private var previousApp: NSRunningApplication?

    /// Tracks Shift across flag changes so a press can be told from a release.
    private var shiftWasDown = false

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var modifierPoll: Timer?

    init(config: Config, store: WindowStore) {
        self.config = config
        self.store = store
        self.panel = SwitcherPanel(config: config)

        panel.switcherView.onHover = { [weak self] index in
            self?.panel.switcherView.select(index)
        }
        panel.switcherView.onClick = { [weak self] index in
            self?.panel.switcherView.select(index)
            self?.commit()
        }
    }

    func prewarm() {
        panel.prewarm()
    }

    // MARK: - Entry point

    /// Called from the hot key handler. Must stay cheap.
    func trigger() {
        if isVisible {
            step(by: 1)
        } else {
            show()
        }
    }

    private func show() {
        entries = store.snapshot
        Log.write("show with \(entries.count) windows")
        guard !entries.isEmpty else {
            Log.write("nothing to show: window snapshot is empty")
            return
        }

        let rows = entries.map {
            SwitcherView.Row(appName: $0.appName, title: $0.title, pid: $0.pid,
                             isMinimized: $0.isMinimized, isAppHidden: $0.isAppHidden)
        }
        // Index 0 is the window you are in right now, so opening lands on the previous one —
        // the plain tap-and-release case switches straight back.
        let initial = entries.count == 1 ? 0 : 1

        panel.switcherView.setRows(rows, selected: initial)
        panel.positionForDisplay(width: config.panelWidth)

        previousApp = NSWorkspace.shared.frontmostApplication
        // Shift may already be down when the switcher opens; only later presses should step back.
        shiftWasDown = NSEvent.modifierFlags.contains(.shift)
        isVisible = true

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        installEventHandling()
    }

    private func step(by delta: Int) {
        guard !entries.isEmpty else { return }
        let count = entries.count
        let next = ((panel.switcherView.selectedIndex + delta) % count + count) % count
        panel.switcherView.select(next)
    }

    // MARK: - Event handling while visible

    private func installEventHandling() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event: event) ? nil : event
        }

        // Backstop for the case where the panel never becomes key: a global monitor cannot
        // consume events, but it can still tell us the modifier came up.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self, !event.modifierFlags.contains(self.config.cocoaModifier) else { return }
            self.commit()
        }

        // Final safety net. Event monitors can be missed if the shortcut is tapped and released
        // faster than the panel comes up; polling the live modifier state cannot be.
        let timer = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            if !NSEvent.modifierFlags.contains(self.config.cocoaModifier) {
                self.commit()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierPoll = timer
    }

    private func removeEventHandling() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        modifierPoll?.invalidate()
        modifierPoll = nil
    }

    /// Returns true when the event was consumed.
    private func handle(event: NSEvent) -> Bool {
        guard isVisible else { return false }

        if event.type == .flagsChanged {
            if !event.modifierFlags.contains(config.cocoaModifier) {
                commit()
                return true
            }
            // Backwards is a Shift press while the browse modifier is held — not a second hot
            // key. Tapping Shift repeatedly walks back up the list. Skipped when Shift *is* the
            // browse modifier, where the two meanings would collide.
            if config.cocoaModifier != .shift {
                let shiftDown = event.modifierFlags.contains(.shift)
                if shiftDown && !shiftWasDown { step(by: -1) }
                shiftWasDown = shiftDown
            }
            return false
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            commit()
        case kVK_DownArrow, kVK_RightArrow:
            step(by: 1)
        case kVK_UpArrow, kVK_LeftArrow:
            step(by: -1)
        case kVK_Tab:
            // Plain modifier+Tab is swallowed by the hot key, so a Tab arriving here means Shift
            // was also held. The Shift press has already stepped back; swallow the Tab rather
            // than stepping twice or letting it escape to another app.
            break
        case kVK_ANSI_W:
            closeSelectedWindow()
        default:
            return false
        }
        return true
    }

    // MARK: - Outcomes

    private func commit() {
        guard isVisible else { return }
        let index = panel.switcherView.selectedIndex
        let entry = index < entries.count ? entries[index] : nil
        hide()
        if let entry { focus(entry) }
    }

    private func cancel() {
        guard isVisible else { return }
        let app = previousApp
        hide()
        app?.activate(options: [])
    }

    private func hide() {
        isVisible = false
        removeEventHandling()
        panel.orderOut(nil)
        previousApp = nil
        store.requestRefresh()
    }

    /// Focus is done off the main thread: raising a window is Accessibility IPC, and an app that
    /// is busy should not be able to stall the UI. The panel is already gone by this point.
    private func focus(_ entry: WindowEntry) {
        store.markUsed(entry.ref)
        let element = entry.axElement
        let pid = entry.pid
        let wasMinimized = entry.isMinimized

        DispatchQueue.global(qos: .userInitiated).async {
            element.setMessagingTimeout(0.5)
            if wasMinimized {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            let app = NSRunningApplication(processIdentifier: pid)
            if app?.isHidden == true { app?.unhide() }

            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            app?.activate(options: [])
        }
    }

    private func closeSelectedWindow() {
        let index = panel.switcherView.selectedIndex
        guard index < entries.count else { return }
        let entry = entries[index]

        DispatchQueue.global(qos: .userInitiated).async {
            guard let button = axElement(entry.axElement, kAXCloseButtonAttribute as String) else { return }
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }

        entries.remove(at: index)
        if entries.isEmpty {
            hide()
            return
        }
        let rows = entries.map {
            SwitcherView.Row(appName: $0.appName, title: $0.title, pid: $0.pid,
                             isMinimized: $0.isMinimized, isAppHidden: $0.isAppHidden)
        }
        panel.switcherView.setRows(rows, selected: min(index, entries.count - 1))
        panel.positionForDisplay(width: config.panelWidth)
    }
}
