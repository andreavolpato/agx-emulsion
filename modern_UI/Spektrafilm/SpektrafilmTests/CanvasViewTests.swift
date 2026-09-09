//  The real MTKView, constructed and drawn into.
//
//  These exist because of a defect the rest of the suite could not see: the
//  canvas was configured with `colorPixelFormat = .rgba16Unorm`, which is a
//  valid *texture* format and not a valid *drawable* format, so `CAMetalLayer`
//  raised `invalid pixel format 110` and the app died on launch. Every other
//  test passed, and the snapshot harness passed too, because snapshot mode
//  substitutes an offscreen render and never builds an `MTKView`.
//
//  So: build the view the app builds, put it in a window, and draw.

import MetalKit
import QuartzCore
import SwiftUI
import XCTest

@MainActor
final class CanvasViewTests: XCTestCase {

    /// The formats `CAMetalLayer` accepts. Anything else raises an ObjC
    /// exception on assignment, which is a crash, not an error.
    static let drawableFormats: Set<MTLPixelFormat> = [
        .bgra8Unorm, .bgra8Unorm_srgb, .rgba16Float, .rgb10a2Unorm, .bgr10a2Unorm,
        .bgra10_xr, .bgra10_xr_srgb, .bgr10_xr, .bgr10_xr_srgb,
    ]

    func testDrawableFormatIsOneCAMetalLayerAccepts() {
        XCTAssertTrue(Self.drawableFormats.contains(Renderer.drawableFormat),
                      "\(Renderer.drawableFormat) is not a drawable format; CAMetalLayer will throw")
        // The offscreen format is the other half of the split: 16-bit unorm so
        // `makeCGImage()` needs no conversion. It is deliberately NOT a
        // drawable format, so the two must differ.
        XCTAssertEqual(Renderer.offscreenFormat, .rgba16Unorm)
    }

    func testCanvasViewBuildsAndDrawsInAWindow() throws {
        let session = Session()
        let view = CanvasNSView.configured(host: session)
        let layer = try XCTUnwrap(view.layer as? CAMetalLayer)
        XCTAssertEqual(layer.pixelFormat, Renderer.drawableFormat)
        XCTAssertEqual(layer.colorspace?.name, ImageDecoder.displayP3.name,
                       "the layer must be tagged Display P3; the pixels are already P3-encoded")
        XCTAssertTrue(view.isFlipped, "mouse points must share the shader's top-left origin")

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()

        // Empty canvas: the ground only.
        session.renderer.draw(in: view)

        // With an image: exercises the drawable render pipeline, which is the
        // state whose pixel format must match the drawable's.
        let tex = try XCTUnwrap(session.renderer.store.makeWritable(width: 4, height: 2))
        session.renderer.setLive(tex)
        session.renderer.viewport.resize(viewport: view.bounds.size, image: CGSize(width: 4, height: 2))
        session.renderer.draw(in: view)
        XCTAssertEqual(view.colorPixelFormat, Renderer.drawableFormat)
    }

    /// A redraw request must produce a draw. This asserts the wiring —
    /// delegate installed, closure connected, view able to dispatch — and it
    /// caught a real defect: `configured(host:)` at one point installed no
    /// `MTKViewDelegate`, so nothing drew however the redraw was requested.
    ///
    /// **What it does not catch, stated so nobody trusts it too far.** The
    /// shipped bug was `needsDisplay = true` failing to fire the delegate in
    /// the running app. In this test process it fires — with the view bare in
    /// a window *and* hosted in `NSHostingView` — so this test passes against
    /// the broken code. Whatever AppKit is doing differently in the real app
    /// does not reproduce in-process. The guard that actually catches it is
    /// `Tools/capture-live.sh`, which photographs the real window through the
    /// window server.
    func testRedrawRequestReachesTheViewWhenHostedBySwiftUI() async throws {
        let session = Session()
        let hosting = NSHostingView(rootView: MetalCanvasView(host: session).frame(width: 400, height: 300))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()

        func canvas(in view: NSView) -> CanvasNSView? {
            (view as? CanvasNSView) ?? view.subviews.lazy.compactMap(canvas(in:)).first
        }
        let view = try XCTUnwrap(canvas(in: hosting), "the representable must produce a CanvasNSView")
        XCTAssertNotNil(view.delegate, "no delegate means no draw, however the redraw is requested")

        // Let the hosting view's own first draws happen, then confirm idle:
        // otherwise the measurement counts those and passes regardless.
        try await Task.sleep(for: .milliseconds(500))
        let settled = session.renderer.drawCount
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(session.renderer.drawCount, settled, "the view must be idle before the measurement")

        let tex = try XCTUnwrap(session.renderer.store.makeWritable(width: 4, height: 2))
        session.renderer.setLive(tex)          // fires needsDraw, exactly as a landed render does
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertGreaterThan(session.renderer.drawCount, settled,
                             "a redraw request must produce a draw, or the canvas stays blank")
    }

    /// The zoom readout is computed from the viewport, and the viewport only
    /// means anything once there is an image in it. With none, the fit scale
    /// is against a 1×1 placeholder and the pill showed "Fit · 158,000 %".
    func testZoomReadoutFollowsTheImage() throws {
        let session = Session()
        session.viewportChanged()
        XCTAssertEqual(session.zoomPercent, 0, "no image, no zoom to report")

        let tex = try XCTUnwrap(session.renderer.store.makeWritable(width: 1000, height: 500))
        session.renderer.viewport.backingScale = 2
        session.renderer.viewport.resize(viewport: CGSize(width: 500, height: 500))
        session.renderer.setLive(tex)     // fits, and must refresh the readout itself
        XCTAssertEqual(session.zoomPercent, 100, "a 1000 pt image fitted to 500 pt at 2× is 100 %")
        XCTAssertTrue(session.isFit)
    }
}
