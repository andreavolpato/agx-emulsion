import XCTest

final class ViewportStateTests: XCTestCase {
    func makeVP() -> ViewportState {
        var v = ViewportState()
        v.backingScale = 2
        v.resize(viewport: CGSize(width: 800, height: 600), image: CGSize(width: 4000, height: 3000))
        return v
    }

    func testFitCentresAndScales() {
        let v = makeVP()
        XCTAssertEqual(v.scale, 0.2, accuracy: 1e-9)
        XCTAssertEqual(v.offset.x, 0, accuracy: 1e-9)
        XCTAssertEqual(v.offset.y, 0, accuracy: 1e-9)
        XCTAssertTrue(v.isFit)
        XCTAssertEqual(v.zoomPercent, 40)
    }

    func testZoomKeepsAnchorFixed() {
        var v = makeVP()
        let anchor = CGPoint(x: 200, y: 150)
        let before = v.imagePoint(atView: anchor)
        v.zoom(by: 2, about: anchor)
        let after = v.imagePoint(atView: anchor)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-6)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-6)
    }

    func testPanIsIgnoredBelowFit() {
        var v = makeVP()
        v.pan(by: CGSize(width: 100, height: 100))
        XCTAssertEqual(v.offset, CGPoint.zero)
    }

    func testPanIsClampedAboveFit() {
        var v = makeVP()
        v.setScale(1, about: CGPoint(x: 400, y: 300))   // 4000×3000 pt image in 800×600
        v.pan(by: CGSize(width: 10_000, height: 10_000))
        XCTAssertEqual(v.offset.x, 0, accuracy: 1e-9)
        XCTAssertEqual(v.offset.y, 0, accuracy: 1e-9)
        v.pan(by: CGSize(width: -10_000, height: -10_000))
        XCTAssertEqual(v.offset.x, 800 - 4000, accuracy: 1e-9)
        XCTAssertEqual(v.offset.y, 600 - 3000, accuracy: 1e-9)
    }

    func testHundredPercentIsOneImagePixelPerDevicePixel() {
        var v = makeVP()
        v.toggleHundred(about: CGPoint(x: 400, y: 300))
        XCTAssertEqual(v.zoomPercent, 100)
        XCTAssertEqual(v.scale, 0.5, accuracy: 1e-9)
        v.toggleHundred(about: CGPoint(x: 400, y: 300))
        XCTAssertTrue(v.isFit)
    }

    func testResizeKeepsFitWhenFitted() {
        var v = makeVP()
        v.resize(viewport: CGSize(width: 1600, height: 600))
        XCTAssertTrue(v.isFit)
        XCTAssertEqual(v.offset.x, (1600 - 4000 * 0.2) / 2, accuracy: 1e-9)
    }

    func testNormalisedRoundTrip() {
        let v = makeVP()
        let n = v.normalised(atView: CGPoint(x: 400, y: 300))!
        XCTAssertEqual(n.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(n.y, 0.5, accuracy: 1e-9)
        XCTAssertNil(v.normalised(atView: CGPoint(x: -1, y: 300)))
    }

    // MARK: the crop tool's fit — the view locked to the whole turned photo
    //
    // While the crop tool is up the canvas draws the whole frame with the
    // photograph turned about the crop's centre, and the user cannot zoom or
    // pan: the view is fitted to the box the *photograph* occupies in edit
    // space, plus a margin. Fitting the frame instead cuts the picture's own
    // corners off, and fitting the crop cuts them worse, because the crop is
    // by construction inside the turned photograph.
    //
    // `fitCropLock` below is the composition `Renderer.fitRotatedPhoto` runs,
    // line for line — `Geometry.editBounds` then
    // `ViewportState.fit(toNormalised:margin:)` — so these tests drive the
    // real step and not a paraphrase of it.

    private let photo = CGSize(width: 4000, height: 3000)
    private let cropLockMargin: CGFloat = 24

    /// The viewport the crop tool's canvas is: the whole frame in an 800×600
    /// canvas, which is what the fit is expressed against while the tool is
    /// up (`Renderer.logicalSize(forSource:)`).
    private func cropLockViewport() -> ViewportState {
        var v = ViewportState()
        v.backingScale = 2
        v.resize(viewport: CGSize(width: 800, height: 600), image: photo)
        return v
    }

    /// The four corners of the photograph in view points, as the canvas draws
    /// them while the crop tool is up: the corner put through E, read as an
    /// image point of the whole frame.
    private func photoCorners(_ g: Geometry, _ v: ViewportState) -> [CGPoint] {
        [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map { c in
            let e = g.editPoint(forSource: CGPoint(x: c.0, y: c.1), pivot: g.centre, imageSize: photo)
            return v.viewPoint(atImage: CGPoint(x: e.x * v.image.width, y: e.y * v.image.height))
        }
    }

    private func fitCropLock(_ g: Geometry, _ v: inout ViewportState) {
        v.fit(toNormalised: g.editBounds(pivot: g.centre, in: photo), margin: cropLockMargin)
    }

    /// No corner of the photograph is cut at any angle, and the margin is
    /// clear all round it — which is what keeps the grips and the rotate zone
    /// outside the frame reachable. Both a full-frame crop and a small
    /// off-centre one at each angle: the fit is the photograph's box, so it
    /// must not depend on where the crop is or how big it is.
    func testTheCropLockHoldsEveryCornerOfTheTurnedPhotograph() {
        for degrees in [0.0, 8, 20, 45] {
            for small in [false, true] {
                var g = Geometry.default
                if small { g.crop = CropRect(x: 0.28, y: 0.18, width: 0.4, height: 0.34) }
                g = g.straightened(to: degrees, in: photo)
                var v = cropLockViewport()
                fitCropLock(g, &v)
                for (i, q) in photoCorners(g, v).enumerated() {
                    let what = "\(degrees)°, \(small ? "small" : "full") crop, corner \(i)"
                    XCTAssertGreaterThanOrEqual(q.x, cropLockMargin - 1e-6, what)
                    XCTAssertGreaterThanOrEqual(q.y, cropLockMargin - 1e-6, what)
                    XCTAssertLessThanOrEqual(q.x, v.viewport.width - cropLockMargin + 1e-6, what)
                    XCTAssertLessThanOrEqual(q.y, v.viewport.height - cropLockMargin + 1e-6, what)
                }
            }
        }
    }

    /// …and the fit is **tight**: the box it fits fills one axis exactly, so
    /// the corners above are against the margin rather than the view having
    /// shrunk the picture to nothing. Without this the containment test would
    /// pass for a scale of zero, which is the failure mode "fitted" hides.
    func testTheCropLockIsTightAgainstTheMargin() {
        for degrees in [0.0, 8, 20, 45] {
            let g = Geometry.default.straightened(to: degrees, in: photo)
            var v = cropLockViewport()
            fitCropLock(g, &v)
            let box = g.editBounds(pivot: g.centre, in: photo)
            let w = box.width * v.image.width * v.scale
            let h = box.height * v.image.height * v.scale
            let fillsWidth = abs(w - (v.viewport.width - 2 * cropLockMargin)) < 1e-6
            let fillsHeight = abs(h - (v.viewport.height - 2 * cropLockMargin)) < 1e-6
            XCTAssertTrue(fillsWidth || fillsHeight,
                          "at \(degrees)° the fitted box is \(w)×\(h) in a \(v.viewport.width)×\(v.viewport.height) canvas")
            // The other axis is centred, which is the only other place it can be.
            XCTAssertLessThanOrEqual(w, v.viewport.width - 2 * cropLockMargin + 1e-6, "\(degrees)°")
            XCTAssertLessThanOrEqual(h, v.viewport.height - 2 * cropLockMargin + 1e-6, "\(degrees)°")
        }
    }

    /// At 0° the photograph *is* the frame, so the box to fit is the unit rect
    /// and the crop tool's fit is the ordinary fit of the frame, shrunk by
    /// just enough to leave the margin. Everything at 0° that is not this fit
    /// is a change to the other angles' arithmetic.
    func testAtZeroDegreesTheCropLockIsTheOrdinaryFitLessTheMargin() {
        let g = Geometry.default
        var v = cropLockViewport()
        let plain = v.fitScale
        XCTAssertEqual(g.editBounds(pivot: g.centre, in: photo),
                       CGRect(x: 0, y: 0, width: 1, height: 1))
        fitCropLock(g, &v)
        // Height-limited here: 600 − 48 over 3000 (0.184), against 800 − 48
        // over 4000 (0.188).
        XCTAssertEqual(v.scale, 552.0 / 3000, accuracy: 1e-9)
        XCTAssertEqual(v.scale / plain, 0.92, accuracy: 1e-9)
        XCTAssertEqual(v.offset.x, (800 - 4000 * v.scale) / 2, accuracy: 1e-9)
        XCTAssertEqual(v.offset.y, cropLockMargin, accuracy: 1e-9)
        // …which is not `fitScale`, and deliberately so: the pill says
        // "Fit · 184 %" while the tool is up because `Session.viewportChanged`
        // counts the crop tool's lock as fitted.
        XCTAssertFalse(v.isFit)
    }

    /// `editBounds` is the box the turned photograph occupies, not a
    /// conservative approximation of it: its half-extents are the ones the
    /// rotation predicts — `(w·|cos θ| + h·|sin θ|)/2` across, and the same
    /// with the terms swapped down — and it is centred on the pivot, because
    /// the pivot is the frame's own centre whenever it is the crop's.
    func testTheEditBoundsAreTheBoxTheTurnedPhotographOccupies() {
        for degrees in [8.0, 20, 45] {
            let g = Geometry.default.straightened(to: degrees, in: photo)
            let box = g.editBounds(pivot: g.centre, in: photo)
            let a = degrees * .pi / 180
            let across = (photo.width * abs(cos(a)) + photo.height * abs(sin(a))) / photo.width / 2
            let down = (photo.width * abs(sin(a)) + photo.height * abs(cos(a))) / photo.height / 2
            XCTAssertEqual(box.width / 2, across, accuracy: 1e-9, "\(degrees)° across")
            XCTAssertEqual(box.height / 2, down, accuracy: 1e-9, "\(degrees)° down")
            XCTAssertEqual(box.midX, g.centre.x, accuracy: 1e-9, "\(degrees)°")
            XCTAssertEqual(box.midY, g.centre.y, accuracy: 1e-9, "\(degrees)°")
            // …and it is strictly bigger than the frame it is a view of.
            XCTAssertGreaterThan(box.width, 1, "\(degrees)°")
            XCTAssertGreaterThan(box.height, 1, "\(degrees)°")
        }
    }
}
