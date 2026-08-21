import AppKit

/// Pre-scaled app icons, keyed by pid.
///
/// `NSImage.draw` on a multi-representation `.icns` is not free, and doing it for a dozen rows
/// inside the hotkey handler is exactly the kind of cost this app exists to avoid. Icons are
/// rasterised once, when a snapshot lands, and reused until the app quits.
final class IconCache {
    static let shared = IconCache()

    private var cache: [pid_t: NSImage] = [:]
    private let side: CGFloat = 26

    private init() {}

    /// Main thread only.
    func icon(for pid: pid_t) -> NSImage? {
        if let cached = cache[pid] { return cached }
        return rasterize(pid: pid)
    }

    /// Rasterises anything not yet cached, and drops entries for apps that have quit.
    func warm(pids: [pid_t]) {
        let live = Set(pids)
        for pid in live where cache[pid] == nil {
            _ = rasterize(pid: pid)
        }
        cache = cache.filter { live.contains($0.key) }
    }

    @discardableResult
    private func rasterize(pid: pid_t) -> NSImage? {
        guard let source = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        let scaled = NSImage(size: NSSize(width: side, height: side))
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                    from: .zero, operation: .sourceOver, fraction: 1)
        scaled.unlockFocus()
        cache[pid] = scaled
        return scaled
    }
}
