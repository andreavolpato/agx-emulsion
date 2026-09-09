//  ThumbnailCache.swift — filmstrip thumbnails from ImageIO's embedded
//  preview, never from the engine, generated off the main actor.

import AppKit
import ImageIO

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [URL: CGImage] = [:]
    private var inFlight: [URL: Task<CGImage?, Never>] = [:]

    func thumbnail(for url: URL, maxPixel: Int = 320) async -> CGImage? {
        if let c = cache[url] { return c }
        if let t = inFlight[url] { return await t.value }
        let task = Task<CGImage?, Never>.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCache: false,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        inFlight[url] = task
        let img = await task.value
        inFlight[url] = nil
        if let img { cache[url] = img }
        return img
    }

    /// Replace the embedded preview with a rendered one (processed state).
    func store(_ image: CGImage, for url: URL) { cache[url] = image }
}
