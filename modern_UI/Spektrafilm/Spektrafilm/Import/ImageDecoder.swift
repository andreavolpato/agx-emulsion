//  ImageDecoder.swift — RAW and flat-file decode through Core Image: one
//  decode for the engine, one for the eye, and the frame the engine is handed.
//
//  Why the client decodes at all: the engine's own RAW path is LibRaw with
//  dcraw's generic camera matrix (HANDOFF-CAMERA-MATRIX §1). Apple's RAW
//  engine is the product decode (HANDOFF-DECODE-AB §3): it is native, supports
//  ProRAW, and — the actual reason — white balance becomes a client decision
//  with a real UI (temperature, tint, pick-neutral) instead of a hardcoded
//  `as_shot`.
//
//  **A RAW is decoded twice, and the two must not be confused.**
//
//  - `linear` is what the engine develops: every stage of Apple's tone
//    rendering switched off, so the film model receives sensor response. Those
//    settings are not tuning. It reaches the engine as float32 linear ProPhoto
//    RGB (`engineFrame`), rendered straight into a buffer the engine borrows.
//  - `display` is what the canvas shows as the *original* — before a develop,
//    under Space, and on the left of the before/after split: Apple's default
//    rendering, the picture a RAW viewer would show. It never reaches the
//    engine.
//
//  They differ in *look* only. Geometry is the same in both — lens correction
//  off, same orientation, same scale — because the split samples the two
//  through one crop and has to line up pixel for pixel. Apple's default turns
//  lens correction on where the camera supports it (the Z7 II does), and that
//  keeps the extent while moving everything inside it: a "default" original
//  would be the right size and quietly misregistered against the print.
//  White balance follows the user's in both, so the comparison is the film,
//  not the neutral point.
//
//  Two measured facts from the previous session that this file preserves:
//   - `CIContext.render` into a Metal texture needs `.shaderWrite` in the
//     usage or it silently writes nothing (see `makePreviewTexture`).
//   - Do NOT `matchedToWorkingSpace` the RAW output: with boostAmount = 0 the
//     values are already scene-linear; the remap darkened by ~45 %.

import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Metal
import UniformTypeIdentifiers

struct DecodedImage: @unchecked Sendable {
    /// What the engine develops: scene-linear, Apple's tone rendering off.
    /// The only image `engineFrame` and the neutral picker read.
    let linear: CIImage
    /// What the canvas shows as the original: Apple's default rendering of the
    /// same frame, same geometry. For a flat file the two are one image.
    let display: CIImage
    let pixelSize: CGSize
    let isRAW: Bool
    let sourceURL: URL
    /// As-shot values reported by the RAW filter (nil for flat files).
    let asShotTemperature: Double?
    let asShotTint: Double?
    var megapixels: Double { pixelSize.width * pixelSize.height / 1e6 }
}

/// One frame in the engine's input format — tightly packed float32 RGBA,
/// linear ProPhoto, top row first — in a shared `MTLBuffer` on the engine's
/// device. `spk_open_device` borrows it for the length of the call and keeps
/// nothing, so this can be dropped the moment `open` returns; at 45 MP it is
/// 727 MB, and holding it through the solve and the first render would be
/// the peak-memory regression this type exists to avoid.
///
/// `@unchecked Sendable` because `MTLBuffer` is not `Sendable` and a buffer is
/// exactly what this carries — the same compromise `RenderOutcome` makes. It
/// is written once, by `ImageDecoder.engineFrame`, before it crosses anything.
struct EngineFrame: @unchecked Sendable {
    let buffer: MTLBuffer
    let width: Int
    let height: Int
    let channels: Int
}

enum ImageDecoder {
    static let rawExtensions: Set<String> =
        ["nef", "arw", "dng", "cr2", "cr3", "raf", "rw2", "orf", "pef", "srw", "3fr", "iiq"]
    static let flatExtensions: Set<String> = ["tif", "tiff", "png", "jpg", "jpeg", "heic", "exr"]
    static var openable: Set<String> { rawExtensions.union(flatExtensions) }

