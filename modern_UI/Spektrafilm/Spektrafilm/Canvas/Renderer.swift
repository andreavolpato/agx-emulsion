//  Renderer.swift — owns the Metal state for the canvas and the offscreen
//  Layer 2 pass used by export.
//
//  Draw-on-demand: the MTKView is paused and `needsDisplay` is set on state
//  change (UI-GUIDELINE §4). Each draw: (1) if Layer 2 or its input changed,
//  run the `layer2` kernel into `adjusted` and the `histogram` kernel over it;
//  (2) blit `adjusted` (or the original, while Space is held) to the drawable
//  through the sampling transform. The histogram buffer is read back on the
//  command buffer's completion and published on the main actor.

import Foundation
import Metal
import MetalKit
import QuartzCore

struct CanvasUniforms {
    var viewportSize = SIMD2<Float>(1, 1)
    /// The **output** size in logical pixels — the crop's size, not the
    /// texture's. Everything the viewport measures is in these units.
    var imageSize = SIMD2<Float>(1, 1)
    var offset = SIMD2<Float>(0, 0)
    /// Device pixels per output logical pixel.
    var scale: Float = 1
    var surroundGray: Float = 0x5F / 255.0
    /// Device pixels per *source texture* pixel. With a crop applied this is
    /// no longer `scale`, and it is the one the sampler choice is made on.
    var magnification: Float = 1
    var geometry = Geometry.Uniform()
    var editingCrop: UInt32 = 0
    var checker: UInt32 = 0
}

@MainActor
final class Renderer: NSObject {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let store: TextureStore
    private let layer2Pipeline: MTLComputePipelineState
    private let histogramPipeline: MTLComputePipelineState
    private let geometryPipeline: MTLComputePipelineState
    private let quadPipelineDrawable: MTLRenderPipelineState
    private let quadPipelineOffscreen: MTLRenderPipelineState
    private let curveTable: MTLTexture
    private let histogramBuffer: MTLBuffer
    private var histogramInFlight = false

    /// The interactive, live-tier image: the print if there is one, else the
    /// decode preview. This is what the canvas shows at fit and while zoomed
    /// out, and it is the texture the service's ~0.4 s reprints replace.
    private(set) var live: MTLTexture?
    /// A higher-resolution print of the same frame, rendered on demand when
    /// the zoom passes the live tier's native resolution
    /// (frontend SPEC §5.0). Kept separate from `live` so zooming back out is
    /// instant and needs no render.
    private(set) var detail: MTLTexture?
    /// Whether `detail` is the image on screen. False at fit, true while
    /// zoomed past the threshold — or true with a stale detail still shown
    /// while a sharper one renders.
    private(set) var showsDetail = false
    /// The image the viewport is expressed against: the live tier's pixel
    /// size, fixed per frame. A resolution swap must not move the view, so
    /// `scale` stays points-per-live-pixel and the draw multiplies it by the
    /// texture's own ratio (see `canvasUniforms`).
    var logicalImageSize: CGSize? {
        viewport.image == CGSize(width: 1, height: 1) ? nil : viewport.image
    }
    /// What the canvas draws: the detail print when one is shown, else the
    /// live print or decode preview.
    var base: MTLTexture? { showsDetail ? (detail ?? live) : live }
    /// Shown instead of the adjusted image while Space is held.
    var original: MTLTexture?
    private var adjusted: MTLTexture?
    private var layer2Dirty = true

