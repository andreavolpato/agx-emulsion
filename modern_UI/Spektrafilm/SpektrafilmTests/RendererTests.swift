//  Behaviour tests for the render path: orientation, colour passthrough and
//  Layer 2 on a synthetic texture. These run on the GPU.

import Metal
import XCTest

@MainActor
final class RendererTests: XCTestCase {
    var renderer: Renderer!

    override func setUp() async throws {
        renderer = try XCTUnwrap(Renderer())
    }

    /// A 4×2 test card: top row red, green, blue, white; bottom row black,
    /// mid-grey, black, mid-grey. Row 0 is the TOP.
    func makeCard() -> MTLTexture {
        let tex = renderer.store.makeWritable(width: 4, height: 2)!
        var px: [UInt16] = []
        let M: UInt16 = 65535, H: UInt16 = 32768
        px += [M, 0, 0, M,  0, M, 0, M,  0, 0, M, M,  M, M, M, M]
        px += [0, 0, 0, M,  H, H, H, M,  0, 0, 0, M,  H, H, H, M]
        px.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, 4, 2), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 32) }
        return tex
    }

    func pixel(_ tex: MTLTexture, _ x: Int, _ y: Int) -> [Double] {
        var px = [UInt16](repeating: 0, count: 4)
        tex.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return px.prefix(3).map { Double($0) / 65535 }
    }

    func testLayer2NeutralIsPassthrough() {
        let card = makeCard()
        let out = renderer.applyLayer2(to: card, uniforms: Adjustments().uniforms)!
        XCTAssertEqual(pixel(out, 0, 0), [1, 0, 0])
        XCTAssertEqual(pixel(out, 1, 0), [0, 1, 0])
        XCTAssertEqual(pixel(out, 1, 1)[0], 0.5, accuracy: 1e-3)
    }

    func testLayer2BypassIgnoresAdjustments() {
        var a = Adjustments(); a.enabled = false; a.exposure = 2
        let out = renderer.applyLayer2(to: makeCard(), uniforms: a.uniforms)!
        XCTAssertEqual(pixel(out, 1, 1)[0], 0.5, accuracy: 1e-3)
    }

    func testExposureBrightensMidGrey() {
        var a = Adjustments(); a.exposure = 1
        let out = renderer.applyLayer2(to: makeCard(), uniforms: a.uniforms)!
        let g = pixel(out, 1, 1)[0]
        XCTAssertGreaterThan(g, 0.6); XCTAssertLessThan(g, 0.75)  // 0.5^2.2*2 → ^(1/2.2) ≈ 0.685
    }

    func testCurvesInvert() {
        var a = Adjustments()
        a.curves.rgb.points = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)]
        renderer.setCurves(a.curves)
        let out = renderer.applyLayer2(to: makeCard(), uniforms: a.uniforms)!
        XCTAssertEqual(pixel(out, 3, 0)[0], 0, accuracy: 0.01)   // white → black
        XCTAssertEqual(pixel(out, 0, 1)[0], 1, accuracy: 0.01)   // black → white
    }

    /// The whole display path at fit: the card's TOP row must land at the
    /// top of the viewport and its LEFT column at the left. This is the test
    /// that catches a flipped or mirrored canvas.
    func testOffscreenRenderOrientation() {
        let card = makeCard()
        renderer.setLive(card)
        renderer.viewport.backingScale = 1
        renderer.viewport.resize(viewport: CGSize(width: 40, height: 20), image: CGSize(width: 4, height: 2))
        let out = renderer.renderOffscreen(size: CGSize(width: 40, height: 20), backingScale: 1)!
        XCTAssertEqual(pixel(out, 5, 5), [1, 0, 0], "top-left must be red")
        XCTAssertEqual(pixel(out, 35, 5), [1, 1, 1], "top-right must be white")
        XCTAssertEqual(pixel(out, 5, 15), [0, 0, 0], "bottom-left must be black")
        XCTAssertEqual(pixel(out, 15, 15)[0], 0.5, accuracy: 0.02, "bottom second must be grey")
    }

    func testOffscreenRenderShowsGroundOutsideImage() {
        let card = makeCard()
        renderer.setLive(card)
        renderer.viewport.backingScale = 1
        renderer.viewport.resize(viewport: CGSize(width: 40, height: 40), image: CGSize(width: 4, height: 2))
        let out = renderer.renderOffscreen(size: CGSize(width: 40, height: 40), backingScale: 1)!
        let ground = 0x5F / 255.0
        XCTAssertEqual(pixel(out, 20, 2)[0], ground, accuracy: 0.01, "letterbox above the image is the ground")
        XCTAssertEqual(pixel(out, 5, 15), [1, 0, 0], "image is vertically centred")
    }

    /// A detail render is several times the live tier's pixel size and must
    /// land in exactly the same on-screen rectangle. The first version of the
    /// scaling math inverted the ratio and drew a 5504 px texture 5.2× too
    /// large — a black canvas. This pins the geometry.
    func testDetailTextureDrawsAtTheLiveRectangle() {
        let card = makeCard()
        renderer.setLive(card)
        renderer.viewport.backingScale = 1
        renderer.viewport.resize(viewport: CGSize(width: 40, height: 20), image: CGSize(width: 4, height: 2))

        // The same card at 4× in each axis: replicate each pixel.
        let big = renderer.store.makeWritable(width: 16, height: 8)!
        var src = [UInt16](repeating: 0, count: 4 * 2 * 4)
        card.getBytes(&src, bytesPerRow: 32, from: MTLRegionMake2D(0, 0, 4, 2), mipmapLevel: 0)
        var dst = [UInt16](repeating: 0, count: 16 * 8 * 4)
        for y in 0..<8 { for x in 0..<16 {
            let sx = x / 4, sy = y / 4
            for c in 0..<4 { dst[(y * 16 + x) * 4 + c] = src[(sy * 4 + sx) * 4 + c] }
        } }
        dst.withUnsafeBytes { big.replace(region: MTLRegionMake2D(0, 0, 16, 8), mipmapLevel: 0,
                                          withBytes: $0.baseAddress!, bytesPerRow: 16 * 8) }

        renderer.setDetail(big)
        XCTAssertTrue(renderer.showsDetail)
        let out = renderer.renderOffscreen(size: CGSize(width: 40, height: 20), backingScale: 1)!
        XCTAssertEqual(pixel(out, 5, 5), [1, 0, 0], "top-left must still be red at 4× the texture")
        XCTAssertEqual(pixel(out, 35, 5), [1, 1, 1], "top-right must still be white")
        XCTAssertEqual(pixel(out, 5, 15), [0, 0, 0], "bottom-left must still be black")
        XCTAssertEqual(pixel(out, 15, 15)[0], 0.5, accuracy: 0.02, "bottom second must still be grey")

        renderer.hideDetail()
        XCTAssertFalse(renderer.showsDetail)
        let back = renderer.renderOffscreen(size: CGSize(width: 40, height: 20), backingScale: 1)!
        XCTAssertEqual(pixel(back, 5, 5), [1, 0, 0], "zooming out returns to the live tier")
    }

    func testDecoderPreviewOrientation() throws {
        // A 2×2 PNG: red top-left, green top-right, blue bottom-left, white bottom-right.
        let url = FileManager.default.temporaryDirectory.appending(path: "orient-\(UUID().uuidString).png")
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CGContext origin is bottom-left.
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        let decoded = try ImageDecoder.decode(url, settings: DecodeSettings())
        let tex = try XCTUnwrap(ImageDecoder.makePreviewTexture(decoded, device: renderer.device, maxEdge: 2))
        // Private storage: copy to shared to read.
        let shared = renderer.store.makeWritable(width: 2, height: 2)!
        let cb = renderer.queue.makeCommandBuffer()!; let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: tex, to: shared); blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        let tl = pixel(shared, 0, 0), br = pixel(shared, 1, 1)
        XCTAssertGreaterThan(tl[0], 0.9); XCTAssertLessThan(tl[1], 0.3)   // red at top-left
        XCTAssertGreaterThan(br[0], 0.9); XCTAssertGreaterThan(br[2], 0.9) // white at bottom-right
    }
}
