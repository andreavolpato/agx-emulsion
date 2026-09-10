//  CompareAndFlagsTests.swift — the 2026-09-10 pass: the withdrawn mask
//  system, the before/after split, the crop's Return/Esc, and "no print
//  profile".
//
//  Three of these four pin *absences*, which is the awkward kind of test and
//  the reason they are written down. A hidden feature that still moves pixels,
//  a disabled row that is still clickable, and an Esc that leaves the tool
//  without putting the crop back all look identical to a working app until
//  someone notices the picture is wrong.

import Metal
import XCTest

@MainActor
final class CompareAndFlagsTests: XCTestCase {

    // MARK: the mask system, withdrawn

    /// The point of the flag: a sidecar that already carries masks renders as
    /// though it did not. Hiding the panel and leaving the kernel packing
    /// masks would be the worst of both — an effect with no control.
    func testMasksInASidecarReachNoPixelWhileTheFlagIsOff() throws {
        try XCTSkipIf(FeatureFlags.masks, "the mask system is on again; this test is about the withdrawn state")
        let session = Session()
        var m = EditMask.make(.radialGradient)
        m.adjustments.exposure = -2
        session.masks = [m]
        session.selectedMaskID = m.id
        XCTAssertEqual(session.masks.count, 1, "the model still holds them — nothing is deleted")
        XCTAssertTrue(session.renderer.masks.isEmpty, "but none of them is packed for the kernel")
        XCTAssertEqual(session.renderer.maskOverlay, -1)
        XCTAssertTrue(session.maskHandles.isEmpty, "and nothing on the canvas can be dragged by them")
    }

    func testMasksStillRoundTripThroughTheSidecarWhileHidden() throws {
        var s = Sidecar()
        s.masks = [EditMask.make(.linearGradient, named: "Sky")]
        let back = try JSONDecoder().decode(Sidecar.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.masks, s.masks, "the flag hides the feature, it does not eat saved work")
    }

    // MARK: no print profile

    /// "No print profile" is `scan_film`, not a sentinel paper id. The
    /// difference is not cosmetic: it is what makes the two questions — which
    /// paper, and whether there is a paper — independent, so the user's paper
    /// choice survives a visit to the Positive row.
    func testNoPrintProfileIsScanFilmAndLeavesThePaperAlone() {
        XCTAssertFalse(FilmParams.default.scanFilm)
        var p = FilmParams.default
        p.printStock = "kodak_2383"
        p.scanFilm = true
        let (delta, layers) = p.delta(from: .default)
        XCTAssertEqual(delta["scan_film"], .bool(true))
        XCTAssertEqual(delta["print_stock"], .string("kodak_2383"),
                       "the paper still travels — turning the scan off must land back on it")
        XCTAssertEqual(layers, [.print], "print layer only: a reprint, not a re-render")
    }

    /// Every field in `wire` has to be one the service validates; a name that
    /// is not in `schema.py` is rejected for the whole delta, so one typo
    /// here silently stops *all* print-side edits from landing.
    func testScanFilmIsOnTheWireInThePrintLayer() {
        let f = FilmParams.default.wire.first { $0.name == "scan_film" }
        XCTAssertEqual(f?.layer, .print)
        XCTAssertEqual(f?.value, .bool(false))
    }

    // MARK: before / after

    func testCompareIsOffUntilThereIsSomethingToCompareAgainst() {
        let session = Session()
        XCTAssertFalse(session.canCompare, "no frame, no original, nothing to compare")
        session.comparing = true
        XCTAssertTrue(session.renderer.compareSplit, "the flag still mirrors — the canvas decides what to draw")
    }

    func testTheSplitPositionIsClamped() {
        let session = Session()
        session.comparePosition = 1.8
        XCTAssertEqual(session.comparePosition, 1)
        session.comparePosition = -0.4
        XCTAssertEqual(session.comparePosition, 0)
        XCTAssertEqual(session.renderer.comparePosition, 0)
    }

    /// The rule the shader reads. Space is a whole-canvas gesture and wins:
    /// `draw` has already swapped the shown texture for the original, so
    /// leaving the split on would show the original against the original.
    func testSpaceWinsOverTheSplitAndTheSplitSurvivesIt() throws {
        let renderer = try XCTUnwrap(Renderer())
        let card = renderer.store.makeWritable(width: 4, height: 2)!
        renderer.original = card
        renderer.compareSplit = true
        XCTAssertEqual(renderer.compareMode, .split)
        renderer.showOriginal = true
        XCTAssertEqual(renderer.compareMode, .off)
        renderer.showOriginal = false
        XCTAssertEqual(renderer.compareMode, .split, "the split was not consumed by the keypress")
        renderer.original = nil
        XCTAssertEqual(renderer.compareMode, .off, "nothing to compare against")
    }

    // MARK: the crop keys

    func testReturnKeepsTheCropAndEscPutsItBack() {
        let session = Session()
        let before = session.geometry
        session.tool = .crop
        var g = session.geometry
        g.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        session.geometry = g
        session.commitCrop()
        XCTAssertEqual(session.tool, .select)
        XCTAssertEqual(session.geometry.crop, g.crop, "Return keeps it")

        session.tool = .crop
        var h = session.geometry
        h.crop = CropRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)
        session.geometry = h
        session.cancelCrop()
        XCTAssertEqual(session.tool, .select)
        XCTAssertEqual(session.geometry.crop, g.crop,
                       "Esc goes back to where *this* visit to the tool started, not to the whole-frame default")
        XCTAssertNotEqual(session.geometry.crop, before.crop)
    }

    func testTheCropKeysDoNothingOutsideTheCropTool() {
        let session = Session()
        var g = session.geometry
        g.crop = CropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        session.geometry = g
        session.tool = .select
        session.cancelCrop()
        XCTAssertEqual(session.geometry.crop, g.crop, "Esc in the select tool is not a crop reset")
        XCTAssertEqual(session.tool, .select)
    }
}

