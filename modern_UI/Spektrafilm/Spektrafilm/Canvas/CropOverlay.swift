//  CropOverlay.swift — the crop's handles, its grid, and the straighten line.
//
//  Drawn in SwiftUI over the `MTKView` rather than in the shader. The shader
//  already does the part that has to be per-pixel — dimming everything
//  outside the oriented rectangle — and everything left is thin lines that
//  want to be crisp at any zoom and never want to be resampled with the
//  image. Metal would draw them into the same texture the image is in.
//
//  It hit-tests nothing (`allowsHitTesting(false)`): the mouse belongs to
//  `CanvasNSView`, which owns the gesture and does its hit testing against
//  `Geometry` in normalised space. Two views both claiming the pointer is the
//  bug this arrangement exists to avoid.

import SwiftUI

struct CropOverlay: View {
    @Bindable var session: Session

    var body: some View {
        GeometryReader { geo in
            let v = session.viewportSnapshot
            let size = session.sourceImageSize
            let g = session.geometry
            if size.width > 1, v.image.width > 1 {
                let corners = g.corners(in: size).map { view($0, g, size, v) }
                ZStack {
                    outline(corners)
                    thirds(g, size, v)
                    grips(g, size, v)
                    straightenLine(g, size, v)
                }
                .compositingGroup()
            }
        }
        .allowsHitTesting(false)
    }

    /// Source-normalised → view points, **through E**.
    ///
    /// The canvas draws the photograph turned about the pivot, so the crop
    /// frame is level on screen; E is that turn, and this is the whole of why
    /// the frame below comes out square. The viewport is expressed against
    /// the whole frame while the crop tool is up
    /// (`Renderer.logicalSize(forSource:)`), which is what lets an edit-space
    /// point be read as an image point directly.
    ///
    /// Note it is E applied to points that are *already* the crop's own
    /// corners — `E(rotated(p)) = E(C) + (p − C)` — so a point given in the
    /// crop's own 0…1 frame lands where it belongs rather than at the origin.
    private func view(_ n: CGPoint, _ g: Geometry, _ size: CGSize, _ v: ViewportState) -> CGPoint {
        let e = g.editPoint(forSource: n, pivot: session.cropPivot, imageSize: size)
        return v.viewPoint(atImage: CGPoint(x: e.x * v.image.width, y: e.y * v.image.height))
    }

    private func path(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        pts.dropFirst().forEach { p.addLine(to: $0) }
        p.closeSubpath()
        return p
    }

    private func outline(_ corners: [CGPoint]) -> some View {
        path(corners)
            .stroke(Theme.selectionFrame, lineWidth: 1)
            .shadow(color: .black.opacity(0.5), radius: 1)
    }

    /// The rule-of-thirds grid, drawn in the crop's own frame and carried to
    /// the screen by `view` — which is what makes it come out square rather
    /// than turned with the photograph. Every crop tool shows one and it is
    /// the only reason to draw inside the rectangle at all.
    private func thirds(_ g: Geometry, _ size: CGSize, _ v: ViewportState) -> some View {
        Path { p in
            for t in [1.0 / 3, 2.0 / 3] {
                let a = view(g.rotated(CGPoint(x: g.crop.x + g.crop.width * t, y: g.crop.y), in: size), g, size, v)
                let b = view(g.rotated(CGPoint(x: g.crop.x + g.crop.width * t, y: g.crop.y + g.crop.height), in: size), g, size, v)
                p.move(to: a); p.addLine(to: b)
                let c = view(g.rotated(CGPoint(x: g.crop.x, y: g.crop.y + g.crop.height * t), in: size), g, size, v)
                let d = view(g.rotated(CGPoint(x: g.crop.x + g.crop.width, y: g.crop.y + g.crop.height * t), in: size), g, size, v)
                p.move(to: c); p.addLine(to: d)
            }
        }
        .stroke(Theme.selectionFrame.opacity(0.35), lineWidth: 0.5)
    }

    /// Corner brackets and edge bars, at the handle positions. No
    /// `rotationEffect` any more: the frame is level on screen whatever the
    /// straighten angle is, so a bar along an edge is simply a bar.
    private func grips(_ g: Geometry, _ size: CGSize, _ v: ViewportState) -> some View {
        ZStack {
            ForEach(CropHandle.allCases.filter { $0 != .body }, id: \.rawValue) { h in
                let pos = h.position
                let n = g.rotated(CGPoint(x: g.crop.x + g.crop.width * pos.x,
                                          y: g.crop.y + g.crop.height * pos.y), in: size)
                let p = view(n, g, size, v)
                // A corner is a square block; an edge grip is a bar lying
                // along the edge it moves.
                Rectangle()
                    .fill(Theme.selectionFrame)
                    .frame(width: h.isCorner ? 11 : (h.movesLeading || h.movesTrailing ? 4 : 22),
                           height: h.isCorner ? 11 : (h.movesLeading || h.movesTrailing ? 22 : 4))
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .position(p)
            }
        }
    }

    /// The ⌘ line being drawn. Stored in the photograph's own coordinates and
    /// drawn through E, so it sits under the cursor whatever the angle is —
    /// and so does the straighten it produces.
    @ViewBuilder
    private func straightenLine(_ g: Geometry, _ size: CGSize, _ v: ViewportState) -> some View {
        if let line = session.straightenPreview {
            Path { p in
                p.move(to: view(line.from, g, size, v))
                p.addLine(to: view(line.to, g, size, v))
            }
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}
