//  Theme.swift — the app's metrics, and the few colours that are ours.
//
//  Most colour is *not* here on purpose. The docks use `.regularMaterial` and
//  the semantic hierarchy (`.primary` / `.secondary` / `.tertiary`) so they
//  pick up the system's vibrancy, contrast and accessibility settings rather
//  than freezing a palette that ignores them — which is what macOS HIG asks
//  for and what makes a window look native instead of themed.
//
//  What remains ours: the canvas surround (which must be a specific, neutral,
//  non-competing value because an image sits on it) and the two filter-pack
//  track gradients, which are the only coloured controls in the app.

import SwiftUI

enum Theme {
    /// The surround the image sits on. Deliberately darker than any dock, and
    /// deliberately neutral — a tinted surround shifts perception of the
    /// print's colour, which is the one judgement this app exists to support.
    static let canvasVoid = Color(white: 0.09)

    static let hairline   = Color.primary.opacity(0.10)
    static let dockStroke = Color.white.opacity(0.09)

    // Filter-pack tracks, ~15% saturation. The only hue in the interface.
    static let yellowBlue = LinearGradient(
        colors: [Color(red: 0.31, green: 0.34, blue: 0.47),
                 Color(white: 0.30),
                 Color(red: 0.47, green: 0.44, blue: 0.29)],
        startPoint: .leading, endPoint: .trailing)
    static let magentaGreen = LinearGradient(
        colors: [Color(red: 0.29, green: 0.43, blue: 0.31),
                 Color(white: 0.30),
                 Color(red: 0.47, green: 0.30, blue: 0.43)],
        startPoint: .leading, endPoint: .trailing)

    // Docks float over the canvas, inset from the window edges.
    static let dockRadius = 10.0
    static let dockPad = 12.0
    static let dockInset = 12.0
    static let leftWidthDefault  = 288.0
    static let rightWidthDefault = 248.0
    static let leftRange  = 240.0...400.0
    static let rightRange = 210.0...340.0

    // The filmstrip is part of the bottom bar, which spans the full window.
    static let stripHeightDefault = 92.0
    static let stripRange = 64.0...180.0
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
