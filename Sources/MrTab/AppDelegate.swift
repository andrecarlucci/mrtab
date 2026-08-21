import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config()
    private var store: WindowStore!
    private var controller: SwitcherController!
    private let hotKeys = HotKeyManager()
    private var statusItem: NSStatusItem?

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

        config.writeIfMissing()

        store = WindowStore(config: config)
        controller = SwitcherController(config: config, store: store)

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
            let status = self.hotKeys.register(config: self.config)
            Log.write("hotkey register \(self.config.displayName): status=\(status)")
            if status != noErr { self.warnHotKeyUnavailable() }
            self.refreshStatusItemTitle()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.unregister()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "square.stack",
                                     accessibilityDescription: "MrTab")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let status = NSMenuItem(title: "Waiting for Accessibility access\u{2026}", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = 1
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Rescan windows", action: #selector(rescan), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Open config file\u{2026}", action: #selector(openConfig), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Accessibility settings\u{2026}", action: #selector(openSettings), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MrTab", action: #selector(quit), keyEquivalent: "q")
            .target = self

        item.menu = menu
        statusItem = item
    }

    private func refreshStatusItemTitle() {
        guard let status = statusItem?.menu?.item(withTag: 1) else { return }
        status.title = "Shortcut: \(config.displayName)"
    }

    private func warnHotKeyUnavailable() {
        guard let status = statusItem?.menu?.item(withTag: 1) else { return }
        status.title = "\(config.displayName) is taken by another app"
    }

    @objc private func rescan() {
        store.requestRefresh()
    }

    @objc private func openConfig() {
        config.writeIfMissing()
        NSWorkspace.shared.open(Config.path)
    }

    @objc private func openSettings() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
