import XCTest

final class CurveMathTests: XCTestCase {
    func testIdentityIsIdentity() {
        let c = Curve.identity
        for i in 0...10 { let x = CGFloat(i) / 10; XCTAssertEqual(c.evaluate(x), x, accuracy: 1e-9) }
        XCTAssertTrue(c.isIdentity)
    }

    func testMonotoneNoOvershoot() {
        var c = Curve.identity
        c.insert(CGPoint(x: 0.25, y: 0.1))
        c.insert(CGPoint(x: 0.3, y: 0.9))    // a violent step
        var last: CGFloat = -1
        for i in 0...200 {
            let y = c.evaluate(CGFloat(i) / 200)
            XCTAssertGreaterThanOrEqual(y, last - 1e-9, "curve must be monotone")
            XCTAssertTrue((0...1).contains(y))
            last = y
        }
    }

    func testInsertKeepsSortedAndMoveRespectsNeighbours() {
        var c = Curve.identity
        let i = c.insert(CGPoint(x: 0.7, y: 0.6))
        let j = c.insert(CGPoint(x: 0.3, y: 0.2))
        XCTAssertEqual(j, 1); XCTAssertEqual(i, 1)  // 0.7 was index 1 before 0.3 came in
        XCTAssertEqual(c.points.map(\.x), [0, 0.3, 0.7, 1])
        c.move(1, to: CGPoint(x: 0.95, y: 0.5))    // cannot cross 0.7
        XCTAssertLessThan(c.points[1].x, c.points[2].x)
        c.move(0, to: CGPoint(x: 0.5, y: 0.5))     // end point keeps x = 0
        XCTAssertEqual(c.points[0].x, 0)
        c.remove(0); XCTAssertEqual(c.points.count, 4)  // ends are not removable
        c.remove(1); XCTAssertEqual(c.points.count, 3)
    }

    func testTableLayout() {
        var set = CurveSet()
        set.red.insert(CGPoint(x: 0.5, y: 0.25))
        let t = set.tables()
        XCTAssertEqual(t.count, Curve.tableSize * 5)
        XCTAssertEqual(t[Curve.tableSize * 2 + 128], 0.25, accuracy: 0.02)   // row 2 = red
        XCTAssertEqual(t[128], 128.0 / 255.0, accuracy: 0.01)               // row 0 = rgb identity
    }
}
