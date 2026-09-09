//  Params.swift — Layer 1: the engine's parameters, as the UI holds them.
//
//  Mirrors `src/spektrafilm/service/schema.py` field for field. Two rules:
//
//  1. Wire names are the schema's names. `delta(from:)` produces exactly the
//     `params_delta` object the service validates, nothing else.
//  2. Every field knows its layer (`shoot` / `print`) — the same table the
//     service uses to decide between a 190 ms reprint and a film-side
//     re-render. The scheduler routes on it, so a wrong layer here is a
//     correctness bug, not a metadata one.

import Foundation

enum ParamLayer: String, Codable, Sendable { case shoot, print }

/// A JSON scalar for `params_delta`.
enum ParamValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case double(Double), bool(Bool), string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .string(try c.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .string(let s): try c.encode(s)
        }
    }
    var description: String {
        switch self {
        case .double(let d): String(format: "%.4g", d)
        case .bool(let b): b ? "true" : "false"
        case .string(let s): s
        }
    }
    var doubleValue: Double? { if case .double(let d) = self { d } else { nil } }
    var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
}

/// Film formats the Camera section offers. `mm` is the long edge of the
/// frame, which is what `camera.film_format_mm` means (the engine derives
/// pixel pitch from it: `film_format_mm * 1000 / max(h, w)`), so it drives
/// grain scale. Range accepted by the service: 4…200.
struct FilmFormat: Identifiable, Hashable, Sendable {
    let id: String
    let mm: Double
    static let all: [FilmFormat] = [
        .init(id: "Super 8", mm: 5.8),
        .init(id: "16mm", mm: 10.3),
        .init(id: "Super 35", mm: 24.9),
        .init(id: "35mm", mm: 36),
        .init(id: "645", mm: 56),
        .init(id: "6×6", mm: 56),
        .init(id: "6×7", mm: 70),
        .init(id: "6×9", mm: 84),
        .init(id: "4×5", mm: 127),
        .init(id: "8×10", mm: 200),
    ]
    static func nearest(mm: Double) -> FilmFormat {
        all.min { abs($0.mm - mm) < abs($1.mm - mm) } ?? all[3]
    }
}

struct FilmParams: Codable, Equatable, Sendable {
    // --- stock (shoot for film, print for paper) ---
    var filmStock: String = "kodak_portra_400"
    var printStock: String = "kodak_supra_endura"
    // --- shoot ---
    var exposureCompensationEV: Double = 0          // -8…8
    var filmFormatMM: Double = 36                    // 4…200
    var grainActive: Bool = true
    var halationActive: Bool = true
    // --- print ---
    /// UI stops, brighter positive. Wire: `print_exposure = 2^(-stops)`,
    /// because less enlarger exposure prints brighter (API-SPEC §2).
    var printBrightnessStops: Double = 0            // -3…3
    var yFilterShift: Double = 0                     // -1…1  yellow ↔ blue
    var mFilterShift: Double = 0                     // -1…1  magenta ↔ green
    var glareActive: Bool = true

    static let `default` = FilmParams()

    /// Wire representation of every field. Order is stable for tests.
    var wire: [(name: String, value: ParamValue, layer: ParamLayer)] {
        [
            ("film_stock", .string(filmStock), .shoot),
            ("print_stock", .string(printStock), .print),
            ("exposure_compensation_ev", .double(exposureCompensationEV), .shoot),
            ("film_format_mm", .double(filmFormatMM), .shoot),
            ("grain_active", .bool(grainActive), .shoot),
            ("grain_sublayers_active", .bool(grainActive), .shoot),
            ("halation_active", .bool(halationActive), .shoot),
            ("print_exposure", .double(FilmParams.printExposure(stops: printBrightnessStops)), .print),
            ("y_filter_shift", .double(yFilterShift), .print),
            ("m_filter_shift", .double(mFilterShift), .print),
            ("glare_active", .bool(glareActive), .print),
        ]
    }

    static func printExposure(stops: Double) -> Double {
        (pow(2.0, -stops)).clamped(to: 0.05...20)
    }

    /// The `params_delta` that turns `other` into `self`, and the layers it
    /// touches. An empty delta means nothing to send.
    func delta(from other: FilmParams) -> (delta: [String: ParamValue], layers: Set<ParamLayer>) {
        var delta: [String: ParamValue] = [:]
        var layers = Set<ParamLayer>()
        let theirs = Dictionary(uniqueKeysWithValues: other.wire.map { ($0.name, $0.value) })
        for f in wire where theirs[f.name] != f.value {
            delta[f.name] = f.value
            layers.insert(f.layer)
        }
        // A film change also invalidates the print side (the service says so).
        if delta["film_stock"] != nil { layers.insert(.print) }
        return (delta, layers)
    }

    /// Everything, as sent with `open`.
    var fullDelta: [String: ParamValue] {
        Dictionary(uniqueKeysWithValues: wire.map { ($0.name, $0.value) })
    }

    /// Fields the service can write onto a live pipeline without a rebuild
    /// (`schema.LIVE_MUTABLE`). Informational — the client sends the same
    /// delta either way — but the scheduler uses it to pick the tighter
    /// debounce.
    static let liveMutable: Set<String> = ["print_exposure", "m_filter_shift", "y_filter_shift"]
}
