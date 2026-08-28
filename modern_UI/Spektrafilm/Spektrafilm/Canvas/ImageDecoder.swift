//  ImageDecoder.swift — RAW and flat-file decode, in-app.
//
//  Decoding in-app is what makes colorimetry controllable (frontend SPEC
//  §2.4). The alternative — accepting whatever a vendor pipeline produced —
//  means the film model receives data that has already been tone-mapped, and
//  the physical-accuracy claim quietly stops holding.
//
//  ## What the engine asks for
//
//  Linear scene-referred, ProPhoto RGB, colorimetric. The engine's README
//  states this directly, and the author's own manual workflow (darktable with
//  filmic/sigmoid disabled, exported as 32-bit float linear ProPhoto TIFF) is
//  the recommended path, not a degraded one. Producing the same artifact from
//  Core Image is therefore in-contract, not a shortcut.
//
//  ## The four settings that are not optional
//
//  `CIRAWFilter` defaults to Apple's *pleasing* rendering. Frontend SPEC §2.5
//  lists what must be turned off, and each one is a tone or gamut decision
//  being made before the film model ever sees the data:
//
//      boostAmount = 0            no tone curve
//      boostShadowAmount = 0      no shadow lift
//      isGamutMappingEnabled = false
//      isDraftModeEnabled = false
//
//  Leave any of them at its default and the model runs over an image that has
//  already been rendered. It will still look fine, which is the problem.
//
//  ## Two decoders that do not agree
//
//  The Python service decodes RAW through rawpy/LibRaw (`raw_engine: "dcraw"`
//  in `open`'s response). This decodes through Core Image. Different
//  demosaic, different camera matrices, different highlight recovery — SPEC
//  §2.5 is explicit that switching changes the output and invalidates any
//  solve calibration. So `DecodedImage.decoder` is recorded and shown, and
//  the sidecar must persist it: reopening old work after a decoder change
//  would otherwise silently alter every image.
//
//  **This client-side decode is for display and inspection only.** The
//  service decodes the file itself when `open` is called. Nothing here is
//  sent to the engine, so the two never disagree *within* one render — they
//  disagree between what the canvas showed before `open` and what came back
//  after, which is exactly the thing the badge in the inspector is for.

import CoreImage
import ImageIO
import Metal
import UniformTypeIdentifiers

struct DecodedImage: @unchecked Sendable {
    let image: CIImage
    let pixelSize: CGSize
    let decoder: Decoder
    /// The colour space the pixels are in *as decoded*, before any display
    /// conversion. Reported, never assumed.
    let workingSpace: CGColorSpace
    let isLinear: Bool
    let sourceURL: URL

    enum Decoder: String, Sendable {
        case coreImageRAW = "coreimage"
        case imageIO = "imageio"

        var label: String {
            switch self {
            case .coreImageRAW: "Core Image (CIRAWFilter)"
            case .imageIO: "ImageIO"
            }
        }
    }

    var megapixels: Double { pixelSize.width * pixelSize.height / 1e6 }
}

enum ImageDecoder {
    /// What this decoder can open. Owned here rather than by the file-list
    /// model: the decoder is the thing that knows.
    static let rawExtensions: Set<String> =
        ["nef", "arw", "dng", "cr2", "cr3", "raf", "rw2", "orf", "pef", "srw"]
    static let flatExtensions: Set<String> =
        ["tif", "tiff", "exr", "png", "jpg", "jpeg", "heic"]
    static var openable: Set<String> { rawExtensions.union(flatExtensions) }

    enum Failure: Error, LocalizedError {
        case unsupported(URL)
        case rawFilterUnavailable(URL)
        case noColorSpace

        var errorDescription: String? {
            switch self {
            case .unsupported(let u): "cannot decode \(u.lastPathComponent)"
            case .rawFilterUnavailable(let u):
                "no RAW decoder for \(u.lastPathComponent) — the camera may not be supported by this macOS version"
            case .noColorSpace: "could not construct the working colour space"
            }
        }
    }

