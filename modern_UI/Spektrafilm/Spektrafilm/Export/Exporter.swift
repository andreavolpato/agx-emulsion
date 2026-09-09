//  Exporter.swift — delivery.
//
//  Two routes (frontend SPEC §6):
//    - finished: JPEG, PNG 8-bit, TIFF 16-bit — Display P3, Layer 2 baked in,
//      cropped, straightened and turned. The service renders the print at
//      full resolution; the client applies Layer 2 and the geometry in Metal
//      and writes through ImageIO with a P3 tag.
//    - DI package: the negative as normalised density (16-bit TIFF) plus the
//      print stock's `.cube` — grade the flat file in Photoshop under a Color
//      Lookup layer, or convert the cube to an ICC for Capture One. Layer 2
//      does not apply; it is pre-print by definition.
//
//  Filenames: `<original>_<film>_<paper>.<ext>` in `<source dir>/_prints/`.

import AppKit
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG", png = "PNG 8-bit", tiff = "TIFF 16-bit", di = "DI package"
    var id: String { rawValue }
    var ext: String { switch self { case .jpeg: "jpg"; case .png: "png"; case .tiff: "tif"; case .di: "tif" } }
    var utType: UTType { switch self { case .jpeg: .jpeg; case .png: .png; case .tiff, .di: .tiff } }
    var note: String {
        switch self {
        case .jpeg: "Display P3, quality 0.95. Adjustments baked in."
        case .png: "Display P3, 8-bit lossless. Adjustments baked in."
        case .tiff: "Display P3, 16-bit. Adjustments baked in; headroom is the scan margin only."
        case .di: "Negative density TIFF + print .cube. For grading under the print LUT in Photoshop."
        }
    }
}

@MainActor
enum Exporter {
    struct Result: Sendable { let urls: [URL]; let note: String? }

    static func destination(for source: URL, params: FilmParams, format: ExportFormat) -> URL {
        let dir = source.deletingLastPathComponent().appending(path: "_prints")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = "\(source.deletingPathExtension().lastPathComponent)_\(params.filmStock)_\(params.printStock)"
        return dir.appending(path: "\(base).\(format.ext)")
    }

    static func export(session: Session, format: ExportFormat, sessionID: String) async throws -> Result {
        guard let source = session.selection else { throw ExportError.nothingOpen }
        let params = session.params
        let out = destination(for: source, params: params, format: format)
        if format == .di {
            let req = ExportDIRequest(sessionID: sessionID, outDir: out.deletingLastPathComponent().path,
                                      baseName: out.deletingPathExtension().lastPathComponent)
            let r: ExportDIResponse = try await session.client.call(.exportDI, req)
            return Result(urls: [URL(fileURLWithPath: r.diPath), URL(fileURLWithPath: r.cubePath)], note: r.warning)
        }
        let r: RenderResponse = try await session.client.call(.export, ExportRequest(sessionID: sessionID))
        guard let raw = r.rawPath, let w = r.width, let h = r.height,
              let full = session.renderer.store.uploadRGBA16(path: raw, width: w, height: h) else { throw ExportError.noPixels }
        defer { try? FileManager.default.removeItem(atPath: raw) }
        guard let adjusted = session.renderer.applyLayer2(to: full, uniforms: session.adjustments.uniforms)
            else { throw ExportError.noPixels }
        // Crop, straighten, quarter turns and flips, through the same
        // `geometryMap` the canvas samples with — not a CoreGraphics
        // transform written a second time. The old path cropped with
        // `CGImage.cropping` and could not rotate at all, so a straightened
        // frame exported unstraightened and nothing in the app said so.
        let framed = session.renderer.applyGeometry(session.geometry, to: adjusted) ?? adjusted
        guard let cg = framed.makeCGImage() else { throw ExportError.noPixels }
        try write(cg, to: out, format: format)
        return Result(urls: [out], note: nil)
    }

    static func write(_ image: CGImage, to url: URL, format: ExportFormat) throws {
        var cg = image
        if format == .jpeg || format == .png {
            // Down-convert to 8-bit in P3 (ImageIO would otherwise write 16-bit PNG).
            guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: ImageDecoder.displayP3, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ExportError.noPixels }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            guard let eight = ctx.makeImage() else { throw ExportError.noPixels }
            cg = eight
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw ExportError.write(url)
        }
        var props: [CFString: Any] = [:]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        if format == .tiff { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.write(url) }
    }

    enum ExportError: Error, LocalizedError {
        case nothingOpen, noPixels, write(URL)
        var errorDescription: String? {
            switch self {
            case .nothingOpen: "Nothing is open."
            case .noPixels: "The render came back empty."
            case .write(let u): "Could not write \(u.lastPathComponent)."
            }
        }
    }
}
