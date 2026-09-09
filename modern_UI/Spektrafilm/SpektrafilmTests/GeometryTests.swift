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

    func testStraighteningBackToZeroRestoresNothingItDidNotTake() {
        // The angle is not destructive, but the shrink is: this documents
        // that going back to 0° leaves the *smaller* crop, which is what
        // every other editor does and what the user sees.
        let g = Geometry.default.straightened(to: 12, in: size).straightened(to: 0, in: size)
        XCTAssertEqual(g.angle, 0)
        XCTAssertLessThan(g.crop.width, 1.0)
        XCTAssertTrue(g.fits(in: size))
    }

    func testTheAngleIsClampedRatherThanWrapped() {
        XCTAssertEqual(Geometry.default.straightened(to: 400, in: size).angle, Geometry.maxAngle)
        XCTAssertEqual(Geometry.default.straightened(to: -400, in: size).angle, -Geometry.maxAngle)
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

    func testSchema3RoundTrips() throws {
        var s = Sidecar()
        s.geometry = Geometry(crop: CropRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6),
                              angle: -4.5, quarterTurns: 3, flipH: true, flipV: false, aspect: .r16x9)
        let back = try JSONDecoder().decode(Sidecar.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.geometry, s.geometry)
    }
}
