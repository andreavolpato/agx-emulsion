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

    /// A frame exactly as the app hands one over: a linear ProPhoto image,
    /// rendered by `ImageDecoder.engineFrame` into a buffer on `device`.
    private func makeFrame(_ size: Int = 96, device: MTLDevice) throws -> EngineFrame {
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
            CIImage(bitmapData: Data(buffer: buffer), bytesPerRow: width * 16,
                    size: CGSize(width: width, height: size), format: .RGBAf, colorSpace: space)
        })
        return try ImageDecoder.engineFrame(from: image, device: device)
    }

    /// The orientation of the frame the engine is handed.
    ///
    /// This exists because getting it wrong is invisible to every other test:
    /// the C++ parity suite hands the engine a numpy array and never goes
    /// through `ImageDecoder.engineFrame`, so a vertical flip here produced a
    /// correctly developed, upside-down photograph with 27 of 27 parity cases
    /// green.
    func testTheEngineFrameIsTopRowFirst() throws {
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
        let frame = try ImageDecoder.engineFrame(from: image, device: try device())
        XCTAssertEqual(frame.width, width)
        XCTAssertEqual(frame.height, height)
        // Handed over with whatever channel count Core Image rendered (4 --
        // the engine drops alpha on the GPU), so index by what the frame says.
        XCTAssertEqual(frame.buffer.length, width * height * frame.channels * 4)
        let pixels = frame.buffer.contents().assumingMemoryBound(to: Float.self)
        func rowMean(_ y: Int) -> Float {
            var sum: Float = 0
            for x in 0..<width { sum += pixels[(y * width + x) * frame.channels + 1] }
            return sum / Float(width)
        }
        XCTAssertGreaterThan(rowMean(1), 0.5, "row 1 should be the image's bright top")
        XCTAssertLessThan(rowMean(height - 2), 0.2, "the last row should be the dark bottom")
    }

    // MARK: - spk_open_device

    /// The borrowed-buffer open and the host-array open are the same session.
    ///
    /// Held at the only bar that means "nothing changed": the live print's
    /// bytes, with the two stochastic stages off (grain and glare are redrawn
    /// on every render by design, so leaving them on measures noise and
    /// reports a defect). The two entry points share every line after the
    /// upload, so what this pins is the upload -- that the borrow, the
    /// `spk_take_rgb` copy and its end are the same pixels `spk_open` gets
    /// from a `memcpy`.
    func testTheDeviceOpenIsTheHostOpen() throws {
        let gpu = try device()
        let frame = try makeFrame(120, device: gpu)
        let resources = EngineClient.defaultResources().path
        let engine = try XCTUnwrap(resources.withCString {
            spk_engine_create($0, Unmanaged.passUnretained(gpu).toOpaque())
        }, "no engine: \(String(cString: spk_last_error(nil)))")
        defer { spk_engine_destroy(engine) }
        let delta = #"{"grain_active":false,"grain_sublayers_active":false,"glare_active":false}"#

        func livePrint(_ open: (UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> OpaquePointer?) throws -> [UInt16] {
            var reply: UnsafeMutablePointer<CChar>?
            let session = try XCTUnwrap(delta.withCString { open($0, &reply) },
                                        String(cString: spk_last_error(engine)))
            defer { spk_session_release(session) }
            if let reply { spk_string_free(reply) }
            var result = spk_result()
            let status = "live".withCString { spk_reprint(session, $0, &result) }
            XCTAssertTrue(status == SPK_OK, String(cString: spk_last_error(engine)))
            defer { spk_result_free(&result) }
            let rgba16 = try XCTUnwrap(result.rgba16)
            var rows: [UInt16] = []
            for y in 0..<Int(result.height) {
                let row = rgba16 + y * Int(result.row_stride_px) * 4
                rows.append(contentsOf: UnsafeBufferPointer(start: row, count: Int(result.width) * 4))
            }
            return rows
        }

        let host = try livePrint { deltaPtr, reply in
            var image = spk_image(data: frame.buffer.contents().assumingMemoryBound(to: Float.self),
                                  width: UInt32(frame.width), height: UInt32(frame.height),
                                  channels: UInt32(frame.channels))
            return spk_open(engine, &image, deltaPtr, reply)
        }
        let device = try livePrint { deltaPtr, reply in
            var image = spk_device_image(buffer: Unmanaged.passUnretained(frame.buffer).toOpaque(),
                                         width: UInt32(frame.width), height: UInt32(frame.height),
                                         channels: UInt32(frame.channels))
            return spk_open_device(engine, &image, deltaPtr, reply)
        }
        XCTAssertFalse(host.isEmpty)
        XCTAssertEqual(host.count, device.count)
        let differing = zip(host, device).filter { $0 != $1 }.count
        XCTAssertEqual(differing, 0, "\(differing) of \(host.count) samples differ between the two opens")
    }


    /// A buffer too short for the image it claims to be is refused by name
    /// rather than read past its end.
    func testAShortBufferIsRefused() async throws {
        let gpu = try device()
        let short = try XCTUnwrap(gpu.makeBuffer(length: 64 * 48 * 16 - 16, options: .storageModeShared))
        let client = EngineClient(device: gpu)
        do {
            _ = try await client.open(EngineFrame(buffer: short, width: 64, height: 48, channels: 4),
                                      paramsDelta: nil)
            XCTFail("the engine opened a frame from a buffer shorter than the frame")
        } catch {
            XCTAssertTrue("\(error)".contains("bytes"), "unhelpful error: \(error)")
        }
        await client.stop()
    }

    /// The borrow ends with the call. The engine keeps its own copy of the
    /// source, and a retained caller's buffer would be 727 MB at 45 MP that
    /// nobody could free -- the frame is dropped straight after `open` for
    /// exactly this reason.
    func testTheEngineKeepsNothingOfTheCallersBuffer() async throws {
        let gpu = try device()
        let client = EngineClient(device: gpu)
        weak var borrowed: MTLBuffer?
        let sessionID: String
        do {
            let frame = try makeFrame(96, device: gpu)
            borrowed = frame.buffer
            sessionID = try await client.open(frame, paramsDelta: nil).sessionID
        }
        XCTAssertNil(borrowed, "the engine (or something on the open path) kept the caller's buffer")
        // And the session it made still renders: it did not depend on it.
        let outcome = try await client.render(.reprint, RenderRequest(sessionID: sessionID))
        XCTAssertNotNil(outcome.texture)
        await client.stop()
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
        let frameSize = 96
        let gpu = try device()
        let client = EngineClient(device: gpu)
        let open = try await client.open(try makeFrame(frameSize, device: gpu), paramsDelta: nil)
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
        let frameSize = 96
        let gpu = try device()
        let client = EngineClient(device: gpu)
        let open = try await client.open(try makeFrame(frameSize, device: gpu), paramsDelta: nil)
        _ = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))
        let second = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))
        // The whole reason the two tiers cache a negative: a print-side edit
        // must not re-run the film side.
        XCTAssertTrue(second.response.negativeWasCached)
        await client.stop()
    }

    func testAPrintSideEditChangesThePictureAndAShootSideOneReRenders() async throws {
        let frameSize = 96
        let gpu = try device()
        let client = EngineClient(device: gpu)
        let open = try await client.open(try makeFrame(frameSize, device: gpu), paramsDelta: nil)
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
        let frameSize = 1800
        let gpu = try device()
        let client = EngineClient(device: gpu)
        let open = try await client.open(try makeFrame(frameSize, device: gpu), paramsDelta: nil)
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
        let frameSize = 96
        let gpu = try device()
        let client = EngineClient(device: gpu)
        let open = try await client.open(try makeFrame(frameSize, device: gpu), paramsDelta: nil)
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

    /// A client that goes away takes its engine and its session with it.
    ///
    /// `EngineClient` holds two C pointers and ARC frees neither: releasing an
    /// `OpaquePointer` releases nothing. Only `stop()` did, and only the tests
    /// in this file call it — every test that builds a `Session` gets its own
    /// `EngineClient` (`Session.swift`: `client = EngineClient(device:)`) and
    /// then drops it. There are 23 of those in this suite.
    ///
    /// Measured, a dropped client kept ~458 MB on a 5.6 MP frame (at the C ABI:
    /// ~386 MB for an engine plus its open session at 6 MP, ~110 MB for a
    /// session alone), and this suite's own peak was 2.55 GB against 1.76 GB
    /// once it was freed. That is worth having back, but it is **not** on its
    /// own what panicked the machine on 2026-09-12 — that was several
    /// multi-gigabyte jobs running at once, one of them a deliberate 151 MP
    /// probe at 11.4 GB. Sizing a leak is the test's job; sizing the machine is
    /// not.
    ///
    /// The bound is deliberately coarse. What it separates is "freed" from
    /// "hundreds of MB per client"; anything in between is already wrong.
    func testAClientThatGoesAwayFreesItsEngine() async throws {
        let gpu = try device()
        // The first engine in a process pays for the Metal library and the
        // baked constants, and that cost is not per client. Pay it here.
        do {
            let warm = EngineClient(device: gpu)
            _ = try await warm.open(try makeFrame(2048, device: gpu), paramsDelta: nil)
            await warm.stop()
        }
        try await Task.sleep(for: .milliseconds(100))
        // One frame, reused: the engine copies what it keeps at `open`, and a
        // fresh `EngineFrame` per iteration would measure the test's own 90 MB
        // buffers autoreleasing (AGENTS: `MTLBuffer.contents()` holds them to
        // the end of the pool) rather than what the client kept.
        let frame = try makeFrame(2048, device: gpu)
        let before = Self.footprintMB()

        for _ in 0..<4 {
            let client = EngineClient(device: gpu)
            let open = try await client.open(frame, paramsDelta: nil)
            _ = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))
            // No `stop()`, deliberately: this is what a dropped `Session` does.
        }
        try await Task.sleep(for: .milliseconds(200))
        let growth = Self.footprintMB() - before
        XCTAssertLessThan(growth, 200,
                          "four dropped clients kept \(Int(growth)) MB — the engine "
                          + "and its session outlive the client that made them")
    }

    /// This process's physical footprint, the number Activity Monitor shows.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return ok == KERN_SUCCESS ? Double(info.phys_footprint) / (1024 * 1024) : 0
    }
}
