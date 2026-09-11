import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Drives the switcher: shows the panel, moves the selection while the modifier is held, and
/// focuses the chosen window on release.
///
/// The show path is deliberately trivial — read an array the store already published, hand it to
/// the view, order the panel front. No Accessibility calls, no allocation of windows or views.
final class SwitcherController {
    private var config: Config
    private let store: WindowStore
    private let panel: SwitcherPanel

    /// Everything the switcher opened with; `entries` is that list after the filter.
    private var allEntries: [WindowEntry] = []
    private var entries: [WindowEntry] = []
    private var query = ""
    /// Set by the first typed character. Searching is an unhurried, two-handed act and holding
    /// the browse modifier through it is not, so typing pins the panel open: release stops
    /// meaning "switch now", and Return, a click or Esc take over.
    private var isPinned = false
    private var isVisible = false
    private var previousApp: NSRunningApplication?

    /// Tracks Shift across flag changes so a press can be told from a release.
    private var shiftWasDown = false

    /// Raised when the gear in the panel header is clicked.
    var onOpenSettings: (() -> Void)?

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
        panel.switcherView.onSettings = { [weak self] in
            // Dismiss without switching, and without handing focus back to the previous app --
            // the settings window is about to take it.
            self?.hide()
            self?.onOpenSettings?()
        }
        // A pinned panel outlives the modifier, so clicking into another app has to dismiss it.
        // Unlike Esc it must not restore `previousApp`: the user has just chosen where to go.
        panel.onResignKey = { [weak self] in
            guard let self, self.isVisible, self.isPinned else { return }
            self.hide()
        }
    }

    /// Adopts settings changed while the app is running.
    func apply(config: Config) {
        self.config = config
        panel.apply(config: config)
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
        allEntries = store.snapshot
        entries = allEntries
        query = ""
        isPinned = false
        Log.write("show with \(entries.count) windows")
        guard !entries.isEmpty else {
            Log.write("nothing to show: window snapshot is empty")
            return
        }

        // Index 0 is the window you are in right now, so opening lands on the previous one —
        // the plain tap-and-release case switches straight back.
        render(selected: entries.count == 1 ? 0 : 1)

        previousApp = NSWorkspace.shared.frontmostApplication
        // Shift may already be down when the switcher opens; only later presses should step back.
        shiftWasDown = NSEvent.modifierFlags.contains(.shift)
        isVisible = true

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        installEventHandling()
    }

    private func render(selected: Int) {
        let rows = entries.map {
            SwitcherView.Row(appName: $0.appName, title: $0.title, pid: $0.pid,
                             isMinimized: $0.isMinimized, isAppHidden: $0.isAppHidden)
        }
        panel.switcherView.setQuery(query)
        panel.switcherView.setRows(rows, selected: selected)
        // The panel is sized to its contents, and filtering changes the row count on every
        // keystroke, so this has to run again each time rather than only on show.
        panel.positionForDisplay(width: config.panelWidth)
    }

    // MARK: - Filtering

    private var selectedRef: AXRef? {
        let index = panel.switcherView.selectedIndex
        return index < entries.count ? entries[index].ref : nil
    }

    /// Refilters in place, keeping the highlight on the same window wherever the narrowed list
    /// still holds it: refining a query you have already aimed should not move the target.
    private func applyQuery(keeping ref: AXRef?) {
        entries = WindowFilter.apply(query, to: allEntries)
        let selected = ref.flatMap { previous in entries.firstIndex { $0.ref == previous } } ?? 0
        render(selected: selected)
    }

    private func type(_ text: String) {
        let previous = selectedRef
        query += text
        isPinned = true
        applyQuery(keeping: previous)
    }

    private func backspace() {
        guard !query.isEmpty else { return }
        let previous = selectedRef
        query.removeLast()
        applyQuery(keeping: previous)
    }

    private func clearQuery() {
        guard !query.isEmpty else { return }
        let previous = selectedRef
        query = ""
        applyQuery(keeping: previous)
    }

    /// The printable part of a key event, or nil when this was not the user typing. Modifiers are
    /// ignored deliberately: the browse modifier is usually still down, so ⌥A has to reach the
    /// filter as "a" rather than as "å".
    private func typedText(from event: NSEvent) -> String? {
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              let characters = event.charactersIgnoringModifiers else { return nil }
        let typed = String(characters.filter {
            $0 == " " || $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol
        })
        guard !typed.isEmpty else { return nil }
        // A space before anything else is a stray keystroke, not the start of a search.
        if query.isEmpty, typed.allSatisfy({ $0 == " " }) { return nil }
        return typed
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
            guard let self, !self.isPinned,
                  self.config.shortcut.isReleased(in: event.modifierFlags) else { return }
            self.commit()
        }

        // Final safety net. Event monitors can be missed if the shortcut is tapped and released
        // faster than the panel comes up; polling the live modifier state cannot be.
        let timer = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            guard let self, self.isVisible, !self.isPinned else { return }
            if self.config.shortcut.isReleased(in: NSEvent.modifierFlags) {
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
            if !isPinned, config.shortcut.isReleased(in: event.modifierFlags) {
                commit()
                return true
            }
            // Backwards is a Shift press while the browse modifier is held — not a second hot
            // key. Tapping Shift repeatedly walks back up the list. Skipped when Shift *is* the
            // browse modifier, where the two meanings would collide, and once typing has begun,
            // where Shift is how you reach a capital letter.
            if config.shortcut.canUseShiftToGoBack {
                let shiftDown = event.modifierFlags.contains(.shift)
                let holding = !config.shortcut.isReleased(in: event.modifierFlags)
                if shiftDown && !shiftWasDown && holding && !isPinned { step(by: -1) }
                shiftWasDown = shiftDown
            }
            return false
        }

        // The shortcut key reaches the monitor as well as the hot key handler, which has already
        // stepped the selection for it. Swallow it rather than typing it into the filter.
        if event.keyCode == config.shortcut.keyCode,
           !config.shortcut.isReleased(in: event.modifierFlags) {
            return true
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            // Esc undoes one thing at a time: the filter first, then the switcher itself.
            if query.isEmpty { cancel() } else { clearQuery() }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            commit()
        case kVK_DownArrow, kVK_RightArrow:
            step(by: 1)
        case kVK_UpArrow, kVK_LeftArrow:
            step(by: -1)
        case kVK_Tab:
            // Only reached once the browse modifier is up — held, it belongs to the hot key and
            // was swallowed above. So this is a pinned panel being walked with bare Tab.
            step(by: event.modifierFlags.contains(.shift) ? -1 : 1)
        case kVK_Delete:
            backspace()
        case kVK_ANSI_W where event.modifierFlags.contains(.command):
            // Closing a window has to take ⌘ now that a bare W is the first letter of a search.
            closeSelectedWindow()
        default:
            guard let text = typedText(from: event) else { return false }
            type(text)
        }
        return true
    }

    // MARK: - Outcomes

    private func commit() {
        guard isVisible else { return }
        let index = panel.switcherView.selectedIndex
        guard index < entries.count else {
            // Nothing matches what was typed, so there is nowhere to go: stay where you were.
            cancel()
            return
        }
        let entry = entries[index]
        hide()
        focus(entry)
    }

    private func cancel() {
        guard isVisible else { return }
        let app = previousApp
        hide()
        app?.activate(options: [])
    }

    private func hide() {
        isVisible = false
        isPinned = false
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

        allEntries.removeAll { $0.ref == entry.ref }
        entries.remove(at: index)
        if allEntries.isEmpty {
            hide()
            return
        }
        render(selected: min(index, max(0, entries.count - 1)))
    }
}
