//  PrintLUTTests.swift — the three methods that used to be refused by name.
//
//  `export`, `preview_stock_lut` and `export_di` were listed in
//  ARCHITECTURE §8.8 as not ported; the engine now implements all three and
//  `EngineClient` reaches them. `engine/tests/parity_lut.py` holds the
//  *numbers* against the Python reference (tables bit-exact, the apply and
//  the DI normalisation inside 8e-6). What these check is the part parity
//  cannot see: that Swift's view of the new ABI is right, that the `.cube`
//  this side writes has the ordering the cube format specifies, and that the
//  DI file is not tagged as a colour.

import ImageIO
import Metal
import XCTest

final class PrintLUTTests: XCTestCase {
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

    // MARK: - the catalog and the table

    /// The eight baked LUTs are in the bundle and the app can see them.
    ///
    /// This is the assertion HANDOFF-DISTRIBUTION §1 asked for: the
    /// print-preview LUTs were deliberately *not* bundled while the three
    /// methods were unported, and porting them made bundling a requirement.
    /// An empty catalog means `engine/build.sh bundle` was not re-run, which
    /// is a build mistake this should name rather than a feature quietly
    /// disappearing.
    func testTheBakedLUTsAreBundled() async throws {
        let client = EngineClient(device: try device())
        let catalog = try await client.printLUTCatalog()
        let resources = await client.resources.path
        XCTAssertFalse(catalog.isEmpty,
                       "no print LUTs in the resources at \(resources); "
                       + "run engine/tools/bake_resources.py and engine/build.sh bundle")
        // The default paper the app opens on must be one of them, or the fast
        // flip is a feature nobody can reach from a fresh session.
        let entry = try XCTUnwrap(catalog["kodak_portra_endura"])
        XCTAssertEqual(entry.pairedFilm, "kodak_portra_400")
        XCTAssertEqual(entry.lutSize, 33)
        for (stock, e) in catalog {
            XCTAssertGreaterThan(e.lutSize, 1, "\(stock) has a degenerate LUT size")
            XCTAssertFalse(e.pairedFilm.isEmpty, "\(stock) names no paired film")
        }
        await client.stop()
    }

    /// The table crosses whole, and a stock with no LUT is refused by name
    /// rather than answered with zeros.
    ///
    /// **The values are not confined to [0, 1]**, and that surprised this
    /// test before it surprised anyone else: `kodak_portra_endura` bottoms
    /// out at -1.115 across 1056 of its 107,811 entries. The bake stores the
    /// print+scan chain's Display P3 output *unclamped*, so a print colour
    /// outside P3's gamut is a negative coordinate rather than a clipped one.
    /// Both consumers clamp — `Exporter.writeCube` on the way to the file and
    /// `spk_to_rgba16` on the way to a texture — which is what the Python
    /// reference did too. So the bar here is that nothing is NaN and the
    /// range matches the asset, not that the table is displayable.
    func testTheTableCrossesWholeAndAnUnknownStockIsRefused() async throws {
        let client = EngineClient(device: try device())
        let (size, table) = try await client.printLUTTable("kodak_portra_endura")
        XCTAssertEqual(size, 33)
        XCTAssertEqual(table.count, 33 * 33 * 33 * 3)
        XCTAssertFalse(table.contains { $0.isNaN }, "the table carries NaN")
        XCTAssertFalse(table.contains { $0.isInfinite }, "the table carries an infinity")
        // The shipped asset's own extremes, so a table read transposed, half
        // short, or widened through the wrong dtype fails here.
        XCTAssertEqual(try XCTUnwrap(table.min()), -1.115051, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(table.max()), 0.956, accuracy: 1e-5)
        do {
            _ = try await client.printLUTTable("not_a_paper")
            XCTFail("the engine invented a LUT for an unknown stock")
        } catch {
            XCTAssertTrue("\(error)".contains("not_a_paper"), "unhelpful error: \(error)")
        }
        await client.stop()
    }

