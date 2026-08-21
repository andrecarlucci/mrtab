import AppKit

/// The switcher list, drawn by hand.
///
/// A single custom-drawn view is used instead of `NSTableView`/`NSCollectionView`/SwiftUI because
/// those all build and lay out a view tree on first display. Here, showing the panel is a `setNeedsDisplay`
/// and one `draw(_:)` over at most a dozen rows, with the strings and icons already prepared.
final class SwitcherView: NSView {
    struct Row {
        let appName: String
        let title: String
        let pid: pid_t
        let isMinimized: Bool
        let isAppHidden: Bool
    }

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    private(set) var rows: [Row] = []
    private(set) var selectedIndex = 0
    private var scrollOffset = 0

    private var rowHeight: CGFloat = 36
    private var maxVisibleRows = 12
    private var attributedRows: [NSAttributedString] = []

    private let padding: CGFloat = 8
    private let iconSide: CGFloat = 26
    private let rowInset: CGFloat = 6

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Content

    func configure(rowHeight: CGFloat, maxVisibleRows: Int) {
        self.rowHeight = rowHeight
        self.maxVisibleRows = maxVisibleRows
    }

    func setRows(_ rows: [Row], selected: Int) {
        self.rows = rows
        self.selectedIndex = rows.isEmpty ? 0 : min(max(0, selected), rows.count - 1)
        self.attributedRows = rows.map(Self.makeAttributedString)
        self.scrollOffset = 0
        clampScroll()
        needsDisplay = true
    }

    func select(_ index: Int) {
        guard !rows.isEmpty else { return }
        let clamped = min(max(0, index), rows.count - 1)
        guard clamped != selectedIndex else { return }
        selectedIndex = clamped
        clampScroll()
        needsDisplay = true
    }

    /// Height the panel needs for the current rows.
    var contentHeight: CGFloat {
        let visible = max(1, min(rows.count, maxVisibleRows))
        return CGFloat(visible) * rowHeight + padding * 2
    }

    var visibleRowCount: Int { max(1, min(rows.count, maxVisibleRows)) }

    private func clampScroll() {
        let visible = visibleRowCount
        if selectedIndex < scrollOffset {
            scrollOffset = selectedIndex
        } else if selectedIndex >= scrollOffset + visible {
            scrollOffset = selectedIndex - visible + 1
        }
        scrollOffset = max(0, min(scrollOffset, max(0, rows.count - visible)))
    }

    // MARK: - Drawing

    private static func makeAttributedString(for row: Row) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let result = NSMutableAttributedString(
            string: row.appName,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ])

        if !row.title.isEmpty && row.title != row.appName {
            // Only the separator is dimmed. The window title is the thing you are actually
            // scanning for, so it is drawn at full strength like the app name -- the two are
            // told apart by weight. Dimming it made it legible only on the selected row, whose
            // solid accent fill happens to guarantee contrast.
            result.append(NSAttributedString(
                string: "  \u{2014}  ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]))
            result.append(NSAttributedString(
                string: row.title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ]))
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        // The panel is translucent, so without this the legibility of every row would depend on
        // whatever happens to be behind it. The scrim keeps the base tone constant.
        NSColor.black.withAlphaComponent(0.38).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()

        guard !rows.isEmpty else {
            drawEmptyState()
            return
        }

        let visible = visibleRowCount
        let upperBound = min(rows.count, scrollOffset + visible)

        for index in scrollOffset..<upperBound {
            let y = padding + CGFloat(index - scrollOffset) * rowHeight
            let rowRect = NSRect(x: rowInset, y: y, width: bounds.width - rowInset * 2, height: rowHeight)
            draw(row: rows[index], text: attributedRows[index],
                 in: rowRect, selected: index == selectedIndex)
        }

        drawScrollIndicators(visible: visible)
    }

    private func draw(row: Row, text: NSAttributedString, in rect: NSRect, selected: Bool) {
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 2), xRadius: 8, yRadius: 8).fill()
        }

        let iconRect = NSRect(x: rect.minX + 10,
                              y: rect.midY - iconSide / 2,
                              width: iconSide, height: iconSide)
        let icon = IconCache.shared.icon(for: row.pid)
        icon?.draw(in: iconRect, from: .zero, operation: .sourceOver,
                   fraction: row.isMinimized || row.isAppHidden ? 0.55 : 1.0)

        var badgeWidth: CGFloat = 0
        if let badge = badgeText(for: row) {
            badgeWidth = drawBadge(badge, in: rect, selected: selected)
        }

        let textX = iconRect.maxX + 10
        let textRect = NSRect(x: textX,
                              y: rect.midY - 9,
                              width: max(0, rect.maxX - textX - 10 - badgeWidth),
                              height: 18)

        // On the accent-filled selected row the default label colours lose contrast.
        let drawable: NSAttributedString
        if selected {
            let mutable = NSMutableAttributedString(attributedString: text)
            mutable.addAttribute(.foregroundColor, value: NSColor.white,
                                 range: NSRange(location: 0, length: mutable.length))
            drawable = mutable
        } else {
            drawable = text
        }
        drawable.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func badgeText(for row: Row) -> String? {
        if row.isMinimized { return "minimized" }
        if row.isAppHidden { return "hidden" }
        return nil
    }

    @discardableResult
    private func drawBadge(_ text: String, in rect: NSRect, selected: Bool) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: selected ? NSColor.white.withAlphaComponent(0.85) : NSColor.secondaryLabelColor,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let origin = NSPoint(x: rect.maxX - 10 - size.width, y: rect.midY - size.height / 2)
        string.draw(at: origin)
        return size.width + 12
    }

    private func drawScrollIndicators(visible: Int) {
        guard rows.count > visible else { return }
        NSColor.tertiaryLabelColor.setFill()
        if scrollOffset > 0 {
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 8, y: 3, width: 16, height: 2),
                         xRadius: 1, yRadius: 1).fill()
        }
        if scrollOffset + visible < rows.count {
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 8, y: bounds.maxY - 5, width: 16, height: 2),
                         xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawEmptyState() {
        let string = NSAttributedString(string: "No windows", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let size = string.size()
        string.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        guard !rows.isEmpty else { return nil }
        let offset = point.y - padding
        guard offset >= 0 else { return nil }
        let index = scrollOffset + Int(offset / rowHeight)
        return index < rows.count ? index : nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard let index = rowIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        onHover?(index)
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = rowIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        onClick?(index)
    }

    override func scrollWheel(with event: NSEvent) {
        guard rows.count > visibleRowCount else { return }
        let steps = Int(event.scrollingDeltaY / 10)
        guard steps != 0 else { return }
        scrollOffset = max(0, min(scrollOffset - steps, rows.count - visibleRowCount))
        needsDisplay = true
    }
}
