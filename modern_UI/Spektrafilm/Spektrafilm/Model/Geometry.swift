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
//  hard the user drags. The shrink itself is a bisection, because it only
//  ever has to be right about "does this fit" and it is called at most once
//  per drag event; where the *largest* fitting size is the question rather
//  than a fallback — a straighten, which must also be able to grow — the
//  bound is closed-form instead (`maxScale`).
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
    /// The crop's size the user last set by hand, normalised like
    /// `crop.width/height`, or nil for "as large as fits".
    ///
    /// This is the memory that makes a sized crop survive a straighten: the
    /// size is what the user chose, so an angle change may shrink it but
    /// never grows it back past this. A crop nobody has sized — the default
    /// full frame, a reset — has no memory and is instead always the largest
    /// rectangle of its shape that fits (see `straightened(to:in:)`).
    ///
    /// Optional on purpose: `Geometry` decodes through synthesised Codable,
    /// and only an optional decodes from an absent key, so every schema-3
    /// sidecar written before this field existed still opens.
    var intendedSize: CGSize? = nil

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

    /// The largest scale of a rectangle about a **fixed centre** that still
    /// lies inside a `imageSize` frame once rotated by `angle`. Everything
    /// is in pixels.
    ///
    /// An oriented rectangle lies inside an axis-aligned frame *iff* its
    /// axis-aligned bounding box does — the frame is a box, so the extremes
    /// of the rectangle are what matter — and that makes the bound
    /// closed-form: half-extents (a, b) project to `a·|cos| + b·|sin|`
    /// across and `a·|sin| + b·|cos|` down, so the scale that puts each of
    /// those exactly on the nearer edge is a division, and the answer is the
    /// smaller of the two.
    ///
    /// `fitted(in:)` bisects to the same number, so this is not a different
    /// model; it is the direct one, and unlike a shrink it can also *grow* a
    /// crop back when the angle returns toward 0°.
    static func maxScale(halfExtents: CGSize, centre: CGPoint, angle: Double,
                         in imageSize: CGSize) -> Double {
        let a = halfExtents.width, b = halfExtents.height
        guard a > 0, b > 0 else { return 0 }
        let radians = angle * .pi / 180
        let ca = abs(cos(radians)), sa = abs(sin(radians))
        let roomX = min(centre.x, imageSize.width - centre.x)
        let roomY = min(centre.y, imageSize.height - centre.y)
        guard roomX > 0, roomY > 0 else { return 0 }
        return min(roomX / (a * ca + b * sa), roomY / (a * sa + b * ca))
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
        rotate(p, about: centre, by: degrees, in: imageSize)
    }

    /// Rotate a normalised point about a normalised pivot, rigidly in
    /// **pixels** — the same convention as `transform`, which is this about
    /// the crop's own centre.
    private func rotate(_ p: CGPoint, about pivot: CGPoint, by degrees: Double,
                        in imageSize: CGSize) -> CGPoint {
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        let dx = (p.x - pivot.x) * w, dy = (p.y - pivot.y) * h
        let a = degrees * .pi / 180
        let ca = cos(a), sa = sin(a)
        return CGPoint(x: pivot.x + (dx * ca - dy * sa) / w,
                       y: pivot.y + (dx * sa + dy * ca) / h)
    }

    // MARK: the crop tool's edit space
    //
    // While the crop is being edited the **frame** stays level on screen and
    // the photograph turns under it (Capture One's tool, and the only one
    // that lets you judge a straighten against a level frame). That screen is
    // edit space, related to the source by a rotation about a pivot `P`:
    //
    //      edit → source:   S(e) = P + R(+θ)(e − P)
    //      source → edit:   E(s) = P + R(−θ)(s − P)
    //
    // with the crop, oriented at θ in the source, appearing in edit space as
    // an axis-aligned rectangle centred on E(C). The pivot is what makes the
    // view stable: while it is the crop's centre the photo turns about the
    // frame's centre, and when it is not (the crop has been moved since) the
    // frame moves over a still picture. Both are rigid in pixels, like every
    // other rotation here.
    //
    // The inverse pair for `sourcePoint(forOutput:)` / `outputPoint(forSource:)`
    // is a different mapping — that one is crop → output — and this is not a
    // replacement for it. Output, and therefore the exported file, does not
    // change when the crop tool does.

    /// Edit space → source, the mapping the canvas samples the photograph
    /// through while the crop tool is up (S above).
    func sourcePoint(forEdit e: CGPoint, pivot: CGPoint, imageSize: CGSize) -> CGPoint {
        rotate(e, about: pivot, by: angle, in: imageSize)
    }

    /// Source → edit space (E above): where a source point is drawn while the
    /// crop tool is up, and therefore where every overlay handle goes.
    func editPoint(forSource s: CGPoint, pivot: CGPoint, imageSize: CGSize) -> CGPoint {
        rotate(s, about: pivot, by: -angle, in: imageSize)
    }

    /// The box the **whole photograph** occupies in edit space: its four
    /// corners put through E, normalised to the source's W×H frame — the units
    /// the canvas measures in while the crop tool is up
    /// (`Renderer.logicalSize(forSource:)`).
    ///
    /// At 0° this is exactly the unit rect and fitting it is the ordinary fit;
    /// at any other angle it is strictly larger than the frame, because the
    /// turned photograph's corners stick out past it — 1/cos θ taller on a
    /// square-ish frame, and more on a wide one. This is what the crop tool's
    /// view is fitted to: fitting the *crop* would cut the picture's own
    /// corners off, since the crop is the largest rectangle that fits inside
    /// the turned photograph and the photograph is therefore always at least
    /// as big (measured: 8.5° cut 37.6 pt off the top and bottom of the frame
    /// at fit, 20.4° 72 pt vertically and 12 pt horizontally).
    func editBounds(pivot: CGPoint, in imageSize: CGSize) -> CGRect {
        let corners = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map {
            editPoint(forSource: CGPoint(x: $0.0, y: $0.1), pivot: pivot, imageSize: imageSize)
        }
        var box = CGRect(origin: corners[0], size: .zero)
        for c in corners.dropFirst() { box = box.union(CGRect(origin: c, size: .zero)) }
        return box
    }

    /// How far every point of edit space moves, **in pixels**, when the pivot
    /// moves from `p1` to `p2` at this angle: `(I − R(−θ))·(p₂ − p₁)`.
    ///
    /// The same for every point — a translation — which is what lets one
    /// nudge of the viewport cancel it exactly when a re-pivot happens under
    /// a rotation. `Geometry.repivot` is its only caller, and `GeometryTests`
    /// pins the cancellation it is used for.
    static func pivotShift(from p1: CGPoint, to p2: CGPoint, angle: Double,
                           in imageSize: CGSize) -> CGSize {
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        let dx = (p2.x - p1.x) * w, dy = (p2.y - p1.y) * h
        let a = -angle * .pi / 180
        let ca = cos(a), sa = sin(a)
        let rx = dx * ca - dy * sa, ry = dx * sa + dy * ca
        return CGSize(width: dx - rx, height: dy - ry)
    }

    /// The re-pivot rule, as one pure step: what `Renderer` does at the
    /// assignment every angle change goes through. `nil` means "nothing to
    /// do" — the angle did not change, or the pivot is already the crop's
    /// centre (which is the ordinary case: the pivot only lags behind after
    /// the crop has been dragged somewhere else).
    ///
    /// **The angle that matters is the one *before* the write, not after.**
    /// What has to stay still is where the frame's centre was drawn before
    /// it, and that is `E_old(C) = P₁ + R(−θ_old)(C − P₁)`; the new one is
    /// just `C`, because the pivot has become the crop's centre. So the
    /// compensation is `(I − R(−θ_old))·(C − P₁)` — `old.angle`. Passing
    /// `new.angle` instead leaves `(R(−θ_new) − R(−θ_old))·(C − P₁)`: nothing
    /// at all for one step of a drag, where the two angles are a degree
    /// apart, but a jump of tens of pixels for a 20°→0° write with the crop
    /// moved off-centre — which is what typing a slider value, the Crop
    /// menu's straighten, a ⌘-line and an undo all are.
    static func repivot(from old: Geometry, to new: Geometry, pivot: CGPoint,
                        in imageSize: CGSize, scale: CGFloat)
        -> (pivot: CGPoint, offset: CGSize)? {
        guard new.angle != old.angle else { return nil }
        let target = new.centre
        guard pivot != target else { return nil }
        let shift = pivotShift(from: pivot, to: target, angle: old.angle, in: imageSize)
        return (target, CGSize(width: -shift.width * scale, height: -shift.height * scale))
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

    /// Set the straighten angle: keep the centre, keep the shape, take the
    /// **largest size that fits at this angle** — capped at `intendedSize`
    /// when the user has set one.
    ///
    /// Rotating a full-frame crop by 5° still shrinks it to about 91 % of the
    /// frame, which is the same thing every other raw editor does and the
    /// reason a straighten costs resolution. What changed is that the result
    /// is now a function of (centre, shape, intendedSize, angle) and nothing
    /// else. The old version fitted *whatever the crop had become*, so each
    /// angle change compounded the last one's shrink and 0° → 12° → 0° left
    /// a crop smaller than the frame. Now the angle is not destructive:
    /// 0° → 12° → 0° restores the frame, and a crop the user resized comes
    /// back to exactly the size they set.
    ///
    /// This is the one angle entry point — the slider, the ⌘-line straighten,
    /// the rotate drag and "Straighten to 0°" all come through here — which
    /// is what lets the frame stay level in the crop tool: the centre does
    /// not wander as the angle changes.
    func straightened(to degrees: Double, in imageSize: CGSize) -> Geometry {
        var g = self
        g.angle = degrees.clamped(to: -Geometry.maxAngle...Geometry.maxAngle)
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        // The centre survives the angle change, clamped into the frame the
        // way `fitted` clamps it.
        let c = CGPoint(x: g.centre.x.clamped(to: 0...1), y: g.centre.y.clamped(to: 0...1))
        // The size to scale: the user's if they set one, otherwise the
        // crop's own shape — for a default crop, the source's. Scaling both
        // normalised sides by one factor keeps the pixel aspect.
        let base = intendedSize ?? CGSize(width: crop.width, height: crop.height)
        guard base.width > 0, base.height > 0 else { return g.fitted(in: imageSize) }
        // What "no size set" means, and the one place an old sidecar is
        // adopted. `nil` is the state of a crop that is maximal about its own
        // centre at its own angle — `.default`, "whole frame", or the result
        // of this function — so a `nil` crop that could still *grow* is one
        // the user sized before this field existed, and it keeps its size.
        // Nothing is written back: the test is the same on every call.
        let cap: Double
        if intendedSize != nil {
            cap = 1
        } else if Geometry.maxScale(halfExtents: CGSize(width: crop.width * w / 2,
                                                        height: crop.height * h / 2),
                                    centre: CGPoint(x: c.x * w, y: c.y * h),
                                    angle: angle, in: imageSize) > 1 + 1e-4 {
            // `self.angle`, not `g.angle`: whether this crop was maximal is a
            // fact about the state being left, not the one being entered.
            cap = 1
        } else {
            cap = .infinity   // no memory means no cap: as large as fits
        }
        let scale = min(Geometry.maxScale(halfExtents: CGSize(width: base.width * w / 2,
                                                              height: base.height * h / 2),
                                          centre: CGPoint(x: c.x * w, y: c.y * h),
                                          angle: g.angle, in: imageSize),
                        cap)
        g.crop = CropRect(x: c.x - base.width * scale / 2, y: c.y - base.height * scale / 2,
                          width: base.width * scale, height: base.height * scale)
        return g
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
        // The user just chose this shape and this is the size it came out:
        // remember it, or a later straighten would treat the result as "no
        // preference" and grow it to the maximal fit.
        let out = g.fitted(in: imageSize)
        return out.rememberingSize()
    }

    /// A brand-new rectangle drawn by the user, in source normalised units
    /// and level in the crop's own frame — so `angle` is untouched, which is
    /// what lets the canvas draw it level on screen while the photograph is
    /// turned. `anchor` is the corner the drag started at (see `constrained`,
    /// which grows the shape from it when an aspect is locked).
    ///
    /// Drawing a rectangle is the user saying how big the crop is, the same
    /// statement dragging a handle makes, so the result is remembered even
    /// when the aspect is free — `constrained` alone does not, because as an
    /// *aspect* entry point its `.free` case is a no-op that must not freeze
    /// a size nobody chose.
    func redrawn(as crop: CropRect, in imageSize: CGSize,
                 anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> Geometry {
        var g = self
        g.crop = crop
        return g.constrained(in: imageSize, anchor: anchor).rememberingSize()
    }

    /// `self` with `intendedSize` set to the crop it actually has. Every
    /// operation that *sizes* a crop ends this way; `moved`, `turned` and
    /// `straightened` deliberately do not, so an angle change cannot make a
    /// size decision on the user's behalf.
    private func rememberingSize() -> Geometry {
        var g = self
        g.intendedSize = CGSize(width: crop.width, height: crop.height)
        return g
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
        // Dragging a handle is the user saying how big the crop should be;
        // whatever came out is the new remembered size.
        return g.fitted(in: imageSize).rememberingSize()
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

    /// The inverse of `sourcePoint(forOutput:imageSize:)`: where a point on
    /// the source appears in the output.
    ///
    /// Needed because masks are anchored to the **source** — a mask stays on
    /// the face when you re-crop, which is what a mask anchored to the output
    /// would not do — while the canvas shows the output. Anything that draws
    /// a mask handle goes through here.
    func outputPoint(forSource p: CGPoint, imageSize: CGSize) -> CGPoint {
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        let c = centre
        // 1. undo the rotation about the crop's centre, in pixels
        let dx = (p.x - c.x) * w, dy = (p.y - c.y) * h
        let a = -angle * .pi / 180
        let ca = cos(a), sa = sin(a)
        let px = dx * ca - dy * sa, py = dx * sa + dy * ca
        // 2. crop-local → 0…1 across the crop
        var u = CGPoint(x: px / (crop.width * w) + 0.5, y: py / (crop.height * h) + 0.5)
        // 3. undo the quarter turns — the inverse of turning by k is turning
        //    by 4 − k, in the same forward form.
        switch (4 - (((quarterTurns % 4) + 4) % 4)) % 4 {
        case 1: u = CGPoint(x: u.y, y: 1 - u.x)
        case 2: u = CGPoint(x: 1 - u.x, y: 1 - u.y)
        case 3: u = CGPoint(x: 1 - u.y, y: u.x)
        default: break
        }
        // 4. undo the flips
        if flipH { u.x = 1 - u.x }
        if flipV { u.y = 1 - u.y }
        return u
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
