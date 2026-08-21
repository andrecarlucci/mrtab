import AppKit
import ApplicationServices
import Foundation

/// One switchable window. Everything the hotkey path needs is already resolved here —
/// no Accessibility round-trip happens while the panel is being shown.
struct WindowEntry {
    let ref: AXRef
    let pid: pid_t
    var title: String
    var appName: String
    var bundleID: String?
    var isMinimized: Bool
    var isAppHidden: Bool
    var onCurrentSpace: Bool
    var frame: CGRect
    /// Monotonic recency stamp; higher is more recently focused.
    var focusStamp: UInt64

    var axElement: AXUIElement { ref.element }
}

/// Tracks every window on the system and publishes an immutable, MRU-sorted snapshot to the
/// main thread.
///
/// The design constraint is that pressing the shortcut must cost nothing: all Accessibility IPC
/// happens on `queue`, driven by AX observer notifications, and the result is handed to the main
/// thread as a plain array. `snapshot` is therefore always ready to render.
final class WindowStore {
    /// Main-thread-only. Read this from the hotkey handler; never touch AX there.
    private(set) var snapshot: [WindowEntry] = []

    private var config: Config
    private let queue = DispatchQueue(label: "dev.mrtab.store", qos: .userInitiated)

    /// Everything below is confined to `queue`.
    private var entries: [AXRef: WindowEntry] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var appElements: [pid_t: AXUIElement] = [:]
    private var observedWindows: Set<AXRef> = []
    private var focusCounter: UInt64 = 0
    private var hasSeededOrder = false
    private var refreshTimer: DispatchSourceTimer?

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Notifications watched on the *application* element.
    private static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]

    /// Notifications watched on each *window* element.
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXTitleChangedNotification,
    ]

    init(config: Config) {
        self.config = config
    }

    // MARK: - Lifecycle

    func start() {
        subscribeToWorkspace()
        queue.async { [weak self] in self?.performFullRefresh() }
        startRefreshTimer()
    }

    /// Adopts settings changed from the settings window and republishes with the new filters.
    func update(config: Config) {
        queue.async { [weak self] in
            guard let self else { return }
            self.config = config
            self.publish()
        }
    }

    /// Nudges a rescan. Called after the switcher closes so the next invocation is accurate.
    func requestRefresh() {
        queue.async { [weak self] in self?.performFullRefresh() }
    }

    private func startRefreshTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + config.fullRefreshInterval,
                       repeating: config.fullRefreshInterval,
                       leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.performFullRefresh() }
        timer.resume()
        refreshTimer = timer
    }

    // MARK: - Workspace observation

    private func subscribeToWorkspace() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let app = note.runningApp else { return }
            self?.handleAppActivated(pid: app.processIdentifier)
        }

        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let app = note.runningApp else { return }
            let pid = app.processIdentifier
            // A freshly launched app has no windows yet; give it a moment to open one.
            self?.queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.refreshApp(pid: pid)
                self?.publish()
            }
        }

        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let app = note.runningApp else { return }
            self?.handleAppTerminated(pid: app.processIdentifier)
        }

        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.requestRefresh()
        }
    }

    private func handleAppActivated(pid: pid_t) {
        guard pid != ownPID else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.refreshApp(pid: pid)
            // Promote the app's focused window to the top of the MRU list.
            if let appElement = self.appElements[pid],
               let focused = axElement(appElement, kAXFocusedWindowAttribute as String) {
                self.touch(AXRef(focused))
            } else if let newest = self.entries.values
                .filter({ $0.pid == pid })
                .max(by: { $0.focusStamp < $1.focusStamp }) {
                // No focused window reported — promote whichever of its windows is newest.
                self.touch(newest.ref)
            }
            self.publish()
        }
    }

    private func handleAppTerminated(pid: pid_t) {
        queue.async { [weak self] in
            guard let self else { return }
            for (ref, entry) in self.entries where entry.pid == pid {
                self.entries.removeValue(forKey: ref)
                self.observedWindows.remove(ref)
            }
            if let observer = self.observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                      AXObserverGetRunLoopSource(observer),
                                      .defaultMode)
            }
            self.appElements.removeValue(forKey: pid)
            self.publish()
        }
    }

    // MARK: - Enumeration (queue-confined)

    private func performFullRefresh() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isTerminated
        }
        let livePIDs = Set(apps.map(\.processIdentifier))

        // Drop anything belonging to an app that went away.
        entries = entries.filter { livePIDs.contains($0.value.pid) }

        let zOrder = windowServerZOrder()

        for app in apps {
            refreshApp(pid: app.processIdentifier, runningApp: app, zOrder: zOrder)
        }

        if !hasSeededOrder && !entries.isEmpty {
            hasSeededOrder = true
            seedInitialOrder(using: zOrder)
        }
        publish()
    }

    private func refreshApp(pid: pid_t,
                            runningApp: NSRunningApplication? = nil,
                            zOrder: [SpaceKey: Int]? = nil) {
        guard pid != ownPID else { return }
        guard let app = runningApp ?? NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular, !app.isTerminated else { return }

        let appElement = appElements[pid] ?? {
            let element = AXUIElementCreateApplication(pid)
            element.setMessagingTimeout(0.25)
            appElements[pid] = element
            return element
        }()

        installObserver(for: pid, appElement: appElement)

        // Space membership is derived from the window server's on-screen list. Only pay for it
        // when the user actually asked to hide off-Space windows.
        let spaceKeys: [SpaceKey: Int]? = config.showAllSpaces ? nil : (zOrder ?? windowServerZOrder())

        let appName = app.localizedName ?? "Unknown"
        let bundleID = app.bundleIdentifier
        let isHidden = app.isHidden

        var seen: Set<AXRef> = []

        for window in axChildElements(appElement, kAXWindowsAttribute as String) {
            let minimized = axBool(window, kAXMinimizedAttribute as String) ?? false
            guard let frame = switchableFrame(of: window, isMinimized: minimized) else { continue }

            let ref = AXRef(window)
            seen.insert(ref)

            let title = (axString(window, kAXTitleAttribute as String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // A minimized or hidden window is not on screen anywhere, so it cannot be judged by
            // the on-screen list; treat it as always available.
            let onCurrentSpace: Bool
            if let spaceKeys, !minimized, !isHidden {
                onCurrentSpace = spaceKeys[SpaceKey(pid: pid, frame: frame)] != nil
            } else {
                onCurrentSpace = true
            }

            if var existing = entries[ref] {
                existing.title = title
                existing.appName = appName
                existing.isMinimized = minimized
                existing.isAppHidden = isHidden
                existing.onCurrentSpace = onCurrentSpace
                existing.frame = frame
                entries[ref] = existing
            } else {
                focusCounter += 1
                entries[ref] = WindowEntry(ref: ref, pid: pid, title: title, appName: appName,
                                           bundleID: bundleID, isMinimized: minimized,
                                           isAppHidden: isHidden, onCurrentSpace: onCurrentSpace,
                                           frame: frame, focusStamp: focusCounter)
                observeWindow(ref, observer: observers[pid])
            }
        }

        // Forget windows this app no longer reports.
        for (ref, entry) in entries where entry.pid == pid && !seen.contains(ref) {
            entries.removeValue(forKey: ref)
            observedWindows.remove(ref)
        }
    }

    /// Returns the window's frame if it is something a user would want to switch to, else nil.
    /// Filters out toolbars, popovers, sheets and zero-size helper windows.
    private func switchableFrame(of window: AXUIElement, isMinimized: Bool) -> CGRect? {
        guard axString(window, kAXRoleAttribute as String) == kAXWindowRole as String else { return nil }
        let subrole = axString(window, kAXSubroleAttribute as String)
        guard subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String else {
            return nil
        }
        guard let frame = axFrame(window) else { return isMinimized ? .zero : nil }
        // Minimized windows report unreliable geometry, so the size filter would wrongly drop them.
        if !isMinimized && (frame.width < 40 || frame.height < 40) { return nil }
        return frame
    }

    // MARK: - Window server ordering

    /// Identifies a window by owner + rounded frame, which is enough to correlate an AX window
    /// with a `CGWindowList` entry without reaching for private API.
    private struct SpaceKey: Hashable {
        let pid: pid_t
        let x: Int, y: Int, w: Int, h: Int

        init(pid: pid_t, frame: CGRect) {
            self.init(pid: pid,
                      x: Int(frame.origin.x.rounded()), y: Int(frame.origin.y.rounded()),
                      w: Int(frame.size.width.rounded()), h: Int(frame.size.height.rounded()))
        }

        init(pid: pid_t, x: Int, y: Int, w: Int, h: Int) {
            self.pid = pid; self.x = x; self.y = y; self.w = w; self.h = h
        }
    }

    /// Maps each on-screen window to its front-to-back index. `optionOnScreenOnly` reports only
    /// windows on the Space that is currently showing, which doubles as Space membership.
    private func windowServerZOrder() -> [SpaceKey: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var order: [SpaceKey: Int] = [:]
        for (index, info) in list.enumerated() {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double
            else { continue }
            let key = SpaceKey(pid: pid, x: Int(x.rounded()), y: Int(y.rounded()),
                               w: Int(w.rounded()), h: Int(h.rounded()))
            if order[key] == nil { order[key] = index }
        }
        return order
    }

    /// The first snapshot has no focus history, so the MRU order would otherwise be whatever
    /// order the apps happened to be enumerated in. Seed it from the window server's stacking
    /// order instead, so the very first press of the shortcut behaves sensibly.
    private func seedInitialOrder(using zOrder: [SpaceKey: Int]) {
        let unknown = Int.max
        let ranked = entries.values.sorted { lhs, rhs in
            let lhsRank = zOrder[SpaceKey(pid: lhs.pid, frame: lhs.frame)] ?? unknown
            let rhsRank = zOrder[SpaceKey(pid: rhs.pid, frame: rhs.frame)] ?? unknown
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.focusStamp > rhs.focusStamp
        }
        // Stamp back-to-front so the frontmost window ends up with the highest value.
        for entry in ranked.reversed() { touch(entry.ref) }
    }

    // MARK: - AX observers

    private func installObserver(for pid: pid_t, appElement: AXUIElement) {
        guard observers[pid] == nil else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let store = Unmanaged<WindowStore>.fromOpaque(refcon).takeUnretainedValue()
            store.handle(notification: notification as String, element: element)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        observers[pid] = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.appNotifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }

        // Windows discovered before the observer existed still need their own subscriptions.
        for (ref, entry) in entries where entry.pid == pid {
            observeWindow(ref, observer: observer)
        }
    }

    private func observeWindow(_ ref: AXRef, observer: AXObserver?) {
        guard let observer, !observedWindows.contains(ref) else { return }
        observedWindows.insert(ref)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.windowNotifications {
            AXObserverAddNotification(observer, ref.element, notification as CFString, refcon)
        }
    }

    /// Called on the main run loop by the AX observer. Keep it cheap; real work goes to `queue`.
    private func handle(notification: String, element: AXUIElement) {
        let pid = axPID(of: element)
        let ref = AXRef(element)

        queue.async { [weak self] in
            guard let self else { return }
            switch notification {
            case kAXUIElementDestroyedNotification:
                if self.entries.removeValue(forKey: ref) != nil {
                    self.observedWindows.remove(ref)
                    self.publish()
                }
            case kAXTitleChangedNotification:
                if var entry = self.entries[ref] {
                    entry.title = (axString(element, kAXTitleAttribute as String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.entries[ref] = entry
                    self.publish()
                } else {
                    self.refreshApp(pid: pid)
                    self.publish()
                }
            case kAXFocusedWindowChangedNotification:
                if self.entries[ref] == nil { self.refreshApp(pid: pid) }
                self.touch(ref)
                self.publish()
            default:
                // Created / miniaturized / hidden / shown: the cheapest correct answer is a
                // rescan of just that app, which is a handful of IPC calls off the main thread.
                self.refreshApp(pid: pid)
                self.publish()
            }
        }
    }

    private func touch(_ ref: AXRef) {
        guard var entry = entries[ref] else { return }
        focusCounter += 1
        entry.focusStamp = focusCounter
        entries[ref] = entry
    }

    /// Marks a window as most-recently-used. Called on commit so the next invocation of the
    /// switcher lands on the window you just came from.
    func markUsed(_ ref: AXRef) {
        queue.async { [weak self] in
            guard let self else { return }
            self.touch(ref)
            self.publish()
        }
    }

    // MARK: - Publishing

    private func publish() {
        let visible = entries.values.filter { entry in
            if entry.isMinimized && !config.includeMinimized { return false }
            if entry.isAppHidden && !config.includeHidden { return false }
            if !config.showAllSpaces && !entry.onCurrentSpace { return false }
            return true
        }
        let sorted = visible.sorted { $0.focusStamp > $1.focusStamp }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = sorted
            IconCache.shared.warm(pids: sorted.map(\.pid))
        }
    }
}

private extension Notification {
    var runningApp: NSRunningApplication? {
        userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }
}