/// Contract §2's version negotiation, which until 2026-09-10 was written down
/// and not built. The backend session nearly shipped a refactor that dropped
/// `transport_version` and `schema_version` from `capabilities` while its
/// commit message said "no wire change" — true of the code, false of the wire,
/// because the wire is assembled from both halves. These are what would have
/// caught it here.
@MainActor
final class CapabilityNegotiationTests: XCTestCase {

    private func caps(transport: Int = 1, schema: Int = 1) throws -> Capabilities {
        let json = """
        {"version":"0.9","engine":"spektrafilm","max_mp":60,"tiers":{"live":1600},
         "transport_version":\(transport),"schema_version":\(schema)}
        """
        return try JSONDecoder().decode(Capabilities.self, from: Data(json.utf8))
    }

    func testAKnownWireIsAccepted() throws {
        let c = try caps()
        XCTAssertNil(c.unsupportedTransport)
        XCTAssertNil(c.schemaMismatch)
    }

    func testAnUnknownTransportIsRefusedInBothDirections() throws {
        let newer = try XCTUnwrap(caps(transport: 2).unsupportedTransport)
        XCTAssertTrue(newer.contains("service is newer"), newer)
        let older = try XCTUnwrap(caps(transport: 0).unsupportedTransport)
        XCTAssertTrue(older.contains("service is older"), older)
    }

    /// A renamed parameter costs some sliders; it is not a reason to refuse to
    /// show the user their photograph. The asymmetry is deliberate.
    func testASchemaMismatchWarnsButDoesNotRefuse() throws {
        let c = try caps(schema: 2)
        XCTAssertNil(c.unsupportedTransport)
        XCTAssertNotNil(c.schemaMismatch)
    }

    /// Neither version field is optional, so dropping one is a decode failure
    /// — and the message the user sees has to name the field. The raw
    /// `DecodingError` is accurate and useless.
    func testADroppedVersionFieldNamesItselfInPlainWords() {
        let json = """
        {"version":"0.9","engine":"spektrafilm","max_mp":60,"tiers":{},"schema_version":1}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(Capabilities.self, from: Data(json.utf8))) { error in
            let message = Session.capabilitiesFailure(error)
            XCTAssertTrue(message.contains("transport_version"), message)
            XCTAssertTrue(message.contains("will not render"), message)
            XCTAssertFalse(message.contains("CodingKeys"), "that is the error, not the explanation")
        }
    }
}

/// Where the engine's data comes from.
///
/// This class replaces `ServiceLaunchEnvironmentTests`, which protected the
/// property that the *Python* service imported the engine next to the binary
/// that launched it (`PYTHONPATH`, per-worktree). There is no child process
/// and no `PYTHONPATH` any more — RFC-014 linked the engine in — but the bug
/// that test existed to prevent is not language-specific and has bitten twice:
/// a whole session's backend work measured against an engine nobody was
/// running, and a two-worktree A/B that read as "no effect" because both arms
/// resolved to the same source.
///
/// The equivalent property now is that the engine's **baked constants, film
/// profiles and Metal library come from the app bundle**, not from a checkout
/// that happens to be above it. So that is what is asserted, plus the fact
/// that the out-of-tree fallback is *visible* rather than silent.
@MainActor
final class EngineResourceOriginTests: XCTestCase {

    func testTheResourcesAreTheOnesNextToTheBinary() {
        let resources = EngineClient.defaultResources()
        XCTAssertTrue(resources.path.hasPrefix(EngineClient.bundle.bundleURL.path),
                      "the engine resolved its resources to \(resources.path), which is outside "
                      + "\(EngineClient.bundle.bundleURL.path) — a render would then come from a "
                      + "checkout rather than from this build")
    }

    /// Every file the engine refuses to start without. A missing one is a
    /// clear error at launch rather than a frame that never appears.
    func testTheBundleCarriesEverythingTheEngineNeeds() {
        let resources = EngineClient.defaultResources()
        for name in ["spektrafilm_constants.bin", "spektrafilm.metallib",
                     "neutral_print_filters.json"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: resources.appending(path: name).path),
                "\(name) is missing from \(resources.path); run engine/build.sh bundle")
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: resources.appending(path: "profiles").path, isDirectory: &isDirectory)
            && isDirectory.boolValue, "the film profiles are missing from \(resources.path)")
    }

    /// The override exists for a build run out of the tree, and it wins — so
    /// a deliberate A/B is possible. If this ever stops working, two builds
    /// silently share one set of constants.
    func testTheOverrideWins() {
        let key = "SPEKTRAFILM_ENGINE_RESOURCES"
        guard ProcessInfo.processInfo.environment[key] == nil else {
            // Already set for this run; the assertion above covers it.
            return
        }
        setenv(key, "/tmp/some-other-engine", 1)
        defer { unsetenv(key) }
        XCTAssertEqual(EngineClient.defaultResources().path, "/tmp/some-other-engine")
    }
}
