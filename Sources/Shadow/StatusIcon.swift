// SPDX-License-Identifier: Apache-2.0

import AppKit
import ShadowKit

/// The menu bar glyph: the app's bubble and four bars, always a template image so macOS tints it for light and dark bars.
/// State is shape, never colour (R16): idle is an outlined bubble, recording is a solid bubble with a dot badge.
enum StatusIcon {
    static func image(_ state: GlyphState) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            // Bubble artwork spans x 120...392, y 114...396 in 512 units; fit it to about 15 pt.
            let s: CGFloat = 15 / 282
            var m = AffineTransform(translationByX: 1, byY: 1)
            m.prepend(AffineTransform(scaleByX: s, byY: s))
            m.prepend(AffineTransform(translationByX: -120, byY: -114))
            let bubble = AppIcon.bubble(); bubble.transform(using: m)
            NSColor.black.setFill(); NSColor.black.setStroke()
            switch state {
            case .idle:
                bubble.lineWidth = 1.3; bubble.stroke()
            case .recording:
                bubble.fill()
            }
            for (x, top, bottom) in AppIcon.bars {
                let bar = NSBezierPath(); bar.move(to: NSPoint(x: x, y: top)); bar.line(to: NSPoint(x: x, y: bottom))
                bar.transform(using: m); bar.lineWidth = 1.6; bar.lineCapStyle = .round
                // On the solid bubble the bars are cut out; on the outline they are drawn.
                if state == .recording { NSGraphicsContext.current?.compositingOperation = .clear }
                bar.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            if state == .recording {
                // A clear ring around the dot separates it from the solid bubble.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 10, y: -1, width: 9, height: 9)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: NSRect(x: 11.5, y: 0.5, width: 6, height: 6)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
