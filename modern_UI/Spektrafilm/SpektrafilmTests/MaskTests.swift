//  MaskTests.swift — the mask model's rules, and the shader's copy of them.
//
//  Two kinds of thing are pinned here. The first is composition: which
//  components add, which subtract, and the rule that the first one is always
//  additive — get that wrong and a two-component mask covers the whole frame
//  or none of it, which looks like a broken slider rather than a broken rule.
//
//  The second is that a mask's arithmetic is the *same* arithmetic the global
//  panel uses. The sliders are visually identical; if they diverged, "+1 stop"
//  would quietly mean two different things depending on which one you reached
//  for, and nothing would say so.

import XCTest

final class MaskTests: XCTestCase {

    // MARK: composition

    func testTheFirstComponentIsAdditiveWhateverItsFlagSays() {
        var m = EditMask.make(.linearGradient)
        m.components[0].subtract = true
        m.components.append(.make(.radialGradient))
        m.components[1].subtract = true
        let u = m.uniform()
        XCTAssertEqual(u.componentCount, 2)
        XCTAssertEqual(u.components.0.subtract, 0, "nothing to subtract from yet")
        XCTAssertEqual(u.components.1.subtract, 1)
    }

    /// The Swift twin of `maskCoverage` in Shaders.metal, for the composition
    /// rule only — the per-kind coverage functions are pinned separately.
    private func compose(_ values: [(cover: Double, subtract: Bool, invert: Bool)]) -> Double {
        var total = 0.0
        for (i, v) in values.enumerated() {
            var cc = v.cover
            if v.invert { cc = 1 - cc }
            if i > 0 && v.subtract { total = min(total, 1 - cc) } else { total = max(total, cc) }
        }
        return max(0, min(1, total))
    }

    func testAddComponentsUnionAndSubtractComponentsCut() {
        // "the sky, minus the trees" — one mask, two components.
        XCTAssertEqual(compose([(1, false, false), (0, true, false)]), 1, accuracy: 1e-9,
                       "where the subtracting shape is absent, the mask survives")
        XCTAssertEqual(compose([(1, false, false), (1, true, false)]), 0, accuracy: 1e-9,
                       "where it is present, the mask is cut away")
        XCTAssertEqual(compose([(0.4, false, false), (0.9, false, false)]), 0.9, accuracy: 1e-9,
                       "two additive shapes union to the stronger")
        XCTAssertEqual(compose([(1, false, false), (0.25, true, false)]), 0.75, accuracy: 1e-9,
                       "a soft subtraction is partial, not binary")
    }

    func testAComponentCanBeInvertedOnItsOwn() {
        XCTAssertEqual(compose([(0.2, false, true)]), 0.8, accuracy: 1e-9)
    }

    func testMaskInvertAndAmountApplyToTheWholeThing() {
        var m = EditMask.make(.radialGradient)
        m.inverted = true
        m.amount = 0.5
        let u = m.uniform()
        XCTAssertEqual(u.inverted, 1)
        XCTAssertEqual(u.amount, 0.5, accuracy: 1e-6)
    }

    // MARK: the shape functions the shader evaluates

    /// `linearCoverage`, transliterated. Coverage is 0 at `a`, 1 at `b`, and
    /// smooth between — and it is measured in long-edge units, so the ramp is
    /// the same width whichever way the gradient runs.
    private func linearCoverage(_ c: MaskComponent, at uv: CGPoint, aspect: Double) -> Double {
        func toLong(_ p: CGPoint) -> CGPoint {
            aspect >= 1 ? CGPoint(x: p.x, y: p.y / aspect) : CGPoint(x: p.x * aspect, y: p.y)
        }
        let p = toLong(uv), a = toLong(c.a), b = toLong(c.b)
        let ax = b.x - a.x, ay = b.y - a.y
        let len2 = max(ax * ax + ay * ay, 1e-9)
        let t = max(0, min(1, ((p.x - a.x) * ax + (p.y - a.y) * ay) / len2))
        return t * t * (3 - 2 * t)   // smoothstep
    }

    func testLinearGradientRunsFromZeroToOneAlongItsAxis() {
        var c = MaskComponent.make(.linearGradient)
        c.a = CGPoint(x: 0, y: 0.2); c.b = CGPoint(x: 0, y: 0.6)
        let aspect = 1.5
        XCTAssertEqual(linearCoverage(c, at: CGPoint(x: 0, y: 0.1), aspect: aspect), 0, accuracy: 1e-9)
        XCTAssertEqual(linearCoverage(c, at: CGPoint(x: 0, y: 0.4), aspect: aspect), 0.5, accuracy: 1e-9)
        XCTAssertEqual(linearCoverage(c, at: CGPoint(x: 0, y: 0.9), aspect: aspect), 1, accuracy: 1e-9)
        // Across the axis makes no difference — a linear gradient is infinite
        // perpendicular to itself, which is why the overlay draws guide lines.
        XCTAssertEqual(linearCoverage(c, at: CGPoint(x: 0.9, y: 0.4), aspect: aspect),
                       linearCoverage(c, at: CGPoint(x: 0.1, y: 0.4), aspect: aspect), accuracy: 1e-9)
    }