    var viewport = ViewportState()
    var showOriginal = false { didSet { if oldValue != showOriginal { needsDraw?() } } }
    /// Crop, straighten, quarter turns and flips. Applied to what the canvas
    /// draws, not only to what export writes — the two disagreeing is what
    /// made the old crop a lie past the canvas edge.
    var geometry = Geometry.default {
        didSet {
            guard oldValue != geometry else { return }
            layer2Dirty = true
            // While the crop tool is up the view stays on the whole frame, so
            // a drag does not make the picture jump under the handles. The
            // refit happens once, on leaving the tool.
            if !editingCrop { refreshLogicalSize() }
            needsDraw?()
        }
    }
    /// True while the crop tool is active: the canvas then shows the whole
    /// frame with the area outside the crop dimmed, rather than the cropped
    /// result. Capture One's behaviour, and the only way to judge a crop.
    var editingCrop = false {
        didSet {
            guard oldValue != editingCrop else { return }
            layer2Dirty = true
            refreshLogicalSize()
            needsDraw?()
        }
    }
    /// The live tier's pixel size — what the geometry is normalised against,
    /// and what `logicalSize(forSource:)` turns into the viewport's units.
    private(set) var sourceSize: CGSize?
    var layer2 = Layer2Uniforms() { didSet { layer2Dirty = true } }
    var onHistogram: (@MainActor ([Float]) -> Void)?
    var needsDraw: (@MainActor () -> Void)?
    /// Fired whenever the renderer itself moves the viewport — which
    /// `setLive` does when it takes a new frame's logical size, because a new
    /// image is fitted. Without it the zoom readout keeps whatever it computed
    /// against the *previous* image; with no image that is a 1×1 placeholder,
    /// and the pill read "Fit · 158,000 %".
    var onViewportChanged: (@MainActor () -> Void)?
    /// Incremented on every completed `draw(in:)`. The canvas cannot be seen
    /// by an offscreen test, but *whether it drew* can be, and that is the
    /// half that broke.
    private(set) var drawCount = 0

