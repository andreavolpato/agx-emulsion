//  DecodeSeparationTests.swift — the canvas shows one decode, the engine
//  develops another, and the before/after compares them through one geometry.
//
//  A RAW is decoded twice (`ImageDecoder`'s header): `display` is Apple's
//  default rendering, shown before a develop, under Space and left of the
//  split; `linear` is sensor response, and it is the only thing the engine is
//  ever handed. Getting that backwards is invisible in every other test — the
//  engine renders *something* either way, and a film simulation of Apple's
//  tone curve is still a plausible photograph. So these check the routing
//  with inputs that cannot be confused, and then the one frame in the test
//  set where Apple's default would silently misregister the comparison.

import CoreImage
import Metal
import XCTest

@MainActor
final class DecodeSeparationTests: XCTestCase {

    private func device() throws -> MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
    }

    /// The Z7 II frame. Chosen, not merely available: Apple corrects this
    /// lens by default, which is the case the geometry rule exists for.
    private func nef() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)   // …/SpektrafilmTests/this file
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/Nikon Z7ii/_DSC2439.NEF")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "the Z7 II frame is not in this checkout")
        return url
    }

    private func solid(_ v: CGFloat) throws -> CIImage {
        let space = try XCTUnwrap(ImageDecoder.linearProPhoto)
        let color = try XCTUnwrap(CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: space))
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
    }

    private func decoded(linear: CIImage, display: CIImage) -> DecodedImage {
        DecodedImage(linear: linear, display: display, pixelSize: linear.extent.size, isRAW: true,
                     sourceURL: URL(fileURLWithPath: "/tmp/spk-separation.NEF"),
                     asShotTemperature: nil, asShotTint: nil)
    }

    /// An rgba16Unorm texture's samples, whatever its storage mode (the decode
    /// preview is `.private`).
    private func samples(_ texture: MTLTexture, _ device: MTLDevice) throws -> [UInt16] {
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

    /// Mean green of a texture, 0…1.
    private func meanGreen(_ s: [UInt16]) -> Double {
        var sum = 0.0
        for i in stride(from: 1, to: s.count, by: 4) { sum += Double(s[i]) }
        return sum / Double(s.count / 4) / 65535
    }

    /// Green, block-averaged onto a `cols` × `rows` grid, row-major from the top.
    private func grid(_ s: [UInt16], width: Int, height: Int, cols: Int = 24, rows: Int = 36) -> [Double] {
        var cells = [Double](repeating: 0, count: cols * rows), counts = [Double](repeating: 0, count: cols * rows)
        for y in 0..<height {
            for x in 0..<width {
                let c = min(cols - 1, x * cols / width) + min(rows - 1, y * rows / height) * cols
                cells[c] += Double(s[(y * width + x) * 4 + 1]); counts[c] += 1
            }
        }
        return zip(cells, counts).map { $0 / max($1, 1) }
    }

    private func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var ab = 0.0, aa = 0.0, bb = 0.0
        for (x, y) in zip(a, b) { ab += (x - ma) * (y - mb); aa += (x - ma) * (x - ma); bb += (y - mb) * (y - mb) }
        return ab / max((aa * bb).squareRoot(), 1e-12)
    }

    // MARK: - routing

    /// The engine's frame is the linear decode, whatever the display decode
    /// is; the canvas preview is the display decode, whatever the linear one
    /// is. Two solids that cannot be mistaken for each other.
    func testTheEngineIsHandedTheLinearDecodeAndTheCanvasTheDisplayOne() throws {
        let gpu = try device()
        let bright = decoded(linear: try solid(0.2), display: try solid(0.8))
        let dark = decoded(linear: try solid(0.2), display: try solid(0.05))

        let a = try ImageDecoder.engineFrame(from: bright, device: gpu)
        let b = try ImageDecoder.engineFrame(from: dark, device: gpu)
        XCTAssertEqual(memcmp(a.buffer.contents(), b.buffer.contents(), a.buffer.length), 0,
                       "the display decode reached the engine's frame")
        let pixel = a.buffer.contents().assumingMemoryBound(to: Float.self)
        for c in 0..<3 {
            XCTAssertEqual(pixel[c], 0.2, accuracy: 2e-3, "the engine was not handed the linear decode (channel \(c))")
        }

        let shownBright = try samples(try XCTUnwrap(ImageDecoder.makePreviewTexture(bright, device: gpu, maxEdge: 64)), gpu)
        let shownDark = try samples(try XCTUnwrap(ImageDecoder.makePreviewTexture(dark, device: gpu, maxEdge: 64)), gpu)
        XCTAssertGreaterThan(meanGreen(shownBright), meanGreen(shownDark) + 0.3,
                             "the canvas preview does not follow the display decode")
    }

    // MARK: - one geometry, one white balance, two looks

    /// Both RAW decodes are the same registration of the frame: lens
    /// correction off in both — on this camera Apple's default turns it *on*,
    /// which keeps the extent and moves the picture inside it — and the user's
    /// white balance in both. They differ in exactly the tone-rendering stages
    /// the engine needs off.
    func testBothRAWDecodesShareOneGeometryAndOneWhiteBalance() throws {
        let url = try nef()
        let stock = try XCTUnwrap(CIRAWFilter(imageURL: url))
        XCTAssertTrue(stock.isLensCorrectionSupported && stock.isLensCorrectionEnabled,
                      "precondition: Apple's default corrects this lens, which is what makes this frame the test")

        var settings = DecodeSettings()
        settings.whiteBalance = .custom
        settings.temperature = 6100
        settings.tint = 12
        let linear = try ImageDecoder.rawFilter(url, look: .linear, settings: settings)
        let display = try ImageDecoder.rawFilter(url, look: .display, settings: settings)

        XCTAssertFalse(linear.isLensCorrectionEnabled)
        XCTAssertFalse(display.isLensCorrectionEnabled, "the original would be misregistered against the print")
        XCTAssertFalse(display.isDraftModeEnabled)
        XCTAssertEqual(linear.outputImage?.extent, display.outputImage?.extent)
        XCTAssertEqual(Double(linear.neutralTemperature), Double(display.neutralTemperature), accuracy: 1)
        XCTAssertEqual(Double(display.neutralTemperature), 6100, accuracy: 25)
        XCTAssertEqual(Double(linear.neutralTint), Double(display.neutralTint), accuracy: 0.1)

        // The looks: off for the engine, Apple's own default for the eye.
        XCTAssertEqual(linear.boostAmount, 0)
        XCTAssertEqual(linear.boostShadowAmount, 0)
        XCTAssertFalse(linear.isGamutMappingEnabled)
        XCTAssertEqual(display.boostAmount, stock.boostAmount)
        XCTAssertEqual(display.boostShadowAmount, stock.boostShadowAmount)
        XCTAssertEqual(display.isGamutMappingEnabled, stock.isGamutMappingEnabled)
        XCTAssertEqual(display.localToneMapAmount, stock.localToneMapAmount)
        XCTAssertNotEqual(linear.boostAmount, display.boostAmount, "the two decodes are the same look")
    }

    // MARK: - the comparison, end to end

    /// Open the frame, develop it, and look at what the before/after actually
    /// compares: `renderer.original` against the print on the canvas.
    ///
    /// - The original is the *display* decode — the exact texture a preview of
    ///   it produces — and visibly not the linear one (Apple's boost lifts it).
    /// - It is the same picture as the print: the same aspect, and the same
    ///   layout of light and dark on a coarse grid, which a vertical flip or a
    ///   different registration would break. The flipped grid is the control
    ///   that shows the check can fail on this frame.
    func testTheOriginalIsTheDisplayDecodeAndLinesUpWithThePrint() async throws {
        let source = try nef()
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-compare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A copy, because a develop writes a sidecar next to the frame and the
        // checkout's own sidecar is somebody's edit.
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)

        let session = Session()
        session.open(urls: [url])
        try await waitUntil("the frame to decode") { session.decoded != nil }
        try await waitUntil("the engine to warm up") { session.serviceReady }
        session.solveNow()
        try await waitUntil("the print to land", timeout: 90) {
            session.serviceSessionIDForExport != nil && session.frameStates[url] == .processed && !session.busy
        }

        let gpu = session.renderer.device
        let d = try XCTUnwrap(session.decoded)
        let original = try XCTUnwrap(session.renderer.original, "nothing to compare against")
        let printed = try XCTUnwrap(session.renderer.store.print(for: url), "no print on the canvas")

        let shown = try samples(original, gpu)
        let display = try samples(try XCTUnwrap(ImageDecoder.makePreviewTexture(d, device: gpu, maxEdge: Session.liveEdge)), gpu)
        XCTAssertEqual(shown, display, "the original is not the display decode")
        let linearOnly = DecodedImage(linear: d.linear, display: d.linear, pixelSize: d.pixelSize, isRAW: true,
                                      sourceURL: url, asShotTemperature: nil, asShotTint: nil)
        let linear = try samples(try XCTUnwrap(ImageDecoder.makePreviewTexture(linearOnly, device: gpu, maxEdge: Session.liveEdge)), gpu)
        XCTAssertGreaterThan(meanGreen(shown), meanGreen(linear) * 1.05,
                             "the original looks like the linear decode, not Apple's rendering")

        XCTAssertEqual(Double(original.width) / Double(original.height),
                       Double(printed.width) / Double(printed.height), accuracy: 0.002, "different aspect")
        let before = grid(shown, width: original.width, height: original.height)
        let afterSamples = try samples(printed, gpu)
        let after = grid(afterSamples, width: printed.width, height: printed.height)
        let flipped = stride(from: 35, through: 0, by: -1).flatMap { r in after[(r * 24)..<(r * 24 + 24)] }
        let r = correlation(before, after), rFlipped = correlation(before, Array(flipped))
        print("before/after grid correlation \(r), against the flipped print \(rFlipped)")
        XCTAssertGreaterThan(r, 0.8, "the original and the print are not the same picture")
        XCTAssertGreaterThan(r - rFlipped, 0.2, "this frame cannot tell an upright print from a flipped one")
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
