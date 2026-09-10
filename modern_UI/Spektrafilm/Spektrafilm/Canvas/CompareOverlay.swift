//  CompareOverlay.swift — the before/after split's line, handle and labels.
//
//  The shader decides which of the two textures each pixel comes from
//  (`canvasFragment`); this draws the furniture. Same division of labour as
//  `CropOverlay`, and for the same reason: a one-point line and a 30 pt disc
//  have to stay one point and 30 pt at 400 % zoom, and anything drawn into the
//  image is resampled with it.
//
//  The split is anchored to the **output** — the cropped picture — not to the
//  viewport. Drag the image and the line goes with it, so the comparison stays
//  on the same eye, the same sky, the same skin. A viewport-anchored line is
//  easier to write and useless the moment you zoom in on something.

import SwiftUI

struct CompareOverlay: View {
    @Bindable var session: Session

    /// Radius of the drag handle, and the grab area, in view points.
    private static let handle: CGFloat = 15

    var body: some View {
        GeometryReader { geo in
            let v = session.viewportSnapshot
            if session.comparing, v.image.width > 1 {
                let x = lineX(v)
                let top = v.offset.y
                let bottom = v.offset.y + v.image.height * v.scale
                // Clamped to the canvas: at high zoom the picture's top and
                // bottom are off screen and a line drawn to them is a line
                // that mostly is not there.
                let y0 = max(0, min(top, geo.size.height))
                let y1 = max(0, min(bottom, geo.size.height))
                let midY = (max(y0, 0) + min(y1, geo.size.height)) / 2

                ZStack(alignment: .topLeading) {
                    Path { p in
                        p.move(to: CGPoint(x: x, y: y0))
                        p.addLine(to: CGPoint(x: x, y: y1))
                    }
                    .stroke(Theme.selectionFrame, lineWidth: 1)
                    .shadow(color: .black.opacity(0.6), radius: 1)

                    grip.position(x: x, y: midY)

                    // In the picture's top corners, not beside the line: the
                    // reference puts them there, and near the line they land
                    // under the top collapse tab — which is drawn over this
                    // view, so the label silently disappears rather than
                    // moving out of the way.
                    let left = max(v.offset.x, 0) + 34
                    let right = min(v.offset.x + v.image.width * v.scale, geo.size.width) - 34
                    let labelY = max(y0, 0) + 16
                    if x - left > 24 { label("Before").position(x: left, y: labelY) }
                    if right - x > 24 { label("After").position(x: right, y: labelY) }
                }
                .contentShape(Rectangle())
                .gesture(drag(in: v, width: geo.size.width))
            }
        }
        // Unlike the crop and mask overlays this one *does* take the mouse:
        // the handle is the control. The gesture is attached above rather
        // than here so the rest of the canvas keeps its pan.
        .allowsHitTesting(session.comparing)
    }

    /// The split's x in view points.
    private func lineX(_ v: ViewportState) -> CGFloat {
        v.offset.x + CGFloat(session.comparePosition) * v.image.width * v.scale
    }

    private var grip: some View {
        ZStack {
            Circle().fill(Theme.card.opacity(0.55))
            Circle().strokeBorder(Theme.selectionFrame, lineWidth: 1)
            HStack(spacing: 2) {
                Image(systemName: "arrowtriangle.left.fill")
                Image(systemName: "arrowtriangle.right.fill")
            }
            .font(.system(size: 7))
            .foregroundStyle(Theme.selectionFrame)
        }
        .frame(width: CompareOverlay.handle * 2, height: CompareOverlay.handle * 2)
        .shadow(color: .black.opacity(0.5), radius: 2)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.card.opacity(0.8), in: Capsule())
            .fixedSize()
    }

    /// Anywhere on the line takes the drag, not only the disc — the line is
    /// what the eye tracks, and a 30 pt target on a 1 pt line is the whole
    /// reason the disc is drawn at all.
    private func drag(in v: ViewportState, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let span = v.image.width * v.scale
                guard span > 1 else { return }
                session.comparePosition = Double((g.location.x - v.offset.x) / span)
            }
    }
}
