// SPDX-License-Identifier: Apache-2.0

import AppKit

/// The app icon, drawn in code so the build needs no image tools and stays crisp at every size.
/// Matches design/mockup.html: a violet-to-blue squircle, a white speech bubble and four voice bars.
enum AppIcon {
    static let violet = NSColor(srgbRed: 0.486, green: 0.361, blue: 1, alpha: 1)   // #7c5cff
    static let blue = NSColor(srgbRed: 0.302, green: 0.608, blue: 1, alpha: 1)     // #4d9bff

    /// The bubble and its four bars in the mockup's 512-unit space (y down). Shared with the menu bar glyph.
    static func bubble() -> NSBezierPath {
        let p = NSBezierPath(roundedRect: NSRect(x: 120, y: 114, width: 272, height: 220), xRadius: 56, yRadius: 56)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 164, y: 320)); tail.line(to: NSPoint(x: 236, y: 334))
        tail.line(to: NSPoint(x: 164, y: 396)); tail.close()
        p.append(tail)
        return p
    }
    /// Bars as (x, top, bottom).
    static let bars: [(CGFloat, CGFloat, CGFloat)] = [(190, 200, 276), (236, 166, 310), (282, 190, 286), (328, 214, 262)]

    /// - padded: leave the transparent margin macOS expects around Dock icons (824 of 1024).
    static func image(size: CGFloat, padded: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let margin: CGFloat = padded ? 100 : 0
            let tile = NSRect(x: margin / 1024 * size, y: margin / 1024 * size,
                              width: (1024 - 2 * margin) / 1024 * size, height: (1024 - 2 * margin) / 1024 * size)
            let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2246, yRadius: tile.width * 0.2246)
            NSGradient(starting: violet, ending: blue)?.draw(in: shape, angle: -45)

            // Map the 512-unit artwork (tile spans 24...488) onto the tile.
            let t = AffineTransform(translationByX: tile.minX, byY: tile.minY)
            var scale = AffineTransform(scaleByX: tile.width / 464, byY: tile.height / 464)
            scale.prepend(AffineTransform(translationByX: -24, byY: -24))
            var m = scale; m.append(t)
            let bubble = bubble(); bubble.transform(using: m)
            NSColor.white.withAlphaComponent(0.95).setFill(); bubble.fill()
            for (x, top, bottom) in bars {
                let bar = NSBezierPath(); bar.move(to: NSPoint(x: x, y: top)); bar.line(to: NSPoint(x: x, y: bottom))
                bar.transform(using: m); bar.lineWidth = 22 * tile.width / 464; bar.lineCapStyle = .round
                NSColor(srgbRed: 0.416, green: 0.298, blue: 0.941, alpha: 1).setStroke(); bar.stroke()   // #6a4cf0
            }
            return true
        }
    }

    /// Writes an .iconset folder for `iconutil -c icns`.
    static func writeIconset(to dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sizes: [(String, CGFloat)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                                          ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
        for (name, px) in sizes {
            guard let tiff = image(size: px, padded: true).tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("icon_\(name).png"))
        }
    }
}
