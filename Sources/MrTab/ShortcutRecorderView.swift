import AppKit
import Carbon.HIToolbox

/// Click, then press a combination. Shows the current shortcut the rest of the time.
///
/// Recording uses a local event monitor rather than `keyDown`, so that combinations the responder
/// chain would otherwise swallow -- Tab moving focus, Escape closing the window -- can be captured.
final class ShortcutRecorderView: NSView {
    /// What this field records. A jump chord keeps only its modifiers, but it is still recorded
    /// by pressing the whole thing — modifiers and a digit — so that what you press is what you
    /// get, and a chord another app has taken makes itself known immediately.
    enum Kind {
        case shortcut
        case jump
    }

    var onChange: ((Shortcut) -> Void)?
    var onJumpChange: ((JumpShortcut) -> Void)?

    private let kind: Kind
    /// The field's whole state is what it shows: the recorded value lives in the config, which
    /// hands it back through `set`.
    private var display: String
    private var isRecording = false
    private var monitor: Any?
    private var message: String?

    init(shortcut: Shortcut) {
        self.kind = .shortcut
        self.display = shortcut.displayString
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 26))
    }

    init(jump: JumpShortcut) {
        self.kind = .jump
        self.display = jump.displayString
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 26))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func set(_ shortcut: Shortcut) {
        display = shortcut.displayString
        needsDisplay = true
    }

    func set(_ jump: JumpShortcut) {
        display = jump.displayString
        needsDisplay = true
    }

    // MARK: - Recording

    override func mouseDown(with event: NSEvent) {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        message = nil
        needsDisplay = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }

            if event.type == .flagsChanged {
                // Redraw so the modifiers appear as they are pressed.
                self.needsDisplay = true
                return nil
            }

            if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.isDisjoint(with: [.command, .option, .control]) {
                self.stopRecording()
                return nil
            }

            // Without a holdable modifier the switcher would have nothing to stay open for, and
            // bare digits would swallow typing everywhere.
            let modifiers = event.modifierFlags.intersection(.shortcutMask)
            switch self.kind {
            case .shortcut:
                let candidate = Shortcut(keyCode: event.keyCode, modifiers: modifiers)
                guard candidate.isValid else { return self.reject("Add \u{2318}, \u{2325} or \u{2303}") }
                self.accept(candidate.displayString)
                self.onChange?(candidate)

            case .jump:
                // Delete turns the jump chord off. The switcher's own shortcut has no such
                // escape: without it MrTab has no way in at all.
                if event.keyCode == UInt16(kVK_Delete), modifiers.isEmpty {
                    self.accept(JumpShortcut.off.displayString)
                    self.onJumpChange?(.off)
                    return nil
                }
                guard JumpShortcut.digit(forKeyCode: event.keyCode) != nil else {
                    return self.reject("Press a digit 1-9")
                }
                let candidate = JumpShortcut(modifiers: modifiers)
                guard candidate.isEnabled else { return self.reject("Add \u{2318}, \u{2325} or \u{2303}") }
                self.accept(candidate.displayString)
                self.onJumpChange?(candidate)
            }
            return nil
        }
    }

    /// Swallows the keystroke and leaves the field recording, showing why it did not take.
    private func reject(_ complaint: String) -> NSEvent? {
        message = complaint
        needsDisplay = true
        return nil
    }

    private func accept(_ recorded: String) {
        display = recorded
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        needsDisplay = true
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)

        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                     : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if let message {
            text = message
            color = .systemRed
        } else if isRecording {
            let symbols = NSEvent.modifierFlags.intersection(.shortcutMask).symbols
            text = symbols.isEmpty ? "Type a shortcut\u{2026}" : symbols
            color = .secondaryLabelColor
        } else {
            text = display
            color = .labelColor
        }

        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: isRecording ? .regular : .medium),
            .foregroundColor: color,
        ])
        let size = string.size()
        string.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
