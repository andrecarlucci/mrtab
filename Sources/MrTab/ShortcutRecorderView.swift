import AppKit
import Carbon.HIToolbox

/// Click, then press a combination. Shows the current shortcut the rest of the time.
///
/// Recording uses a local event monitor rather than `keyDown`, so that combinations the responder
/// chain would otherwise swallow -- Tab moving focus, Escape closing the window -- can be captured.
final class ShortcutRecorderView: NSView {
    var onChange: ((Shortcut) -> Void)?

    private var shortcut: Shortcut
    private var isRecording = false
    private var monitor: Any?
    private var message: String?

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 26))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func set(_ shortcut: Shortcut) {
        self.shortcut = shortcut
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

            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let candidate = Shortcut(keyCode: event.keyCode, modifiers: modifiers)
            guard candidate.isValid else {
                // Without a holdable modifier the switcher would have nothing to stay open for.
                self.message = "Add \u{2318}, \u{2325} or \u{2303}"
                self.needsDisplay = true
                return nil
            }

            self.shortcut = candidate
            self.stopRecording()
            self.onChange?(candidate)
            return nil
        }
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
            let live = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
            let symbols = Shortcut(keyCode: 0, modifiers: live).displayString
                .replacingOccurrences(of: KeyNames.name(for: 0), with: "")
            text = symbols.isEmpty ? "Type a shortcut\u{2026}" : symbols
            color = .secondaryLabelColor
        } else {
            text = shortcut.displayString
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