    enum Failure: Error, LocalizedError {
        case unsupported(URL), rawFilterUnavailable(URL), noColorSpace, emptyFrame, noFrameBuffer(Int)
        var errorDescription: String? {
            switch self {
            case .unsupported(let u): "cannot decode \(u.lastPathComponent)"
            case .rawFilterUnavailable(let u): "no RAW decoder for \(u.lastPathComponent)"
            case .noColorSpace: "could not construct the working colour space"
            case .emptyFrame: "the decoded frame has no pixels"
            case .noFrameBuffer(let bytes): "could not allocate \(bytes / 1_000_000) MB for the frame"
            }
        }
    }

    /// Linear ProPhoto RGB, constructed: Core Graphics ships ROMM at gamma
    /// 1.8 and linear variants of sRGB/P3, but no linear ROMM. Published
    /// ROMM primaries against D50, column-major as `CGColorSpace` wants.
    nonisolated(unsafe) static let linearProPhoto: CGColorSpace? = {
        let d50: [CGFloat] = [0.9642, 1.0000, 0.8249]
        let black: [CGFloat] = [0, 0, 0]
        let gamma: [CGFloat] = [1, 1, 1]
        let primaries: [CGFloat] = [
            0.7976749, 0.2880402, 0.0000000,
            0.1351917, 0.7118741, 0.0000000,
            0.0313534, 0.0000857, 0.8252100,
        ]
        return d50.withUnsafeBufferPointer { wp in
            black.withUnsafeBufferPointer { bp in
                gamma.withUnsafeBufferPointer { gp in
                    primaries.withUnsafeBufferPointer { mp in
                        CGColorSpace(calibratedRGBWhitePoint: wp.baseAddress!, blackPoint: bp.baseAddress,
                                     gamma: gp.baseAddress!, matrix: mp.baseAddress)
                    }
                }
            }
        }
    }()

    nonisolated(unsafe) static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    nonisolated(unsafe) static let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    /// One context for the whole app: Core Image contexts are expensive and
    /// cache compiled kernels.
    nonisolated(unsafe) static let context: CIContext = {
        let device = MTLCreateSystemDefaultDevice()!
        return CIContext(mtlDevice: device, options: [
            .workingColorSpace: linearP3,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            .highQualityDownsample: true,
        ])
    }()

    // MARK: decode

    static func decode(_ url: URL, settings: DecodeSettings) throws -> DecodedImage {
        rawExtensions.contains(url.pathExtension.lowercased())
            ? try decodeRAW(url, settings: settings)
            : try decodeFlat(url)
    }

    /// Which of the two RAW decodes a filter is for. See the file header.
    enum RAWLook { case linear, display }

    /// A `CIRAWFilter` configured for one of the two decodes. Separate
    /// instances, not one filter read twice: a filter is mutable, and a decode
    /// whose settings could change under an image already handed out is the
    /// kind of sharing this split exists to rule out.
    static func rawFilter(_ url: URL, look: RAWLook, settings: DecodeSettings) throws -> CIRAWFilter {
        guard let filter = CIRAWFilter(imageURL: url) else { throw Failure.rawFilterUnavailable(url) }
        // Geometry: identical in both, or the before/after split compares two
        // registrations of the frame rather than two renderings of it.
        filter.isLensCorrectionEnabled = false
        filter.isDraftModeEnabled = false
        if look == .linear {
            // Apple's tone rendering, off: the film model wants sensor response.
            filter.boostAmount = 0
            filter.boostShadowAmount = 0
            filter.isGamutMappingEnabled = false
            filter.localToneMapAmount = 0
            filter.extendedDynamicRangeAmount = 0
        }
        switch settings.whiteBalance {
        case .asShot: break
        default:
            filter.neutralTemperature = Float(settings.temperature)
            filter.neutralTint = Float(settings.tint)
        }
        return filter
    }