    /// Linear ProPhoto RGB — the engine's stated input contract, and what the
    /// author's darktable export produces.
    ///
    /// **Constructed, because Core Graphics does not ship it.** The SDK has
    /// `kCGColorSpaceROMMRGB`, which is ProPhoto with its native gamma 1.8
    /// curve, and linear variants of sRGB, P3, Gray and ITU-R — but no linear
    /// ROMM. Substituting the gamma-1.8 one would be a silent whole-image
    /// tone error of exactly the kind API-SPEC §4 and RFC-010 are about, and
    /// substituting linear P3 would silently narrow the gamut. So the space
    /// is built from ROMM's own primaries at gamma 1.0 instead.
    ///
    /// Primaries are the published ROMM RGB values against D50, laid out
    /// column-major as `CGColorSpace` wants them — each triple is one
    /// primary's XYZ, not one row of the conventional matrix.
    static let linearProPhoto: CGColorSpace? = {
        let d50: [CGFloat] = [0.9642, 1.0000, 0.8249]
        let black: [CGFloat] = [0, 0, 0]
        let gamma: [CGFloat] = [1.0, 1.0, 1.0]
        let primaries: [CGFloat] = [
            0.7976749, 0.2880402, 0.0000000,   // red   → XYZ
            0.1351917, 0.7118741, 0.0000000,   // green → XYZ
            0.0313534, 0.0000857, 0.8252100,   // blue  → XYZ
        ]
        return d50.withUnsafeBufferPointer { wp in
            black.withUnsafeBufferPointer { bp in
                gamma.withUnsafeBufferPointer { gp in
                    primaries.withUnsafeBufferPointer { mp in
                        CGColorSpace(calibratedRGBWhitePoint: wp.baseAddress!,
                                     blackPoint: bp.baseAddress,
                                     gamma: gp.baseAddress!,
                                     matrix: mp.baseAddress)
                    }
                }
            }
        }
    }()

