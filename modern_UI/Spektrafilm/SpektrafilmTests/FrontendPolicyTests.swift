//  FrontendPolicyTests.swift — the pure decisions added with the polish pass.
//
//  These are not coverage for its own sake. Each one pins a rule whose wrong
//  value is invisible in a screenshot: which tier a zoom asks for, whether two
//  files share a sidecar, and whether a detail render is still the truth.

import Metal
import XCTest

@MainActor
final class FrontendPolicyTests: XCTestCase {

    /// HANDOFF-FRONTEND-POLISH §5.0 / the user's request: live by default,
    /// preview at 100 %, full at 200 % — but never escalate a frame that is
    /// already at or below the live tier's resolution.
    ///
    /// **The numbers are native-frame zoom since D4**, not the old
    /// texture-relative ones. The rule is unchanged: a tier is sharp enough
    /// while its pixels are still one per native pixel on screen, so the
    /// escalation point is the ratio of that tier's long edge to the frame's —
    /// at 8256 px the live tier is 1:1 at 0.19 and the preview tier at 0.41,
    /// where the old texture units said 1.0 and 2.0. That is the same
    /// behaviour with a label that means what it says.
    func testDetailTierEscalation() {
        let liveCovers = CGFloat(Session.liveEdge) / 8256       // 0.194
        let previewCovers = CGFloat(Session.previewEdge) / 8256 // 0.412
        XCTAssertEqual(Session.wantedTier(zoomFraction: liveCovers * 0.9, imageLongEdge: 8256), .live)
        XCTAssertEqual(Session.wantedTier(zoomFraction: liveCovers, imageLongEdge: 8256), .preview)
        XCTAssertEqual(Session.wantedTier(zoomFraction: previewCovers, imageLongEdge: 8256), .full)
        XCTAssertEqual(Session.wantedTier(zoomFraction: 8.0, imageLongEdge: 8256), .full)
        // Already native at the live tier.
        XCTAssertEqual(Session.wantedTier(zoomFraction: 4.0, imageLongEdge: 1600), .live)
        // Between the tiers: a 3000 px frame is 1:1 at the live tier from 0.53,
        // and being under `previewEdge` it never asks for `full` at all — the
        // preview tier is already sharper than the frame.
        XCTAssertEqual(Session.wantedTier(zoomFraction: 0.6, imageLongEdge: 3000), .preview)
        XCTAssertEqual(Session.wantedTier(zoomFraction: 8.0, imageLongEdge: 3000), .preview)
        XCTAssertEqual(Session.wantedTier(zoomFraction: 0.5, imageLongEdge: 3000), .live)
    }

    /// The label, and everything that reads it, is measured against the
    /// **native** frame however small the texture on screen is.
    ///
    /// DSC03710 decodes to 6000 × 4000; the live tier is 1600 px. Measuring
    /// the zoom against that texture made Fit read 109 % on a large window,
    /// where the honest answer is ~29 %, and made "100 %" mean a third of the
    /// frame's pixels per device pixel.
    func testTheZoomLabelIsMeasuredAgainstTheNativeFrame() async throws {
        let url = try rawFrame("A7m3/DSC03710.ARW")
        let session = Session()
        session.open(urls: [url])
        // The decode is all this needs: the native size comes from it, and no
        // develop is required to know how big the frame is.
        try await waitUntil("the frame to decode", timeout: 120) { session.decoded != nil }
        let native = try XCTUnwrap(session.decoded?.pixelSize)
        XCTAssertEqual(native.width, 6000, accuracy: 1, "not the frame this test is about")
        XCTAssertEqual(native.height, 4000, accuracy: 1)
        // The texture on the canvas is a tier; the size the viewport is
        // expressed against is the frame — which is the whole of D4.
        let texture = try XCTUnwrap(session.renderer.live)
        XCTAssertLessThan(CGFloat(texture.width), native.width, "the canvas is holding the frame itself")
        XCTAssertEqual(session.renderer.sourceSize?.width ?? 0, native.width,
                       "the viewport is expressed against the texture, not the frame")

        // A canvas of 1200 × 800 points at 2 device pixels per point.
        var vp = session.renderer.viewport
        vp.viewport = CGSize(width: 1200, height: 800)
        vp.backingScale = 2
        session.renderer.viewport = vp

        session.zoomToFit()
        // Fitted: 1200 points of 6000 native px, at 2 device px per point, is
        // 0.4 — device px over native px, which is what the label means.
        let fitted = 1200 * 2 / native.width
        XCTAssertEqual(Double(session.zoomPercent), Double(fitted * 100), accuracy: 1,
                       "Fit is measured against the texture, not the frame")

        session.zoomTo(fraction: 1.0)
        XCTAssertEqual(session.zoomPercent, 100)
        let onScreen = session.renderer.viewport.image.width * session.renderer.viewport.scale * 2
        XCTAssertEqual(Double(onScreen), Double(native.width), accuracy: 1,
                       "100 % is not one native pixel per device pixel")
    }

