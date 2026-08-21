import AppKit

/// Draws the app icon and writes a full .iconset, so the artwork lives in version control as code
/// rather than as a binary blob nobody can diff.
///
///     MRTAB_MAKE_ICONSET=build/MrTab.iconset build/MrTab.app/Contents/MacOS/MrTab
///
/// `build.sh` runs this and pipes the result through `iconutil`.
enum IconGenerator {
    static func runIfRequested() -> Bool {
        guard let directory = ProcessInfo.processInfo.environment["MRTAB_MAKE_ICONSET"] else { return false }

        let variants: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        for (name, pixels) in variants {
            guard let png = render(pixels: pixels) else { continue }
            try? png.write(to: url.appendingPathComponent("\(name).png"))
        }
        FileHandle.standardOutput.write(Data("wrote \(variants.count) icons to \(directory)\n".utf8))
        return true
    }

    /// Renders at an exact pixel size rather than letting NSImage scale, so every slice is crisp.
    private static func render(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(side: CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    /// Two offset window shapes on a rounded gradient tile — the app switches windows, so the
    /// icon shows one window in front of another.
    private static func draw(side: CGFloat) {
        let inset = side * 0.055
        let tile = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let radius = tile.width * 0.225

        let background = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
        NSGradient(colors: [
            NSColor(srgbRed: 0.36, green: 0.49, blue: 0.99, alpha: 1),
            NSColor(srgbRed: 0.42, green: 0.24, blue: 0.86, alpha: 1),
        ])?.draw(in: background, angle: -90)

        let unit = tile.width
        let corner = unit * 0.055

        // Back window: dimmed, up and to the left.
        let back = NSRect(x: tile.minX + unit * 0.17, y: tile.minY + unit * 0.40,
                          width: unit * 0.47, height: unit * 0.35)
        NSColor.white.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: back, xRadius: corner, yRadius: corner).fill()

        // Front window: solid, down and to the right, with a title bar.
        let front = NSRect(x: tile.minX + unit * 0.36, y: tile.minY + unit * 0.23,
                           width: unit * 0.47, height: unit * 0.35)
        let frontPath = NSBezierPath(roundedRect: front, xRadius: corner, yRadius: corner)
        NSColor.white.setFill()
        frontPath.fill()

        frontPath.setClip()
        NSColor(srgbRed: 0.36, green: 0.49, blue: 0.99, alpha: 0.22).setFill()
        NSRect(x: front.minX, y: front.maxY - unit * 0.085,
               width: front.width, height: unit * 0.085).fill()

        // Traffic-light dots, only where they would still be legible.
        if side >= 128 {
            let dot = unit * 0.022
            NSColor(srgbRed: 0.42, green: 0.24, blue: 0.86, alpha: 0.55).setFill()
            for index in 0..<3 {
                let x = front.minX + unit * 0.035 + CGFloat(index) * dot * 2.6
                NSBezierPath(ovalIn: NSRect(x: x, y: front.maxY - unit * 0.062,
                                            width: dot * 1.6, height: dot * 1.6)).fill()
            }
        }
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).setClip()
    }
}
