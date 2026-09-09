//  Frame.swift — one file in the session.

import Foundation

enum FrameState: Codable, Sendable, Equatable {
    /// Never opened in the service; the thumbnail is the embedded JPEG.
    case unprocessed
    /// Rendered once; sidecar matches what is on screen.
    case processed
    /// Rendered, then the parameters changed; the thumbnail is stale.
    case stale
}

struct Frame: Identifiable, Hashable, Sendable {
    let id: URL
    var url: URL { id }
    var name: String { url.lastPathComponent }
    var isRAW: Bool { ImageDecoder.rawExtensions.contains(url.pathExtension.lowercased()) }
}
