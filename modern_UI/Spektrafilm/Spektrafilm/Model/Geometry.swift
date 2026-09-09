//  Geometry.swift — crop, straighten, rotate and flip, as pure arithmetic.
//
//  No view code and no Metal here, for the same reason `ViewportState` and
//  `CurveMath` have none: the interesting failures are geometric, and a
//  geometric failure is only cheap to find if it can be asserted about
//  without a window.
//
//  ## The model (Capture One's)
//
//  A crop is an **oriented rectangle**: a normalised rect plus an angle it is
//  rotated by about its own centre. It is not "rotate the image, then crop
//  the result" — that model has to invent pixels in the corners, and it makes
//  every straighten destructive because the crop is re-expressed in a frame
//  that just changed. Here the source never moves; the rectangle does.
//
//      ┌───────────────────────────────┐   source, normalised (0,0)…(1,1)
//      │        ╱‾‾‾‾‾‾‾‾‾‾‾╲          │
//      │      ╱   the crop    ╲        │   `crop` + `angle`
//      │     ╲                ╱        │
//      │       ╲____________╱          │
//      └───────────────────────────────┘
//
//  Straightening therefore never resamples anything twice, and turning the
//  angle back to zero restores exactly the rectangle you started with.
//
//  ## The fallback
//
//  An oriented rectangle can rotate its corners outside the source, and the
//  pixels out there do not exist. Every mutation here returns a crop that
//  **fits** — `fitted(in:)` shrinks about the centre until all four corners
//  are inside the frame. That is the fallback, and it is why `straighten` and
//  `move` cannot produce a crop with a transparent corner in it no matter how
//  hard the user drags. The shrink is a bisection rather than a closed form:
//  the closed form has four cases and a degenerate one near the corners, and
//  this is called at most once per drag event.
//
//  ## Order of operations, fixed
//
//      source ─ crop (oriented, `angle`) ─ quarter turns ─ flips ─ output
//
//  `angle` is the fine straighten, −45…45. `quarterTurns` is the coarse one,
//  and it is separate because a 90° turn is exact and lossless while a 7.3°
//  straighten is a resample. Keeping them apart means "rotate right" never
//  costs you sharpness.

import CoreGraphics
import Foundation

// MARK: - aspect

/// The aspect presets, in the order the picker shows them.
enum CropAspect: String, Codable, CaseIterable, Sendable, Identifiable {
    case free, original, square, r3x2, r2x3, r4x3, r3x4, r16x9, r5x4, r7x5

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case .r3x2: "3:2"
        case .r2x3: "2:3"
        case .r4x3: "4:3"
        case .r3x4: "3:4"
        case .r16x9: "16:9"
        case .r5x4: "5:4"
        case .r7x5: "7:5"
        }
    }

    /// Width ÷ height, in pixels. `nil` means unconstrained; `original` needs
    /// the source, so it resolves through `ratio(sourceAspect:)`.
    var fixedRatio: Double? {
        switch self {
        case .free, .original: nil
        case .square: 1
        case .r3x2: 3.0 / 2
        case .r2x3: 2.0 / 3
        case .r4x3: 4.0 / 3
        case .r3x4: 3.0 / 4
        case .r16x9: 16.0 / 9
        case .r5x4: 5.0 / 4
        case .r7x5: 7.0 / 5
        }
    }

    func ratio(sourceAspect: Double) -> Double? {
        self == .original ? sourceAspect : fixedRatio
    }
}

// MARK: - geometry

struct Geometry: Codable, Equatable, Sendable {
    /// The crop rectangle before rotation, normalised to the source with a
    /// top-left origin. Rotated about its own centre by `angle`.
    var crop = CropRect.full
    /// Fine straighten in degrees, positive clockwise. Capture One's range.
    var angle: Double = 0
    /// Coarse rotation in 90° steps, applied after the crop. Lossless.
    var quarterTurns: Int = 0
    var flipH = false
    var flipV = false
    var aspect: CropAspect = .free

    static let `default` = Geometry()
    static let maxAngle: Double = 45

    var isIdentity: Bool {
        crop.isFull && angle == 0 && quarterTurns == 0 && !flipH && !flipV
    }

    /// The crop's centre, normalised.
    var centre: CGPoint { CGPoint(x: crop.x + crop.width / 2, y: crop.y + crop.height / 2) }

    // MARK: corners and fit

