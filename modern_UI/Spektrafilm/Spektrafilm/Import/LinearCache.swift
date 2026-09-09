//  LinearCache.swift — the on-disk cache of decoded linear ProPhoto TIFFs.
//
//  What it is for: `service.open` takes a *file*, and decoding a 45 MP RAW
//  through Core Image and writing the half-float TIFF costs ~2 s. The cache
//  makes returning to a frame cost the service's `open` and nothing else.
//
//  Why it is bounded. Each entry is the source at full resolution — 363 MB
//  for one 45 MP frame — and the first build never deleted one. A handful of
//  white-balance values on a single image reached 1.7 GB, and a folder of
//  fifty frames browsed once would be ~18 GB
//  (HANDOFF-FRONTEND-POLISH §3.1). Entries are regenerable in a couple of
//  seconds, so the right policy is a small ceiling and LRU eviction, not
//  "keep everything".
//
//  Why full resolution is kept, against the handoff's §3.1.3 suggestion of a
//  1600 px live-tier file: the service derives *every* tier from the file it
//  opens (`RenderSession._images["full"]` is the loaded array), so a live-tier
//  input silently caps the detail render and `export` at 1600 px. Keeping the
//  full-resolution file is what makes the zoom-detail path and a full-size
//  export possible from one session. The cost is the 4 GB ceiling below.
//
//  Eviction is by modification date, and a hit bumps it: APFS does not
//  reliably update atime, so "last touched" has to be written explicitly.

import Foundation

enum LinearCache {
    /// 4 GB — about eleven 45 MP frames. The handoff's SPEC §1.1 proposed
    /// 20 GB, which was written before the entries were known to be 363 MB.
    static let maxBytes: Int64 = 4 * 1024 * 1024 * 1024

    static var directory: URL { Session.cacheRoot.appending(path: "linear") }

    /// Called before a write. Prunes first so the write cannot be the thing
    /// that pushes the directory over the ceiling.
    static func prepare() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prune()
    }

    /// A cache hit: bump the entry's modification date so LRU sees it as used.
    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    static func prune(in directory: URL? = nil, limit: Int64? = nil) {
        let directory = directory ?? LinearCache.directory
        let limit = limit ?? maxBytes
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        var files: [(url: URL, date: Date, size: Int64)] = []
        var total: Int64 = 0
        for url in entries {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true else { continue }
            let size = Int64(v.fileSize ?? 0)
            files.append((url, v.contentModificationDate ?? .distantPast, size))
            total += size
        }
        guard total > limit else { return }
        for f in files.sorted(by: { $0.date < $1.date }) {
            guard total > limit else { break }
            try? FileManager.default.removeItem(at: f.url)
            total -= f.size
        }
    }

    /// Total bytes on disk, for the status line and the tests.
    static func size() -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return 0 }
        return entries.reduce(0) { sum, url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return sum + Int64((v?.isRegularFile == true ? v?.fileSize : 0) ?? 0)
        }
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