    /// The grips the overlay draws must sit on the ellipse the shader
    /// evaluates. `MaskGeometry.point` is what draws them; this checks that a
    /// point on it really is at radius 1 in the shader's own normalisation.
    func testRadialGripsSitOnTheEllipseTheShaderUses() {
        var c = MaskComponent.make(.radialGradient)
        c.a = CGPoint(x: 0.4, y: 0.55)
        c.radii = CGSize(width: 0.3, height: 0.12)
        c.angle = 27
        let size = CGSize(width: 8256, height: 5504)
        let aspect = size.width / size.height
        for t in stride(from: 0.0, to: 2 * Double.pi, by: 0.4) {
            let n = MaskGeometry.point(on: c, at: t, imageSize: size)
            // `radialCoverage`, transliterated: into long-edge units, into the
            // ellipse's frame, divided by the semi-axes.
            let dx = (n.x - c.a.x), dy = (n.y - c.a.y) / aspect
            let a = c.angle * .pi / 180
            let ex = (dx * cos(a) + dy * sin(a)) / c.radii.width
            let ey = (-dx * sin(a) + dy * cos(a)) / c.radii.height
            XCTAssertEqual((ex * ex + ey * ey).squareRoot(), 1, accuracy: 1e-9,
                           "grip at t=\(t) is not on the ellipse the shader draws")
        }
    }

    func testLuminanceRangeSelectsBetweenItsBounds() {
        var c = MaskComponent.make(.luminanceRange)
        c.low = 0.4; c.high = 0.8; c.softness = 0.05
        func cover(_ l: Double) -> Double {
            func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
                let t = max(0, min(1, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
            }
            return smooth(c.low - c.softness, c.low + c.softness, l) *
                   (1 - smooth(c.high - c.softness, c.high + c.softness, l))
        }
        XCTAssertEqual(cover(0.2), 0, accuracy: 1e-9)
        XCTAssertEqual(cover(0.6), 1, accuracy: 1e-6)
        XCTAssertEqual(cover(0.95), 0, accuracy: 1e-9)
        XCTAssertEqual(cover(0.4), 0.5, accuracy: 1e-6, "the ramp is centred on the bound")
    }

    // MARK: the shared arithmetic

    /// The claim the whole design rests on: a mask's sliders and the global
    /// panel's sliders are the same control applied to a different region.
    func testAMasksToneArithmeticIsTheGlobalPanelsArithmetic() {
        var global = Adjustments.default
        global.exposure = 1.25; global.contrast = 18; global.brightness = -7
        global.saturation = 22; global.highlights = -40; global.shadows = 30
        global.blackPoint = 6; global.whitePoint = 3; global.temperature = -14; global.tint = 9

        var local = MaskAdjustments.default
        local.exposure = 1.25; local.contrast = 18; local.brightness = -7
        local.saturation = 22; local.highlights = -40; local.shadows = 30
        local.blackPoint = 6; local.whitePoint = 3; local.temperature = -14; local.tint = 9

        let g = global.uniforms, l = local.uniforms
        XCTAssertEqual(g.exposureGain, l.exposureGain)
        XCTAssertEqual(g.contrast, l.contrast)
        XCTAssertEqual(g.brightness, l.brightness)
        XCTAssertEqual(g.saturation, l.saturation)
        XCTAssertEqual(g.highlights, l.highlights)
        XCTAssertEqual(g.shadows, l.shadows)
        XCTAssertEqual(g.blackPoint, l.blackPoint)
        XCTAssertEqual(g.whitePoint, l.whitePoint)
        XCTAssertEqual(g.wbGain, l.wbGain)
        // And what a mask deliberately does *not* carry stays neutral.
        XCTAssertEqual(l.curvesActive, 0)
        XCTAssertEqual(l.vignetteAmount, 0)
        XCTAssertEqual(l.cbMaster, SIMD3<Float>(repeating: 0))
    }

    // MARK: packing and limits

    func testComponentKindOrderMatchesTheShadersSwitch() {
        // The kernel switches on the raw index, so this order is load-bearing:
        // reordering the enum silently turns every radial gradient into a
        // linear one in already-saved sidecars.
        XCTAssertEqual(MaskComponentKind.allCases.map(\.rawValue),
                       ["linearGradient", "radialGradient", "luminanceRange", "colorRange", "brush"])
        XCTAssertEqual(EditMask.make(.colorRange).uniform().components.0.kind, 3)
    }

    func testOnlyTheFirstSixComponentsArePacked() {
        var m = EditMask.make(.linearGradient)
        for _ in 0..<10 { m.components.append(.make(.radialGradient)) }
        XCTAssertEqual(m.uniform().componentCount, UInt32(EditMask.maxComponents))
    }

    func testBrushIsNotOfferedUntilSomethingRasterisesIt() {
        // It exists in the model and in the shader — kind 4, and
        // `MaskUniform.rasterSlice` is where its texture goes — but offering
        // it in the UI would offer a mask that does nothing.
        XCTAssertTrue(MaskComponentKind.brush.isRaster)
        XCTAssertFalse(MasksSection.addable.contains(.brush))
        XCTAssertEqual(EditMask.make(.brush).uniform().rasterSlice, MaskUniform.noRaster,
                       "no rasteriser has assigned a slice, so the shader must read none")
    }

    func testMasksRoundTripThroughTheSidecar() throws {
        var s = Sidecar()
        var m = EditMask.make(.radialGradient, named: "Her face")
        m.components.append({ var c = MaskComponent.make(.luminanceRange); c.subtract = true; return c }())
        m.adjustments.exposure = -0.75
        m.amount = 0.6
        s.masks = [m]
        let back = try JSONDecoder().decode(Sidecar.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.masks, s.masks)
    }

    func testASidecarWithNoMasksDoesNotWriteTheKey() throws {
        let text = String(decoding: try JSONEncoder().encode(Sidecar()), as: UTF8.self)
        XCTAssertFalse(text.contains("masks"))
    }
}
