//  TextureStore.swift — the buffer system behind a snappy canvas.
//
//  What is resident, and why:
//
//  | texture             | source                      | lifetime            |
//  |---------------------|-----------------------------|---------------------|
//  | source preview      | Core Image decode, P3       | per frame, LRU 8    |
//  | print (live tier)   | service reprint, rgba16 raw | per frame, LRU 8    |
//  | detail (higher tier)| service reprint at the zoom | one frame only      |
//  | stock LUT preview   | service preview_stock_lut   | transient           |
//  | adjusted            | Layer 2 kernel output       | one, re-run on edit |
//  | curve table         | CPU, 256×5 r32Float         | one                 |
//
//  Frame switches are instant because the last eight frames' live textures
//  stay resident (a 1600 px rgba16 texture is ~14 MB; eight of each kind is
//  well under 250 MB). Returning to a frame shows its last print immediately,
//  flagged `soft` until the service's session catches up.
//
//  The detail texture is deliberately *not* kept per frame: at the full tier
//  one is 360 MB, so eight would be 2.9 GB.
//
//  The one detail slot is **ranked and stamped**, and both matter:
//
//  - **Ranked.** A `full` render contains everything a `preview` render does,
//    so a lookup asks for "this tier *or sharper*". Without that, zooming
//    200 % → 120 % asked for `preview`, missed, spent 2.75 s re-rendering
//    detail the resident texture already had — and the result then evicted
//    the `full` one, so zooming back cost another 6–17 s. The slot only ever
//    moves *up* within one frame and one set of parameters.
//  - **Stamped** with the parameters the service rendered it from, so
//    validity is data rather than timing. An undo, or a slider dragged back
//    to where it was, makes the resident render correct again and it is
//    shown instead of re-rendered.
//
//  Showing a sharper texture than the zoom asked for is free and correct:
//  `canvasFragment` picks its sampler from the *texture* scale, so a native
//  texture drawn at 120 % minifies with `filter::linear` exactly as a 3400 px
//  one would.

import Foundation
import Metal

/// One resident higher-resolution render: which frame, which tier, which
/// parameters made it, and how sharp it is relative to the other tiers.
struct DetailEntry: @unchecked Sendable {
    let url: URL
    let tier: String
    let rank: Int
    let stamp: String
    let texture: MTLTexture
}

final class TextureStore: @unchecked Sendable {
    let device: MTLDevice
    private var sources: [URL: MTLTexture] = [:]
    private var prints: [URL: MTLTexture] = [:]
    /// One higher-resolution print, for the current frame only. A full-res
    /// 45 MP rgba16 texture is 360 MB, so eight of them is not an option the
    /// way eight live-tier prints (14 MB each) is.
    ///
    /// `rank` orders the tiers (live 0 · preview 1 · full 2) and `stamp` is
    /// the Layer 1 parameters it was rendered from. Together they are what
    /// makes a lookup a cache hit rather than a coincidence.
    private var detail: DetailEntry?
    private var order: [URL] = []
    private let capacity = 8
    private let lock = NSLock()

    init(device: MTLDevice) { self.device = device }

    func source(for url: URL) -> MTLTexture? { lock.withLock { sources[url] } }
    func print(for url: URL) -> MTLTexture? { lock.withLock { prints[url] } }

    /// The resident detail render for `url`, if it was made from `stamp` and
    /// is at least as sharp as `rank`. Returns what is actually resident —
    /// which may be sharper than asked for — so the caller can record the
    /// tier it is really showing rather than the one it wanted.
    func detail(for url: URL, stamp: String, atLeast rank: Int) -> DetailEntry? {
        lock.withLock {
            guard let d = detail, d.url == url, d.stamp == stamp, d.rank >= rank else { return nil }
            return d
        }
    }

    func setSource(_ t: MTLTexture, for url: URL) { lock.withLock { sources[url] = t; touch(url) } }
    func setPrint(_ t: MTLTexture?, for url: URL) { lock.withLock { prints[url] = t; touch(url) } }
    /// Take a detail render into the slot. A render is only ever accepted if
    /// it is sharper than what is already there for the same frame and the
    /// same parameters — a lower tier for an unchanged frame is by definition
    /// information the slot already holds, and letting it in is what used to
    /// evict a 17 s `full` render in favour of a 2.75 s `preview` one.
    func setDetail(_ t: MTLTexture, tier: String, rank: Int, stamp: String, for url: URL) {
        lock.withLock {
            if let d = detail, d.url == url, d.stamp == stamp, d.rank >= rank { return }
            detail = DetailEntry(url: url, tier: tier, rank: rank, stamp: stamp, texture: t)
        }
    }
    func dropDetail() { lock.withLock { detail = nil } }
    /// Free the slot unless it still matches these parameters. Called when a
    /// new print lands: if the edit was an undo back to what the resident
    /// render was made from, it is still the truth and is kept.
    func dropDetail(unless stamp: String, for url: URL) {
        lock.withLock { if detail?.url != url || detail?.stamp != stamp { detail = nil } }
    }
    func invalidatePrint(for url: URL) { lock.withLock { prints[url] = nil } }
    func removeAll() { lock.withLock { sources.removeAll(); prints.removeAll(); detail = nil; order.removeAll() } }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > capacity {
            let old = order.removeFirst()
            sources[old] = nil
            prints[old] = nil
            if detail?.url == old { detail = nil }
        }
    }

    // MARK: uploads

    /// A raw 16-bit RGBA dump from the service (row 0 = top row), straight
    /// into an `rgba16Unorm` texture. No colour interpretation happens here:
    /// the values are already Display P3 encoded and the layer is P3.
    func uploadRGBA16(path: String, width: Int, height: Int) -> MTLTexture? {
        guard width > 0, height > 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              data.count >= width * height * 8 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        data.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: width * 8)
        }
        return tex
    }

    func makeWritable(width: Int, height: Int, format: MTLPixelFormat = .rgba16Unorm) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    /// 256 × 5 r32Float: rgb, luma, r, g, b tables.
    func makeCurveTable() -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: Curve.tableSize, height: 5, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    func upload(curves: CurveSet, into tex: MTLTexture) {
        var floats = curves.tables()
        floats.withUnsafeMutableBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, Curve.tableSize, 5), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: Curve.tableSize * 4)
        }
    }
}