    private static func decodeRAW(_ url: URL, settings: DecodeSettings) throws -> DecodedImage {
        // As-shot is read from a filter nobody has set a white balance on.
        guard let probe = CIRAWFilter(imageURL: url) else { throw Failure.rawFilterUnavailable(url) }
        let asShotT = Double(probe.neutralTemperature), asShotTint = Double(probe.neutralTint)
        guard let linear = try rawFilter(url, look: .linear, settings: settings).outputImage,
              let display = try rawFilter(url, look: .display, settings: settings).outputImage
        else { throw Failure.unsupported(url) }
        return DecodedImage(linear: linear, display: display, pixelSize: linear.extent.size,
                            isRAW: true, sourceURL: url,
                            asShotTemperature: asShotT, asShotTint: asShotTint)
    }

    private static func decodeFlat(_ url: URL) throws -> DecodedImage {
        guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw Failure.unsupported(url)
        }
        // Untagged files: Core Image assumes sRGB for 8-bit, which matches
        // the service's own default; float/16-bit untagged TIFFs are the
        // engine's linear ProPhoto convention.
        var image = ci
        if ci.colorSpace == nil, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let isFloat = props[kCGImagePropertyIsFloat] as? Bool ?? false
            let depth = props[kCGImagePropertyDepth] as? Int ?? 8
            if (isFloat || depth >= 16), let pp = linearProPhoto {
                image = ci.matchedToWorkingSpace(from: pp) ?? ci
            }
        }
        // A flat file is already a rendering: there is no second look to take.
        return DecodedImage(linear: image, display: image, pixelSize: image.extent.size,
                            isRAW: false, sourceURL: url, asShotTemperature: nil, asShotTint: nil)
    }

    // MARK: the engine's frame

    /// The frame the engine develops: `decoded.linear` rendered at full
    /// resolution into float32 RGBA **linear ProPhoto**, top row first, in a
    /// shared `MTLBuffer` on `device` that `spk_open_device` borrows.
    ///
    /// This replaces a round trip through a file. The decode used to be
    /// written to a 364 MB half-float TIFF and read back by the same process:
    /// 6.4–7.1 s at 45 MP, against **~230 ms** for this render, measured one
    /// variant per fresh process (HANDOFF-OPEN-PATH §3.4's rule). The file was
    /// also the *less* faithful path — a half-float quantization and a
    /// ProPhoto → P3 → ProPhoto trip — by up to 5.9e-4.
    ///
    /// Three details are load-bearing:
    ///
    /// - **`toBitmap`, into the buffer's own memory.** Rendering here is
    ///   bit-identical to rendering into a `[Float]` (1.4 M samples, 0 Δ) and
    ///   costs the engine no copy. Core Image's `render(_:to:)` into an
    ///   `MTLTexture` over the same buffer is ~40 ms faster and *not*
    ///   identical (2.5e-4), and it needs a vertical flip — which is how this
    ///   app once developed a correct, upside-down photograph (below).
    /// - **No vertical flip.** `render(_:toBitmap:...)` writes top row first,
    ///   unlike `render(_:to:)` into a texture (`makePreviewTexture` needs
    ///   one). Adding a flip on the strength of "Core Image's origin is
    ///   bottom-left" produced an upside-down print that survived a 27-case
    ///   parity suite, because that suite hands the engine an array and never
    ///   comes through here. `testTheEngineFrameIsTopRowFirst` pins it.
    /// - **Linear ProPhoto is requested as the destination**, the space
    ///   `io.input_color_space` names. Asking for the working space instead
    ///   would apply a conversion the engine then applies again.
    ///
    /// Four channels because `.RGBAf` is the only float format Core Image
    /// renders; the engine drops the alpha on the GPU (`spk_take_rgb`, which
    /// is also the copy that ends the borrow).
    static func engineFrame(from decoded: DecodedImage, device: MTLDevice) throws -> EngineFrame {
        try engineFrame(from: decoded.linear, device: device)
    }

    static func engineFrame(from image: CIImage, device: MTLDevice) throws -> EngineFrame {
        guard let space = linearProPhoto else { throw Failure.noColorSpace }
        // Checked before the `Int` conversion, which traps on infinity.
        guard !image.extent.isInfinite, !image.extent.isEmpty else { throw Failure.emptyFrame }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        let placed = image.transformed(by: .init(translationX: -extent.origin.x, y: -extent.origin.y))
        guard let buffer = device.makeBuffer(length: width * height * 16, options: .storageModeShared) else {
            throw Failure.noFrameBuffer(width * height * 16)
        }
        // In a pool of its own, because `contents()` returns an inner pointer
        // and the call *autoreleases the buffer* to keep it valid — so without
        // this the 727 MB frame outlives every owner that drops it, until
        // whatever pool the calling thread drains next. The engine keeps
        // nothing (`testTheEngineKeepsNothingOfTheCallersBuffer` saw the buffer
        // alive after `open`, and this was the only holder).
        autoreleasepool {
            context.render(placed, toBitmap: buffer.contents(), rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: space)
        }
        return EngineFrame(buffer: buffer, width: width, height: height, channels: 4)
    }

    // MARK: display preview

    /// Render the *display* decode into a Display P3 texture for the canvas:
    /// the picture shown before a develop, and the original the split and
    /// Space compare the print against. Never the engine's input.
    static func makePreviewTexture(_ decoded: DecodedImage, device: MTLDevice, maxEdge: Int) -> MTLTexture? {
        let extent = decoded.display.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1.0, Double(maxEdge) / Double(max(extent.width, extent.height)))
        var scaled = scale < 1 ? decoded.display.transformed(by: .init(scaleX: scale, y: scale)) : decoded.display
        scaled = scaled.transformed(by: .init(translationX: -scaled.extent.origin.x, y: -scaled.extent.origin.y))
        let target = scaled.extent.integral
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm,
                                                          width: Int(target.width), height: Int(target.height), mipmapped: false)
        d.usage = [.shaderRead, .renderTarget, .shaderWrite]   // .shaderWrite is load-bearing
        d.storageMode = .private
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        guard let queue = device.makeCommandQueue(), let cb = queue.makeCommandBuffer() else { return nil }
        // Core Image's origin is bottom-left; Metal's is top-left. Render with
        // a vertical flip so the texture's row 0 is the image's top row —
        // the canvas shader samples with (0,0) at the top.
        let flipped = scaled.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -target.height))
        context.render(flipped, to: tex, commandBuffer: cb,
                       bounds: CGRect(origin: .zero, size: target.size), colorSpace: displayP3)
        cb.commit()
        cb.waitUntilCompleted()
        return tex
    }

    /// Value at a point (0…1 normalised, top-left origin) of the *linear*
    /// decode — working-space RGB, sensor response. Used by the neutral
    /// picker, which needs the scene's values, not Apple's rendering of them.
    static func sampleLinear(_ decoded: DecodedImage, at p: CGPoint, radius: Int = 4) -> SIMD3<Double>? {
        let e = decoded.linear.extent
        let x = e.origin.x + p.x.clamped(to: 0...1) * e.width
        let y = e.origin.y + (1 - p.y.clamped(to: 0...1)) * e.height
        let r = CGFloat(radius)
        let rect = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r).intersection(e)
        guard !rect.isEmpty else { return nil }
        let avg = CIFilter.areaAverage()
        avg.inputImage = decoded.linear
        avg.extent = rect
        guard let out = avg.outputImage else { return nil }
        var px = [Float](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: linearP3)
        return SIMD3(Double(px[0]), Double(px[1]), Double(px[2]))
    }

    /// The RAW filter's own estimate of temperature/tint that makes `p` neutral.
    static func neutral(at p: CGPoint, in url: URL) -> (temperature: Double, tint: Double)? {
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        let e = f.outputImage?.extent ?? .zero
        f.neutralLocation = CGPoint(x: e.origin.x + p.x * e.width, y: e.origin.y + (1 - p.y) * e.height)
        return (Double(f.neutralTemperature), Double(f.neutralTint))
    }
}
