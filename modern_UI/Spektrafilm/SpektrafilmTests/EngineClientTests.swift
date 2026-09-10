//  EngineClientTests.swift — the engine, in this process, from Swift.
//
//  RFC-014 §6 step 2's gate as the app sees it: create the engine with this
//  process's own `MTLDevice`, open a frame, render it, and get an `MTLTexture`
//  back. No subprocess, no file handoff, and -- the point of the whole RFC --
//  no `<repo>/.venv/bin/python`.
//
//  The C++ side has its own harnesses (`engine/tests/parity_render.py` holds
//  the picture against numba at 2.3e-5). What these check is the *boundary*:
//  that Swift's view of the C ABI is right, that the texture is real and the
//  right size, and that the two version numbers still match what this build
//  was written against.

import Metal
import XCTest

final class EngineClientTests: XCTestCase {
    private func device() throws -> MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
    }

    /// The importer's own output: a linear ProPhoto TIFF, which is what
    /// `open` takes on the wire and what `EngineClient` decodes.
    private func writeFrame(_ size: Int = 96) throws -> URL {
        let width = size * 4 / 3
        var rgba = [Float](repeating: 0, count: width * size * 4)
        for y in 0..<size {
            for x in 0..<width {
                let i = (y * width + x) * 4
                rgba[i] = 0.05 + 0.5 * Float(x) / Float(width)
                rgba[i + 1] = 0.3
                rgba[i + 2] = 0.1 + 0.4 * Float(y) / Float(size)
                rgba[i + 3] = 1
            }
        }
        let space = try XCTUnwrap(ImageDecoder.linearProPhoto)
        let image = try XCTUnwrap(rgba.withUnsafeBufferPointer { buffer in
            CIImage(bitmapData: Data(buffer: buffer),
                    bytesPerRow: width * 16,
                    size: CGSize(width: width, height: size),
                    format: .RGBAf,
                    colorSpace: space)
        })
        let url = FileManager.default.temporaryDirectory
            .appending(path: "spk-engine-test-\(UUID().uuidString).tiff")
        try ImageDecoder.context.writeTIFFRepresentation(
            of: image, to: url, format: .RGBAh, colorSpace: space, options: [:])
        return url
    }

    /// The orientation of the frame the engine is handed.
    ///
    /// This exists because getting it wrong is invisible to every other test:
    /// the C++ parity suite hands the engine a numpy array and never goes
    /// through `readLinearRGB`, so a vertical flip here produced a correctly
    /// developed, upside-down photograph with 27 of 27 parity cases green.
    func testTheFrameIsReadTopRowFirst() throws {
        // Top half bright, bottom half dark -- an asymmetry no amount of film
        // simulation can hide.
        let width = 40, height = 24
        var rgba = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let value: Float = y < height / 2 ? 0.9 : 0.02
            for x in 0..<width {
                let i = (y * width + x) * 4
                rgba[i] = value; rgba[i + 1] = value; rgba[i + 2] = value; rgba[i + 3] = 1
            }
        }
        let space = try XCTUnwrap(ImageDecoder.linearProPhoto)
        let image = try XCTUnwrap(rgba.withUnsafeBufferPointer { buffer in
            CIImage(bitmapData: Data(buffer: buffer), bytesPerRow: width * 16,
                    size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
        })
        let url = FileManager.default.temporaryDirectory
            .appending(path: "spk-orientation-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageDecoder.context.writeTIFFRepresentation(
            of: image, to: url, format: .RGBAh, colorSpace: space, options: [:])

        let frame = try EngineClient.readLinearRGB(url)
        XCTAssertEqual(frame.width, width)
        XCTAssertEqual(frame.height, height)
        func rowMean(_ y: Int) -> Float {
            var sum: Float = 0
            for x in 0..<width { sum += frame.pixels[(y * width + x) * 3 + 1] }
            return sum / Float(width)
        }
        XCTAssertGreaterThan(rowMean(1), 0.5, "row 1 should be the image's bright top")
        XCTAssertLessThan(rowMean(height - 2), 0.2, "the last row should be the dark bottom")
    }

    func testCapabilitiesReportTheNativeCore() async throws {
        let client = EngineClient(device: try device())
        let caps: Capabilities = try await client.call(.capabilities, as: Capabilities.self)
        // The two numbers the frontend refuses on. If the engine ever moves
        // them, this build must be told rather than guess (contract §2).
        XCTAssertEqual(caps.transportVersion, Capabilities.knownTransportVersion)
        XCTAssertEqual(caps.schemaVersion, Capabilities.knownSchemaVersion)
        XCTAssertNil(caps.unsupportedTransport)
        XCTAssertEqual(caps.backend?.renderCore, "native-metal")
        XCTAssertEqual(caps.backend?.concurrent, true)
        // The trap-1 guard, as the app sees it: the engine refuses to start at
        // all under fast math, so reaching here means the probe passed.
        XCTAssertNotNil(caps.backend?.gpu)
        await client.stop()
    }

    func testSchemaMatchesTheBuild() async throws {
        let client = EngineClient(device: try device())
        struct Schema: Decodable {
            let schemaVersion: Int
            let fields: [Field]
            struct Field: Decodable { let name: String; let type: String; let layer: String }
            enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", fields }
        }
        let schema: Schema = try await client.call(.paramsSchema, as: Schema.self)
        XCTAssertEqual(schema.schemaVersion, Capabilities.knownSchemaVersion)
        // The fields the frontend's own params model depends on being there.
        let names = Set(schema.fields.map(\.name))
        for required in ["film_stock", "print_stock", "print_exposure", "m_filter_shift",
                         "y_filter_shift", "exposure_compensation_ev", "scan_film"] {
            XCTAssertTrue(names.contains(required), "the schema lost \(required)")
        }
        await client.stop()
    }

    func testOpenAndRenderProduceATexture() async throws {
        let url = try writeFrame()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = EngineClient(device: try device())
        let open: OpenResponse = try await client.call(
            .open, OpenRequest(imagePath: url.path, paramsDelta: nil))
        XCTAssertFalse(open.sessionID.isEmpty)
        XCTAssertGreaterThan(open.meta.megapixels, 0)

        let outcome = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))
        let texture = try XCTUnwrap(outcome.texture, "the engine returned no texture")
        XCTAssertEqual(texture.pixelFormat, .rgba16Unorm)
        XCTAssertEqual(texture.width, outcome.response.width)
        XCTAssertEqual(texture.height, outcome.response.height)
        XCTAssertGreaterThan(outcome.response.elapsedMs, 0)
        // No file was written, and the response says so rather than naming
        // one nothing can open.
        XCTAssertNil(outcome.response.rawPath)
        await client.stop()
    }

    func testAReprintReusesTheNegative() async throws {
        let url = try writeFrame()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = EngineClient(device: try device())
        let open: OpenResponse = try await client.call(
            .open, OpenRequest(imagePath: url.path, paramsDelta: nil))
        _ = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))
        let second = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))
        // The whole reason the two tiers cache a negative: a print-side edit
        // must not re-run the film side.
        XCTAssertTrue(second.response.negativeWasCached)
        await client.stop()
    }

    func testAPrintSideEditChangesThePictureAndAShootSideOneReRenders() async throws {
        let url = try writeFrame()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = EngineClient(device: try device())
        let open: OpenResponse = try await client.call(
            .open, OpenRequest(imagePath: url.path, paramsDelta: nil))
        _ = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))

        let print: SetParamsResponse = try await client.call(
            .setParams, SetParamsRequest(sessionID: open.sessionID,
                                          paramsDelta: ["print_exposure": .double(1.6)]),
            as: SetParamsResponse.self)
        XCTAssertEqual(print.invalidated, "print")

        let shoot: SetParamsResponse = try await client.call(
            .setParams, SetParamsRequest(sessionID: open.sessionID,
                                          paramsDelta: ["exposure_compensation_ev": .double(1.0)]),
            as: SetParamsResponse.self)
        XCTAssertEqual(shoot.invalidated, "shoot")
        let after = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))
        // A shoot-layer edit drops the cached negative, so the next render
        // rebuilds it. Getting this wrong would silently reuse a stale
        // negative, which is the failure `service/schema.py`'s layer table
        // exists to prevent.
        XCTAssertFalse(after.response.negativeWasCached)
        await client.stop()
    }

    /// The three tiers, and what "full" means.
    ///
    /// `full` must come back at the *source's* resolution, not the live tier's
    /// -- it is what the canvas shows past 100 % zoom, and a `full` render
    /// that quietly returned 1600 px would be a soft image the app believed
    /// was sharp. The tiers must also be ordered: live <= preview <= full.
    func testEachTierRendersAtItsOwnResolution() async throws {
        // Above the live tier's 1600 px, so the three tiers are distinct.
        let url = try writeFrame(1800)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = EngineClient(device: try device())
        let open: OpenResponse = try await client.call(
            .open, OpenRequest(imagePath: url.path, paramsDelta: nil))
        let sourceWidth = open.meta.width, sourceHeight = open.meta.height

        var sizes: [String: (Int, Int)] = [:]
        for tier in ["live", "preview", "full"] {
            var request = RenderRequest(sessionID: open.sessionID)
            request.tier = tier
            let outcome = try await client.render(.reprint, request)
            let texture = try XCTUnwrap(outcome.texture, "\(tier) returned no texture")
            sizes[tier] = (texture.width, texture.height)
        }
        XCTAssertEqual(sizes["full"]?.0, sourceWidth, "the full tier is not full resolution")
        XCTAssertEqual(sizes["full"]?.1, sourceHeight, "the full tier is not full resolution")
        XCTAssertEqual(sizes["live"]?.0, 1600, "the live tier should cap at 1600 px")
        XCTAssertLessThanOrEqual(sizes["live"]!.0, sizes["preview"]!.0)
        XCTAssertLessThanOrEqual(sizes["preview"]!.0, sizes["full"]!.0)
        await client.stop()
    }

    func testAnUnknownParameterIsRefused() async throws {
        let url = try writeFrame()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = EngineClient(device: try device())
        let open: OpenResponse = try await client.call(
            .open, OpenRequest(imagePath: url.path, paramsDelta: nil))
        do {
            let _: SetParamsResponse = try await client.call(
                .setParams, SetParamsRequest(sessionID: open.sessionID,
                                              paramsDelta: ["not_a_parameter": .double(1)]),
                as: SetParamsResponse.self)
            XCTFail("the engine accepted an unknown parameter")
        } catch {
            XCTAssertTrue("\(error)".contains("not_a_parameter"), "unhelpful error: \(error)")
        }
        await client.stop()
    }

    func testTheEngineRunsFromTheBundleOrSaysWhereItRanFrom() async throws {
        let client = EngineClient(device: try device())
        let where_ = await client.resources
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: where_.appending(path: "spektrafilm_constants.bin").path),
            "no baked constants at \(where_.path); run engine/build.sh bundle")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: where_.appending(path: "spektrafilm.metallib").path),
            "no Metal library at \(where_.path)")
        await client.stop()
    }
}
