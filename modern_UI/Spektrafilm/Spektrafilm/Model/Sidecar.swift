//  Sidecar.swift — `<image>.spektra.json`, next to the source. Never writes
//  the source file. Small enough to rewrite whole on every change.

import Foundation

struct DecodeSettings: Codable, Equatable, Sendable {
    enum WhiteBalance: String, Codable, CaseIterable, Sendable {
        case asShot = "As Shot", daylight = "Daylight", cloudy = "Cloudy", shade = "Shade",
             tungsten = "Tungsten", fluorescent = "Fluorescent", custom = "Custom"
        var kelvin: Double? {
            switch self {
            case .daylight: 5500
            case .cloudy: 6500
            case .shade: 7500
            case .tungsten: 3200
            case .fluorescent: 4000
            case .asShot, .custom: nil
            }
        }
    }
    var whiteBalance: WhiteBalance = .asShot
    /// Kelvin and tint actually applied at decode. For `.asShot` these are
    /// the camera's, filled in after the first decode; for presets the preset's.
    var temperature: Double = 5500
    var tint: Double = 0
    /// Only the decode-affecting fields matter for the cache key.
    var cacheKey: String { "\(whiteBalance.rawValue)-\(Int(temperature))-\(Int(tint * 10))" }
}

struct CropRect: Codable, Equatable, Sendable {
    /// Normalised to the image, origin top-left.
    var x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1
    static let full = CropRect()
    var isFull: Bool { self == .full }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct Sidecar: Codable, Equatable, Sendable {
    var schemaVersion = 3
    var decoder = "coreimage"
    var decode = DecodeSettings()
    var params = FilmParams.default
    var adjustments = Adjustments.default
    /// Crop, straighten, quarter turns and flips (`Model/Geometry.swift`).
    var geometry = Geometry.default
    /// The solve the service returned for this frame (EV, filter neutrals),
    /// kept so the UI can show the sliders as offsets from it.
    var solvedEV: Double?
    var state: FrameState = .unprocessed

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, decoder, decode, params, adjustments, geometry, solvedEV, state
        /// Schema 2's field. Read, never written.
        case crop
    }

    init() {}

    /// Schema 2 stored a bare `crop` and had no angle, turns or flips. It
    /// decodes into `geometry.crop` unchanged — the two mean the same thing
    /// at angle 0 — so an existing sidecar opens with its crop intact rather
    /// than silently resetting to the full frame.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        self.decoder = try c.decodeIfPresent(String.self, forKey: .decoder) ?? "coreimage"
        decode = try c.decodeIfPresent(DecodeSettings.self, forKey: .decode) ?? DecodeSettings()
        params = try c.decodeIfPresent(FilmParams.self, forKey: .params) ?? .default
        adjustments = try c.decodeIfPresent(Adjustments.self, forKey: .adjustments) ?? .default
        solvedEV = try c.decodeIfPresent(Double.self, forKey: .solvedEV)
        state = try c.decodeIfPresent(FrameState.self, forKey: .state) ?? .unprocessed
        if let g = try c.decodeIfPresent(Geometry.self, forKey: .geometry) {
            geometry = g
        } else if let legacy = try c.decodeIfPresent(CropRect.self, forKey: .crop) {
            geometry = Geometry(crop: legacy)
        }
        schemaVersion = 3
    }

    /// Schema 2's `crop` is deliberately not written back: one field, one
    /// meaning. A file written here and read by an older build loses its
    /// crop, which is the honest outcome — that build cannot honour the
    /// angle or the turns either.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(decoder, forKey: .decoder)
        try c.encode(decode, forKey: .decode)
        try c.encode(params, forKey: .params)
        try c.encode(adjustments, forKey: .adjustments)
        try c.encode(geometry, forKey: .geometry)
        try c.encodeIfPresent(solvedEV, forKey: .solvedEV)
        try c.encode(state, forKey: .state)
    }

    /// `<original>.spektra.json` — the **whole** file name, extension
    /// included. The first build used
    /// `deletingPathExtension().appendingPathExtension("spektra.json")`, so
    /// `a.NEF` and `a.tif` in one folder both resolved to `a.spektra.json`
    /// and silently overwrote each other's settings
    /// (HANDOFF-FRONTEND-POLISH §3.2). Keeping the extension is the fix.
    static func url(for image: URL) -> URL {
        image.deletingLastPathComponent()
            .appending(path: image.lastPathComponent + ".spektra.json")
    }

    /// The pre-fix name. Read once, migrated to `url(for:)`, then never
    /// written again. The old file is left in place: it may belong to a
    /// sibling with the same stem, and deleting it would destroy the other
    /// frame's settings.
    static func legacyURL(for image: URL) -> URL {
        image.deletingPathExtension().appendingPathExtension("spektra.json")
    }

    static func load(for image: URL) -> Sidecar? {
        if let data = try? Data(contentsOf: url(for: image)),
           let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) {
            return sidecar
        }
        guard let data = try? Data(contentsOf: legacyURL(for: image)),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) else { return nil }
        // Migrate: adopt the settings and write them under the new name so the
        // next read is unambiguous.
        try? sidecar.save(for: image)
        return sidecar
    }

    /// Remove both names — "reset to defaults" must not leave a legacy file
    /// that would be re-adopted on the next open.
    static func remove(for image: URL) {
        try? FileManager.default.removeItem(at: url(for: image))
        try? FileManager.default.removeItem(at: legacyURL(for: image))
    }

    func save(for image: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Sidecar.url(for: image), options: .atomic)
    }
}
