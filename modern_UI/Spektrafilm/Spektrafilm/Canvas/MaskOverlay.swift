//  MaskOverlay.swift — the selected mask's geometry, on the canvas.
//
//  The shader draws the *coverage* (the red tint). This draws the **controls**
//  — a gradient's axis and its two guide lines, a radial's ellipse and its
//  grips — for the same reason `CropOverlay` does: they are thin lines that
//  must stay one point wide at 400 % zoom and must never be resampled with
//  the image.
//
//  Masks are anchored to the **source**, not to the crop, so a mask stays on
//  the face when the frame is re-cropped. The canvas shows the crop. Every
//  position therefore goes source → output → view, and the middle step is
//  `Geometry.outputPoint(forSource:imageSize:)`.
//
//  Hit-testing lives in `CanvasNSView` (this view takes no mouse events), so
//  the two agree by both asking `Session.maskHandles` where the grips are.

import SwiftUI

/// One draggable grip on a mask's geometry, in source-normalised coordinates.
struct MaskHandle: Equatable, Sendable, Identifiable {
    enum Role: String, Sendable { case a, b, centre, radiusX, radiusY, rotate }
    var component: UUID
    var role: Role
    var position: CGPoint
    var id: String { "\(component)-\(role.rawValue)" }
}

struct MaskOverlay: View {
    @Bindable var session: Session

    var body: some View {
        GeometryReader { _ in
            let v = session.viewportSnapshot
            let size = session.sourceImageSize
            if size.width > 1, v.image.width > 1, let mask = session.selectedMask, mask.enabled {
                ZStack {
                    ForEach(mask.components) { c in
                        switch c.kind {
                        case .linearGradient: linear(c, size, v)
                        case .radialGradient: radial(c, size, v)
                        default: EmptyView()
                        }
                    }
                    grips(v, size)
                }
                .compositingGroup()
            }
        }
        .allowsHitTesting(false)
    }

    /// Source-normalised → view points, through the crop.
    private func view(_ n: CGPoint, _ v: ViewportState, _ size: CGSize) -> CGPoint {
        let o = session.geometry.outputPoint(forSource: n, imageSize: size)
        return CGPoint(x: v.offset.x + o.x * v.image.width * v.scale,
                       y: v.offset.y + o.y * v.image.height * v.scale)
    }

    /// The axis, plus a guide line through each end perpendicular to it —
    /// the two lines that say where the gradient starts and stops, which is
    /// the whole reason a linear gradient is legible in Lightroom and a bare
    /// arrow would not be.
    private func linear(_ c: MaskComponent, _ size: CGSize, _ v: ViewportState) -> some View {
        let a = view(c.a, v, size), b = view(c.b, v, size)
        let d = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        let len = max(hypot(d.dx, d.dy), 1e-6)
        let perp = CGVector(dx: -d.dy / len, dy: d.dx / len)
        let reach: CGFloat = 4000   // long enough to leave any canvas
        return ZStack {
            Path { p in p.move(to: a); p.addLine(to: b) }
                .stroke(Theme.selectionFrame.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            guide(a, perp, reach)
            guide(b, perp, reach)
        }
        .shadow(color: .black.opacity(0.5), radius: 1)
    }

    private func guide(_ at: CGPoint, _ dir: CGVector, _ reach: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: at.x - dir.dx * reach, y: at.y - dir.dy * reach))
            p.addLine(to: CGPoint(x: at.x + dir.dx * reach, y: at.y + dir.dy * reach))
        }
        .stroke(Theme.selectionFrame.opacity(0.6), lineWidth: 1)
    }

    /// The ellipse, at its rotation, plus a second dashed one at the inner
    /// edge of the feather so the falloff is visible rather than guessed.
    private func radial(_ c: MaskComponent, _ size: CGSize, _ v: ViewportState) -> some View {
        let steps = 96
        func ring(_ scale: CGFloat) -> Path {
            var p = Path()
            for i in 0...steps {
                let t = Double(i) / Double(steps) * 2 * .pi
                let n = MaskGeometry.point(on: c, at: t, scale: scale, imageSize: size)
                let q = view(n, v, size)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            p.closeSubpath()
            return p
        }
        return ZStack {
            ring(1).stroke(Theme.selectionFrame.opacity(0.9), lineWidth: 1)
            if c.feather > 0.01 {
                ring(CGFloat(1 - c.feather))
                    .stroke(Theme.selectionFrame.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 1)
    }

    private func grips(_ v: ViewportState, _ size: CGSize) -> some View {
        ForEach(session.maskHandles) { h in
            Circle()
                .fill(Theme.selectionFrame)
                .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 0.5))
                .frame(width: h.role == .centre ? 9 : 7, height: h.role == .centre ? 9 : 7)
                .shadow(color: .black.opacity(0.5), radius: 1)
                .position(view(h.position, v, size))
        }
    }
}

/// The radial's shape arithmetic, shared by the overlay (which draws it) and
/// `Session` (which puts grips on it). Pure, so the ring and the grips cannot
/// end up describing different ellipses.
enum MaskGeometry {
    /// A point on the component's ellipse at parameter `t`, scaled about its
    /// centre. Radii are normalised to the **long edge**, matching
    /// `toLongEdge` in the shader, so the ellipse the user drags is the
    /// ellipse the coverage uses.
    static func point(on c: MaskComponent, at t: Double, scale: CGFloat = 1, imageSize: CGSize) -> CGPoint {
        let long = max(imageSize.width, imageSize.height)
        let sx = imageSize.width / long, sy = imageSize.height / long
        let a = c.angle * .pi / 180
        let ex = c.radii.width * scale * cos(t), ey = c.radii.height * scale * sin(t)
        let rx = ex * cos(a) - ey * sin(a)
        let ry = ex * sin(a) + ey * cos(a)
        // Long-edge units → normalised on each axis.
        return CGPoint(x: c.a.x + rx / sx, y: c.a.y + ry / sy)
    }
}
