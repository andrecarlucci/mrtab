import AppKit

/// The switcher list, drawn by hand.
///
/// A single custom-drawn view is used instead of `NSTableView`/`NSCollectionView`/SwiftUI because
/// those all build and lay out a view tree on first display. Here, showing the panel is a
/// `setNeedsDisplay` and one `draw(_:)` over at most a dozen rows, with the strings and icons
/// already prepared.
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
    var onSettings: (() -> Void)?

    private(set) var rows: [Row] = []
    private(set) var selectedIndex = 0
    private var scrollOffset = 0

    private var rowHeight: CGFloat = 36
    private var maxVisibleRows = 12

    /// App names and window titles are laid out as two columns, so the strings are kept apart
    /// rather than concatenated.
    private var appStrings: [NSAttributedString] = []
    private var titleStrings: [NSAttributedString] = []
    private var widestAppName: CGFloat = 0

    private let padding: CGFloat = 8
    private let iconSide: CGFloat = 26
    private let rowInset: CGFloat = 6
    private let iconGap: CGFloat = 10
    private let columnGap: CGFloat = 14
    /// The app name column never takes more than this share of the panel, however long the
    /// longest name is, so the titles always get room.
    private let maxColumnShare: CGFloat = 0.40
    private let headerHeight: CGFloat = 34
    private let gearSide: CGFloat = 16
    private let brandIconSide: CGFloat = 18

    private var gearRect: NSRect = .zero
    private var gearHovered = false

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
        self.appStrings = rows.map { Self.appString(for: $0) }
        self.titleStrings = rows.map { Self.titleString(for: $0) }
        // Measuring once here keeps the per-row draw free of text metrics.
        self.widestAppName = appStrings.reduce(0) { max($0, $1.size().width) }
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
        headerHeight + CGFloat(visibleRowCount) * rowHeight + padding * 2
    }

    /// Y of the first row. Everything below the header is offset by this.
    private var rowsTop: CGFloat { headerHeight + padding }

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

    /// Width reserved for app names. Every window title starts at the same x as a result — an
    /// invisible column, with no rule or separator drawn between the two.
    private var appColumnWidth: CGFloat {
        min(widestAppName, bounds.width * maxColumnShare)
    }

    // MARK: - Strings

    private static func paragraphStyle() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return paragraph
    }

    private static func appString(for row: Row) -> NSAttributedString {
        NSAttributedString(string: row.appName, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle(),
        ])
    }

    private static func titleString(for row: Row) -> NSAttributedString {
        guard !row.title.isEmpty, row.title != row.appName else { return NSAttributedString() }
        // Full strength, like the app name. The two are told apart by weight and by column, not
        // by opacity: dimming the title made it legible only on the selected row.
        return NSAttributedString(string: row.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle(),
        ])
    }

    /// On the accent-filled selected row the dynamic label colours lose contrast.
    private static func whitened(_ string: NSAttributedString) -> NSAttributedString {
        guard string.length > 0 else { return string }
        let mutable = NSMutableAttributedString(attributedString: string)
        mutable.addAttribute(.foregroundColor, value: NSColor.white,
                             range: NSRange(location: 0, length: mutable.length))
        return mutable
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The panel is translucent, so without this the legibility of every row would depend on
        // whatever happens to be behind it. The scrim keeps the base tone constant.
        NSColor.black.withAlphaComponent(0.38).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()

        drawHeader()

        guard !rows.isEmpty else {
            drawEmptyState()
            return
        }

        let visible = visibleRowCount
        let upperBound = min(rows.count, scrollOffset + visible)
        let columnWidth = appColumnWidth

        for index in scrollOffset..<upperBound {
            let y = rowsTop + CGFloat(index - scrollOffset) * rowHeight
            let rowRect = NSRect(x: rowInset, y: y, width: bounds.width - rowInset * 2, height: rowHeight)
            draw(row: rows[index], app: appStrings[index], title: titleStrings[index],
                 in: rowRect, columnWidth: columnWidth, selected: index == selectedIndex)
        }

        drawScrollIndicators(visible: visible)
    }

    private func draw(row: Row, app: NSAttributedString, title: NSAttributedString,
                      in rect: NSRect, columnWidth: CGFloat, selected: Bool) {
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 2), xRadius: 8, yRadius: 8).fill()
        }

        let iconRect = NSRect(x: rect.minX + iconGap,
                              y: rect.midY - iconSide / 2,
                              width: iconSide, height: iconSide)
        IconCache.shared.icon(for: row.pid)?.draw(
            in: iconRect, from: .zero, operation: .sourceOver,
            fraction: row.isMinimized || row.isAppHidden ? 0.55 : 1.0)

        var badgeWidth: CGFloat = 0
        if let badge = badgeText(for: row) {
            badgeWidth = drawBadge(badge, in: rect, selected: selected)
        }

        let textTop = rect.midY - 9
        let appRect = NSRect(x: iconRect.maxX + iconGap, y: textTop, width: columnWidth, height: 18)
        (selected ? Self.whitened(app) : app)
            .draw(with: appRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        guard title.length > 0 else { return }
        let titleX = appRect.maxX + columnGap
        let titleRect = NSRect(x: titleX, y: textTop,
                               width: max(0, rect.maxX - titleX - iconGap - badgeWidth),
                               height: 18)
        (selected ? Self.whitened(title) : title)
            .draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawHeader() {
        let icon = Self.brandIcon
        let iconRect = NSRect(x: 14, y: (headerHeight - brandIconSide) / 2,
                              width: brandIconSide, height: brandIconSide)
        icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)

        let name = NSAttributedString(string: "MrTab", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        let nameSize = name.size()
        name.draw(at: NSPoint(x: iconRect.maxX + 8, y: (headerHeight - nameSize.height) / 2))

        gearRect = NSRect(x: bounds.width - 14 - gearSide, y: (headerHeight - gearSide) / 2,
                          width: gearSide, height: gearSide)
        if let gear = Self.gearIcon {
            // The whole header is the hit target's neighbourhood, so brightening on hover is the
            // only affordance telling you the gear is clickable.
            gear.draw(in: gearRect, from: .zero, operation: .sourceOver,
                      fraction: gearHovered ? 1.0 : 0.6)
        }

        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 12, y: headerHeight - 1, width: bounds.width - 24, height: 1).fill()
    }

    /// Tinting is done once and cached: a template image has to be redrawn through a colour to
    /// take one, and that is not work for a draw path this hot.
    private static let gearIcon: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "gearshape",
                                   accessibilityDescription: "Settings")?
            .withSymbolConfiguration(configuration) else { return nil }
        return symbol.tinted(with: .labelColor)
    }()

    private static let brandIcon: NSImage? = {
        let icon = NSApp.applicationIconImage
        guard let icon else { return nil }
        let scaled = NSImage(size: NSSize(width: 18, height: 18))
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        scaled.unlockFocus()
        return scaled
    }()

    private func badgeText(for row: Row) -> String? {
        if row.isMinimized { return "minimized" }
        if row.isAppHidden { return "hidden" }
        return nil
    }

    @discardableResult
    private func drawBadge(_ text: String, in rect: NSRect, selected: Bool) -> CGFloat {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: selected ? NSColor.white.withAlphaComponent(0.85)
                                       : NSColor.secondaryLabelColor,
        ])
        let size = string.size()
        string.draw(at: NSPoint(x: rect.maxX - iconGap - size.width, y: rect.midY - size.height / 2))
        return size.width + 12
    }

    private func drawScrollIndicators(visible: Int) {
        guard rows.count > visible else { return }
        NSColor.tertiaryLabelColor.setFill()
        if scrollOffset > 0 {
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 8, y: headerHeight + 3,
                                             width: 16, height: 2),
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
        string.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                                y: headerHeight + (bounds.height - headerHeight - size.height) / 2))
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
        let offset = point.y - rowsTop
        guard offset >= 0 else { return nil }
        let index = scrollOffset + Int(offset / rowHeight)
        return index < rows.count ? index : nil
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        let overGear = gearRect.contains(point)
        if overGear != gearHovered {
            gearHovered = overGear
            needsDisplay = true
        }
        // Moving across the header must not drag the selection with it.
        guard point.y >= headerHeight, let index = rowIndex(at: point) else { return }
        onHover?(index)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if gearRect.contains(point) {
            onSettings?()
            return
        }
        guard point.y >= headerHeight, let index = rowIndex(at: point) else { return }
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