    /// The space Core Image composites in.
    ///
    /// Extended-range linear P3 rather than the linear ProPhoto above: it is
    /// linear (so compositing is physically meaningful) and *extended*, so
    /// values outside [0, 1] survive intermediate steps instead of being
    /// clamped. Nothing is delivered in this space — it is scratch — so its
    /// primaries do not constrain the result the way the decode target's do.
    static let compositingSpace: CGColorSpace? =
        CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)

    static func decode(_ url: URL) throws -> DecodedImage {
        rawExtensions.contains(url.pathExtension.lowercased())
            ? try decodeRAW(url)
            : try decodeFlat(url)
    }

    // MARK: - RAW

    private static func decodeRAW(_ url: URL) throws -> DecodedImage {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw Failure.rawFilterUnavailable(url)
        }
        // Frontend SPEC §2.5. Not tuning — each of these is Apple's tone
        // rendering being switched off so the film model receives sensor
        // response rather than a finished picture.
        filter.boostAmount = 0
        filter.boostShadowAmount = 0
        filter.isGamutMappingEnabled = false
        filter.isDraftModeEnabled = false
        // Sharpening and noise reduction are spatial operations applied
        // before the film side. Grain and halation are the engine's business;
        // a decoder that has already denoised has removed what grain is
        // supposed to sit on top of.
        filter.isLensCorrectionEnabled = false

        guard let output = filter.outputImage else { throw Failure.unsupported(url) }
        guard let space = linearProPhoto else { throw Failure.noColorSpace }

        // The output is handed back untouched. An earlier version called
        // `matchedToWorkingSpace(from: output.colorSpace)` here, which is
        // wrong and was measured wrong: CIRAWFilter reports its output as
        // Display P3, but with `boostAmount = 0` the *values* are already
        // scene-linear in the context's working space. Remapping therefore
        // decoded a curve that had never been applied. Whole-image mean over
        // the 45 MP reference frame: 0.477 without the remap, 0.261 with it —
        // the image came out roughly 45% too dark. Same family as API-SPEC
        // §4's double-encode, in the opposite direction.
        return DecodedImage(
            image: output,
            pixelSize: output.extent.size,
            decoder: .coreImageRAW,
            workingSpace: space,
            isLinear: true,
            sourceURL: url)
    }

    // MARK: - flat files

    /// TIFF / EXR / PNG / JPEG / HEIC.
    ///
    /// The transfer function here is a property of the *storage type*, not of
    /// a preference — the same rule `service.py::_load_image` follows. A
    /// 16-bit integer TIFF out of Capture One carries its colour space's
    /// curve (gamma 1.8 for ProPhoto) and must be decoded; a float TIFF or
    /// EXR is already linear. Getting this backwards is a silent whole-image
    /// tone error, so it is read from the file rather than assumed.
    private static func decodeFlat(_ url: URL) throws -> DecodedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { throw Failure.unsupported(url) }

        let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
        let isFloat = properties[kCGImagePropertyIsFloat] as? Bool ?? false
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0

        guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        else { throw Failure.unsupported(url) }

        // Core Image reads the embedded ICC and reports it. Trust it; fall
        // back to the engine's own convention only when the file is untagged.
        let embedded = ci.colorSpace
        let linear = isFloat || depth > 16
        let space = embedded ?? (linear ? linearProPhoto : CGColorSpace(name: CGColorSpace.sRGB))

        guard let space else { throw Failure.noColorSpace }
        return DecodedImage(
            image: ci,
            pixelSize: CGSize(width: width, height: height),
            decoder: .imageIO,
            workingSpace: space,
            isLinear: linear,
            sourceURL: url)
    }

    // MARK: - to a texture

    /// Render a decoded image into a Metal texture for the canvas.
    ///
    /// **The one colour rule that matters here.** The texture is rendered
    /// into Display P3 *with* P3's transfer function, exactly once, and the
    /// canvas layer is then told it is holding Display P3. No curve is
    /// applied in the shader and the pixel format is not an `_srgb` one
    /// (UI-GUIDELINE §4, rules 1–3). API-SPEC §4 records a session lost to
    /// the opposite instinct — helping an already-encoded array along with a
    /// second `**(1/2.2)`. Encode once, here, or not at all.
    static func makeTexture(_ decoded: DecodedImage,
                            context: CIContext,
                            device: MTLDevice,
                            commandBuffer: MTLCommandBuffer,
                            maxEdge: Int) -> MTLTexture? {
        let extent = decoded.image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scale = min(1.0, Double(maxEdge) / Double(max(extent.width, extent.height)))
        let scaled = scale < 1.0
            ? decoded.image.transformed(by: .init(scaleX: scale, y: scale))
            : decoded.image
        let target = scaled.extent.integral

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm,          // NOT _srgb — see above
            width: Int(target.width), height: Int(target.height), mipmapped: false)
        // `.shaderWrite` is not optional and its absence is not an error.
        // CIContext renders through a compute kernel, and into a texture
        // without this flag it writes **nothing at all**, silently — no
        // exception, no command-buffer error. The texture then holds whatever
        // was in that GPU allocation, which with `.private` storage is
        // uninitialised memory: the canvas showed flat magenta.
        //
        // Measured, via `Tools/probe.sh`: identical call, same format, same
        // image — `[.shaderRead, .renderTarget]` gives min 0 / max 0 / mean 0
        // on every channel including alpha; adding `.shaderWrite` gives
        // mean 0.477 / 0.467 / 0.453. Format was never the problem; both
        // rgba16Unorm and rgba16Float fail the same way without it.
        descriptor.usage = [.shaderRead, .renderTarget, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let p3 = CGColorSpace(name: CGColorSpace.displayP3)
        else { return nil }

        context.render(scaled.transformed(by: .init(translationX: -target.origin.x,
                                                    y: -target.origin.y)),
                       to: texture,
                       commandBuffer: commandBuffer,
                       bounds: CGRect(origin: .zero, size: target.size),
                       colorSpace: p3)
        return texture
    }
}
