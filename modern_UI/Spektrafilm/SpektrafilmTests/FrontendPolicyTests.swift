//  FrontendPolicyTests.swift — the pure decisions added with the polish pass.
//
//  These are not coverage for its own sake. Each one pins a rule whose wrong
//  value is invisible in a screenshot: which tier a zoom asks for, whether two
//  files share a sidecar, and which cache entry is evicted first.

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
