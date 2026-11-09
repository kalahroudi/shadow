// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoreGraphics

/// Which face the overlay shows. Answering is a stub in milestone 1: nothing ever enters it (R13).
public enum OverlayState: Sendable, Equatable {
    case idle, listening, answering

    public static func from(sessionRunning: Bool) -> OverlayState { sessionRunning ? .listening : .idle }
    public var label: String {
        switch self { case .idle: "Idle"; case .listening: "Listening"; case .answering: "Answering" }
    }
}

/// Overlay sizes and where it opens (R13). Compact and Expanded follow the mockup widths, which double as minimums.
public enum OverlayLayout {
    public static let compactSize = CGSize(width: 420, height: 230)
    public static let expandedSize = CGSize(width: 520, height: 420)
    public static let minHeight: CGFloat = 150
    public static let opacityRange: ClosedRange<Double> = 0.4...1
    public static let defaultOpacity = 1.0

    public static func size(compact: Bool) -> CGSize { compact ? compactSize : expandedSize }
    public static func minSize(compact: Bool) -> CGSize { CGSize(width: size(compact: compact).width, height: minHeight) }

    /// The top-right corner of a screen, with a margin, as the first-run position.
    public static func defaultFrame(compact: Bool, in visible: CGRect) -> CGRect {
        let s = size(compact: compact)
        return CGRect(x: visible.maxX - s.width - 24, y: visible.maxY - s.height - 24, width: s.width, height: s.height)
    }

    /// Resizing for a Compact/Expanded toggle: the new size, anchored at the top-left of the old frame.
    public static func resized(_ frame: CGRect, compact: Bool) -> CGRect {
        let s = size(compact: compact)
        return CGRect(x: frame.minX, y: frame.maxY - s.height, width: s.width, height: s.height)
    }
}

/// Remembers the overlay frame per display (R13). The key is a stable display identifier, so each monitor keeps its own place.
public struct FrameStore {
    private let defaults: UserDefaults
    private let storeKey = "overlayFrames"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func frame(for display: String) -> CGRect? {
        guard let rect = all()[display] else { return nil }
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    public func save(_ frame: CGRect, for display: String) {
        var map = all()
        map[display] = frame
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: storeKey)
    }

    /// The remembered frame when it still overlaps the screen's visible area, otherwise the default position.
    public func restored(for display: String, compact: Bool, visible: CGRect) -> CGRect {
        if let saved = frame(for: display) {
            // A frame saved in the other mode may be narrower than this mode's minimum; keep the top-left and grow it.
            let min = OverlayLayout.minSize(compact: compact)
            let fitted = CGRect(x: saved.minX, y: saved.maxY - Swift.max(saved.height, min.height),
                                width: Swift.max(saved.width, min.width), height: Swift.max(saved.height, min.height))
            // Usable only if enough of it is on screen to grab and drag (at least a 100x60 corner).
            let shown = fitted.intersection(visible)
            if !shown.isNull, shown.width >= 100, shown.height >= 60 { return fitted }
        }
        return OverlayLayout.defaultFrame(compact: compact, in: visible)
    }

    private func all() -> [String: CGRect] {
        guard let data = defaults.data(forKey: storeKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CGRect].self, from: data)) ?? [:]
    }
}
