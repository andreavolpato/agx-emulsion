//  Theme.swift — every visual token in the interface, measured from the design.
//
//  The drawing (`modern_UI/reference_layout/SVG_link/sample_frontend.svg`) is
//  a 3840×2160 canvas, i.e. a 1920×1080 window at 2×. Every number here is
//  the drawing's value divided by two. Nothing in a view file may carry a
//  literal colour or size that could have come from here — that is the rule
//  that keeps the interface matching the drawing when one token moves.

import SwiftUI

enum Theme {

    // MARK: colours (from the SVG's style classes)

    /// `.st2` — the window ground. The canvas surround and every well.
    static let ground = Color(hex: 0x5F5F5F)
    /// `.st5` — the four floating cards (panels, top bar, filmstrip).
    static let card = Color(hex: 0x2C2D2B)
    /// Wells inside a card: same value as the ground, on purpose — the design
    /// reads as "cards punched through to the ground".
    static let well = ground
    /// A pill or field sitting inside a well (the Format picker, the zoom pill).
    static let field = card
    /// `.st4` / `.st9` — primary text and glyphs.
    static let text = Color(hex: 0xFAF8F4)
    /// `.st6` — slider tracks, dim captions.
    static let dim = Color(hex: 0x898989)
    /// Text on a well that is secondary (group headers "Still" / "Cine").
    static let secondaryText = Color(hex: 0xDAD8D4)
    /// Plot grounds (histogram / curve) are one step darker than the card.
    static let plot = Color(hex: 0x1E1F1E)
    static let plotGrid = Color(hex: 0x3A3B39)
    /// The one accent in the interface: the active curve tab and its points.
    static let accent = Color(hex: 0xEE8A2B)
    static let selectionFrame = Color(hex: 0xFAF8F4)
    static let knob = Color(hex: 0xFAF8F4)
    static let canvasSurround = ground

    static let histR = Color(hex: 0xE8524E)
    static let histG = Color(hex: 0x62C462)
    static let histB = Color(hex: 0x5D7DE8)
    static let histY = Color(hex: 0xBDBDBD)

    // MARK: metrics (SVG ÷ 2)

    enum Metric {
        /// Card corner radius (rx 30 → 15).
        static let cardRadius: CGFloat = 15
        /// Well corner radius (rx 22.9 → 11.5).
        static let wellRadius: CGFloat = 11.5
        /// Outer margin between window edge and cards (17.9 → 9, 14.1 → 7).
        static let outerX: CGFloat = 9
        static let outerY: CGFloat = 7
        /// Gutter between a side panel and the centre column. The drawing's is
        /// 8 (690.5 − 674.8); 6 spends less screen on ground between the four
        /// cards. Deliberate departure from the drawing.
        static let gutter: CGFloat = 6
        static let leftPanelWidth: CGFloat = 328
        static let rightPanelWidth: CGFloat = 286
        static let topBarHeight: CGFloat = 41
        static let filmstripHeight: CGFloat = 125
        /// Well inset from the card edge (36.2 − 17.9 → 9).
        static let wellInset: CGFloat = 9
        /// Leading inset for the left panel's header row.
        ///
        /// `.windowStyle(.hiddenTitleBar)` does not remove the three window
        /// buttons; it floats them over the content, the way Xcode's sit over
        /// its navigator sidebar. Measured on this machine: x 10–57 pt,
        /// y 5–26 pt. The card starts at x 9, so the first glyph must begin at
        /// x ≥ 78 — 69 pt inside the card. 70 keeps a 1 pt margin and leaves a
        /// gap about the size of Xcode's between the buttons and the first
        /// toolbar item. This is the one place the built interface departs
        /// from the drawing, which puts the import glyph at x 12; every other
        /// card keeps its 12 pt. The window server draws the buttons, so no
        /// offscreen capture (`Tools/snapshot.sh`) can see the collision this
        /// avoids — `Tools/capture-live.sh` is the check.
        static let panelHeaderLeading: CGFloat = 70
        /// Text inset from the well edge (label x 62 → 31, well x 18 → 13).
        static let wellPadding: CGFloat = 13
        /// Section header height and the gap wells keep from headers.
        static let headerHeight: CGFloat = 26
        static let headerToWell: CGFloat = 6
        static let wellToHeader: CGFloat = 10
        /// Slider: track height, knob size.
        static let trackHeight: CGFloat = 2.5
        static let knobSize = CGSize(width: 10.5, height: 8.7)
        static let knobRadius: CGFloat = 3
        /// Column where every slider track starts inside a well (201 → 100.5,
        /// minus well x 18 → 82.5) and the value column width.
        static let sliderLabelWidth: CGFloat = 70
        static let sliderValueWidth: CGFloat = 40
        static let rowHeight: CGFloat = 20
        static let listRowHeight: CGFloat = 24
        /// Checkbox square (9.9 → 5) drawn with a 1 pt stroke.
        static let checkbox: CGFloat = 9
        /// Disclosure triangle (24.3×14.5 → 12×7).
        static let disclosure = CGSize(width: 12, height: 7)
        /// Section icon box.
        static let sectionIcon: CGFloat = 16
        /// Toolbar glyph size.
        static let toolIcon: CGFloat = 17
        /// Panel-header glyph size (import/export, sliders).
        static let panelIcon: CGFloat = 19
        /// Collapse tab (27.8×83.1 → 14×41.5).
        static let tabThickness: CGFloat = 14
        static let tabLength: CGFloat = 41.5
        /// Zoom pill (210.5×41.4 → 105×20.7).
        static let zoomPill = CGSize(width: 105, height: 20.7)
        static let filmCover: CGFloat = 20
        static let thumbHeight: CGFloat = 105
        static let minWindow = CGSize(width: 1100, height: 700)
    }

    // MARK: type ramp
    //
    // Cap height of "Kodak Portra 400" in the drawing: 16.9 units → 8.45 pt,
    // i.e. a 12 pt face. Headers share it. Labels are one step down.

    enum Font {
        static let sectionTitle = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let listItem = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let groupHeader = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let label = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let sublabel = SwiftUI.Font.system(size: 10, weight: .medium)
        static let value = SwiftUI.Font.system(size: 10.5, weight: .medium).monospacedDigit()
        static let tab = SwiftUI.Font.system(size: 10.5, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 9, weight: .regular)
        static let pill = SwiftUI.Font.system(size: 10.5, weight: .semibold).monospacedDigit()
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
