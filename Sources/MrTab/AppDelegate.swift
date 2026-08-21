import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config()
    private var store: WindowStore!
    private var controller: SwitcherController!
    private let hotKeys = HotKeyManager()

    private var statusItem: NSStatusItem?
    private var settings: SettingsWindowController?

    private enum Tag: Int {
        case status = 1
        case login = 2
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.write("--- launch pid=\(ProcessInfo.processInfo.processIdentifier) "
                  + "bundle=\(Bundle.main.bundlePath) trusted=\(Permissions.isTrusted)")

        config = Config.load()

        // Dev affordance; renders the list offscreen and exits without touching Accessibility.
        if SelfTest.renderIfRequested(config: config) {
            NSApp.terminate(nil)
            return
        }
        if IconGenerator.runIfRequested() {
            NSApp.terminate(nil)
            return
        }

        terminateOtherInstances()
        config.writeIfMissing()

        store = WindowStore(config: config)
        controller = SwitcherController(config: config, store: store)
        controller.onOpenSettings = { [weak self] in self?.openSettings() }

        setUpStatusItem()

        // Paying the window-server and first-draw cost now means the first real invocation is
        // as fast as the thousandth.
        controller.prewarm()

        hotKeys.onTrigger = { [weak self] in
            Log.write("hotkey fired")
            self?.controller.trigger()
        }

        Permissions.requestAccessibility()
        Permissions.waitForTrust { [weak self] in
            guard let self else { return }
            Log.write("accessibility trust granted; starting store")
            self.store.start()
            self.registerHotKey()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.unregister()
    }

    /// Two copies of MrTab -- typically a build in the repo and one in /Applications -- share a
    /// bundle identifier, so they compete for the same Accessibility grant and the same hot key.
    /// The symptom is not obvious: the older instance keeps the hot key but silently loses its
    /// window list to the newer one's grant. The most recently launched copy wins instead.
    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != mine && !$0.isTerminated }

        for other in others {
            Log.write("replacing earlier instance pid=\(other.processIdentifier) "
                      + "at \(other.bundleURL?.path ?? "unknown")")
            other.terminate()
        }
    }

    // MARK: - Configuration

    private func applyConfig(_ updated: Config) {
        let shortcutChanged = updated.shortcut != config.shortcut
        config = updated
        store?.update(config: config)
        controller?.apply(config: config)
        if shortcutChanged { registerHotKey() }
        refreshStatusItemTitle()
    }

    private func registerHotKey() {
        let status = hotKeys.register(shortcut: config.shortcut)
        Log.write("hotkey register \(config.displayName): status=\(status)")
        if status == noErr {
            refreshStatusItemTitle()
        } else {
            warnHotKeyUnavailable()
        }
    }

    private func openSettings() {
        if settings == nil {
            settings = SettingsWindowController(config: config) { [weak self] updated in
                self?.applyConfig(updated)
            }
        }
        settings?.refresh(config: config)
        settings?.show()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "square.stack",
                                     accessibilityDescription: "MrTab")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: "Waiting for Accessibility access\u{2026}", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = Tag.status.rawValue
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Settings\u{2026}", action: #selector(showSettings), keyEquivalent: ",")
            .target = self

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.tag = Tag.login.rawValue
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Rescan windows", action: #selector(rescan), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Open config file\u{2026}", action: #selector(openConfig), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Accessibility settings\u{2026}", action: #selector(openAccessibility), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MrTab", action: #selector(quit), keyEquivalent: "q")
            .target = self

        item.menu = menu
        statusItem = item
    }

    /// The login item can be switched off from System Settings, so the tick is resolved when the
    /// menu opens rather than cached.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: Tag.login.rawValue)?.state = LoginItem.isEnabled ? .on : .off
    }

    private func refreshStatusItemTitle() {
        statusItem?.menu?.item(withTag: Tag.status.rawValue)?.title = "Shortcut: \(config.displayName)"
    }

    private func warnHotKeyUnavailable() {
        statusItem?.menu?.item(withTag: Tag.status.rawValue)?.title =
            "\(config.displayName) is taken by another app"
    }

    // MARK: - Menu actions

    @objc private func showSettings() { openSettings() }

    @objc private func toggleLogin() {
        let wanted = !LoginItem.isEnabled
        if let failure = LoginItem.setEnabled(wanted) {
            let alert = NSAlert()
            alert.messageText = "Could not \(wanted ? "enable" : "disable") opening at login"
            alert.informativeText = failure
            alert.runModal()
        }
        settings?.refresh(config: config)
    }

    @objc private func rescan() { store?.requestRefresh() }

    @objc private func openConfig() {
        config.writeIfMissing()
        NSWorkspace.shared.open(Config.path)
    }

    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }

    @objc private func quit() { NSApp.terminate(nil) }
}