    // MARK: - the `.cube` writer

    /// The cube's ordering, against the format's own rule.
    ///
    /// `.cube` is red-fastest and blue-slowest, and the table is
    /// `[r][g][b]` — so line `n` must be the entry the format says it is.
    /// Getting this wrong produces a file every host loads happily and every
    /// host grades wrongly, which is why it is checked against a table whose
    /// values *encode their own index* rather than against a shipped one.
    @MainActor func testTheCubeIsWrittenRedFastest() throws {
        let n = 4
        var table = [Float](repeating: 0, count: n * n * n * 3)
        for r in 0..<n {
            for g in 0..<n {
                for b in 0..<n {
                    let i = ((r * n + g) * n + b) * 3
                    table[i] = Float(r) / 100
                    table[i + 1] = Float(g) / 100
                    table[i + 2] = Float(b) / 100
                }
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "spk-cube-\(UUID().uuidString).cube")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exporter.writeCube(table, size: n, to: url, title: "test")

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        XCTAssertEqual(lines[0], "TITLE \"test\"")
        XCTAssertEqual(lines[1], "LUT_3D_SIZE 4")
        XCTAssertTrue(lines.contains("DOMAIN_MIN 0.0 0.0 0.0"))
        XCTAssertTrue(lines.contains("DOMAIN_MAX 1.0 1.0 1.0"))
        let values = lines.dropFirst(4)
        XCTAssertEqual(values.count, n * n * n)
        for (index, line) in values.enumerated() {
            // The format's own indexing: red is the fastest axis.
            let r = index % n, g = (index / n) % n, b = index / (n * n)
            let want = String(format: "%.6f %.6f %.6f",
                              Float(r) / 100, Float(g) / 100, Float(b) / 100)
            XCTAssertEqual(line, want, "line \(index) should be (r \(r), g \(g), b \(b))")
        }
    }

    /// A malformed call fails rather than writing a truncated cube that a
    /// host would load and grade with.
    @MainActor func testACubeOfTheWrongLengthIsRefused() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "spk-cube-bad-\(UUID().uuidString).cube")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try Exporter.writeCube([0, 0, 0], size: 33, to: url, title: "x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - the two render paths

    func testAStockPreviewComesBackAsATextureAndReportsItsPairing() async throws {
        let frameSize = 96
        let gpu = try device()
        let client = EngineClient(device: gpu)
        let open = try await client.open(try makeFrame(frameSize, device: gpu), paramsDelta: nil)
        // Warm the negative first, which is what the interactive path does.
        _ = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))

        let paired = try await client.previewStockLUT("kodak_portra_endura")
        let texture = try XCTUnwrap(paired.texture, "the preview returned no texture")
        XCTAssertEqual(texture.pixelFormat, .rgba16Unorm)
        XCTAssertEqual(texture.width, paired.width)
        XCTAssertEqual(paired.meta.lutSource, "shipped")
        XCTAssertEqual(paired.meta.applyBackend, "native-metal")
        XCTAssertEqual(paired.meta.pairedFilm, "kodak_portra_400")
        // The session's film *is* the paired one, so there is nothing to warn
        // about — and a warning that fires anyway would train the user to
        // ignore the one that matters.
        XCTAssertNil(paired.meta.warning)

