//  BeforeAfterIcon.swift — the split-view glyph, from the drawing.
//
//  Traced from `modern_UI/control_asset/SVG/资源 1.svg` rather than
//  approximated: the numbers below are that file's, on its own 60.8 × 48.11
//  viewBox, scaled to whatever box the view is given. An outlined rectangle on
//  the left (what the picture was), a filled one on the right (what it is),
//  and the divider between them — the same three marks the shader draws.
//
//  It is a view rather than an asset because it has to take the interface's
//  colour: selected controls tint orange (Capture One's convention, and the
//  rule this app now follows), and a bitmap or a colour-baked SVG cannot.

import SwiftUI

struct BeforeAfterIcon: View {
    /// The glyph's colour. The filled half is drawn at reduced opacity so the
    /// two rectangles stay distinguishable in one colour.
    var color: Color = Theme.text
    var lineWidth: CGFloat = 1.4

    /// The source drawing's coordinate system.
    private static let art = CGSize(width: 60.8, height: 48.11)

    var body: some View {
        GeometryReader { geo in
            let m = BeforeAfterIcon.fit(geo.size)
            ZStack(alignment: .topLeading) {
                // Left: the outline — "before" is the frame, not the picture.
                Path { $0.addRect(m.rect(1, 6.32, 23.52, 35.28)) }
                    .stroke(color, lineWidth: lineWidth)
                // Right: filled — "after" is a picture.
                Path { $0.addRect(m.rect(35.87, 5.27, 24.93, 37.39)) }
                    .fill(color.opacity(0.5))
                // The divider, full height.
                Path { p in
                    p.move(to: m.point(30.5, 0))
                    p.addLine(to: m.point(30.5, BeforeAfterIcon.art.height))
                }
                .stroke(color, lineWidth: lineWidth)
            }
        }
    }

    /// Art coordinates → view coordinates: aspect-fit, centred.
    struct Fit {
        var scale: CGFloat, dx: CGFloat, dy: CGFloat
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: dx + x * scale, y: dy + y * scale)
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(origin: point(x, y), size: CGSize(width: w * scale, height: h * scale))
        }
    }

    static func fit(_ size: CGSize) -> Fit {
        let s = min(size.width / art.width, size.height / art.height)
        return Fit(scale: s,
                   dx: (size.width - art.width * s) / 2,
                   dy: (size.height - art.height * s) / 2)
    }
}
