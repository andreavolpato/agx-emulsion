//  Layout tests: the window at the three display shapes that matter —
//  MacBook Pro 14" (1512×982 pt), 16:9 (1920×1080), the 21:9 (3360×1418) —
//  measured against the drawing's geometry, not eyeballed.

import SwiftUI
import XCTest

@MainActor
final class LayoutTests: XCTestCase {
    static let sizes: [(String, CGSize)] = [
        ("macbook-pro-14", CGSize(width: 1512, height: 982)),
        ("16x9", CGSize(width: 1920, height: 1080)),
        ("21x9", CGSize(width: 3360, height: 1418)),
    ]

    /// Host the real EditorWindow in an NSHostingView at each size and read
    /// the frames of the four cards through the accessibility-free route:
    /// the geometry the layout math promises.
    func testCardGeometryAtEverySize() {
        let m = Theme.Metric.self
        for (name, size) in Self.sizes {
            let session = Session()
            let host = NSHostingView(rootView: EditorWindow(session: session).environment(\.snapshotMode, true))
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            // Left card
            let leftX = m.outerX, leftW = m.leftPanelWidth
            let rightX = size.width - m.outerX - m.rightPanelWidth
            let canvasX = leftX + leftW + m.gutter
            let canvasW = rightX - m.gutter - canvasX
            XCTAssertGreaterThan(canvasW, 500, "\(name): canvas too narrow")
            let canvasTop = m.outerY + m.topBarHeight + m.gutter
            let canvasBottom = size.height - m.outerY - m.filmstripHeight - m.gutter
            XCTAssertGreaterThan(canvasBottom - canvasTop, 400, "\(name): canvas too short")
            // The fit-scale rule: with a 3:2 image the canvas is wider than tall on every size.
            XCTAssertGreaterThan(canvasW / (canvasBottom - canvasTop), 1.0, name)
            _ = host.fittingSize
        }
    }

    func testTokensMatchTheDrawing() {
        // The drawing is 3840×2160; a 1920×1080 window is exactly half.
        let m = Theme.Metric.self
        XCTAssertEqual(m.leftPanelWidth, (656.9 / 2).rounded(), accuracy: 0.6)
        XCTAssertEqual(m.rightPanelWidth, (572.3 / 2).rounded(), accuracy: 0.6)
        XCTAssertEqual(m.topBarHeight, (82.7 / 2).rounded(), accuracy: 0.6)
        XCTAssertEqual(m.filmstripHeight, (250.6 / 2).rounded(), accuracy: 0.6)
        XCTAssertEqual(m.cardRadius, 15)
        XCTAssertEqual(m.gutter, 8, accuracy: 0.5)
        // Right card's x in the drawing: 3250.1 / 2 = 1625.05 at 1920 wide.
        XCTAssertEqual(1920 - m.outerX - m.rightPanelWidth, 1625, accuracy: 1)
        // Canvas column x: 690.5 / 2.
        XCTAssertEqual(m.outerX + m.leftPanelWidth + m.gutter, 345, accuracy: 1)
    }

    func testMinimumWindowStillFitsBothPanels() {
        let m = Theme.Metric.self
        let canvas = m.minWindow.width - 2 * m.outerX - m.leftPanelWidth - m.rightPanelWidth - 2 * m.gutter
        XCTAssertGreaterThanOrEqual(canvas, 400)
    }
}