    /// The four corners of the oriented rectangle, normalised, clockwise from
    /// top-left in the crop's own frame. `imageSize` is needed because the
    /// rotation is rigid in *pixels*: a rectangle rotated in normalised space
    /// on a 3:2 frame comes out sheared.
    func corners(in imageSize: CGSize) -> [CGPoint] {
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        let c = centre
        let hw = crop.width / 2 * w, hh = crop.height / 2 * h
        let a = angle * .pi / 180
        let ca = cos(a), sa = sin(a)
        return [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)].map { sx, sy in
            let px = sx * hw, py = sy * hh
            return CGPoint(x: c.x + (px * ca - py * sa) / w,
                           y: c.y + (px * sa + py * ca) / h)
        }
    }

    /// Whether every corner is inside the source. The epsilon absorbs the
    /// bisection's own residue so a fitted crop does not immediately read as
    /// unfitted on the next event.
    func fits(in imageSize: CGSize, epsilon: Double = 1e-6) -> Bool {
        corners(in: imageSize).allSatisfy {
            $0.x >= -epsilon && $0.y >= -epsilon && $0.x <= 1 + epsilon && $0.y <= 1 + epsilon
        }
    }

    /// The fallback: the largest version of this crop, about the same centre
    /// and at the same angle and aspect, whose corners are all inside the
    /// source. Returns `self` when it already fits.
    ///
    /// A bisection on the scale factor. It always converges because the
    /// centre is clamped inside the frame first, and a crop scaled towards a
    /// point inside the frame fits at some small enough scale.
    func fitted(in imageSize: CGSize) -> Geometry {
        var g = self
        // A centre outside the frame has no valid crop at any scale.
        g.crop.x = (g.crop.x + g.crop.width / 2).clamped(to: 0...1) - g.crop.width / 2
        g.crop.y = (g.crop.y + g.crop.height / 2).clamped(to: 0...1) - g.crop.height / 2
        if g.fits(in: imageSize) { return g }

        let c = g.centre
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            var t = g
            t.crop = CropRect(x: c.x - g.crop.width * mid / 2, y: c.y - g.crop.height * mid / 2,
                              width: g.crop.width * mid, height: g.crop.height * mid)
            if t.fits(in: imageSize) { lo = mid } else { hi = mid }
        }
        g.crop = CropRect(x: c.x - g.crop.width * lo / 2, y: c.y - g.crop.height * lo / 2,
                          width: g.crop.width * lo, height: g.crop.height * lo)
        return g
    }

    // MARK: moving between the source's frame and the crop's own

    /// A source-normalised point, expressed in the crop's **unrotated** frame
    /// (still normalised to the source, so it is directly comparable with
    /// `crop`). Every hit test and every resize works here: the crop is
    /// axis-aligned in this frame whatever the straighten angle is, which is
    /// what lets `resized` stay simple arithmetic.
    func unrotated(_ p: CGPoint, in imageSize: CGSize) -> CGPoint {
        transform(p, in: imageSize, by: -angle)
    }

    /// The inverse: a point in the crop's unrotated frame, back to where it
    /// actually sits on the source. What the overlay draws with.
    func rotated(_ p: CGPoint, in imageSize: CGSize) -> CGPoint {
        transform(p, in: imageSize, by: angle)
    }

    private func transform(_ p: CGPoint, in imageSize: CGSize, by degrees: Double) -> CGPoint {
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        let c = centre
        let dx = (p.x - c.x) * w, dy = (p.y - c.y) * h
        let a = degrees * .pi / 180
        let ca = cos(a), sa = sin(a)
        return CGPoint(x: c.x + (dx * ca - dy * sa) / w,
                       y: c.y + (dx * sa + dy * ca) / h)
    }

    /// Which grip a source-normalised point is on, or `.body` for inside the
    /// rectangle, or `nil` for outside it. `tolerance` is in source pixels —
    /// the caller converts from view points through the viewport's scale, so
    /// the grab area is a constant size on screen at every zoom.
    func handle(at p: CGPoint, in imageSize: CGSize, tolerance: CGFloat) -> CropHandle? {
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        let q = unrotated(p, in: imageSize)
        let dx = (q.x - crop.x) * w, dy = (q.y - crop.y) * h
        let cw = crop.width * w, ch = crop.height * h
        // Corners first: on a small crop the corner and the two edges it
        // belongs to all match, and the corner is what the user meant.
        var best: (handle: CropHandle, rank: Double)?
        for handle in CropHandle.allCases where handle != .body {
            let pos = handle.position
            let d = hypot(dx - pos.x * cw, dy - pos.y * ch)
            guard d <= tolerance else { continue }
            let rank = handle.isCorner ? d : d + tolerance   // corners win ties
            if best == nil || rank < best!.rank { best = (handle, rank) }
        }
        if let best { return best.handle }
        let inside = dx >= -tolerance && dy >= -tolerance && dx <= cw + tolerance && dy <= ch + tolerance
        return inside ? .body : nil
    }

    /// The angle, in degrees, that would make the line `a`→`b` horizontal —
    /// the straighten-by-drawing-a-line gesture. Both points are
    /// source-normalised; the angle is computed in pixels, and a line closer
    /// to vertical than horizontal straightens to vertical instead, which is
    /// what a user drawing down a doorframe means.
    static func straightenAngle(from a: CGPoint, to b: CGPoint, in imageSize: CGSize) -> Double? {
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        let dx = (b.x - a.x) * w, dy = (b.y - a.y) * h
        guard hypot(dx, dy) > 8 else { return nil }   // a click, not a line
        var deg = atan2(dy, dx) * 180 / .pi
        if abs(deg) > 90 { deg += deg > 0 ? -180 : 180 }
        if abs(deg) > 45 { deg += deg > 0 ? -90 : 90 }
        return deg.clamped(to: -Geometry.maxAngle...Geometry.maxAngle)
    }

    // MARK: mutations, each of which returns something that fits

    /// Set the straighten angle and pull the crop back inside the frame.
    /// This is the operation that makes the fallback visible: rotating a
    /// full-frame crop by 5° shrinks it to about 91 % of the frame, which is
    /// the same thing every other raw editor does and the reason a straighten
    /// costs resolution.
    func straightened(to degrees: Double, in imageSize: CGSize) -> Geometry {
        var g = self
        g.angle = degrees.clamped(to: -Geometry.maxAngle...Geometry.maxAngle)
        return g.fitted(in: imageSize)
    }

    /// Move the crop by a normalised delta, keeping it inside the frame.
    /// Moving is clamped rather than shrunk: a drag that would leave the
    /// frame stops at the edge instead of quietly making the crop smaller.
    func moved(by delta: CGSize, in imageSize: CGSize) -> Geometry {
        var g = self
        g.crop.x += delta.width
        g.crop.y += delta.height
        guard !g.fits(in: imageSize) else { return g }
        // Walk back along the delta to the last position that fits. Cheaper
        // to reason about than solving for the contact edge, and exact to
        // within a pixel at any sane image size.
        var lo = 0.0, hi = 1.0
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            var t = self
            t.crop.x += delta.width * mid
            t.crop.y += delta.height * mid
            if t.fits(in: imageSize) { lo = mid } else { hi = mid }
        }
        var out = self
        out.crop.x += delta.width * lo
        out.crop.y += delta.height * lo
        return out
    }

    /// Apply the current aspect to the crop, keeping `anchor` (normalised, in
    /// the crop's own 0…1 space — (0,0) is its top-left corner) fixed. The
    /// area is preserved, so switching 3:2 → 16:9 neither grows nor shrinks
    /// the crop noticeably; it reshapes it.
    func constrained(in imageSize: CGSize, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> Geometry {
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        guard let ratio = aspect.ratio(sourceAspect: w / h) else { return fitted(in: imageSize) }
        var g = self
        // Solve in pixels, then normalise back.
        let pw = g.crop.width * w, ph = g.crop.height * h
        let area = max(pw * ph, 1)
        let nw = (area * ratio).squareRoot()
        let nh = nw / ratio
        let x1 = g.crop.x + g.crop.width * anchor.x
        let y1 = g.crop.y + g.crop.height * anchor.y
        g.crop = CropRect(x: x1 - (nw / w) * anchor.x, y: y1 - (nh / h) * anchor.y,
                          width: nw / w, height: nh / h)
        return g.fitted(in: imageSize)
    }

    /// Resize by moving one handle, honouring the aspect lock. `handle` says
    /// which corner or edge moved; `point` is where it was dragged to,
    /// source-normalised and **already put through `unrotated(_:in:)`** — the
    /// crop is axis-aligned in that frame at any straighten angle.
    func resized(handle: CropHandle, to point: CGPoint, in imageSize: CGSize) -> Geometry {
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        var minX = crop.x, minY = crop.y
        var maxX = crop.x + crop.width, maxY = crop.y + crop.height
        if handle.movesLeading { minX = point.x }
        if handle.movesTrailing { maxX = point.x }
        if handle.movesTop { minY = point.y }
        if handle.movesBottom { maxY = point.y }
        // A drag past the opposite edge flips the rectangle rather than
        // inverting it, which is what every direct-manipulation crop does.
        var g = self
        g.crop = CropRect(x: min(minX, maxX), y: min(minY, maxY),
                          width: max(abs(maxX - minX), Geometry.minSide / w),
                          height: max(abs(maxY - minY), Geometry.minSide / h))
        if let ratio = aspect.ratio(sourceAspect: w / h) {
            // Keep the corner opposite the one being dragged pinned, and
            // derive the other side from the ratio.
            let anchor = handle.oppositeAnchor
            let pw = g.crop.width * w, ph = g.crop.height * h
            var nw = pw, nh = ph
            if handle.isCorner { nh = pw / ratio; if nh < Geometry.minSide { nh = Geometry.minSide; nw = nh * ratio } }
            else if handle.movesLeading || handle.movesTrailing { nh = pw / ratio }
            else { nw = ph * ratio }
            let ax = g.crop.x + g.crop.width * anchor.x
            let ay = g.crop.y + g.crop.height * anchor.y
            g.crop = CropRect(x: ax - (nw / w) * anchor.x, y: ay - (nh / h) * anchor.y,
                              width: nw / w, height: nh / h)
        }
        return g.fitted(in: imageSize)
    }

    /// Coarse rotation. The crop rides along: turning the frame right must
    /// not leave the crop pointing at a different part of the picture.
    func turned(by steps: Int) -> Geometry {
        var g = self
        g.quarterTurns = ((g.quarterTurns + steps) % 4 + 4) % 4
        return g
    }

    /// Smallest crop side, in source pixels. Below this the handles overlap
    /// and the render is pointless.
    static let minSide: Double = 16

    // MARK: what comes out

    /// The output's pixel size for a given source size: the crop, then the
    /// quarter turns' axis swap.
    func outputSize(for imageSize: CGSize) -> CGSize {
        let w = (crop.width * imageSize.width).rounded(), h = (crop.height * imageSize.height).rounded()
        let size = CGSize(width: max(w, 1), height: max(h, 1))
        return quarterTurns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// Map a point in the *output* (normalised, top-left origin) back to the
    /// source (normalised). This is the shader's sampling function, written
    /// once here so the test and the Metal kernel cannot drift: the kernel is
    /// a transliteration of this and `GeometryTests` pins the pairs.
    func sourcePoint(forOutput p: CGPoint, imageSize: CGSize) -> CGPoint {
        var u = p
        // 1. undo the flips
        if flipH { u.x = 1 - u.x }
        if flipV { u.y = 1 - u.y }
        // 2. undo the quarter turns, into the crop's own unrotated frame
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: u = CGPoint(x: u.y, y: 1 - u.x)
        case 2: u = CGPoint(x: 1 - u.x, y: 1 - u.y)
        case 3: u = CGPoint(x: 1 - u.y, y: u.x)
        default: break
        }
        // 3. crop-local pixels about the centre, then the rotation
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        let px = (u.x - 0.5) * crop.width * w
        let py = (u.y - 0.5) * crop.height * h
        let a = angle * .pi / 180
        let ca = cos(a), sa = sin(a)
        let c = centre
        return CGPoint(x: c.x + (px * ca - py * sa) / w,
                       y: c.y + (px * sa + py * ca) / h)
    }

    // MARK: the uniform the shader gets
    //
    // Packed so the kernel does no trigonometry per pixel: the rotation is
    // two scalars, and the normalisation ratios are folded in.

    struct Uniform: Equatable {
        var centre = SIMD2<Float>(0.5, 0.5)
        var halfExtent = SIMD2<Float>(0.5, 0.5)   // crop half-size, normalised
        var cosSin = SIMD2<Float>(1, 0)
        var pixelRatio = SIMD2<Float>(1, 1)       // (w/h, h/w), for the rigid rotation
        var quarterTurns: UInt32 = 0
        var flips: UInt32 = 0                     // bit 0 = horizontal, bit 1 = vertical
        var active: UInt32 = 0
        var pad: UInt32 = 0
    }

    func uniform(for imageSize: CGSize) -> Uniform {
        var u = Uniform()
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        let a = angle * .pi / 180
        u.centre = SIMD2(Float(centre.x), Float(centre.y))
        u.halfExtent = SIMD2(Float(crop.width / 2), Float(crop.height / 2))
        u.cosSin = SIMD2(Float(cos(a)), Float(sin(a)))
        u.pixelRatio = SIMD2(Float(w / h), Float(h / w))
        u.quarterTurns = UInt32(((quarterTurns % 4) + 4) % 4)
        u.flips = (flipH ? 1 : 0) | (flipV ? 2 : 0)
        u.active = isIdentity ? 0 : 1
        return u
    }
}

// MARK: - handles

/// The eight grips on the crop rectangle, plus the body.
enum CropHandle: String, CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, body

    var isCorner: Bool { [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(self) }
    var movesLeading: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    var movesTrailing: Bool { [.topRight, .right, .bottomRight].contains(self) }
    var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
    var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }

    /// The point that stays put while this handle is dragged, in the crop's
    /// own 0…1 space.
    var oppositeAnchor: CGPoint {
        CGPoint(x: movesLeading ? 1 : (movesTrailing ? 0 : 0.5),
                y: movesTop ? 1 : (movesBottom ? 0 : 0.5))
    }

    /// Where the handle sits on the rectangle, in the crop's own 0…1 space.
    var position: CGPoint {
        CGPoint(x: movesLeading ? 0 : (movesTrailing ? 1 : 0.5),
                y: movesTop ? 0 : (movesBottom ? 1 : 0.5))
    }
}
