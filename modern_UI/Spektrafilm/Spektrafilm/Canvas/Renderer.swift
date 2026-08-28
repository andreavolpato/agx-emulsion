//  Renderer.swift — MTKViewDelegate. Draws on demand, never on a display link.
//
//  `isPaused = true` and `enableSetNeedsDisplay = true` (UI-GUIDELINE §4): a
//  continuously rendering MTKView burns battery for an image that changes
//  only when something is dragged.

import Metal
import CoreGraphics
import MetalKit
import CoreImage
import simd

struct CanvasUniforms {
    var scale: SIMD2<Float> = .init(1, 1)
    var offset: SIMD2<Float> = .zero
    var exposure: Float = 0
    var highlights: Float = 0
    var shadows: Float = 0
    var blackPoint: Float = 0
    var whitePoint: Float = 0
    var layer2Enabled: Float = 0
}

@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var backdrop: MTLRenderPipelineState?
    private let ciContext: CIContext

    /// The image currently resident on the GPU.
    private(set) var texture: MTLTexture?
    private(set) var textureSize = CGSize.zero

    var uniforms = CanvasUniforms()
    /// Fit-scale zoom multiplier and pan offset, in image space.
    var zoom: Double = 1.0
    var pan: CGPoint = .zero
    var fitToWindow = true

    /// Reported back so the inspector can show what the canvas actually did,
    /// rather than what it was asked to do.
    private(set) var lastUploadMs: Double?
    private(set) var lastError: String?

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        // Core Image composites in a wide *linear extended* space; the
        // single encode to Display P3 happens once, at render time, in
        // ImageDecoder.makeTexture. `cacheIntermediates` off because the
        // canvas holds one image and a CI cache would duplicate it.
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: ImageDecoder.compositingSpace as Any,
            .cacheIntermediates: false,
        ])
        super.init()
        buildPipelines()
    }

    private func buildPipelines() {
        guard let library = device.makeDefaultLibrary() else {
            lastError = "no default.metallib — are Shaders.metal in the target?"
            return
        }
        func make(_ fragment: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "canvas_vertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            // Matches MTKView.colorPixelFormat below. Half-float, and
            // explicitly not an `_srgb` format: the data is already
            // P3-encoded and an `_srgb` format would decode on read and
            // re-encode on write (UI-GUIDELINE §4 rule 2).
            d.colorAttachments[0].pixelFormat = .rgba16Float
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        pipeline = make("canvas_fragment")
        backdrop = make("canvas_backdrop")
        if pipeline == nil { lastError = "canvas pipeline failed to build" }
    }

    // MARK: - image

    func load(_ decoded: DecodedImage, maxEdge: Int) {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let buffer = queue.makeCommandBuffer() else { return }
        let made = ImageDecoder.makeTexture(decoded, context: ciContext, device: device,
                                            commandBuffer: buffer, maxEdge: maxEdge)
        buffer.commit()
        buffer.waitUntilCompleted()
        guard let made else {
            lastError = "could not build a texture from \(decoded.sourceURL.lastPathComponent)"
            return
        }
        texture = made
        textureSize = CGSize(width: made.width, height: made.height)
        lastUploadMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        lastError = nil
    }

    func clear() { texture = nil; textureSize = .zero }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let viewport = view.drawableSize

        if let backdrop {
            encoder.setRenderPipelineState(backdrop)
            var vp = SIMD2<Float>(Float(viewport.width), Float(viewport.height))
            encoder.setFragmentBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        if let pipeline, let texture {
            var u = uniforms
            (u.scale, u.offset) = samplingTransform(viewport: viewport)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// Map viewport uv to image uv, fitted and clamped.
    ///
    /// Capture One's canvas behaviour, and the point of it: **the image never
    /// leaves the viewport.** Below fit scale it is centred and pan is
    /// ignored entirely; above it, pan is clamped so an image edge can never
    /// be dragged inside the viewport edge. There is no scrollable void to
    /// get lost in and no way to lose the picture off-screen — a free-panning
    /// canvas costs the user a "where did it go" every time they zoom.
    ///
    /// Zoom is a transform on the sampling coordinates, not a re-render, so
    /// all of this is free within the resident buffer.
    func samplingTransform(viewport: CGSize) -> (SIMD2<Float>, SIMD2<Float>) {
        guard textureSize.width > 0, textureSize.height > 0,
              viewport.width > 0, viewport.height > 0 else {
            return (.init(1, 1), .zero)
        }
        let imageAspect = textureSize.width / textureSize.height
        let viewAspect = viewport.width / viewport.height

        // Fit: the whole frame visible, letterboxed on the shorter axis.
        var sx = 1.0, sy = 1.0
        if viewAspect > imageAspect { sx = viewAspect / imageAspect } else { sy = imageAspect / viewAspect }

        let z = fitToWindow ? 1.0 : max(zoom / fitScale(viewport: viewport), 0.01)
        sx /= z; sy /= z

        // Centre, then pan — but only along an axis the image actually
        // overflows. `sx < 1` means the sampled window is narrower than the
        // image, i.e. there is something off-screen to pan to.
        var ox = (1.0 - sx) / 2.0
        var oy = (1.0 - sy) / 2.0
        if sx < 1.0 { ox = (ox + pan.x).clamped(to: 0...(1.0 - sx)) }
        if sy < 1.0 { oy = (oy + pan.y).clamped(to: 0...(1.0 - sy)) }
        return (.init(Float(sx), Float(sy)), .init(Float(ox), Float(oy)))
    }

    /// Screen pixels per image pixel when the frame is fitted. `zoom` is
    /// expressed as an absolute magnification (1.0 == 100% == one image pixel
    /// per point) so the toolbar can show a number that means something,
    /// rather than a multiplier off an arbitrary fit.
    func fitScale(viewport: CGSize) -> Double {
        guard textureSize.width > 0, textureSize.height > 0 else { return 1 }
        return min(viewport.width / textureSize.width, viewport.height / textureSize.height)
    }

    /// True when the canvas is magnifying past the resident buffer's own
    /// resolution — there is no more data up there, so the badge says `soft`.
    func isSoft(viewport: CGSize) -> Bool {
        guard !fitToWindow, textureSize.width > 0 else { return false }
        return zoom > 1.001
    }
}