    /// The rule that makes the detail slot a cache instead of a coincidence:
    /// a `full` render contains everything a `preview` render does, so a
    /// lookup asks for "this tier or sharper". Without this, zooming
    /// 200 % → 120 % re-rendered 3400 px it already had, and the result
    /// evicted the `full` texture so zooming back cost another 6–17 s.
    func testDetailTiersAreRanked() {
        XCTAssertEqual(Session.DetailTier.live.rank, 0)
        XCTAssertLessThan(Session.DetailTier.preview.rank, Session.DetailTier.full.rank)
        XCTAssertEqual(Session.DetailTier(rank: 2), .full)
        XCTAssertNil(Session.DetailTier(rank: 3))
    }

    /// A resident render satisfies any tier at or below its own rank, for the
    /// same frame and the same parameters — and nothing else.
    func testDetailStoreAnswersThisTierOrSharper() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let store = TextureStore(device: device)
        let a = URL(fileURLWithPath: "/tmp/a.NEF"), b = URL(fileURLWithPath: "/tmp/b.NEF")
        let tex = try XCTUnwrap(store.makeWritable(width: 8, height: 8))
        store.setDetail(tex, tier: "full", rank: 2, stamp: "s1", for: a)

        // Sharper than asked for: a hit, reporting what is really resident.
        XCTAssertEqual(store.detail(for: a, stamp: "s1", atLeast: 1)?.tier, "full")
        XCTAssertEqual(store.detail(for: a, stamp: "s1", atLeast: 2)?.tier, "full")
        // Wrong frame, or parameters that have since moved: a miss.
        XCTAssertNil(store.detail(for: b, stamp: "s1", atLeast: 1))
        XCTAssertNil(store.detail(for: a, stamp: "s2", atLeast: 1))

        // A lower tier for the same frame and parameters is information the
        // slot already holds; accepting it is the eviction bug.
        let lower = try XCTUnwrap(store.makeWritable(width: 4, height: 4))
        store.setDetail(lower, tier: "preview", rank: 1, stamp: "s1", for: a)
        XCTAssertEqual(store.detail(for: a, stamp: "s1", atLeast: 2)?.tier, "full")

        // Different parameters do replace it, whatever the rank.
        store.setDetail(lower, tier: "preview", rank: 1, stamp: "s2", for: a)
        XCTAssertEqual(store.detail(for: a, stamp: "s2", atLeast: 1)?.tier, "preview")
        XCTAssertNil(store.detail(for: a, stamp: "s2", atLeast: 2))
    }

    /// A new print keeps a detail render whose parameters still match — the
    /// undo case, which used to throw away a full-resolution render.
    func testDetailSurvivesAnUndoBackToItsOwnParameters() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let store = TextureStore(device: device)
        let a = URL(fileURLWithPath: "/tmp/a.NEF")
        let tex = try XCTUnwrap(store.makeWritable(width: 8, height: 8))
        store.setDetail(tex, tier: "full", rank: 2, stamp: "s1", for: a)
        store.dropDetail(unless: "s1", for: a)
        XCTAssertNotNil(store.detail(for: a, stamp: "s1", atLeast: 2))
        store.dropDetail(unless: "s2", for: a)
        XCTAssertNil(store.detail(for: a, stamp: "s1", atLeast: 0))
    }

    /// The stamp is what makes validity a question about data. Two different
    /// parameter sets must not collide, and one set must be stable.
    func testPrintStampDistinguishesParameters() {
        var p = FilmParams.default
        let base = Session.printStamp(p)
        XCTAssertEqual(base, Session.printStamp(FilmParams.default))
        p.printBrightnessStops += 0.5
        XCTAssertNotEqual(base, Session.printStamp(p))
    }

    /// HANDOFF §3.2: `a.NEF` and `a.tif` in one folder must not share
    /// `a.spektra.json`.
    func testSidecarNamesKeepTheExtension() {
        let dir = URL(fileURLWithPath: "/tmp/photos")
        let nef = Sidecar.url(for: dir.appending(path: "a.NEF"))
        let tif = Sidecar.url(for: dir.appending(path: "a.tif"))
        XCTAssertEqual(nef.lastPathComponent, "a.NEF.spektra.json")
        XCTAssertNotEqual(nef, tif)
        XCTAssertEqual(Sidecar.legacyURL(for: dir.appending(path: "a.NEF")).lastPathComponent,
                       "a.spektra.json")
    }

    // MARK: - helpers

    /// A camera frame, copied out of the checkout: opening one writes a
    /// sidecar beside it, and the checkout's copy is shared with every other
    /// suite (see `develop-writes-a-sidecar-copy-the-fixture`).
    private func rawFrame(_ relativePath: String) throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/\(relativePath)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "\(relativePath) is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-zoom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private func waitUntil(_ what: String, timeout: Double = 30,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(what)")
    }
}