    /// The **drawable** format. `CAMetalLayer` accepts only a short list —
    /// bgra8Unorm(_srgb), rgba16Float, rgb10a2Unorm, bgr10a2Unorm and the xr
    /// variants — and setting anything else raises
    /// `CAMetalLayerInvalid: invalid pixel format`. `rgba16Unorm` (110) is a
    /// perfectly good *texture* format and is not on that list; it crashed the
    /// app on the first real launch. Float16 also matches UI-GUIDELINE §4.
    ///
    /// This does not change the colour rule: the layer's colour space is
    /// Display P3 and the values written are already P3-encoded, so ColorSync
    /// still performs exactly one transform. Float storage is not linear
    /// storage — the numbers are unchanged, only their container is.
    static let drawableFormat: MTLPixelFormat = .rgba16Float
    /// The **offscreen** format, for snapshots and export: 16-bit unorm, so
    /// `makeCGImage()` can hand the bytes to ImageIO without a conversion.
    static let offscreenFormat: MTLPixelFormat = .rgba16Unorm

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.store = TextureStore(device: device)
        guard let lib = try? device.makeDefaultLibrary(bundle: Bundle(for: Renderer.self)),
              let l2 = lib.makeFunction(name: "layer2"),
              let hist = lib.makeFunction(name: "histogram"),
              let geo = lib.makeFunction(name: "geometryResample"),
              let vs = lib.makeFunction(name: "canvasVertex"),
              let fs = lib.makeFunction(name: "canvasFragment") else { return nil }
        do {
            layer2Pipeline = try device.makeComputePipelineState(function: l2)
            histogramPipeline = try device.makeComputePipelineState(function: hist)
            geometryPipeline = try device.makeComputePipelineState(function: geo)
            let rd = MTLRenderPipelineDescriptor()
            rd.vertexFunction = vs
            rd.fragmentFunction = fs
            rd.colorAttachments[0].pixelFormat = Renderer.drawableFormat
            quadPipelineDrawable = try device.makeRenderPipelineState(descriptor: rd)
            rd.colorAttachments[0].pixelFormat = Renderer.offscreenFormat
            quadPipelineOffscreen = try device.makeRenderPipelineState(descriptor: rd)
        } catch { return nil }
        guard let ct = store.makeCurveTable(),
              let hb = device.makeBuffer(length: 4 * 256 * 4, options: .storageModeShared) else { return nil }
        curveTable = ct
        histogramBuffer = hb
        super.init()
        store.upload(curves: CurveSet(), into: curveTable)
    }

    // MARK: inputs

    func setLive(_ texture: MTLTexture?, logical: CGSize? = nil) {
        log("setLive \(texture.map { "\($0.width)x\($0.height)" } ?? "nil"), needsDraw=\(needsDraw != nil)")
        live = texture
        if texture == nil { showsDetail = false; sourceSize = nil }
        layer2Dirty = true
        // `logical` is the live tier's source size, fixed per frame. The
        // first image of a frame passes it (and refits); later live prints
        // and every detail swap pass nil so the view does not move.
        if let logical { sourceSize = logical }
        else if sourceSize == nil, let texture { sourceSize = CGSize(width: texture.width, height: texture.height) }
        refreshLogicalSize()
        needsDraw?()
    }

    /// Re-express the viewport against whatever the output currently is — the
    /// whole frame while cropping, the crop's own size otherwise — and refit
    /// if that changed. `ViewportState.resize` fits on an image-size change,
    /// which is what makes leaving the crop tool land on the crop.
    func refreshLogicalSize() {
        guard let sourceSize else { return }
        let target = logicalSize(forSource: sourceSize)
        guard target != viewport.image else { return }
        viewport.resize(viewport: viewport.viewport, image: target)
        onViewportChanged?()
    }

    /// Put a higher-resolution render of the current frame on screen. The
    /// viewport is unchanged: the draw scales the texture to the same
    /// on-screen rectangle.
    func setDetail(_ texture: MTLTexture?) {
        detail = texture
        showsDetail = texture != nil
        layer2Dirty = true
        needsDraw?()
    }

    /// Show the live tier again without discarding the detail texture, so
    /// zooming back in is instant.
    func hideDetail() {
        guard showsDetail else { return }
        showsDetail = false
        layer2Dirty = true
        needsDraw?()
    }

    /// Discard the detail texture. Used when it can no longer be trusted:
    /// the parameters changed, or another frame is selected.
    func dropDetail() {
        guard detail != nil || showsDetail else { return }
        detail = nil
        showsDetail = false
        layer2Dirty = true
        needsDraw?()
    }

    func setCurves(_ curves: CurveSet) {
        store.upload(curves: curves, into: curveTable)
        layer2Dirty = true
        needsDraw?()
    }

    var imageSize: CGSize? { base.map { CGSize(width: $0.width, height: $0.height) } }

    // MARK: Layer 2

    private func ensureAdjusted(for src: MTLTexture) -> MTLTexture? {
        if let a = adjusted, a.width == src.width, a.height == src.height { return a }
        adjusted = store.makeWritable(width: src.width, height: src.height)
        return adjusted
    }

    private func encodeLayer2(_ cb: MTLCommandBuffer, src: MTLTexture, dst: MTLTexture) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(layer2Pipeline)
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        enc.setTexture(curveTable, index: 2)
        var u = layer2
        enc.setBytes(&u, length: MemoryLayout<Layer2Uniforms>.stride, index: 0)
        let w = layer2Pipeline.threadExecutionWidth
        let h = max(1, layer2Pipeline.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
    }

    private func encodeHistogram(_ cb: MTLCommandBuffer, src: MTLTexture) {
        guard let blit = cb.makeBlitCommandEncoder() else { return }
        blit.fill(buffer: histogramBuffer, range: 0..<histogramBuffer.length, value: 0)
        blit.endEncoding()
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(histogramPipeline)
        enc.setTexture(src, index: 0)
        enc.setBuffer(histogramBuffer, offset: 0, index: 0)
        var stride = UInt32(max(1, Int((Double(src.width * src.height) / 200_000).squareRoot())))
        enc.setBytes(&stride, length: 4, index: 1)
        let gw = (src.width + Int(stride) - 1) / Int(stride), gh = (src.height + Int(stride) - 1) / Int(stride)
        let w = histogramPipeline.threadExecutionWidth
        let h = max(1, histogramPipeline.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: gw, height: gh, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
    }

    private func publishHistogram() {
        let p = histogramBuffer.contents().bindMemory(to: UInt32.self, capacity: 1024)
        var bins = [Float](repeating: 0, count: 1024)
        var maxv: Float = 1
        for i in 0..<1024 {
            let v = Float(p[i])
            bins[i] = v
            // Ignore the extreme bins for scaling: clipped black/white dominate.
            if i % 256 > 1 && i % 256 < 254 { maxv = max(maxv, v) }
        }
        for i in 0..<1024 { bins[i] = min(1, bins[i] / maxv) }
        onHistogram?(bins)
    }

    // MARK: drawing

    /// `SPEKTRAFILM_CANVAS_LOG=1` prints one line per draw. The canvas is the
    /// one surface no offscreen test can see (a `CAMetalLayer` renders nothing
    /// into `cacheDisplay`), so when it is blank this is how you find out
    /// which of the three possible reasons it is: no drawable, no base
    /// texture, or a base that never reached the encoder.
    static let logDraws = ProcessInfo.processInfo.environment["SPEKTRAFILM_CANVAS_LOG"] == "1"

    private func log(_ message: @autoclosure () -> String) {
        guard Renderer.logDraws else { return }
        FileHandle.standardError.write(Data("canvas: \(message())\n".utf8))
    }

    /// The canvas uniforms for one draw. `shown` may be the live texture or a
    /// detail texture several times its size; the viewport is always in live
    /// pixels, so the texture scale is the viewport's scale times the ratio
    /// of logical to texture pixels. Without that ratio a 5504 px detail
    /// render would draw 5.2× too large — which is exactly what the first
    /// capture of this path showed: a black canvas, because only a corner of
    /// the magnified image was on screen.
    private func canvasUniforms(shown: MTLTexture?, viewportSize: CGSize, backingScale: CGFloat) -> CanvasUniforms {
        var u = CanvasUniforms()
        u.viewportSize = SIMD2(Float(viewportSize.width), Float(viewportSize.height))
        guard let shown else { return u }
        // The viewport is in *output* logical pixels, so the sampling
        // transform is now the identity on them and the shader does the rest
        // in normalised space. That is what retires the old
        // logical-over-texture ratio: a 5504 px detail texture and a 1600 px
        // live one already occupy the same rectangle because they are both
        // sampled by uv, not by pixel.
        let output = max(viewport.image.width, 1)
        u.imageSize = SIMD2(Float(viewport.image.width), Float(viewport.image.height))
        u.offset = SIMD2(Float(viewport.offset.x * backingScale), Float(viewport.offset.y * backingScale))
        u.scale = Float(viewport.scale * backingScale)
        // Source texture pixels actually spanned by the output, so the
        // sampler choice survives both the detail-tier swap and the crop.
        let spanned = editingCrop ? CGFloat(shown.width) : CGFloat(shown.width) * geometry.crop.width
        u.magnification = Float(viewport.scale * backingScale * output / max(spanned, 1))
        u.geometry = geometry.uniform(for: CGSize(width: shown.width, height: shown.height))
        u.editingCrop = editingCrop ? 1 : 0
        return u
    }

    /// The size the viewport should be expressed against for a given source:
    /// the whole frame while the crop is being edited, the crop's output
    /// otherwise. Fit and zoom then mean what they say in both states.
    func logicalSize(forSource size: CGSize) -> CGSize {
        editingCrop ? size : geometry.outputSize(for: size)
    }

    func draw(in view: MTKView) {
        // Counted here, before the drawable guard: the question a test needs
        // answered is whether the invalidation reached the delegate at all.
        // An off-screen window legitimately vends no drawable.
        drawCount += 1
        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer() else {
            log("no drawable (size \(view.drawableSize), window \(view.window != nil))")
            return
        }
        var shown: MTLTexture? = nil
        if let base {
            if showOriginal, let original { shown = original }
            else if let dst = ensureAdjusted(for: base) {
                if layer2Dirty {
                    encodeLayer2(cb, src: base, dst: dst)
                    layer2Dirty = false
                    if !histogramInFlight {
                        histogramInFlight = true
                        encodeHistogram(cb, src: dst)
                        cb.addCompletedHandler { [weak self] _ in
                            Task { @MainActor in
                                self?.histogramInFlight = false
                                self?.publishHistogram()
                            }
                        }
                    }
                }
                shown = dst
            }
        }
        let bs = Float(view.window?.backingScaleFactor ?? viewport.backingScale)
        var u = canvasUniforms(shown: shown, viewportSize: view.drawableSize, backingScale: CGFloat(bs))
        log("base=\(base.map { "\($0.width)x\($0.height)" } ?? "nil") shown=\(shown != nil) " +
            "detail=\(showsDetail) scale=\(viewport.scale) offset=\(viewport.offset) drawable=\(view.drawableSize)")
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: Double(u.surroundGray), green: Double(u.surroundGray), blue: Double(u.surroundGray), alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        if let shown {
            enc.setRenderPipelineState(quadPipelineDrawable)
            enc.setFragmentTexture(shown, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    // MARK: offscreen (export, snapshot, tests)

    /// Run Layer 2 over any texture synchronously. Used by export at full
    /// resolution and by the tests.
    func applyLayer2(to src: MTLTexture, uniforms: Layer2Uniforms? = nil) -> MTLTexture? {
        guard let dst = store.makeWritable(width: src.width, height: src.height),
              let cb = queue.makeCommandBuffer() else { return nil }
        let saved = layer2
        if let uniforms { layer2 = uniforms }
        encodeLayer2(cb, src: src, dst: dst)
        layer2 = saved
        cb.commit()
        cb.waitUntilCompleted()
        return dst
    }

    /// Apply crop, straighten, quarter turns and flips to a texture at its
    /// own resolution, through the same `geometryMap` the canvas draws with.
    /// Export calls this; nothing else needs to, because the canvas applies
    /// the geometry while sampling rather than by making a second texture.
    func applyGeometry(_ g: Geometry, to src: MTLTexture) -> MTLTexture? {
        guard !g.isIdentity else { return src }
        let srcSize = CGSize(width: src.width, height: src.height)
        let out = g.outputSize(for: srcSize)
        let w = Int(out.width), h = Int(out.height)
        guard w > 0, h > 0,
              let dst = store.makeWritable(width: w, height: h),
              let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        var u = g.uniform(for: srcSize)
        enc.setComputePipelineState(geometryPipeline)
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        enc.setBytes(&u, length: MemoryLayout<Geometry.Uniform>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1),
                                 threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return dst
    }

    /// Render the canvas exactly as the window would show it, into an image.
    /// The snapshot harness uses this for the centre of the window.
    func renderOffscreen(size: CGSize, backingScale: CGFloat) -> MTLTexture? {
        let w = Int(size.width * backingScale), h = Int(size.height * backingScale)
        guard w > 0, h > 0, let target = store.makeWritable(width: w, height: h, format: Renderer.offscreenFormat),
              let cb = queue.makeCommandBuffer() else { return nil }
        var shown: MTLTexture? = nil
        if let base, let dst = ensureAdjusted(for: base) {
            encodeLayer2(cb, src: base, dst: dst)
            layer2Dirty = false
            encodeHistogram(cb, src: dst)
            shown = dst
        }
        var u = canvasUniforms(shown: shown, viewportSize: CGSize(width: w, height: h), backingScale: backingScale)
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: Double(u.surroundGray), green: Double(u.surroundGray), blue: Double(u.surroundGray), alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        if let shown {
            enc.setRenderPipelineState(quadPipelineOffscreen)
            enc.setFragmentTexture(shown, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if shown != nil { publishHistogram() }
        return target
    }
}

extension MTLTexture {
    /// Read an rgba16Unorm texture back as a CGImage in Display P3 (no
    /// conversion — the bytes are P3-encoded already; the tag says so).
    func makeCGImage() -> CGImage? {
        guard pixelFormat == .rgba16Unorm else { return nil }
        let bpr = width * 8
        var data = Data(count: bpr * height)
        data.withUnsafeMutableBytes { raw in
            getBytes(raw.baseAddress!, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: bpr,
                       space: ImageDecoder.displayP3,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Raw 16-bit RGBA bytes, top row first.
    func rgba16Bytes() -> Data {
        let bpr = width * 8
        var data = Data(count: bpr * height)
        data.withUnsafeMutableBytes { raw in
            getBytes(raw.baseAddress!, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return data
    }
}
