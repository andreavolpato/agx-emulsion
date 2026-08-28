//  Params.swift — the client's mirror of the service's transport schema.
//
//  These names are not invented. Every one is a wire name from
//  `spektrafilm/service/schema.py::_FIELDS`, and the `layer` each belongs to
//  is copied from the same table. That mapping is load-bearing rather than
//  decorative: schema.py's own header says getting a field's layer wrong is a
//  *correctness* bug, because it would let a shoot-side edit silently reuse a
//  stale cached negative. The client therefore repeats the assignment instead
//  of guessing it from the control's position in the panel.
//
//  Ranges are likewise copied from `_FIELDS`, so a slider physically cannot
//  travel somewhere `validate_delta` would reject.
//
//  Defaults are NOT copied. schema.py reads them from `params_schema.py` at
//  import time precisely so the frontend does not re-decide them (API-SPEC
//  §4's closing note). The values below are placeholders used only before a
//  session is open; `open`'s response replaces every one of them.

import Foundation

enum ParamLayer: String, Sendable, Codable {
    /// Upstream of `Tap.CMY_FILM`. Changing one invalidates the cached
    /// negative and forces a film-side re-render (1–7 s, frontend SPEC §4).
    case shoot
    /// Enlarger, paper, scanner — everything reachable by `reprint` at
    /// ~193 ms without touching the film side.
    case print
}

/// One declared transport field: wire name, layer, range, live-mutability.
struct ParamField: Sendable, Hashable {
    let name: String
    let layer: ParamLayer
    let range: ClosedRange<Double>?
    /// Mirrors `schema.LIVE_MUTABLE` — the four fields the service can write
    /// straight onto a live pipeline without rebuilding it. Deliberately
    /// short; schema.py warns against widening it without re-running the
    /// reprint-equivalence test per field added.
    let liveMutable: Bool

    init(_ name: String, _ layer: ParamLayer,
         _ range: ClosedRange<Double>? = nil, live: Bool = false) {
        self.name = name; self.layer = layer; self.range = range; self.liveMutable = live
    }
}

enum Schema {
    static let fields: [ParamField] = [
        // mandatory stock selection — API-SPEC §4: no "off" state exists
        .init("film_stock",  .shoot),
        .init("print_stock", .print),
        // shoot side
        .init("exposure_compensation_ev", .shoot, -8...8),
        .init("auto_exposure",            .shoot),
        .init("film_format_mm",           .shoot, 4...200),
        .init("lens_blur_um",             .shoot, 0...200),
        .init("halation_active",          .shoot),
        .init("halation_amount",          .shoot, 0...4),
        .init("halation_boost_ev",        .shoot, 0...8),
        .init("grain_active",             .shoot),
        .init("grain_sublayers_active",   .shoot),
        .init("dir_couplers_active",      .shoot),
        .init("dir_couplers_amount",      .shoot, 0...4),
        .init("density_curve_gamma",      .shoot, 0.2...4),
        .init("input_color_space",        .shoot),
        .init("input_cctf_decoding",      .shoot),
        // print side — the sliders actually dragged
        .init("print_exposure",   .print, 0.05...20, live: true),
        .init("m_filter_shift",   .print, -1...1,    live: true),
        .init("y_filter_shift",   .print, -1...1,    live: true),
        .init("c_filter_neutral", .print, 0...200),
        .init("m_filter_neutral", .print, 0...200),
        .init("y_filter_neutral", .print, 0...200),
        .init("preflash_exposure", .print, 0...1,    live: true),
        .init("enlarger_illuminant",      .print),
        .init("glare_active",             .print),
        .init("scanner_white_correction", .print),
        .init("scanner_black_correction", .print),
        .init("scanner_lens_blur",        .print, 0...20),
        .init("output_color_space",       .print),
        .init("output_cctf_encoding",     .print),
        .init("scan_film",                .print),
    ]

    static let byName: [String: ParamField] =
        Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })

    static func layer(of name: String) -> ParamLayer? { byName[name]?.layer }
    static func range(of name: String) -> ClosedRange<Double>? { byName[name]?.range }

    /// Which cache layers a delta invalidates — the client-side twin of
    /// `schema.layers_touched`. Drives whether a commit routes to `reprint`
    /// or to a full re-render, and therefore which feedback the canvas shows.
    static func layersTouched(_ delta: [String: ParamValue]) -> Set<ParamLayer> {
        Set(delta.keys.compactMap { layer(of: $0) })
    }
}

/// A transport value. JSON-RPC carries exactly these three types for params.
enum ParamValue: Sendable, Hashable, Codable {
    case number(Double)
    case flag(Bool)
    case text(String)

    var double: Double? { if case .number(let v) = self { return v }; return nil }
    var bool: Bool?     { if case .flag(let v)   = self { return v }; return nil }
    var string: String? { if case .text(let v)   = self { return v }; return nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Bool before Double: JSONDecoder will happily read `true` as 1.0,
        // and schema.py's `validate_delta` rejects a bool where a float is
        // declared, so the order here is not cosmetic.
        if let b = try? c.decode(Bool.self)   { self = .flag(b);   return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        self = .text(try c.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let v): try c.encode(v)
        case .flag(let v):   try c.encode(v)
        case .text(let v):   try c.encode(v)
        }
    }
}
