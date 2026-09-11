//  Exporter.swift — delivery.
//
//  Two routes (frontend SPEC §6):
//    - finished: JPEG, PNG 8-bit, TIFF 16-bit — Display P3, Layer 2 baked in,
//      cropped, straightened and turned. The engine renders the print at full
//      resolution into a texture; the client applies Layer 2 and the geometry
//      in Metal and writes through ImageIO with a P3 tag.
//    - DI package: the negative as normalised density (16-bit TIFF) plus the
//      print stock's `.cube` — grade the flat file in Photoshop under a Color
//      Lookup layer, or convert the cube to an ICC for Capture One. Layer 2
//      does not apply; it is pre-print by definition.
//
//  **Both routes are native now.** They used to call a Python service that
//  wrote files into a workspace and returned paths; the engine returns
//  textures and a pointer to the LUT table, and the three files — the DI
//  TIFF, the `.cube`, the optional print preview — are written here. That is
//  where they belong: ImageIO is already how the finished formats are
//  written, and `writeCube` is thirty lines of text formatting that no C++
//  file writer needs to exist for.
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
        if format == .di { return try await exportDI(session: session, to: out) }

        // `.export` is a full-tier reprint: the engine reuses the working
        // negative when one is warm and runs the film side when it is not.
        let outcome = try await session.client.render(
            .export, RenderRequest(sessionID: sessionID, tier: "full"))
        guard let full = outcome.texture else { throw ExportError.noPixels }
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

    // MARK: - the DI package

    /// Three files: the normalised-density negative, the print stock's
    /// `.cube`, and a print preview so the flat file can be checked against
    /// what the LUT does to it.
    ///
    /// The geometry is already in the negative — `node_geometry` runs on the
    /// film side, before the density curves — so the crop and the straighten
    /// are baked in and nothing is applied here. Layer 2 is not, and must not
    /// be: it lives after the print and the DI file is before it.
    private static func exportDI(session: Session, to out: URL) async throws -> Result {
        let di = try await session.client.exportDI()
        guard let texture = di.texture else { throw ExportError.noPixels }
        // Device RGB, not Display P3. These are not colours: each channel is
        // a film density normalised by the LUT's own axis, and the `.cube`
        // beside it indexes exactly those numbers. Tagging the file with a
        // rendering space invites whatever opens it to convert the values and
        // silently move the cube's domain out from under it, so this asks
        // ImageIO for the most nearly untagged thing it will write.
        guard let cg = texture.makeCGImage(space: CGColorSpaceCreateDeviceRGB())
            else { throw ExportError.noPixels }
        try write(cg, to: out, format: .tiff)

        let base = out.deletingPathExtension()
        let cube = base.deletingLastPathComponent()
            .appending(path: "\(base.lastPathComponent)_\(di.meta.printStock).cube")
        let table = try await session.client.printLUTTable(di.meta.printStock)
        try writeCube(table.table, size: table.size, to: cube,
                      title: "spektrafilm \(di.meta.printStock) print (from \(di.meta.pairedFilm))")

        var urls = [out, cube]
        // The print preview is the same table applied to the same negative,
        // which is what `preview_stock_lut` is. It is written last and its
        // failure is not the export's: the two files that carry the grade are
        // already on disk.
        if let preview = try? await session.client.previewStockLUT(di.meta.printStock, tier: "full"),
           let tex = preview.texture, let cg = tex.makeCGImage() {
            let path = base.deletingLastPathComponent()
                .appending(path: "\(base.lastPathComponent)_print.tif")
            if (try? write(cg, to: path, format: .tiff)) != nil { urls.append(path) }
        }
        return Result(urls: urls, note: di.meta.warning)
    }

    /// A plain 3D `.cube`: `LUT_3D_SIZE N`, domain 0..1, red fastest.
    ///
    /// `table` is (N, N, N, 3) indexed [r, g, b] — the bake's own axis order
    /// — so iterating blue outermost and red innermost gives the cube's
    /// ordering. The domain is 0..1 because the DI file beside it was
    /// normalised by the same axes, which is what lets this carry no
    /// `DOMAIN_MIN`/`DOMAIN_MAX` for a host to misread.
    static func writeCube(_ table: [Float], size n: Int, to url: URL, title: String) throws {
        guard table.count == n * n * n * 3 else { throw ExportError.noPixels }
        var text = """
        TITLE "\(title)"
        LUT_3D_SIZE \(n)
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0


        """
        text.reserveCapacity(n * n * n * 26 + 128)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let i = ((r * n + g) * n + b) * 3
                    text += String(format: "%.6f %.6f %.6f\n",
                                   min(max(table[i], 0), 1),
                                   min(max(table[i + 1], 0), 1),
                                   min(max(table[i + 2], 0), 1))
                }
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    static func write(_ image: CGImage, to url: URL, format: ExportFormat) throws -> URL {
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
        return url
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
