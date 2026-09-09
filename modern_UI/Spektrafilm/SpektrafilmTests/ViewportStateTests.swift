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
}
