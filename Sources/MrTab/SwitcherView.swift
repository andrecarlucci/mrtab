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
        /// 1-9 if the window has been given a number, `nil` otherwise.
        let mark: Int?
    }

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onMark: ((Int) -> Void)?
    var onSettings: (() -> Void)?

    private(set) var rows: [Row] = []
    private(set) var selectedIndex = 0
    private(set) var query = ""
    private var scrollOffset = 0

    private var rowHeight: CGFloat = 36
    private var maxVisibleRows = 12

    /// App names and window titles are laid out as two columns, so the strings are kept apart
    /// rather than concatenated.
    private var appStrings: [NSAttributedString] = []
    private var titleStrings: [NSAttributedString] = []
    private var widestAppName: CGFloat = 0

    private static let iconSide: CGFloat = 26

    private let padding: CGFloat = 8
    private let rowInset: CGFloat = 6
    private let iconGap: CGFloat = 10
    private let columnGap: CGFloat = 14
    /// The app name column never takes more than this share of the panel, however long the
    /// longest name is, so the titles always get room.
    private let maxColumnShare: CGFloat = 0.40
    private let headerHeight: CGFloat = 38
    private let gearSide: CGFloat = 16
    private let closeSide: CGFloat = 16
    private let markSide: CGFloat = 16

    /// Left edge of the icon column, and of the text column beside it. The header uses these too,
    /// so the app icon and the word MrTab line up with the rows below rather than being placed
    /// by eye.
    private var iconLeft: CGFloat { rowInset + iconGap }
    private var textLeft: CGFloat { iconLeft + Self.iconSide + iconGap }

    private var gearRect: NSRect = .zero
    private var gearHovered = false

    /// The row under the pointer, which is the only one showing its close and mark buttons, and
    /// which of those the pointer is on rather than elsewhere in the row.
    private var hoveredRow: Int?
    private var closeHovered = false
    private var markHovered = false

    /// What a point in a row lands on. The two buttons sit at the right edge; everything else is
    /// the row itself.
    enum Target {
        case row
        case mark
        case close
    }

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
        // The scroll position is kept and merely re-clamped: numbering or closing a row hands the
        // same list back, and having it jump to the top under the pointer would be maddening.
        // Filtering moves the selection to the top anyway, which drags the offset with it.
        clampScroll()
        needsDisplay = true
    }

    /// Test seam: an offscreen render has no pointer, and the row buttons only show under one.
    func hoverRow(_ index: Int?) {
        hoveredRow = index
        closeHovered = false
        markHovered = false
        needsDisplay = true
    }

    /// What the user has typed to filter the list. Drawn in the header; the filtering itself
    /// happens in the controller, which hands down the rows that survived it.
    func setQuery(_ query: String) {
        guard query != self.query else { return }
        self.query = query
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

        // Hover is settled here rather than on the mouse event that last moved it: closing a
        // window or narrowing the filter rewrites the list and resizes the panel under a pointer
        // that has not moved, and by draw time the geometry it has to be measured against is final.
        refreshHover()

        guard !rows.isEmpty else {
            drawEmptyState()
            return
        }

        let visible = visibleRowCount
        let upperBound = min(rows.count, scrollOffset + visible)
        let columnWidth = appColumnWidth

        for index in scrollOffset..<upperBound {
            draw(row: rows[index], app: appStrings[index], title: titleStrings[index],
                 in: rowRect(for: index), columnWidth: columnWidth,
                 selected: index == selectedIndex, hovered: index == hoveredRow)
        }

        drawScrollIndicators(visible: visible)
    }

    private func draw(row: Row, app: NSAttributedString, title: NSAttributedString,
                      in rect: NSRect, columnWidth: CGFloat, selected: Bool, hovered: Bool) {
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 2), xRadius: 8, yRadius: 8).fill()
        }

        let iconRect = NSRect(x: iconLeft, y: rect.midY - Self.iconSide / 2,
                              width: Self.iconSide, height: Self.iconSide)
        IconCache.shared.icon(for: row.pid)?.draw(
            in: iconRect, from: .zero, operation: .sourceOver,
            fraction: row.isMinimized || row.isAppHidden ? 0.55 : 1.0)

        // The two buttons' room is reserved on every row, hovered or not, so that text never
        // reflows under the pointer.
        let close = closeRect(in: rect)
        if hovered, let cross = Self.closeIcon {
            cross.draw(in: close, from: .zero, operation: .sourceOver,
                       fraction: closeHovered ? 1.0 : 0.45)
        }

        let mark = markRect(in: rect)
        drawMark(row.mark, in: mark, selected: selected, hovered: hovered)

        let rightEdge = mark.minX - 6

        var badgeWidth: CGFloat = 0
        if let badge = badgeText(for: row) {
            badgeWidth = drawBadge(badge, rightEdge: rightEdge, in: rect, selected: selected)
        }

        let textTop = rect.midY - 9
        let appRect = NSRect(x: textLeft, y: textTop, width: columnWidth, height: 18)
        (selected ? Self.whitened(app) : app)
            .draw(with: appRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        guard title.length > 0 else { return }
        let titleX = appRect.maxX + columnGap
        let titleRect = NSRect(x: titleX, y: textTop,
                               width: max(0, rightEdge - titleX - badgeWidth),
                               height: 18)
        (selected ? Self.whitened(title) : title)
            .draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func rowRect(for index: Int) -> NSRect {
        NSRect(x: rowInset, y: rowsTop + CGFloat(index - scrollOffset) * rowHeight,
               width: bounds.width - rowInset * 2, height: rowHeight)
    }

    private func closeRect(in rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - iconGap - closeSide, y: rect.midY - closeSide / 2,
               width: closeSide, height: closeSide)
    }

    private func markRect(in rect: NSRect) -> NSRect {
        NSRect(x: closeRect(in: rect).minX - 8 - markSide, y: rect.midY - markSide / 2,
               width: markSide, height: markSide)
    }

    /// A numbered window wears its number always, because that is the whole point of having given
    /// it one. An unnumbered one shows a dashed ring only under the pointer, like the close
    /// button beside it.
    private func drawMark(_ number: Int?, in rect: NSRect, selected: Bool, hovered: Bool) {
        guard let number else {
            guard hovered, let ring = Self.markIcon else { return }
            ring.draw(in: rect, from: .zero, operation: .sourceOver,
                      fraction: markHovered ? 1.0 : 0.45)
            return
        }

        (selected ? NSColor.white : NSColor.controlAccentColor).setFill()
        NSBezierPath(ovalIn: rect).fill()

        let digit = NSAttributedString(string: String(number), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: selected ? NSColor.controlAccentColor : NSColor.white,
        ])
        let size = digit.size()
        digit.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func drawHeader() {
        let iconRect = NSRect(x: iconLeft, y: (headerHeight - Self.iconSide) / 2,
                              width: Self.iconSide, height: Self.iconSide)
        Self.brandIcon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)

        let name = NSAttributedString(string: "MrTab", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        name.draw(at: NSPoint(x: textLeft, y: (headerHeight - name.size().height) / 2))

        gearRect = NSRect(x: bounds.width - 14 - gearSide, y: (headerHeight - gearSide) / 2,
                          width: gearSide, height: gearSide)

        drawSearchField(from: textLeft + name.size().width + 14)

        if let gear = Self.gearIcon {
            // The whole header is the hit target's neighbourhood, so brightening on hover is the
            // only affordance telling you the gear is clickable.
            gear.draw(in: gearRect, from: .zero, operation: .sourceOver,
                      fraction: gearHovered ? 1.0 : 0.6)
        }

        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 12, y: headerHeight - 1, width: bounds.width - 24, height: 1).fill()
    }

    /// The typed filter, in the strip of header between the app name and the gear. There is no
    /// text field: a real one would need focus, an insertion point and a first responder dance
    /// for something the user can only ever type into. The prompt stands in for all of it, and
    /// doubles as the hint that typing does anything at all.
    private func drawSearchField(from left: CGFloat) {
        let glassSide: CGFloat = 16
        var x = left
        if let glass = Self.searchIcon {
            let rect = NSRect(x: x, y: (headerHeight - glassSide) / 2,
                              width: glassSide, height: glassSide)
            glass.draw(in: rect, from: .zero, operation: .sourceOver,
                       fraction: query.isEmpty ? 0.5 : 0.95)
            x = rect.maxX + 6
        }

        // A long query is truncated at the *head*, so the keystrokes just typed stay visible.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = query.isEmpty ? .byTruncatingTail : .byTruncatingHead

        let text = query.isEmpty ? "Type to filter" : query
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: query.isEmpty ? .regular : .semibold),
            .foregroundColor: query.isEmpty ? NSColor.white.withAlphaComponent(0.5)
                                            : NSColor.white,
            .paragraphStyle: paragraph,
        ])
        let width = gearRect.minX - 10 - x
        guard width > 20 else { return }
        let rect = NSRect(x: x, y: (headerHeight - 18) / 2, width: width, height: 18)
        string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Tinting is done once and cached: a template image has to be redrawn through a colour to
    /// take one, and that is not work for a draw path this hot.
    private static let searchIcon: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "magnifyingglass",
                                   accessibilityDescription: "Filter")?
            .withSymbolConfiguration(configuration) else { return nil }
        return symbol.tinted(with: .labelColor)
    }()

    private static let gearIcon: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "gearshape",
                                   accessibilityDescription: "Settings")?
            .withSymbolConfiguration(configuration) else { return nil }
        return symbol.tinted(with: .labelColor)
    }()

    private static let closeIcon: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "xmark",
                                   accessibilityDescription: "Close this window")?
            .withSymbolConfiguration(configuration) else { return nil }
        return symbol.tinted(with: .labelColor)
    }()

    private static let markIcon: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "circle.dashed",
                                   accessibilityDescription: "Give this window a number")?
            .withSymbolConfiguration(configuration) else { return nil }
        return symbol.tinted(with: .labelColor)
    }()

    private static let brandIcon: NSImage? = {
        guard let icon = NSApp.applicationIconImage else { return nil }
        let scaled = NSImage(size: NSSize(width: iconSide, height: iconSide))
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: iconSide, height: iconSide))
        scaled.unlockFocus()
        return scaled
    }()

    private func badgeText(for row: Row) -> String? {
        if row.isMinimized { return "minimized" }
        if row.isAppHidden { return "hidden" }
        return nil
    }

    /// Draws the badge with its right edge at `rightEdge`, and returns the width it claims,
    /// padding included, so the window title can be given what is left.
    @discardableResult
    private func drawBadge(_ text: String, rightEdge: CGFloat, in rect: NSRect,
                           selected: Bool) -> CGFloat {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: selected ? NSColor.white.withAlphaComponent(0.85)
                                       : NSColor.secondaryLabelColor,
        ])
        let size = string.size()
        string.draw(at: NSPoint(x: rightEdge - size.width, y: rect.midY - size.height / 2))
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
        // An empty list means two very different things depending on whether a filter is on, and
        // "no windows" would be a lie about the machine when it is really a miss on the query.
        let text = query.isEmpty ? "No windows" : "No window matches \u{201C}\(query)\u{201D}"
        let string = NSAttributedString(string: text, attributes: [
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
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        guard !rows.isEmpty else { return nil }
        let offset = point.y - rowsTop
        guard offset >= 0 else { return nil }
        let index = scrollOffset + Int(offset / rowHeight)
        return index < rows.count ? index : nil
    }

    /// Re-reads hover from where the pointer actually is.
    private func refreshHover() {
        guard let window, window.isVisible else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let target = bounds.contains(point) ? hit(at: point) : nil
        hoveredRow = target?.index
        closeHovered = target?.target == .close
        markHovered = target?.target == .mark
    }

    /// What the pointer is on, if it is on a row at all. The buttons sit inside the row, so they
    /// have to be tested before the row itself — otherwise closing or numbering a window would
    /// switch to it on the way out.
    private func hit(at point: NSPoint) -> (index: Int, target: Target)? {
        guard point.y >= headerHeight, let index = rowIndex(at: point) else { return nil }
        let rect = rowRect(for: index)
        if closeRect(in: rect).contains(point) { return (index, .close) }
        if markRect(in: rect).contains(point) { return (index, .mark) }
        return (index, .row)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        let overGear = gearRect.contains(point)
        if overGear != gearHovered {
            gearHovered = overGear
            needsDisplay = true
        }

        let target = hit(at: point)
        let row = target?.index
        let overClose = target?.target == .close
        let overMark = target?.target == .mark
        if row != hoveredRow || overClose != closeHovered || overMark != markHovered {
            hoveredRow = row
            closeHovered = overClose
            markHovered = overMark
            needsDisplay = true
        }

        // Moving across the header must not drag the selection with it.
        guard let row else { return }
        onHover?(row)
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredRow != nil || gearHovered else { return }
        hoveredRow = nil
        closeHovered = false
        markHovered = false
        gearHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if gearRect.contains(point) {
            onSettings?()
            return
        }
        guard let target = hit(at: point) else { return }
        switch target.target {
        case .close: onClose?(target.index)
        case .mark: onMark?(target.index)
        case .row: onClick?(target.index)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard rows.count > visibleRowCount else { return }
        let steps = Int(event.scrollingDeltaY / 10)
        guard steps != 0 else { return }
        scrollOffset = max(0, min(scrollOffset - steps, rows.count - visibleRowCount))
        needsDisplay = true
    }
}
