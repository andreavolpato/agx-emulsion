//  GeometryTests.swift — the crop's arithmetic.
//
//  Every failure this pins is geometric and silent: an export that is subtly
//  the wrong part of the frame, a straighten that leaves transparent corners,
//  a handle you cannot grab at 400 %. None of them throws, and none of them
//  is visible in a layout capture.
//
//  The one to read first is `testShaderMappingMatchesTheModel`. The Metal
//  kernel's `geometryMap` is a hand transliteration of
//  `Geometry.sourcePoint(forOutput:imageSize:)`, and the two drifting apart
//  is a picture that is simply of somewhere else.

import XCTest

final class GeometryTests: XCTestCase {

    /// A 45 MP frame, 3:2. The rotation is rigid in *pixels*, so a
    /// non-square frame is the only honest test subject: on a square one
    /// every sign error cancels.
    private let size = CGSize(width: 8256, height: 5504)

    // MARK: the fallback

    func testAFullFrameCropFitsAndAStraightenedOneShrinksToFit() {
        var g = Geometry.default
        XCTAssertTrue(g.fits(in: size))

        g = g.straightened(to: 8, in: size)
        XCTAssertEqual(g.angle, 8)
        XCTAssertTrue(g.fits(in: size), "straighten must return something that fits — that is the fallback")
        XCTAssertLessThan(g.crop.width, 1.0)
        // 8° on a 3:2 frame costs about 20 % of the width. The point of the
        // assertion is the order of magnitude: a straighten is not free, and
        // a version that shrank to nothing or not at all would pass a bare
        // `fits`.
        XCTAssertEqual(g.crop.width, 0.79, accuracy: 0.06)
        XCTAssertEqual(g.crop.width / g.crop.height, 1.0, accuracy: 1e-6,
                       "the shrink is about the centre, so the shape is unchanged")
    }

    /// The angle is not destructive. This test used to assert the opposite —
    /// that 12° and back left a permanently smaller crop, because the
    /// straighten fitted whatever the previous angle had already shrunk —
    /// and that is exactly the behaviour the maximal fit replaces.
    func testStraighteningBackToZeroRestoresTheWholeFrame() {
        let g = Geometry.default.straightened(to: 12, in: size).straightened(to: 0, in: size)
        XCTAssertEqual(g.angle, 0)
        XCTAssertEqual(g.crop.width, 1.0, accuracy: 1e-9)
        XCTAssertEqual(g.crop.height, 1.0, accuracy: 1e-9)
        XCTAssertTrue(g.fits(in: size))
    }

    /// A crop nobody sized is the maximal rectangle of its shape at every
    /// angle — tangent to the frame — and the angle it arrives *from* does
    /// not matter. The second half is the half that fails on the old
    /// compounding fit: coming down from 30° used to leave a crop sized for
    /// 30° at every later angle.
    func testADefaultCropIsMaximalAtEveryAngleWhereverItComesFrom() {
        for angle in [3.0, 8, 20, -30, 45] {
            let direct = Geometry.default.straightened(to: angle, in: size)
            let roundTrip = Geometry.default.straightened(to: 30, in: size).straightened(to: angle, in: size)
            for (name, g) in [("direct", direct), ("after 30°", roundTrip)] {
                XCTAssertTrue(g.fits(in: size), "\(name) at \(angle)°")
                let tangent = g.corners(in: size).contains { c in
                    [c.x, 1 - c.x, c.y, 1 - c.y].map(abs).min()! < 1e-6
                }
                XCTAssertTrue(tangent, "\(name) at \(angle)° must touch the frame; corners \(g.corners(in: size))")
            }
            XCTAssertEqual(direct.crop.width, roundTrip.crop.width, accuracy: 1e-9,
                           "the size at \(angle)° must not depend on the path taken to it")
            XCTAssertEqual(direct.crop.height, roundTrip.crop.height, accuracy: 1e-9)
        }
    }

    func testTheAngleIsClampedRatherThanWrapped() {
        XCTAssertEqual(Geometry.default.straightened(to: 400, in: size).angle, Geometry.maxAngle)
        XCTAssertEqual(Geometry.default.straightened(to: -400, in: size).angle, -Geometry.maxAngle)
    }

