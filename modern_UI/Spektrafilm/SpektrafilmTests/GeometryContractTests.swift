//  GeometryContractTests.swift — the frontend and the engine must agree about
//  which pixels are in the picture.
//
//  `Model/Geometry.swift`'s `sourcePoint(forOutput:imageSize:)` is the
//  definition of the crop/straighten mapping. The engine's
//  `preprocess.geometry` node (RFC-011 §9, on `gpu/native-metal`) is a
//  transliteration of it, and `geometryResample` in Shaders.metal is another.
//  Three implementations of one rotation is three chances to disagree about a
//  sign, and the way that failure presents is an exported file that is subtly
//  of somewhere else — no crash, no warning, and it survives every other test
//  in this suite.
//
//  These rows are the engine's own fixture (`tests/fixtures/geometry_pairs.json`),
//  copied in rather than read from the other worktree so this bundle depends
//  on nothing outside itself. They matched to 0.0 on the day they were
//  written; the tolerance below is float64 slack, not an allowance for drift.
//
//  If this fails, do not widen it. Send the failing row to whoever owns the
//  engine side and find out which of the two moved.

import XCTest

final class GeometryContractTests: XCTestCase {

    /// angle, quarter turns, flipH, flipV, output u, output v, source x, source y.
    /// Frame 8256 × 5504, crop (0.18, 0.22, 0.5, 0.44).
    private static let pairs: [(Double, Int, Bool, Bool, Double, Double, Double, Double)] = [
        (0.0, 0, false, false, 0.1, 0.2, 0.230000000, 0.308000000),
        (0.0, 0, false, false, 0.5, 0.5, 0.430000000, 0.440000000),
        (0.0, 0, false, false, 0.87, 0.04, 0.615000000, 0.237600000),
        (7.5, 0, false, false, 0.1, 0.2, 0.243197333, 0.269971421),
        (7.5, 0, false, false, 0.5, 0.5, 0.430000000, 0.440000000),
        (7.5, 0, false, false, 0.87, 0.04, 0.631029634, 0.275552578),
        (0.0, 1, false, false, 0.1, 0.2, 0.280000000, 0.616000000),
        (0.0, 1, false, false, 0.5, 0.5, 0.430000000, 0.440000000),
        (0.0, 1, false, false, 0.87, 0.04, 0.200000000, 0.277200000),
        (-13.0, 2, true, false, 0.1, 0.2, 0.254921680, 0.636102165),
        (-13.0, 2, true, false, 0.5, 0.5, 0.430000000, 0.440000000),
        (-13.0, 2, true, false, 0.87, 0.04, 0.640611858, 0.574788584),
        (21.0, 3, true, true, 0.1, 0.2, 0.247914430, 0.523677366),
        (21.0, 3, true, true, 0.5, 0.5, 0.430000000, 0.440000000),
        (21.0, 3, true, true, 0.87, 0.04, 0.254171370, 0.164376164),
    ]

    func testTheEngineAndTheClientMapTheSamePoints() {
        let size = CGSize(width: 8256, height: 5504)
        for (angle, turns, fh, fv, u, v, sx, sy) in GeometryContractTests.pairs {
            var g = Geometry.default
            g.crop = CropRect(x: 0.18, y: 0.22, width: 0.5, height: 0.44)
            g.angle = angle
            g.quarterTurns = turns
            g.flipH = fh
            g.flipV = fv
            let p = g.sourcePoint(forOutput: CGPoint(x: u, y: v), imageSize: size)
            XCTAssertEqual(p.x, sx, accuracy: 1e-9, "x — angle \(angle), turns \(turns), flips \(fh)/\(fv), uv (\(u), \(v))")
            XCTAssertEqual(p.y, sy, accuracy: 1e-9, "y — angle \(angle), turns \(turns), flips \(fh)/\(fv), uv (\(u), \(v))")
        }
    }

    /// And the inverse the mask handles are drawn with really is the inverse
    /// of the map the picture is sampled with.
    func testOutputPointInvertsSourcePoint() {
        let size = CGSize(width: 8256, height: 5504)
        for (angle, turns, fh, fv, u, v, _, _) in GeometryContractTests.pairs {
            var g = Geometry.default
            g.crop = CropRect(x: 0.18, y: 0.22, width: 0.5, height: 0.44)
            g.angle = angle; g.quarterTurns = turns; g.flipH = fh; g.flipV = fv
            let src = g.sourcePoint(forOutput: CGPoint(x: u, y: v), imageSize: size)
            let back = g.outputPoint(forSource: src, imageSize: size)
            XCTAssertEqual(back.x, u, accuracy: 1e-9)
            XCTAssertEqual(back.y, v, accuracy: 1e-9)
        }
    }
}
