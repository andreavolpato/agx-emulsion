//  OpenPathTests.swift — opening a frame costs the decode and nothing else,
//  and Solve is what turns it into a print.
//
//  This pins *when* the develop runs, which is a rule neither a screenshot nor
//  a pixel comparison can see: the canvas shows a picture either way, and the
//  difference is whether the engine has been asked for one yet. It is the
//  shape the app is for — the decode lands in a few hundred milliseconds, the
//  develop (the engine's frame, `open`, the solve and the first print) costs
//  about as much again on a 45 MP frame — and the failure it guards is the
//  app starting that work the moment a frame is picked, which leaves the
//  Solve pill with nothing to do and the user waiting for a print they did
//  not ask for.
//
//  The other half of it is the *re*-decode: a white-balance change runs the
//  same open path again, and whether it reaches the engine is again a thing
//  only the print can show (RFC-015 §1.1, below).

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
        let source = Self.smokeFrame
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "the 1 MP smoke frame is not in this checkout")
        // A copy, for the same reason `rawFrame()` makes one: a develop writes
        // a sidecar beside the frame, and the checkout's copy is shared with
        // every other suite. Developing it in place left this test reading a
        // sidecar another test had just written — and since the sidecar now
        // carries the Camera section's Tone, that is no longer only a
        // white-balance setting leaking between tests but the exposure meter.
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    /// The A7 III frame — a RAW, because the white balance under test is
    /// Camera WB, which `ImageDecoder` applies at the decode for RAWs and
    /// which a flat file has nowhere to put (RFC-015 §1.2, §1.3).
    ///
    /// A copy in a fresh directory, never the checkout's own file: a develop
    /// writes a `.spektra.json` sidecar beside the frame, and the checkout's
    /// sidecar is somebody's edit. Removed on teardown.
    private func rawFrame(_ relativePath: String = "A7m3/DSC03710.ARW") throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/\(relativePath)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "\(relativePath) is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-openpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private static var rawFrameURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/A7m3/DSC03710.ARW")
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

    // MARK: - the re-decode

    /// A camera white-balance change reaches the *print*, not just the decode.
    ///
    /// The reopen re-decodes the RAW and the canvas — which before a develop
    /// is showing the *display* decode — visibly changes with it. That is what
    /// made this look like it worked. But the engine is handed the *linear*
    /// decode once, at the develop, and holds that frame in its session: the
    /// engine has no idea a decode happened after it, so unless the reopen
    /// drops the session, every later print, slider move and export renders
    /// the frame as it was decoded the first time and the setting does nothing
    /// the user can see (RFC-015 §1.1).
    ///
    /// The check is on the print's **red/blue ratio** rather than any pixel
    /// equality. A white balance is a colour cast, so it has to move the
    /// balance and must not be confused with a brightness change. Grain and
    /// glare are stochastic by design (AGENTS trap 1), and a ratio of two
    /// whole-frame channel means is far too coarse a statistic to see them:
    /// the measured move is 1.30 → 0.76 against a 10 % bar, and the same
    /// before-value comes back run after run, which is the noise floor
    /// sitting orders of magnitude under the signal.
    func testACameraWhiteBalanceChangeReachesThePrint() async throws {
        let url = try rawFrame()
        let session = Session()
        session.open(urls: [url])
        try await waitUntil("the frame to decode", timeout: 90) { session.decoded != nil }
        try await waitUntil("the engine to warm up", timeout: 90) { session.serviceReady }
        session.solveNow()
        try await waitUntil("the print to land", timeout: 90) {
            session.serviceSessionIDForExport != nil && session.frameStates[url] == .processed && !session.busy
        }
        let sid1 = try XCTUnwrap(session.serviceSessionIDForExport)
        let before = try XCTUnwrap(printRB(session, url), "no engine print on the canvas after the solve")

        // Tungsten, 3200 K, against a daylight frame's as-shot white balance.
        session.setWhiteBalance(.tungsten)

        // The reopen is a 350 ms debounce, a re-decode and then the develop;
        // what says it finished is a *new* print, from a session the reopen
        // had to have made.
        let settled = await waitFor(timeout: 90) {
            session.serviceSessionIDForExport != sid1 && !session.busy
                && session.renderer.store.print(for: url) != nil
        }
        let sid2 = session.serviceSessionIDForExport
        let after = try printRB(session, url)
        let moved = after.map { abs($0 - before) / before } ?? 0
        let state = "sid \(sid1) → \(sid2 ?? "nil"), print R/B "
            + String(format: "%.3f", before) + " → "
            + (after.map { String(format: "%.3f", $0) } ?? "no print on the canvas")
        print("white balance: \(state)")

        // Named in this order so a red run reads top-down as the trace does:
        // no new print, then the session that explains why, then the colour.
        XCTAssertTrue(settled, "the re-decode did not produce a new print: \(state)")
        XCTAssertNotEqual(sid2, sid1,
                          "the reopen kept the engine session, so the print is still the first decode's: \(state)")
        XCTAssertGreaterThan(moved, 0.10, "the print did not follow the white balance: \(state)")
    }

    /// A white-balance change on a frame that is only *decoded* re-decodes it
    /// and stops there.
    ///
    /// `wantsDevelop` is the only thing that asks for a develop, and a reopen
    /// must not turn it on: a frame nobody has solved is a frame the user has
    /// not asked to spend a develop on, and opening onto the decode is what
    /// the rest of this file is about. **This passes before and after the
    /// RFC-015 §1.1 fix** — it is here because that fix moves the session
    /// handling in `scheduleReopen`, and a frame with no session is the case
    /// where dropping one can go wrong quietly.
    func testAWhiteBalanceChangeOnADecodedFrameDoesNotDevelopIt() async throws {
        let url = try rawFrame()
        let session = Session()
        session.open(urls: [url])
        try await waitUntil("the frame to decode", timeout: 90) { session.decoded != nil }
        let first = try XCTUnwrap(session.renderer.store.source(for: url), "no decode preview on the canvas")
        let before = meanRB(try samples(first, session.renderer.device))
        XCTAssertNil(session.serviceSessionIDForExport)

        session.setWhiteBalance(.tungsten)

        // The decode lands a second time: a *new* preview texture, and the new
        // white balance on it. `first` is held for the length of the test, so
        // the two cannot be the same object.
        try await waitUntil("the frame to re-decode", timeout: 90) {
            guard let now = session.renderer.store.source(for: url) else { return false }
            return now !== first
        }
        let after = try XCTUnwrap(session.renderer.store.source(for: url))
        let shown = meanRB(try samples(after, session.renderer.device))
        print("re-decode preview R/B \(String(format: "%.3f", before)) → \(String(format: "%.3f", shown))")
        XCTAssertGreaterThan(abs(shown - before) / before, 0.10,
                             "the re-decode did not apply the new white balance "
                             + "(preview R/B \(String(format: "%.3f", before)) → \(String(format: "%.3f", shown)))")
        // Long enough for the develop to have started if it were going to —
        // the same reasoning as `testAnOpenStopsAtTheDecode`.
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(session.serviceSessionIDForExport,
                     "a white-balance change developed a frame that was never solved")
    }

    // MARK: - the detail render

    /// A white-balance change reaches the zoomed-in detail render too.
    ///
    /// The detail cache is stamped with `printStamp`, which is the *film*
    /// params. A white balance is a decode setting and does not appear in it,
    /// so after the frame has been re-decoded the resident tile still matches
    /// its own stamp and the cache believes it is current. The reopen drops
    /// the renderer's copy — the one on screen — but the *store's* is the one
    /// `updateDetailTier` finds on the next pan, so the canvas goes back to
    /// the old colour the first time the user moves the view. That is the
    /// worst shape a bug can have: it looks fixed until you touch it.
    ///
    /// Both halves are checked: what comes back is not the pre-change render,
    /// and it arrives on its own rather than waiting for a viewport move.
    func testAWhiteBalanceChangeReachesTheZoomedDetailRender() async throws {
        let url = try rawFrame()
        let session = Session()
        session.open(urls: [url])
        try await waitUntil("the frame to decode", timeout: 90) { session.decoded != nil }
        try await waitUntil("the engine to warm up", timeout: 90) { session.serviceReady }
        session.solveNow()
        try await waitUntil("the print to land", timeout: 90) {
            session.serviceSessionIDForExport != nil && session.frameStates[url] == .processed && !session.busy
        }

        // Past 100 %, which is what asks for a detail render at all
        // (`Session.wantedTier`). There is no window here, so the viewport is
        // set directly and `viewportChanged` is what the view would have
        // called after the gesture.
        try zoom(session, to: 1.5)
        try await waitUntil("the detail render to land", timeout: 90) {
            session.detailTier != .live && session.renderer.showsDetail
        }
        let stamp = Session.printStamp(session.scheduler.sent)
        let first = try XCTUnwrap(session.renderer.store.detail(for: url, stamp: stamp, atLeast: 1),
                                  "the detail render is not in the store")
        let firstRB = meanRB(try samples(first.texture, session.renderer.device))

        session.setWhiteBalance(.tungsten)

        // The reopen has a 350 ms debounce, so right after the change the old
        // print and the old session are both still there and "a print is on the
        // canvas" is true before anything has happened. Wait for the reopen to
        // have *started* first, or everything below runs against the old state.
        try await waitUntil("the reopen to start", timeout: 90) {
            session.renderer.store.print(for: url) == nil
        }
        try await waitUntil("the new print to land", timeout: 90) {
            session.renderer.store.print(for: url) != nil && session.serviceSessionIDForExport != nil && !session.busy
        }
        // The premise of the bug, asserted rather than assumed: if the white
        // balance ever reaches `printStamp`, the cache stops being fooled and
        // this test proves nothing.
        XCTAssertEqual(Session.printStamp(session.scheduler.sent), stamp,
                       "the white balance is in the detail stamp now — this test needs rewriting")

        // A pan at the same zoom: the user action that used to bring the old
        // colour back.
        session.viewportChanged()
        let afterPan = session.renderer.store.detail(for: url, stamp: stamp, atLeast: 1)
        XCTAssertFalse(afterPan.map { $0.texture === first.texture } ?? false,
                       "the pre-change detail render is still resident, and the next pan serves it")

        // And a new one arrives by itself, with no viewport move to prompt it.
        try await waitUntil("a new detail render", timeout: 90) {
            guard let resident = session.renderer.store.detail(for: url, stamp: stamp, atLeast: 1) else { return false }
            return resident.texture !== first.texture
        }
        let second = try XCTUnwrap(session.renderer.store.detail(for: url, stamp: stamp, atLeast: 1))
        let secondRB = meanRB(try samples(second.texture, session.renderer.device))
        let printRB1 = try XCTUnwrap(printRB(session, url))
        print("detail R/B \(String(format: "%.3f", firstRB)) → \(String(format: "%.3f", secondRB)), "
              + "print \(String(format: "%.3f", printRB1))")

        XCTAssertGreaterThan(abs(secondRB - firstRB) / firstRB, 0.10,
                             "the detail render did not follow the white balance")
        // It is a sharper render of the *same* film: it has to agree with the
        // print on the canvas more closely than the old one did.
        XCTAssertLessThan(abs(secondRB - printRB1) / printRB1, abs(firstRB - printRB1) / printRB1,
                          "the new detail render disagrees with the print it is a sharper render of")
    }

    /// Solve pressed while a white-balance drag is still settling.
    ///
    /// A reopen cancels the load it supersedes and starts another. A develop
    /// asked for in between used to wait on the *first* load, find it
    /// cancelled with the frame still stale, and give up — so Solve and Export
    /// did nothing at all for as long as the user kept dragging the Kelvin
    /// slider. Waiting for the newest load instead is what fixes it.
    ///
    /// Solve zeroes the filter shifts, so a solve that never ran leaves them
    /// where they were — that is the observable. The timings are the point:
    /// the solve is asked for while the first reopen is mid-decode (about two
    /// seconds of work) and the second reopen fires 350 ms later, so the
    /// racy interleaving is the deterministic one here, not a coin flip.
    func testSolveDuringASecondReopenLandsOnTheFinalSession() async throws {
        let url = try rawFrame()
        let session = Session()
        session.open(urls: [url])
        try await waitUntil("the frame to decode", timeout: 90) { session.decoded != nil }
        try await waitUntil("the engine to warm up", timeout: 90) { session.serviceReady }
        session.solveNow()
        try await waitUntil("the print to land", timeout: 90) {
            session.serviceSessionIDForExport != nil && session.frameStates[url] == .processed && !session.busy
        }

        // Something for the solve to *do*: without a shift to zero, a dropped
        // solve and a solve with nothing to change look the same.
        var p = session.params
        p.yFilterShift = 0.3
        session.params = p

        session.setWhiteBalance(.tungsten)                                   // reopen 1
        try await waitUntil("the first reopen to start", timeout: 90) {
            session.renderer.store.print(for: url) == nil
        }
        session.setWhiteBalance(.shade)                                      // reopen 2, 350 ms away
        session.solveNow()                                                   // …with the solve in between
        XCTAssertNotEqual(session.params.yFilterShift, 0, "the solve had already run")

        try await waitUntil("the final print to land", timeout: 90) {
            session.serviceSessionIDForExport != nil && session.frameStates[url] == .processed && !session.busy
        }
        XCTAssertEqual(session.params.yFilterShift, 0, "the solve was dropped when its load was superseded")
        XCTAssertEqual(session.params.mFilterShift, 0)
    }

    /// Put the viewport at `fraction` of 100 % and tell the session, which is
    /// what the canvas does after a gesture.
    private func zoom(_ session: Session, to fraction: CGFloat) throws {
        var vp = session.renderer.viewport
        vp.scale = fraction * vp.hundredScale
        session.renderer.viewport = vp
        session.viewportChanged()
        XCTAssertEqual(session.renderer.viewport.zoomFraction, fraction, accuracy: 1e-6,
                       "the viewport did not take the zoom")
    }

    // MARK: - reading the canvas back

    /// An rgba16Unorm texture's samples, whatever its storage mode. The print
    /// comes from the engine and the decode preview is `.private`, so this
    /// always blits into a copy it can read rather than trusting `getBytes` to
    /// work on the texture it was handed.
    private func samples(_ texture: MTLTexture, _ device: MTLDevice) throws -> [UInt16] {
        XCTAssertEqual(texture.pixelFormat, .rgba16Unorm,
                       "this test reads 16-bit RGBA bytes and the texture is not rgba16Unorm")
        guard texture.pixelFormat == .rgba16Unorm else { return [] }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                         height: texture.height, mipmapped: false)
        d.storageMode = .shared
        let copy = try XCTUnwrap(device.makeTexture(descriptor: d))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var out = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        out.withUnsafeMutableBytes {
            copy.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                          from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return out
    }

    /// Mean red over mean blue, in whatever domain the bytes are (the print is
    /// Display P3 *encoded* — this is a comparison, not a measurement).
    ///
    /// A ratio of two channel means rather than a difference, because every
    /// global change to the tone curve moves numerator and denominator
    /// together and cancels: what is left is the colour balance, which is the
    /// only thing a white balance is supposed to move.
    private func meanRB(_ s: [UInt16]) -> Double {
        var r = 0.0, b = 0.0
        guard s.count >= 4 else { return 1 }
        for i in stride(from: 0, to: s.count - 3, by: 4) { r += Double(s[i]); b += Double(s[i + 2]) }
        return r / max(b, 1)
    }

    /// The R/B of the **engine print** — the texture the engine rendered and
    /// the film simulation produced, which is what the user is looking at once
    /// a frame is developed. Deliberately not the live texture: before a
    /// develop, and for a moment after a reopen, the canvas is showing the
    /// *display decode*, and comparing that would measure Core Image's white
    /// balance application rather than the engine's (RFC-015 §1.1).
    ///
    /// nil when no print is resident for the frame.
    private func printRB(_ session: Session, _ url: URL) throws -> Double? {
        guard let tex = session.renderer.store.print(for: url) else { return nil }
        return meanRB(try samples(tex, session.renderer.device))
    }

    /// Waits for `condition`, returning whether it became true. Unlike
    /// `waitUntil` it does not assert, because the caller wants the state *in*
    /// the failure message and a bare "timed out" says nothing about which
    /// half of it did not happen.
    private func waitFor(timeout: Double = 30, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
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
