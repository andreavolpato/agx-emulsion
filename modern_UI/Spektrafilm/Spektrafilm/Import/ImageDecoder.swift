//  ImageDecoder.swift — RAW and flat-file decode through Core Image, to the
//  engine's input contract: a float32 TIFF in **linear ProPhoto RGB**.
//
//  Why the client decodes at all: the engine's own RAW path is LibRaw with
//  dcraw's generic camera matrix (HANDOFF-CAMERA-MATRIX §1). Apple's RAW
//  engine is the product decode (HANDOFF-DECODE-AB §3): it is native, supports
//  ProRAW, and — the actual reason — white balance becomes a client decision
//  with a real UI (temperature, tint, pick-neutral) instead of a hardcoded
//  `as_shot`. The decoded TIFF is what the service opens; it detects a float
//  TIFF as linear ProPhoto (`service.py::_detect_nonraw_input`), verified by
//  `Tools/probe.sh`.
//
//  The four `CIRAWFilter` settings are not tuning: each one is Apple's tone
//  rendering being switched off so the film model receives sensor response.
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
    let image: CIImage
    let pixelSize: CGSize
    let isRAW: Bool
    let sourceURL: URL
    /// As-shot values reported by the RAW filter (nil for flat files).
    let asShotTemperature: Double?
    let asShotTint: Double?
    var megapixels: Double { pixelSize.width * pixelSize.height / 1e6 }
}

enum ImageDecoder {
    static let rawExtensions: Set<String> =
        ["nef", "arw", "dng", "cr2", "cr3", "raf", "rw2", "orf", "pef", "srw", "3fr", "iiq"]
    static let flatExtensions: Set<String> = ["tif", "tiff", "png", "jpg", "jpeg", "heic", "exr"]
    static var openable: Set<String> { rawExtensions.union(flatExtensions) }

    enum Failure: Error, LocalizedError {
        case unsupported(URL), rawFilterUnavailable(URL), noColorSpace, writeFailed(URL)
        var errorDescription: String? {
            switch self {
            case .unsupported(let u): "cannot decode \(u.lastPathComponent)"
            case .rawFilterUnavailable(let u): "no RAW decoder for \(u.lastPathComponent)"
            case .noColorSpace: "could not construct the working colour space"
            case .writeFailed(let u): "could not write \(u.lastPathComponent)"
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

    private static func decodeRAW(_ url: URL, settings: DecodeSettings) throws -> DecodedImage {
        guard let filter = CIRAWFilter(imageURL: url) else { throw Failure.rawFilterUnavailable(url) }
        filter.boostAmount = 0
        filter.boostShadowAmount = 0
        filter.isGamutMappingEnabled = false
        filter.isDraftModeEnabled = false
        filter.isLensCorrectionEnabled = false
        filter.localToneMapAmount = 0
        filter.extendedDynamicRangeAmount = 0
        let asShotT = Double(filter.neutralTemperature), asShotTint = Double(filter.neutralTint)
        switch settings.whiteBalance {
        case .asShot: break
        default:
            filter.neutralTemperature = Float(settings.temperature)
            filter.neutralTint = Float(settings.tint)
        }
        guard let output = filter.outputImage else { throw Failure.unsupported(url) }
        return DecodedImage(image: output, pixelSize: output.extent.size, isRAW: true, sourceURL: url,
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
        return DecodedImage(image: image, pixelSize: image.extent.size, isRAW: false, sourceURL: url,
                            asShotTemperature: nil, asShotTint: nil)
    }

    // MARK: the engine's input file

    /// Write the decoded image as a float32 linear ProPhoto TIFF — the engine's
    /// stated input. `maxEdge` lets the caller cap resolution (nil = full).
    static func writeLinearTIFF(_ decoded: DecodedImage, to url: URL, maxEdge: Int? = nil) throws {
        guard let space = linearProPhoto else { throw Failure.noColorSpace }
        var image = decoded.image
        if let maxEdge {
            let s = min(1, Double(maxEdge) / Double(max(image.extent.width, image.extent.height)))
            if s < 1 { image = image.transformed(by: .init(scaleX: s, y: s)) }
        }
        image = image.transformed(by: .init(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Half float: OIIO reads it as float (so the service treats it as linear) at half the bytes.
        try context.writeTIFFRepresentation(of: image, to: url, format: .RGBAh, colorSpace: space, options: [:])
    }

    // MARK: display preview

    /// Render into a Display P3 texture for the canvas, encoded once here.
    static func makePreviewTexture(_ decoded: DecodedImage, device: MTLDevice, maxEdge: Int) -> MTLTexture? {
        let extent = decoded.image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1.0, Double(maxEdge) / Double(max(extent.width, extent.height)))
        var scaled = scale < 1 ? decoded.image.transformed(by: .init(scaleX: scale, y: scale)) : decoded.image
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

    /// Value at a point (0…1 normalised, top-left origin) of the decoded
    /// image — linear working-space RGB. Used by the neutral picker.
    static func sampleLinear(_ decoded: DecodedImage, at p: CGPoint, radius: Int = 4) -> SIMD3<Double>? {
        let e = decoded.image.extent
        let x = e.origin.x + p.x.clamped(to: 0...1) * e.width
        let y = e.origin.y + (1 - p.y.clamped(to: 0...1)) * e.height
        let r = CGFloat(radius)
        let rect = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r).intersection(e)
        guard !rect.isEmpty else { return nil }
        let avg = CIFilter.areaAverage()
        avg.inputImage = decoded.image
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