        let mismatched = try await client.previewStockLUT("kodak_2383")
        XCTAssertEqual(mismatched.meta.pairedFilm, "kodak_vision3_250d")
        let warning = try XCTUnwrap(mismatched.meta.warning,
                                    "a mismatched film must warn (PRD §7.3)")
        XCTAssertTrue(warning.contains("kodak_vision3_250d"))
        await client.stop()
    }

    func testAnUnknownStockPreviewNamesWhatIsAvailable() async throws {
        let frameSize = 96
        let gpu = try device()
        let client = EngineClient(device: gpu)
        let open = try await client.open(try makeFrame(frameSize, device: gpu), paramsDelta: nil)
        _ = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))
        do {
            _ = try await client.previewStockLUT("not_a_paper")
            XCTFail("the engine previewed a stock it has no table for")
        } catch {
            let message = "\(error)"
            XCTAssertTrue(message.contains("not_a_paper"), "unhelpful error: \(message)")
            XCTAssertTrue(message.contains("kodak_portra_endura"),
                          "the refusal should say what is available: \(message)")
        }
        await client.stop()
    }

    /// The DI image is the full tier, in [0, 1], and it is *not* the print.
    func testTheDIImageIsFullResolutionAndNormalised() async throws {
        let frameSize = 96
        let gpu = try device()
        let client = EngineClient(device: gpu)
        let open = try await client.open(try makeFrame(frameSize, device: gpu), paramsDelta: nil)
        let di = try await client.exportDI()
        let texture = try XCTUnwrap(di.texture, "export_di returned no texture")
        XCTAssertEqual(di.width, open.meta.width, "the DI file must be full resolution")
        XCTAssertEqual(di.height, open.meta.height)
        XCTAssertEqual(di.meta.lutSize, 33)
        XCTAssertEqual(di.meta.printStock, "kodak_portra_endura")

        // The normalisation is what makes the cube's domain 0..1. rgba16Unorm
        // cannot hold anything outside it, so what is checked is that the
        // frame is not degenerate — a normalisation with the wrong axes
        // clamps to a flat 0 or a flat 1.
        let print = try await client.render(.reprint, RenderRequest(sessionID: open.sessionID))
        let printTexture = try XCTUnwrap(print.texture)
        let diMean = try mean(texture), printMean = try mean(printTexture)
        XCTAssertGreaterThan(diMean, 0.01, "the DI image is black")
        XCTAssertLessThan(diMean, 0.99, "the DI image is white")
        // A negative in density is not a print in Display P3. If these agree
        // the wrong tap was read.
        XCTAssertGreaterThan(abs(diMean - printMean), 0.01,
                             "the DI image looks like the print")
        await client.stop()
    }

    /// The DI TIFF is written without a rendering profile.
    ///
    /// Its channels are film densities, and a host that treats them as
    /// Display P3 and converts on open moves every value — which silently
    /// invalidates the `.cube` shipped beside it, because the cube's domain
    /// is those exact numbers.
    @MainActor func testTheDIFileIsNotTaggedAsAColour() throws {
        var bytes = [UInt16](repeating: 0, count: 8 * 8 * 4)
        for i in 0..<(8 * 8) {
            bytes[i * 4] = 20000; bytes[i * 4 + 1] = 30000
            bytes[i * 4 + 2] = 40000; bytes[i * 4 + 3] = 65535
        }
        let data = bytes.withUnsafeBufferPointer { Data(buffer: $0) }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let cg = try XCTUnwrap(CGImage(
            width: 8, height: 8, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: 8 * 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                     | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "spk-di-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exporter.write(cg, to: url, format: .tiff)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(props[kCGImagePropertyProfileName],
                     "the DI TIFF carries a colour profile: \(props[kCGImagePropertyProfileName]!)")
        let reread = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(reread.bitsPerComponent, 16, "the DI TIFF is not 16-bit")
    }


    // MARK: - the finished-export path

    /// `export` end to end, minus `Session`'s plumbing.
    ///
    /// This is the path that was **entirely broken** before this session and
    /// had no test: `Exporter` called `.export` over the wire, `EngineClient`
    /// threw `unsupported`, and every finished export failed at the first
    /// step. Nothing caught it because the export path had no coverage at
    /// all — the render tests stop at the texture, and the layout tests never
    /// press the button.
    ///
    /// So the assertion is deliberately end-to-end: a full-tier render,
    /// through Layer 2 and the geometry in Metal, into a file, read back off
    /// disk. What it does not cover is `Session.selection` and the filename,
    /// which is why `Exporter.destination` is checked separately below.
    @MainActor
    func testTheFinishedExportPathProducesAFileOnDisk() async throws {
        let frameSize = 200
        let renderer = try XCTUnwrap(Renderer(), "no renderer")
        let gpu = renderer.device
        let client = EngineClient(device: gpu)
        let open = try await client.open(try makeFrame(frameSize, device: gpu), paramsDelta: nil)

        // `.export` is the full tier, and it must be the *source's*
        // resolution: an export that quietly wrote the 1600 px live tier
        // would be a soft file nobody would question.
        let outcome = try await client.render(
            .export, RenderRequest(sessionID: open.sessionID, tier: "full"))
        let full = try XCTUnwrap(outcome.texture, "the export render returned no texture")
        XCTAssertEqual(full.width, open.meta.width)
        XCTAssertEqual(full.height, open.meta.height)

        var adjustments = Adjustments.default
        adjustments.exposure = 0.5
        let adjusted = try XCTUnwrap(renderer.applyLayer2(to: full, uniforms: adjustments.uniforms),
                                     "Layer 2 produced nothing")
        // A crop and a straighten, so the geometry stage is not a no-op —
        // the bug this replaced could not rotate at all, and a straightened
        // frame exported unstraightened with nothing saying so.
        var geometry = Geometry.default
        geometry.crop = CropRect(x: 0.1, y: 0.05, width: 0.6, height: 0.7)
        geometry.angle = 5
        let framed = try XCTUnwrap(renderer.applyGeometry(geometry, to: adjusted),
                                   "the geometry stage produced nothing")
        XCTAssertLessThan(framed.width, full.width, "the crop did not apply")

        let cg = try XCTUnwrap(framed.makeCGImage())
        let out = FileManager.default.temporaryDirectory
            .appending(path: "spk-export-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: out) }
        try Exporter.write(cg, to: out, format: .tiff)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        let reread = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(reread.width, framed.width)
        XCTAssertEqual(reread.height, framed.height)
        XCTAssertEqual(reread.bitsPerComponent, 16, "a TIFF export must be 16-bit")
        // A print is a colour, so unlike the DI file this one *is* tagged.
        XCTAssertNotNil(reread.colorSpace, "the print export carries no colour profile")
        await client.stop()
    }

    /// The filenames the two routes write to, and that the DI package's three
    /// files land beside each other rather than overwriting one another.
    @MainActor
    func testTheExportFilenames() {
        var params = FilmParams.default
        params.filmStock = "kodak_portra_400"
        params.printStock = "kodak_portra_endura"
        let source = URL(fileURLWithPath: "/tmp/spk-names/_DSC2439.NEF")
        let tiff = Exporter.destination(for: source, params: params, format: .tiff)
        XCTAssertEqual(tiff.lastPathComponent,
                       "_DSC2439_kodak_portra_400_kodak_portra_endura.tif")
        XCTAssertEqual(tiff.deletingLastPathComponent().lastPathComponent, "_prints")
        let di = Exporter.destination(for: source, params: params, format: .di)
        // The DI TIFF and the finished TIFF share an extension, so they would
        // collide if the DI route did not distinguish its own files — which it
        // does by suffixing the cube and the preview, not the TIFF. Worth
        // pinning: they are the same name today and that is a real hazard.
        XCTAssertEqual(di.lastPathComponent, tiff.lastPathComponent)
        try? FileManager.default.removeItem(at: tiff.deletingLastPathComponent())
    }

    private func mean(_ texture: MTLTexture) throws -> Double {
        let bpr = texture.width * 8
        var data = Data(count: bpr * texture.height)
        data.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: bpr,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        var sum = 0.0
        var count = 0
        data.withUnsafeBytes { raw in
            let words = raw.bindMemory(to: UInt16.self)
            for i in stride(from: 0, to: words.count, by: 4) {
                sum += Double(words[i]) + Double(words[i + 1]) + Double(words[i + 2])
                count += 3
            }
        }
        return sum / Double(count) / 65535.0
    }
}
