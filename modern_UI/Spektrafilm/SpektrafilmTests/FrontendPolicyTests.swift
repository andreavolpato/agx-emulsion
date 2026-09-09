//  FrontendPolicyTests.swift — the pure decisions added with the polish pass.
//
//  These are not coverage for its own sake. Each one pins a rule whose wrong
//  value is invisible in a screenshot: which tier a zoom asks for, whether two
//  files share a sidecar, and which cache entry is evicted first.

import Metal
import XCTest

@MainActor
final class FrontendPolicyTests: XCTestCase {

    /// HANDOFF-FRONTEND-POLISH §5.0 / the user's request: live by default,
    /// preview at 100 %, full at 200 % — but never escalate a frame that is
    /// already at or below the live tier's resolution.
    func testDetailTierEscalation() {
        XCTAssertEqual(Session.wantedTier(zoomFraction: 0.5, imageLongEdge: 8256), .live)
        XCTAssertEqual(Session.wantedTier(zoomFraction: 1.0, imageLongEdge: 8256), .preview)
        XCTAssertEqual(Session.wantedTier(zoomFraction: 2.0, imageLongEdge: 8256), .full)
        XCTAssertEqual(Session.wantedTier(zoomFraction: 8.0, imageLongEdge: 8256), .full)
        // Already native at the live tier.
        XCTAssertEqual(Session.wantedTier(zoomFraction: 4.0, imageLongEdge: 1600), .live)
        // Between the tiers, `full` and `preview` are the same render.
        XCTAssertEqual(Session.wantedTier(zoomFraction: 4.0, imageLongEdge: 3000), .preview)
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

    /// HANDOFF §3.1.1: the cache is bounded and evicts least-recently-used.
    func testLinearCacheEvictsTheOldestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "linearcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (i, bytes) in [100, 100, 100].enumerated() {
            let url = dir.appending(path: "f\(i).tif")
            try Data(count: bytes).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(i))], ofItemAtPath: url.path)
        }
        LinearCache.prune(in: dir, limit: 250)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, ["f1.tif", "f2.tif"], "the least recently used entry goes first")
    }
}
