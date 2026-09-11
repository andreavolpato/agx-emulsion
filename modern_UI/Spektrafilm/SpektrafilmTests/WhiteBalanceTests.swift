//  WhiteBalanceTests.swift — the Camera section's two pills and two boxes.
//
//  Three things that are easy to get subtly wrong and invisible on screen:
//
//  1. **The legacy sidecar.** `auto_exposure_method` is a new field, and a
//     sidecar written before it existed must keep rendering exactly as it did:
//     it decodes to nil, the wire carries no method, and the engine's own
//     default (`center_weighted`) meters the frame. Sending a method for such a
//     frame would silently re-expose somebody's edit.
//  2. **The "As Shot" boxes.** Ticked means "this axis is the camera's", which
//     is `.asShot` *and* a `.custom` setting that happens to hold the camera's
//     value — the two render the same picture, so they have to read the same.
//  3. **The Tone pill's label.** Exp. Comp.'s "auto +x EV" is a report of what
//     the meter chose, and the meter changes the moment the pill does; the
//     number comes from the map `solve` already reported, not from the develop
//     that is still a film render away (RFC-015 §3).

import Metal
import XCTest

@MainActor
final class WhiteBalanceTests: XCTestCase {

    // MARK: - the wire

    /// A sidecar the way a build without this field wrote one: a real
    /// `Sidecar`, encoded, with `autoExposureMethod` taken out of the JSON.
    ///
    /// Built rather than hand-written on purpose. A literal JSON sidecar
    /// breaks every time an unrelated field changes shape, and a test that
    /// fails because `Adjustments` grew a key says nothing about the field
    /// under test — the first version of this did exactly that.
    private func legacySidecar() throws -> (json: Data, params: FilmParams) {
        var sidecar = Sidecar()
        sidecar.params.autoExposureMethod = nil
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sidecar)) as? [String: Any],
              var params = object["params"] as? [String: Any]
        else { return (Data(), FilmParams()) }
        params.removeValue(forKey: "autoExposureMethod")
        object["params"] = params
        let json = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Sidecar.self, from: json)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("autoExposureMethod"),
                       "the key is still in the JSON this test is about")
        return (json, decoded.params)
    }

    func testALegacySidecarDecodesToNoMethodAndSendsNone() throws {
        let params = try legacySidecar().params
        XCTAssertNil(params.autoExposureMethod, "an absent key must not become the default")
        XCTAssertNil(params.fullDelta["auto_exposure_method"], "the open delta carries a method")
        XCTAssertNil(params.delta(from: FilmParams()).delta["auto_exposure_method"])
    }

    /// A frame that was never given a method must stay that way on disk: the
    /// nil is not written as a `null`, which a later build would have to
    /// decide whether to send.
    func testANilMethodIsNotWrittenToTheSidecar() throws {
        var sidecar = Sidecar()
        sidecar.params.autoExposureMethod = nil
        let json = try JSONEncoder().encode(sidecar)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("autoExposureMethod"))
        XCTAssertNil(try JSONDecoder().decode(Sidecar.self, from: json).params.autoExposureMethod)
    }

    func testAFreshFrameStartsBalanced() throws {
        XCTAssertEqual(FilmParams().autoExposureMethod, "balanced")
        XCTAssertEqual(Sidecar().params.autoExposureMethod, "balanced")
        XCTAssertEqual(FilmParams().fullDelta["auto_exposure_method"], .string("balanced"))
    }

    func testTheMethodSurvivesASidecarRoundTrip() throws {
        var params = try legacySidecar().params
        params.autoExposureMethod = "protect_shadows"
        var sidecar = Sidecar()
        sidecar.params = params
        let back = try JSONDecoder().decode(Sidecar.self, from: JSONEncoder().encode(sidecar))
        XCTAssertEqual(back.params.autoExposureMethod, "protect_shadows")
    }

    /// Changing the method is a shoot-layer edit, and it is what the detail
    /// cache's stamp is built from — so a tile rendered under one intent can
    /// never be served under another.
    func testChangingTheMethodChangesTheStamp() {
        var a = FilmParams()
        var b = FilmParams()
        b.autoExposureMethod = "protect_highlights"
        XCTAssertNotEqual(Session.printStamp(a), Session.printStamp(b))
        // A legacy frame is stamped without the field, and stays that way.
        a.autoExposureMethod = nil
        b.autoExposureMethod = nil
        XCTAssertEqual(Session.printStamp(a), Session.printStamp(b))
        XCTAssertFalse(Session.printStamp(a).contains("auto_exposure_method"))
    }

    func testTheMethodIsAShootLayerEdit() {
        var legacy = FilmParams()
        legacy.autoExposureMethod = nil
        let toBalanced = FilmParams().delta(from: legacy)
        XCTAssertEqual(toBalanced.delta["auto_exposure_method"], .string("balanced"))
        XCTAssertEqual(toBalanced.layers, [.shoot])
        // And a legacy frame asked to stay legacy sends nothing at all.
        XCTAssertTrue(legacy.delta(from: legacy).delta.isEmpty)
    }

    // MARK: - the four names, as the pill shows them

    func testThePillNamesTheIntents() {
        XCTAssertEqual(ExposureMethod.balanced.title, "balanced")
        XCTAssertEqual(ExposureMethod.center.title, "center")
        XCTAssertEqual(ExposureMethod.protectHighlights.title, "protect highlights")
        XCTAssertEqual(ExposureMethod.protectShadows.title, "protect shadows")
        XCTAssertEqual(ExposureMethod.allCases.map(\.rawValue),
                       ["balanced", "center", "protect_highlights", "protect_shadows"])
    }

    func testALegacyFrameSaysWhichMeterIsRunningRatherThanPickingOne() {
        XCTAssertEqual(ExposureMethod.title(forWire: nil), "center-weighted (legacy)")
        XCTAssertEqual(ExposureMethod.title(forWire: "protect_shadows"), "protect shadows")
        // The legacy name is not offered, but an old sidecar that somehow
        // carries it still reads as itself rather than as a blank pill.
        XCTAssertEqual(ExposureMethod.title(forWire: "center_weighted"), "center_weighted")
        XCTAssertNil(ExposureMethod(rawValue: "center_weighted"))
    }

    // MARK: - the "As Shot" boxes

    private let asShot: WhiteBalanceBoxes.AsShot = (temperature: 4730, tint: 12)

    private func settings(_ wb: DecodeSettings.WhiteBalance, _ t: Double, _ tint: Double) -> DecodeSettings {
        var d = DecodeSettings()
        d.whiteBalance = wb
        d.temperature = t
        d.tint = tint
        return d
    }

    func testTheBoxesReadTheCameraWhenTheDecodeIsTakingIt() {
        // `.asShot` takes both, whatever the stored numbers say.
        XCTAssertEqual(WhiteBalanceBoxes(settings(.asShot, 5500, 0), asShot: asShot),
                       WhiteBalanceBoxes(temp: true, tint: true))
        // A preset is not the camera's.
        XCTAssertEqual(WhiteBalanceBoxes(settings(.daylight, 5500, 0), asShot: asShot),
                       WhiteBalanceBoxes(temp: false, tint: false))
        // A custom setting pinned exactly to the camera's value renders the
        // same picture, so it reads as ticked — per axis.
        XCTAssertEqual(WhiteBalanceBoxes(settings(.custom, 4730, 12), asShot: asShot),
                       WhiteBalanceBoxes(temp: true, tint: true))
        XCTAssertEqual(WhiteBalanceBoxes(settings(.custom, 4730, 5), asShot: asShot),
                       WhiteBalanceBoxes(temp: true, tint: false))
        XCTAssertEqual(WhiteBalanceBoxes(settings(.custom, 6000, 12), asShot: asShot),
                       WhiteBalanceBoxes(temp: false, tint: true))
    }

    func testBothBoxesTickedIsAsShot() {
        let out = WhiteBalanceBoxes().applying(temp: true, tint: true,
                                               to: settings(.custom, 6000, 5), asShot: asShot)
        XCTAssertEqual(out.whiteBalance, .asShot)
        XCTAssertEqual(out.temperature, 4730)
        XCTAssertEqual(out.tint, 12)
    }

    func testOneBoxTickedIsCustomWithThatAxisPinned() {
        let onlyTemp = WhiteBalanceBoxes().applying(temp: true, tint: false,
                                                    to: settings(.daylight, 5500, 20), asShot: asShot)
        XCTAssertEqual(onlyTemp.whiteBalance, .custom)
        XCTAssertEqual(onlyTemp.temperature, 4730)
        XCTAssertEqual(onlyTemp.tint, 20, "ticking Temp must not move Tint")

        let onlyTint = WhiteBalanceBoxes().applying(temp: false, tint: true,
                                                    to: settings(.custom, 6000, 20), asShot: asShot)
        XCTAssertEqual(onlyTint.whiteBalance, .custom)
        XCTAssertEqual(onlyTint.temperature, 6000, "ticking Tint must not move Temp")
        XCTAssertEqual(onlyTint.tint, 12)
    }

    func testUntickingIsCustom() {
        let out = WhiteBalanceBoxes().applying(temp: false, tint: nil,
                                               to: settings(.asShot, 4730, 12), asShot: asShot)
        XCTAssertEqual(out.whiteBalance, .custom)
        XCTAssertEqual(out.temperature, 4730, "unticking keeps the value that was showing")
        XCTAssertEqual(out.tint, 12)
    }

    func testAPresetUnticksBothUnlessItIsTheCameraPair() {
        let daylight = settings(.daylight, 5500, 0)
        XCTAssertEqual(WhiteBalanceBoxes(daylight, asShot: asShot), WhiteBalanceBoxes())
        // The exception the rule has to have: a preset whose pair *is* the
        // camera's is the as-shot picture, so it reads as both ticked.
        XCTAssertEqual(WhiteBalanceBoxes(settings(.custom, 4730, 12), asShot: asShot),
                       WhiteBalanceBoxes(temp: true, tint: true))
    }

    func testWithNoDecodeTheBoxesReadUntickedAndChangeNothing() {
        XCTAssertEqual(WhiteBalanceBoxes(settings(.asShot, 4730, 12), asShot: nil), WhiteBalanceBoxes())
        let out = WhiteBalanceBoxes().applying(temp: true, tint: true,
                                               to: settings(.custom, 6000, 20), asShot: nil)
        XCTAssertEqual(out, settings(.custom, 6000, 20), "nothing to pin to")
    }

    func testTickingAMixedPairLeavesTheOtherAxisAsAShot() {
        // `.custom` with the temperature already at the camera's and the tint
        // elsewhere: ticking Tint must leave a real `.custom` — not `.asShot`,
        // which would discard the tint the user can see.
        let out = WhiteBalanceBoxes().applying(temp: nil, tint: true,
                                               to: settings(.custom, 4730, 5), asShot: asShot)
        XCTAssertEqual(out.whiteBalance, .custom)
        XCTAssertEqual(out.temperature, 4730)
        XCTAssertEqual(out.tint, 12)
    }

    // MARK: - Tone, against a developed frame

    /// The label is right the moment the pill moves, and the print follows.
    func testAToneChangeRetargetsTheLabelAndThePrint() async throws {
        let url = try frame()
        let session = Session()
        // Grain and glare are stochastic (AGENTS trap 1); off, so the two
        // prints differ by the exposure and not by one noise realisation.
        session.open(urls: [url])
        try await waitUntil("the frame to decode") { session.decoded != nil }
        try await waitUntil("the engine to warm up") { session.serviceReady }
        var p = session.params
        p.grainActive = false
        p.glareActive = false
        session.params = p
        session.solveNow()
        try await waitUntil("the print to land", timeout: 90) {
            session.serviceSessionIDForExport != nil && session.frameStates[url] == .processed && !session.busy
        }

        XCTAssertEqual(session.params.autoExposureMethod, "balanced", "a new frame starts balanced")
        let sid = try XCTUnwrap(session.serviceSessionIDForExport)
        let solved = try await session.client.call(.solve, SolveRequest(sessionID: sid, target: "exposure"),
                                                   as: SolveResponse.self)
        let evs = try XCTUnwrap(solved.exposureEvByMethod, "the engine reported no per-method EVs")
        let balanced = try XCTUnwrap(evs["balanced"])
        let highlights = try XCTUnwrap(evs["protect_highlights"])
        XCTAssertEqual(session.sidecar.solvedEV ?? .nan, balanced, accuracy: 1e-9,
                       "the develop's own solve is not the balanced intent's EV")
        // The pair this test needs: on the smoke frame `balanced` and
        // `protect_shadows` are equal, so the difference is measured against
        // the highlight bound instead.
        XCTAssertGreaterThan(abs(balanced - highlights), 0.1, "this frame cannot tell the two apart")

        let before = try meanLuma(session, url)
        let previousPrint = try XCTUnwrap(session.renderer.store.print(for: url))
        session.setAutoExposureMethod("protect_highlights")

        // Immediate: the label is a report, and the meter has changed.
        XCTAssertEqual(session.solvedEVLabel, String(format: "auto %+.1f EV", highlights),
                       "the label waited for the film render")
        // A Tone change is a shoot-layer edit on the *same* session — the
        // engine re-renders the negative rather than opening a new one — so
        // what says it landed is a new print texture, not a new session id.
        try await waitUntil("the new print to land", timeout: 90) {
            guard let now = session.renderer.store.print(for: url) else { return false }
            return now !== previousPrint && session.frameStates[url] == .processed && !session.busy
        }
        let after = try meanLuma(session, url)
        print("tone change: mean luma \(String(format: "%.6f", before)) → \(String(format: "%.6f", after))")
        XCTAssertGreaterThan(abs(after - before), 5e-4,
                             "the print did not follow the intent (a reprint, not a re-render?)")
    }

    // MARK: - helpers

    /// The 1 MP smoke frame, **copied into a directory of its own**.
    ///
    /// A develop writes a sidecar beside the frame, and the checkout's copy is
    /// shared with the other suites — so developing it in place leaves this
    /// test reading, and writing, somebody else's parameters. That is not
    /// hypothetical: the first run of this test opened a sidecar written by a
    /// build without `autoExposureMethod`, decoded it to nil, and then wrote
    /// its own Tone choice back into the shared fixture.
    private func frame() throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/_smoke_1mp.tif")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "the 1 MP smoke frame is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-wb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    /// Mean luminance of the engine print on the canvas, 0…1.
    private func meanLuma(_ session: Session, _ url: URL) throws -> Double {
        let texture = try XCTUnwrap(session.renderer.store.print(for: url), "no print on the canvas")
        XCTAssertEqual(texture.pixelFormat, .rgba16Unorm, "this reads 16-bit RGBA bytes")
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat,
                                                         width: texture.width, height: texture.height,
                                                         mipmapped: false)
        d.storageMode = .shared
        let copy = try XCTUnwrap(session.renderer.device.makeTexture(descriptor: d))
        let queue = try XCTUnwrap(session.renderer.device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            copy.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                          from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        var sum = 0.0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            sum += 0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])
        }
        return sum / Double(bytes.count / 4) / 65535
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
