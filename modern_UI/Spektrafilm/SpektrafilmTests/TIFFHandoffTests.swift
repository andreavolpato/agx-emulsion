//  TIFFHandoffTests.swift — the linear TIFF handed to the render service must
//  stay uncompressed.
//
//  This is a performance cliff disguised as a storage decision. The file is
//  364 MB for a 45 MP frame and compressing it looks like an obvious win for a
//  disk cache that is already bounded at 4 GB. Measured on the engine side,
//  reading it back: **uncompressed 0.11 s · LZW 1.6 s · ZIP 1.35 s**, threads
//  making no difference. `open` is ~0.9 s in total, so compression would more
//  than double it — and the symptom would be "opening a frame got slow again"
//  with nothing in the frontend's own timings to explain it, because the cost
//  lands in the other process.
//
//  Nothing else asserts this: `writeLinearTIFF` passes `options: [:]` and gets
//  uncompressed by default, so the property is currently held by an empty
//  dictionary and a comment.

import CoreGraphics
import ImageIO
import XCTest

final class TIFFHandoffTests: XCTestCase {

    func testTheLinearHandoffTIFFIsUncompressed() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "spektrafilm-handoff-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }

        let ci = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        let space = try XCTUnwrap(ImageDecoder.linearProPhoto)
        try ImageDecoder.context.writeTIFFRepresentation(of: ci, to: url, format: .RGBAh,
                                                        colorSpace: space, options: [:])

        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        let tiff = try XCTUnwrap(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        let compression = tiff[kCGImagePropertyTIFFCompression] as? Int

        // TIFF compression 1 = none. A missing tag also means none.
        XCTAssertEqual(compression ?? 1, 1,
                       "the handoff TIFF is compressed — that is +1.2 s on every open, in the other process")
    }
}
