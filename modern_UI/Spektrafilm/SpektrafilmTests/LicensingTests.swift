//  LicensingTests.swift — the obligations a shipped bundle carries.
//
//  `Tools/check-bundle-resources.sh` already fails the *build* when the
//  licence texts are absent, and that is the right place for it. This is the
//  second half: the files being present is not the same as the app being able
//  to read them, and the About panel resolving its directory through
//  `Bundle(for:)` is exactly the kind of lookup that returns nil after a
//  reorganisation with nothing else complaining.
//
//  Distributing a GPL binary without its licence text, or the CC BY-SA
//  profiles without their attribution, is not a cosmetic failure
//  (HANDOFF-DISTRIBUTION §2.3) — so it is a test, not a checklist item.

import XCTest

final class LicensingTests: XCTestCase {

    func testTheLicenceTextsAreInTheBundleAndReadable() throws {
        let dir = try XCTUnwrap(AboutWindow.licenceDirectory,
                                "no Licenses/ in the bundle; run Tools/bundle-licenses.sh")
        for licence in AboutWindow.licences {
            let url = try XCTUnwrap(licence.url, "\(licence.id) has no URL")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(licence.id) is missing from \(dir.path)")
            // Read through the same accessor the panel uses, so a file that
            // exists but cannot be decoded fails here rather than showing the
            // user an apology.
            let body = licence.body
            XCTAssertGreaterThan(body.count, 400, "\(licence.id) is too short to be its licence")
            XCTAssertFalse(body.contains("Run Tools/bundle-licenses.sh"),
                           "\(licence.id) could not be read from the bundle")
        }
    }

    /// Each text is the licence it claims to be. A build that shipped the GPL
    /// four times would pass the existence check above.
    func testEachTextIsTheLicenceItClaimsToBe() throws {
        let expected = [
            "Spektrafilm-GPL-3.0.txt": "GNU GENERAL PUBLIC LICENSE",
            "Profiles-and-LUTs-CC-BY-SA-4.0.txt": "Attribution-ShareAlike 4.0 International",
            "metal-cpp-Apache-2.0.txt": "Apache License",
        ]
        for licence in AboutWindow.licences {
            guard let phrase = expected[licence.id] else { continue }
            XCTAssertTrue(licence.body.contains(phrase),
                          "\(licence.id) does not contain \(phrase.debugDescription)")
        }
    }

    /// The attribution CC BY-SA requires: the author, the canonical source,
    /// and the fact that the LUTs are derivatives rather than copies.
    func testTheProfileAttributionIsPresent() throws {
        let licence = try XCTUnwrap(
            AboutWindow.licences.first { $0.id == "Profiles-and-LUTs-CC-BY-SA-4.0.txt" })
        XCTAssertTrue(licence.body.contains("Andrea Volpato"))
        XCTAssertTrue(licence.body.contains("github.com/andreavolpato/spektrafilm"))

        let changelog = try XCTUnwrap(
            AboutWindow.licences.first { $0.id == "Profiles-and-LUTs-CHANGELOG.txt" })
        // The licence asks for changes to be recorded beside the files rather
        // than by editing it, and the honest answer has two halves: the
        // profiles are untouched, the LUTs are derived.
        XCTAssertTrue(changelog.body.contains("UNMODIFIED"))
        XCTAssertTrue(changelog.body.contains("DERIVED"))
        XCTAssertTrue(changelog.body.contains("Andrea Volpato"))
    }

    /// The version is derived, not typed into `Info.plist`.
    ///
    /// It sat at 0.2 for every build because two literals were the only
    /// record of it (HANDOFF-DISTRIBUTION §2.6). This does not assert a
    /// particular version — that would need editing on every release, which
    /// is the habit that let it rot — only that the plist was expanded from
    /// the build settings rather than shipping the `$(...)` placeholder.
    func testTheVersionCameFromTheBuildSettings() throws {
        let info = try XCTUnwrap(Bundle(for: BundleTag.self).infoDictionary)
        let short = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertFalse(short.contains("$("), "CFBundleShortVersionString was not expanded: \(short)")
        XCTAssertFalse(build.contains("$("), "CFBundleVersion was not expanded: \(build)")
        XCTAssertNotEqual(short, "0.2", "the version is still the hand-typed 0.2")
        XCTAssertEqual(short.split(separator: ".").count, 2, "expected MAJOR.MINOR, got \(short)")
    }

    private final class BundleTag {}
}

/// The engine's errors, as the person looking at them reads them.
///
/// The case that named this file's neighbour in HANDOFF-DISTRIBUTION §2.6 is
/// the first test: `spk_last_error` says "run engine/build.sh bundle", which
/// is the right answer for a checkout and no answer at all for a download.
final class EngineMessageTests: XCTestCase {

    private struct Engine: Error, CustomStringConvertible { let description: String }

    func testAnIncompleteInstallDoesNotTellTheUserToRunABuildScript() {
        let message = EngineMessage.userFacing(Engine(
            description: "the engine's resources are missing at /Applications/Spektrafilm.app; "
                       + "run engine/build.sh bundle"))
        XCTAssertFalse(message.hasPrefix("the engine's resources"),
                       "the developer text was passed through unchanged")
        XCTAssertTrue(message.contains("Download it again"))
        // The original is kept, because a user who reports this is the only
        // source of what actually went wrong.
        XCTAssertTrue(message.contains("engine/build.sh bundle"),
                      "the technical detail was thrown away")
    }

    func testTheFastMathRefusalSaysTheBuildIsWrongRatherThanTheApp() {
        let message = EngineMessage.userFacing(Engine(
            description: "the Metal library was compiled with fast math: `a*b - a*b` came back "
                       + "exactly zero for all 64 probes."))
        XCTAssertTrue(message.contains("refused to start"))
        XCTAssertTrue(message.contains("report"))
    }

    func testACancelledRenderDoesNotReadAsAFailure() {
        let message = EngineMessage.userFacing(Engine(description: "render cancelled"))
        XCTAssertEqual(message, "The render was cancelled.")
    }

    /// An unrecognised failure is passed through, not replaced with a guess.
    /// A confidently wrong instruction is worse than an unfamiliar sentence.
    func testAnUnrecognisedFailureIsPassedThrough() {
        let raw = "curve_interp: xa and y disagree on K (256 vs 255)"
        XCTAssertEqual(EngineMessage.userFacing(Engine(description: raw)), raw)
        XCTAssertEqual(EngineMessage.technical(Engine(description: raw)), raw)
    }
}
