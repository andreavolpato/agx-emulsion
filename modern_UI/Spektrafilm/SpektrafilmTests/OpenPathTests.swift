//  OpenPathTests.swift — opening a frame costs the decode and nothing else,
//  and Solve is what turns it into a print.
//
//  This pins *when* the develop runs, which is a rule neither a screenshot nor
//  a pixel comparison can see: the canvas shows a picture either way, and the
//  difference is whether the engine has been asked for one yet. It is the
//  shape the app is for — the decode lands in tens of milliseconds, the 364 MB
//  linear TIFF and the `open` that reads it back cost a second or two on a
//  real frame — and the failure it guards is the app starting that work the
//  moment a frame is picked, which leaves the Solve pill with nothing to do
//  and the user waiting for a print they did not ask for.

import Metal
import XCTest

@MainActor
final class OpenPathTests: XCTestCase {

    /// The 1 MP smoke frame the parity harnesses use for the same reason: it is
    /// a real file, and it opens in a fraction of a second.
    private static var smokeFrame: URL {
        URL(fileURLWithPath: #filePath)          // …/SpektrafilmTests/OpenPathTests.swift
            .deletingLastPathComponent()          // …/SpektrafilmTests
            .deletingLastPathComponent()          // …/Spektrafilm
            .deletingLastPathComponent()          // …/modern_UI
            .deletingLastPathComponent()          // the checkout
            .appending(path: "tests/Test_image/_smoke_1mp.tif")
    }

    private func frame() throws -> URL {
        let url = Self.smokeFrame
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "the 1 MP smoke frame is not in this checkout")
        return url
    }

    /// A frame opens onto its decode: the decode is what the canvas shows and
    /// the engine is not asked for anything.
    func testAnOpenStopsAtTheDecode() async throws {
        let url = try frame()
        let session = Session()
        session.open(urls: [url])
        try await waitUntil("the frame to decode") { session.decoded != nil }

        // Long enough for the develop to have started if it were going to —
        // the TIFF and the `open` are both asynchronous and neither announces
        // itself, so the check has to be "nothing happened", not "nothing has
        // happened yet".
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(session.serviceSessionIDForExport, "opening a frame developed it")
        XCTAssertTrue(session.previewSoft, "the canvas is showing something other than the decode")
        XCTAssertTrue(session.canSolve, "Solve is unavailable on a decoded frame")
    }

    /// Solve on a frame that is still only decoded is also the develop, and the
    /// solve lands on the session that develop made.
    func testSolveDevelopsTheFrameAndSolvesIt() async throws {
        let url = try frame()
        let session = Session()
        session.open(urls: [url])
        try await waitUntil("the frame to decode") { session.decoded != nil }
        try await waitUntil("the engine to warm up") { session.serviceReady }
        XCTAssertNil(session.serviceSessionIDForExport)

        session.solveNow()
        try await waitUntil("the print to land", timeout: 60) {
            session.serviceSessionIDForExport != nil && session.frameStates[url] == .processed && !session.busy
        }

        XCTAssertFalse(session.previewSoft, "the canvas is still showing the decode")
        // The develop reports the exposure baseline the Exp. Comp. slider is an
        // offset from (HANDOFF-FRONTEND-POLISH §4); Solve must not skip it.
        XCTAssertNotNil(session.sidecar.solvedEV, "the develop did not report the solved exposure")
        // A shift left on top of a freshly solved pack means Solve visibly did
        // not solve, so the button zeroes them.
        XCTAssertEqual(session.params.yFilterShift, 0)
        XCTAssertEqual(session.params.mFilterShift, 0)
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