    // MARK: the remembered size

    /// "Remember my size": a crop the user sized does not jump out to the
    /// maximal fit when the angle moves — it keeps its size where the
    /// rotation allows, shrinks where it must, and comes back to exactly the
    /// size that was set.
    func testASizedCropKeepsItsSizeAndGrowsBackNoFurther() {
        var small = Geometry.default
        small.crop = CropRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        small.intendedSize = CGSize(width: 0.2, height: 0.2)
        let nudged = small.straightened(to: 5, in: size)
        XCTAssertEqual(nudged.crop.width, 0.2, accuracy: 1e-9, "a small crop fits at 5° untouched")
        XCTAssertEqual(nudged.crop.height, 0.2, accuracy: 1e-9)
        XCTAssertEqual(nudged.crop.x, 0.4, accuracy: 1e-9, "and does not move")
        XCTAssertEqual(nudged.crop.y, 0.4, accuracy: 1e-9)

        var large = Geometry.default
        large.crop = CropRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        large.intendedSize = CGSize(width: 0.9, height: 0.9)
        let rotated = large.straightened(to: 20, in: size)
        XCTAssertTrue(rotated.fits(in: size))
        XCTAssertLessThan(rotated.crop.width, 0.9, "20° costs a large crop something")
        XCTAssertGreaterThan(rotated.crop.width, 0.5)
        let restored = rotated.straightened(to: 0, in: size)
        XCTAssertEqual(restored.crop.width, 0.9, accuracy: 1e-9, "and 0° gives back exactly the size that was set")
        XCTAssertEqual(restored.crop.height, 0.9, accuracy: 1e-9)
        XCTAssertEqual(restored.crop.x, 0.05, accuracy: 1e-9, "about the same centre")
    }

    /// Which operations make a size decision and which must not. `moved` and
    /// `turned` carry the memory along untouched; a resize and an aspect
    /// change *are* the user choosing a size, so both record one.
    func testRememberedSizeIsSetBySizingAndKeptByEverythingElse() {
        var g = Geometry.default
        g.crop = CropRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        XCTAssertNil(g.intendedSize)
        XCTAssertNil(g.moved(by: CGSize(width: 0.05, height: 0), in: size).intendedSize)
        XCTAssertNil(g.turned(by: 1).intendedSize)
        XCTAssertNil(g.straightened(to: 7, in: size).intendedSize,
                     "an angle change must not invent a size the user never chose")

        let resized = g.resized(handle: .bottomRight, to: CGPoint(x: 0.7, y: 0.7), in: size)
        XCTAssertEqual(resized.intendedSize?.width ?? -1, resized.crop.width, accuracy: 1e-9)
        XCTAssertEqual(resized.intendedSize?.height ?? -1, resized.crop.height, accuracy: 1e-9)
        XCTAssertEqual(resized.straightened(to: 9, in: size).intendedSize, resized.intendedSize,
                       "and the angle change keeps it")

        var square = g
        square.aspect = .square
        let constrained = square.constrained(in: size)
        XCTAssertEqual(constrained.intendedSize?.width ?? -1, constrained.crop.width, accuracy: 1e-9)
        XCTAssertEqual(constrained.intendedSize?.height ?? -1, constrained.crop.height, accuracy: 1e-9)
    }

    /// An old sidecar has no `intendedSize` — the field did not exist — so a
    /// crop the user sized back then arrives looking exactly like a crop
    /// nobody ever touched. The invariant that tells them apart: `nil` means
    /// "maximal about this centre at this angle". A `nil` crop that could
    /// still *grow* is therefore somebody's crop, and it keeps its own size
    /// instead of being launched out to the maximal fit by the first nudge of
    /// the slider.
    func testAnUnsizedOldCropKeepsItsSizeWhenItCouldStillGrow() {
        var old = Geometry.default
        old.crop = CropRect(x: 0.3, y: 0.35, width: 0.25, height: 0.2)
        XCTAssertNil(old.intendedSize)
        let round = old.straightened(to: 5, in: size).straightened(to: 0, in: size)
        XCTAssertEqual(round.crop.width, 0.25, accuracy: 1e-9, "its own size, not the maximal fit")
        XCTAssertEqual(round.crop.height, 0.2, accuracy: 1e-9)
        XCTAssertEqual(round.crop.x, 0.3, accuracy: 1e-9, "and it must not move")
        XCTAssertEqual(round.crop.y, 0.35, accuracy: 1e-9)
        XCTAssertNil(round.intendedSize, "adopted on the way past, never written back")
    }

