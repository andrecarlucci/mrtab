import AppKit

/// The settings window. Changes take effect immediately and are written straight to disk —
/// there is no OK/Cancel, which suits a utility whose whole surface is a handful of toggles.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var config: Config
    private let onChange: (Config) -> Void

    private var recorder: ShortcutRecorderView!
    private var minimizedBox: NSButton!
    private var hiddenBox: NSButton!
    private var spacesBox: NSButton!
    private var loginBox: NSButton!
    private var widthSlider: NSSlider!
    private var widthLabel: NSTextField!
    private var heightSlider: NSSlider!
    private var heightLabel: NSTextField!
    private var rowsSlider: NSSlider!
    private var rowsLabel: NSTextField!

    private var banner: BannerView!
    private var bannerLabel: NSTextField!
    private var bannerButton: NSButton!
    private var permissionPoll: Timer?

    private static let repositoryURL = URL(string: "https://github.com/andrecarlucci/mrtab")!

    init(config: Config, onChange: @escaping (Config) -> Void) {
        self.config = config
        self.onChange = onChange

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "MrTab Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self

        let content = buildContent()
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: max(500, content.fittingSize.width),
                                     height: content.fittingSize.height))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        // An accessory app has to activate explicitly, or the window opens behind everything.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refreshPermissionBanner()
        startPermissionPoll()
    }

    /// Trust is granted out of process with no notification to observe, so the banner is polled
    /// while the window is on screen, and left alone when it is not.
    private func startPermissionPoll() {
        permissionPoll?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshPermissionBanner()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPoll = timer
    }

    func windowWillClose(_ notification: Notification) {
        permissionPoll?.invalidate()
        permissionPoll = nil
    }

    private func refreshPermissionBanner() {
        let trusted = Permissions.isTrusted
        banner.isWarning = !trusted
        bannerLabel.stringValue = trusted
            ? "Accessibility access granted. The shortcut is live."
            : "MrTab needs Accessibility access to list your windows. "
              + "Until that is granted, the shortcut does nothing."
        bannerButton.isHidden = trusted
        banner.needsDisplay = true
    }

    @objc private func openAccessibilitySettings() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        recorder = ShortcutRecorderView(shortcut: config.shortcut)
        recorder.onChange = { [weak self] shortcut in
            self?.update { $0.shortcut = shortcut }
        }

        minimizedBox = checkbox("Include minimized windows", config.includeMinimized,
                                #selector(toggleMinimized))
        hiddenBox = checkbox("Include windows of hidden apps", config.includeHidden,
                             #selector(toggleHidden))
        spacesBox = checkbox("Include windows from all Spaces", config.showAllSpaces,
                             #selector(toggleSpaces))
        loginBox = checkbox("Open MrTab at login", LoginItem.isEnabled, #selector(toggleLogin))

        (widthSlider, widthLabel) = slider(Config.panelWidthRange, Double(config.panelWidth),
                                           #selector(changeWidth), suffix: " pt")
        (heightSlider, heightLabel) = slider(Config.rowHeightRange, Double(config.rowHeight),
                                             #selector(changeHeight), suffix: " pt")
        (rowsSlider, rowsLabel) = slider(Config.visibleRowsRange, Double(config.maxVisibleRows),
                                         #selector(changeRows), suffix: " rows", integral: true)

        banner = BannerView()
        bannerLabel = label("", size: 12)
        bannerLabel.lineBreakMode = .byWordWrapping
        bannerLabel.usesSingleLineMode = false
        bannerLabel.preferredMaxLayoutWidth = 290
        bannerButton = NSButton(title: "Open System Settings", target: self,
                                action: #selector(openAccessibilitySettings))
        bannerButton.bezelStyle = .rounded
        banner.install(label: bannerLabel, button: bannerButton)
        refreshPermissionBanner()

        let stack = NSStackView(views: [
            banner,
            section("Shortcut", [
                labelled("Open switcher", recorder),
                hint("Hold the modifier to keep browsing. Tap Tab to move down the list, "
                     + "\u{21E7} to move back up, and release to switch."),
            ]),
            section("Windows to list", [minimizedBox, hiddenBox, spacesBox]),
            section("Appearance", [
                labelled("Panel width", pair(widthSlider, widthLabel)),
                labelled("Row height", pair(heightSlider, heightLabel)),
                labelled("Visible rows", pair(rowsSlider, rowsLabel)),
            ]),
            section("General", [loginBox]),
            NSBox.horizontalRule(),
            aboutSection(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func aboutSection() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let name = label("MrTab \(version)", size: 15, weight: .semibold)
        let blurb = label("A window switcher for macOS. Lists every open window rather than every "
                          + "app, and shows the list the instant you press the shortcut.",
                          size: 12, color: .secondaryLabelColor)
        blurb.preferredMaxLayoutWidth = 330
        blurb.lineBreakMode = .byWordWrapping
        blurb.usesSingleLineMode = false

        let link = NSButton(title: "View on GitHub", target: self, action: #selector(openRepository))
        link.bezelStyle = .rounded

        let text = NSStackView(views: [name, blurb, link])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        return row
    }

    // MARK: - Small builders

    private func section(_ title: String, _ views: [NSView]) -> NSView {
        let header = label(title.uppercased(), size: 10, weight: .semibold, color: .tertiaryLabelColor)
        let body = NSStackView(views: views)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8

        let stack = NSStackView(views: [header, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func labelled(_ title: String, _ control: NSView) -> NSView {
        let caption = label(title, size: 13)
        caption.alignment = .right
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let stack = NSStackView(views: [caption, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        return stack
    }

    private func pair(_ slider: NSSlider, _ value: NSTextField) -> NSView {
        let stack = NSStackView(views: [slider, value])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func hint(_ text: String) -> NSTextField {
        let field = label(text, size: 11, color: .secondaryLabelColor)
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.preferredMaxLayoutWidth = 420
        return field
    }

    private func label(_ text: String, size: CGFloat,
                       weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func checkbox(_ title: String, _ on: Bool, _ action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = on ? .on : .off
        return button
    }

    private func slider(_ range: ClosedRange<Double>, _ value: Double, _ action: Selector,
                        suffix: String, integral: Bool = false) -> (NSSlider, NSTextField) {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: self, action: action)
        slider.isContinuous = true
        if integral {
            slider.numberOfTickMarks = Int(range.upperBound - range.lowerBound) + 1
            slider.allowsTickMarkValuesOnly = true
        }
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 210).isActive = true

        let field = label("\(Int(value))\(suffix)", size: 12, color: .secondaryLabelColor)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        return (slider, field)
    }

    // MARK: - Actions

    private func update(_ mutate: (inout Config) -> Void) {
        mutate(&config)
        config.save()
        onChange(config)
    }

    @objc private func toggleMinimized() { update { $0.includeMinimized = minimizedBox.state == .on } }
    @objc private func toggleHidden() { update { $0.includeHidden = hiddenBox.state == .on } }
    @objc private func toggleSpaces() { update { $0.showAllSpaces = spacesBox.state == .on } }

    @objc private func toggleLogin() {
        let wanted = loginBox.state == .on
        if let failure = LoginItem.setEnabled(wanted) {
            loginBox.state = wanted ? .off : .on
            let alert = NSAlert()
            alert.messageText = "Could not \(wanted ? "enable" : "disable") opening at login"
            alert.informativeText = failure
            alert.runModal()
        }
    }

    @objc private func changeWidth() {
        let value = widthSlider.doubleValue.rounded()
        widthLabel.stringValue = "\(Int(value)) pt"
        update { $0.panelWidth = CGFloat(value) }
    }

    @objc private func changeHeight() {
        let value = heightSlider.doubleValue.rounded()
        heightLabel.stringValue = "\(Int(value)) pt"
        update { $0.rowHeight = CGFloat(value) }
    }

    @objc private func changeRows() {
        let value = Int(rowsSlider.doubleValue.rounded())
        rowsLabel.stringValue = "\(value) rows"
        update { $0.maxVisibleRows = value }
    }

    @objc private func openRepository() {
        NSWorkspace.shared.open(Self.repositoryURL)
    }

    /// Keeps the window in step when something outside it changes the config.
    func refresh(config: Config) {
        self.config = config
        recorder.set(config.shortcut)
        minimizedBox.state = config.includeMinimized ? .on : .off
        hiddenBox.state = config.includeHidden ? .on : .off
        spacesBox.state = config.showAllSpaces ? .on : .off
        loginBox.state = LoginItem.isEnabled ? .on : .off
    }
}

private extension NSBox {
    static func horizontalRule() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 452).isActive = true
        return box
    }
}


/// A tinted rounded panel: amber while a permission is missing, green once it is granted.
///
/// This exists because the app's only failure mode that matters is invisible -- without
/// Accessibility the shortcut silently does nothing, and nothing on screen says so.
final class BannerView: NSView {
    var isWarning = true

    override var isFlipped: Bool { true }

    func install(label: NSTextField, button: NSButton) {
        let stack = NSStackView(views: [label, button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        widthAnchor.constraint(equalToConstant: 452).isActive = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isWarning ? NSColor.systemOrange.withAlphaComponent(0.15)
                             : NSColor.systemGreen.withAlphaComponent(0.13)
        let border = isWarning ? NSColor.systemOrange.withAlphaComponent(0.55)
                               : NSColor.systemGreen.withAlphaComponent(0.45)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        fill.setFill(); path.fill()
        border.setStroke(); path.lineWidth = 1; path.stroke()
    }
}