    /// The ⌥-drag rectangle. It is given in the crop's **own** frame — the
    /// canvas hands over what it drew level on screen — so the angle
    /// survives, it is fitted if part of it hangs outside, and it is
    /// remembered, because drawing a rectangle is how the user said how big
    /// the crop should be.
    func testADrawnRectangleKeepsTheAngleAndIsRemembered() {
        var g = Geometry.default
        g.angle = 12
        g.crop = CropRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        g.intendedSize = CGSize(width: 0.2, height: 0.2)
        let drawn = g.redrawn(as: CropRect(x: 0.25, y: 0.3, width: 0.4, height: 0.3), in: size)
        XCTAssertEqual(drawn.angle, 12, "level on screen means level in the turned photograph")
        XCTAssertEqual(drawn.crop.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(drawn.crop.y, 0.3, accuracy: 1e-9)
        XCTAssertEqual(drawn.crop.width, 0.4, accuracy: 1e-9)
        XCTAssertEqual(drawn.crop.height, 0.3, accuracy: 1e-9)
        XCTAssertEqual(drawn.intendedSize?.width ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(drawn.intendedSize?.height ?? -1, 0.3, accuracy: 1e-9)

        let spilling = g.redrawn(as: CropRect(x: -0.2, y: -0.2, width: 1.4, height: 1.4), in: size)
        XCTAssertTrue(spilling.fits(in: size), "a rectangle drawn past the frame is fitted, not refused")
        XCTAssertLessThan(spilling.crop.width, 0.95)
        XCTAssertEqual(spilling.intendedSize?.width ?? -1, spilling.crop.width, accuracy: 1e-9,
                       "remembered at what it actually came out as")
    }

    func testMovingStopsAtTheEdgeInsteadOfShrinking() {
        var g = Geometry.default
        g.crop = CropRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let moved = g.moved(by: CGSize(width: 5, height: 0), in: size)
        XCTAssertTrue(moved.fits(in: size))
        XCTAssertEqual(moved.crop.width, 0.2, accuracy: 1e-9, "a move must never resize")
        XCTAssertEqual(moved.crop.x + moved.crop.width, 1.0, accuracy: 1e-3, "it stops against the edge")
    }

    // MARK: aspect

    func testAspectReshapesWithoutChangingTheArea() {
        var g = Geometry.default
        g.crop = CropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let before = g.crop.width * size.width * g.crop.height * size.height
        g.aspect = .square
        let out = g.constrained(in: size)
        let after = out.crop.width * size.width * out.crop.height * size.height
        XCTAssertEqual(after, before, accuracy: before * 0.01)
        XCTAssertEqual(out.crop.width * size.width / (out.crop.height * size.height), 1, accuracy: 1e-6)
        XCTAssertTrue(out.fits(in: size))
    }

    func testOriginalAspectResolvesAgainstTheSource() {
        XCTAssertNil(CropAspect.original.fixedRatio)
        XCTAssertEqual(CropAspect.original.ratio(sourceAspect: 1.5), 1.5)
        XCTAssertNil(CropAspect.free.ratio(sourceAspect: 1.5))
    }

    func testResizingAHandleKeepsTheOppositeCornerAndTheRatio() {
        var g = Geometry.default
        g.crop = CropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        g.aspect = .r16x9
        g = g.constrained(in: size)
        let anchorX = g.crop.x + g.crop.width, anchorY = g.crop.y + g.crop.height
        let out = g.resized(handle: .topLeft, to: CGPoint(x: 0.3, y: 0.3), in: size)
        XCTAssertEqual(out.crop.x + out.crop.width, anchorX, accuracy: 1e-6)
        XCTAssertEqual(out.crop.y + out.crop.height, anchorY, accuracy: 1e-6)
        XCTAssertEqual(out.crop.width * size.width / (out.crop.height * size.height), 16.0 / 9, accuracy: 1e-4)
    }

    // MARK: the mapping the shader copies

    /// The corners of the oriented rectangle are exactly where the output's
    /// corners map to. If these disagree, the picture is cropped somewhere
    /// other than where the handles are drawn.
    func testOutputCornersLandOnTheCropCorners() {
        var g = Geometry.default
        g.crop = CropRect(x: 0.25, y: 0.3, width: 0.4, height: 0.3)
        g.angle = 11
        let corners = g.corners(in: size)
        let mapped = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
            .map { g.sourcePoint(forOutput: $0, imageSize: size) }
        for (a, b) in zip(corners, mapped) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
        }
    }

    /// The kernel is a transliteration of `sourcePoint`. This runs the model's
    /// arithmetic the way the kernel does it — from the packed `Uniform`,
    /// with the same `pixelRatio` trick — so a change to one that is not made
    /// to the other fails here rather than in a photograph.
    func testShaderMappingMatchesTheModel() {
        for (angle, turns, fh, fv) in [(0.0, 0, false, false), (7.5, 0, false, false),
                                       (0.0, 1, false, false), (-13.0, 2, true, false),
                                       (21.0, 3, true, true)] {
            var g = Geometry.default
            g.crop = CropRect(x: 0.18, y: 0.22, width: 0.5, height: 0.44)
            g.angle = angle; g.quarterTurns = turns; g.flipH = fh; g.flipV = fv
            let u = g.uniform(for: size)
            for uv in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.87, y: 0.04)] {
                let model = g.sourcePoint(forOutput: uv, imageSize: size)
                let shader = GeometryTests.shaderMap(uv, u)
                XCTAssertEqual(model.x, shader.x, accuracy: 1e-6, "x at \(uv), angle \(angle), turns \(turns)")
                XCTAssertEqual(model.y, shader.y, accuracy: 1e-6, "y at \(uv), angle \(angle), turns \(turns)")
            }
        }
    }

    /// Swift written to be line-for-line what `geometryMap` in Shaders.metal
    /// does. Keep the two in step by hand; the assertion above is what says
    /// you did not.
    private static func shaderMap(_ uv: CGPoint, _ g: Geometry.Uniform) -> CGPoint {
        var u = SIMD2<Double>(Double(uv.x), Double(uv.y))
        if g.flips & 1 != 0 { u.x = 1 - u.x }
        if g.flips & 2 != 0 { u.y = 1 - u.y }
        switch g.quarterTurns {
        case 1: u = SIMD2(u.y, 1 - u.x)
        case 2: u = SIMD2(1 - u.x, 1 - u.y)
        case 3: u = SIMD2(1 - u.y, u.x)
        default: break
        }
        let px = (u.x - 0.5) * 2 * Double(g.halfExtent.x)
        let py = (u.y - 0.5) * 2 * Double(g.halfExtent.y) * Double(g.pixelRatio.y)
        let rx = px * Double(g.cosSin.x) - py * Double(g.cosSin.y)
        let ry = px * Double(g.cosSin.y) + py * Double(g.cosSin.x)
        return CGPoint(x: Double(g.centre.x) + rx, y: Double(g.centre.y) + ry * Double(g.pixelRatio.x))
    }

    func testRotatedAndUnrotatedAreInverses() {
        var g = Geometry.default
        g.crop = CropRect(x: 0.1, y: 0.15, width: 0.6, height: 0.5)
        g.angle = -17
        for p in [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.9, y: 0.1)] {
            let back = g.unrotated(g.rotated(p, in: size), in: size)
            XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        }
    }

    // MARK: edit space (the crop tool's view)

    /// S and E are the two directions of one rotation. If they are not
    /// inverses, the crop tool's picture and its handles drift apart under
    /// the pointer, which reads as a broken drag rather than as a mapping
    /// bug — and the angle at which it starts to show is an accident.
    func testEditAndSourceAreInverses() {
        var g = Geometry.default
        g.angle = 12
        let pivot = CGPoint(x: 0.4, y: 0.55)
        for p in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.93, y: 0.77)] {
            let there = g.sourcePoint(forEdit: p, pivot: pivot, imageSize: size)
            let back = g.editPoint(forSource: there, pivot: pivot, imageSize: size)
            XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        }
    }

    /// The whole point of the tool: in edit space the crop is a **level**
    /// rectangle whatever the straighten angle is. Two corners share an x and
    /// two share a y, and not approximately — the rotation is undone exactly.
    func testTheCropIsAxisAlignedInEditSpace() {
        for angle in [0.0, 5, 23, -41, 45] {
            var g = Geometry.default
            g.crop = CropRect(x: 0.12, y: 0.2, width: 0.6, height: 0.5)
            g.angle = angle
            let pivot = CGPoint(x: 0.3, y: 0.3)
            let e = g.corners(in: size).map { g.editPoint(forSource: $0, pivot: pivot, imageSize: size) }
            XCTAssertEqual(e[0].x, e[3].x, accuracy: 1e-9, "left edge vertical at \(angle)°")
            XCTAssertEqual(e[1].x, e[2].x, accuracy: 1e-9, "right edge vertical at \(angle)°")
            XCTAssertEqual(e[0].y, e[1].y, accuracy: 1e-9, "top edge horizontal at \(angle)°")
            XCTAssertEqual(e[2].y, e[3].y, accuracy: 1e-9, "bottom edge horizontal at \(angle)°")
            XCTAssertEqual(e[1].x - e[0].x, g.crop.width, accuracy: 1e-9, "and the crop's own shape")
            XCTAssertEqual(e[3].y - e[0].y, g.crop.height, accuracy: 1e-9)
        }
    }

    /// The pivot is a point of the *photograph*, so the point it sits on does
    /// not move when it is the pivot. That is what makes entering the tool on
    /// the crop's centre turn the picture about the middle of the frame.
    func testAPointSitsStillWhenItIsThePivot() {
        var g = Geometry.default
        g.angle = 18
        let pivot = CGPoint(x: 0.37, y: 0.62)
        let e = g.editPoint(forSource: pivot, pivot: pivot, imageSize: size)
        XCTAssertEqual(e.x, pivot.x, accuracy: 1e-12)
        XCTAssertEqual(e.y, pivot.y, accuracy: 1e-12)
        // …and the crop's centre is only still when it *is* the pivot.
        let off = g.editPoint(forSource: g.centre, pivot: pivot, imageSize: size)
        XCTAssertGreaterThan(hypot(off.x - g.centre.x, off.y - g.centre.y), 1e-3)
    }

    /// The re-pivot compensation, which is the difference between a rotation
    /// that turns the photograph and one that throws it across the window.
    ///
    /// Changing the pivot from P₁ to P₂ shifts every edit point by the same
    /// `Geometry.pivotShift` — a translation, which is the only reason a
    /// single nudge of the viewport can cancel it exactly. This walks a real
    /// `ViewportState` through the same arithmetic `Renderer` does and checks
    /// that a point of the photograph lands on the same screen pixel before
    /// and after.
    func testARepivotMovesNothingOnScreen() {
        var g = Geometry.default
        g.angle = 12
        g.crop = CropRect(x: 0.3, y: 0.45, width: 0.35, height: 0.3)
        let p1 = CGPoint(x: 0.5, y: 0.5)          // where the pivot was
        let p2 = g.centre                            // where the crop now is
        let subject = g.centre                       // what must not move

        var v = ViewportState()
        v.image = size
        v.viewport = CGSize(width: 1200, height: 800)
        v.scale = 0.11
        v.offset = CGPoint(x: 37, y: 21)

        func screen(_ pivot: CGPoint, _ viewport: ViewportState) -> CGPoint {
            let e = g.editPoint(forSource: subject, pivot: pivot, imageSize: size)
            return viewport.viewPoint(atImage: CGPoint(x: e.x * size.width, y: e.y * size.height))
        }
        let before = screen(p1, v)

        let shift = Geometry.pivotShift(from: p1, to: p2, angle: g.angle, in: size)
        v.offset.x -= shift.width * v.scale
        v.offset.y -= shift.height * v.scale
        let after = screen(p2, v)

        XCTAssertEqual(after.x, before.x, accuracy: 1e-6, "the frame must not jump on a re-pivot")
        XCTAssertEqual(after.y, before.y, accuracy: 1e-6)
        XCTAssertGreaterThan(abs(shift.width) + abs(shift.height), 1,
                             "and this is not passing because the pivot barely moved")
    }

    /// The re-pivot has to be computed at the angle the picture was drawn at
    /// **before** the write. The test above pins the shift formula but only
    /// ever involves a single angle, so it cannot see *which* angle the
    /// caller hands over — and the caller is where it went wrong.
    ///
    /// This drives the rule the renderer actually calls, with a crop dragged
    /// away from the pivot and a 20°→0° write in one go. That single-write
    /// case is the one that is visible to a person: one step of a rotate drag
    /// moves the angle by about a degree, where old and new are nearly the
    /// same rotation and the error is nothing, but typing a slider value,
    /// the Crop menu's straighten, a ⌘-line and an undo all land at once.
    func testAnAngleChangeLeavesAnOffCentreFrameWhereItWas() {
        var old = Geometry.default
        old.crop = CropRect(x: 0.28, y: 0.18, width: 0.4, height: 0.34)
        old.angle = 20
        let pivot = CGPoint(x: 0.5, y: 0.5)          // where the tool opened
        let subject = old.centre                     // the frame's centre

        var v = ViewportState()
        v.image = size
        v.viewport = CGSize(width: 1200, height: 800)
        v.scale = 0.11
        v.offset = CGPoint(x: 37, y: 21)

        func screen(_ g: Geometry, _ pivot: CGPoint, _ viewport: ViewportState) -> CGPoint {
            let e = g.editPoint(forSource: subject, pivot: pivot, imageSize: size)
            return viewport.viewPoint(atImage: CGPoint(x: e.x * size.width, y: e.y * size.height))
        }
        let before = screen(old, pivot, v)

        // One write carrying the new angle, then the renderer's own two
        // steps — the pivot moves, the viewport takes the nudge.
        var new = old
        new.angle = 0
        guard let r = Geometry.repivot(from: old, to: new, pivot: pivot, in: size, scale: v.scale) else {
            return XCTFail("an angle change away from the pivot must re-pivot")
        }
        v.offset.x += r.offset.width
        v.offset.y += r.offset.height
        let after = screen(new, r.pivot, v)

        XCTAssertEqual(after.x, before.x, accuracy: 1e-6, "the frame must not jump on a re-pivot")
        XCTAssertEqual(after.y, before.y, accuracy: 1e-6)
        XCTAssertGreaterThan(abs(r.offset.width) + abs(r.offset.height), 1,
                             "and this is not passing because the pivot barely moved")
    }

    // MARK: output size and turns

    func testQuarterTurnsSwapTheOutputAxes() {
        var g = Geometry.default
        g.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        XCTAssertEqual(g.outputSize(for: size), CGSize(width: 4128, height: 5504))
        g.quarterTurns = 1
        XCTAssertEqual(g.outputSize(for: size), CGSize(width: 5504, height: 4128))
        g.quarterTurns = 2
        XCTAssertEqual(g.outputSize(for: size), CGSize(width: 4128, height: 5504))
    }

    func testTurnsWrapInBothDirections() {
        XCTAssertEqual(Geometry.default.turned(by: -1).quarterTurns, 3)
        XCTAssertEqual(Geometry.default.turned(by: 5).quarterTurns, 1)
        XCTAssertEqual(Geometry.default.turned(by: 4).quarterTurns, 0)
    }

    // MARK: hit testing

    func testHandlesAreHitInTheCropsOwnRotatedFrame() {
        var g = Geometry.default
        g.crop = CropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        g.angle = 20
        let tol: CGFloat = 60   // source pixels
        // The visual top-left grip is the *rotated* corner, not (0.2, 0.2).
        let visual = g.corners(in: size)[0]
        XCTAssertEqual(g.handle(at: visual, in: size, tolerance: tol), .topLeft)
        XCTAssertEqual(g.handle(at: g.centre, in: size, tolerance: tol), .body)
        XCTAssertNil(g.handle(at: CGPoint(x: 0.95, y: 0.95), in: size, tolerance: tol))
        // An unrotated hit test would have matched here and does not.
        XCTAssertNotEqual(g.handle(at: CGPoint(x: 0.2, y: 0.2), in: size, tolerance: tol), .topLeft)
    }

    func testACornerBeatsTheEdgesItBelongsTo() {
        var g = Geometry.default
        g.crop = CropRect(x: 0.4, y: 0.4, width: 0.05, height: 0.05)
        // A tolerance larger than the crop: every handle matches, and the
        // corner must still win.
        XCTAssertEqual(g.handle(at: g.corners(in: size)[1], in: size, tolerance: 400), .topRight)
    }

    // MARK: straighten by drawing a line

    func testStraightenAngleFromALine() {
        // A line running down-right at 10° should straighten by −10°… but the
        // sign convention is the one the gesture needs: the angle returned is
        // what makes that line horizontal when *added* to the current one.
        let a = CGPoint(x: 0.2, y: 0.5)
        let b = CGPoint(x: 0.6, y: 0.5 + 0.4 * (size.width / size.height) * tan(10 * .pi / 180))
        let deg = Geometry.straightenAngle(from: a, to: b, in: size)
        XCTAssertEqual(try XCTUnwrap(deg), 10, accuracy: 0.01)
        // A click is not a line.
        XCTAssertNil(Geometry.straightenAngle(from: a, to: a, in: size))
        // A near-vertical line straightens to vertical, not by 87°.
        let v = Geometry.straightenAngle(from: CGPoint(x: 0.5, y: 0.2), to: CGPoint(x: 0.51, y: 0.8), in: size)
        XCTAssertEqual(try XCTUnwrap(v), 0, accuracy: 6)
    }

    // MARK: persistence

    /// Schema 2 stored a bare `crop` and knew nothing about angles. An
    /// existing sidecar must open with its crop intact rather than silently
    /// resetting to the full frame.
    func testSchema2SidecarsKeepTheirCrop() throws {
        let json = """
        {"schemaVersion":2,"decoder":"coreimage","crop":{"x":0.1,"y":0.2,"width":0.5,"height":0.4}}
        """
        let s = try JSONDecoder().decode(Sidecar.self, from: Data(json.utf8))
        XCTAssertEqual(s.geometry.crop, CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4))
        XCTAssertEqual(s.geometry.angle, 0)
        XCTAssertEqual(s.schemaVersion, 3)
        // And it round-trips as schema 3 without the legacy key.
        let out = try JSONEncoder().encode(s)
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains("geometry"))
        XCTAssertFalse(text.contains("\"crop\":{\"height\":0.4,\"width\":0.5"))
    }

    /// `intendedSize` arrived after schema 3 did. Every sidecar written
    /// before it has no such key, and `Geometry` decodes through synthesised
    /// Codable — where only an optional survives an absent key. A
    /// non-optional here would fail the decode and take the whole sidecar
    /// with it, which reads to the user as "my crop was forgotten".
    func testSchema3SidecarsWithoutTheKeyStillLoadAndDecodeToNoMemory() throws {
        let json = """
        {"schemaVersion":3,"decoder":"coreimage","geometry":{"crop":{"x":0.1,"y":0.2,"width":0.5,"height":0.4},"angle":4.5,"quarterTurns":1,"flipH":false,"flipV":false,"aspect":"free"}}
        """
        let s = try JSONDecoder().decode(Sidecar.self, from: Data(json.utf8))
        XCTAssertEqual(s.geometry.crop, CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4))
        XCTAssertEqual(s.geometry.angle, 4.5)
        XCTAssertNil(s.geometry.intendedSize)

        // And one that has been set survives the round trip.
        var withSize = s
        withSize.geometry.intendedSize = CGSize(width: 0.4, height: 0.3)
        let back = try JSONDecoder().decode(Sidecar.self, from: JSONEncoder().encode(withSize))
        XCTAssertEqual(back.geometry.intendedSize, CGSize(width: 0.4, height: 0.3))
    }

    func testSchema3RoundTrips() throws {
        var s = Sidecar()
        s.geometry = Geometry(crop: CropRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6),
                              angle: -4.5, quarterTurns: 3, flipH: true, flipV: false, aspect: .r16x9)
        let back = try JSONDecoder().decode(Sidecar.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.geometry, s.geometry)
    }
}
