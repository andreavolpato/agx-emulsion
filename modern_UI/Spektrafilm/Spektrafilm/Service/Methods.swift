//  Methods.swift — Codable request/response types for the render service.
//
//  One type per method in `spektrafilm/service/service.py`. Field names are
//  the wire names. Additions made to the service for this client (all
//  additive, all optional on the wire) are marked `[client-added]`:
//
//    - `export_di` — the DI package: normalised-density negative plus the
//      print stock's `.cube`.
//
//  Every reply that used to carry a *path* no longer does. The engine renders
//  into an `MTLTexture` in this process (RFC-014), so `reprint`,
//  `preview_render`, `export`, `preview_stock_lut` and `export_di` all return
//  pixels through `RenderOutcome` and leave only metadata in these types. The
//  `output: "rgba16"` field and the workspace filename counter it needed are
//  gone with the file they described.

import Foundation

struct Capabilities: Decodable, Sendable {
    let version: String
    let engine: String
    let maxMP: Double
    let tiers: [String: Int?]
    let transportVersion: Int
    let schemaVersion: Int
    let backend: Backend?

    /// The wire this build was written against (contract §2). Both are 1.
    ///
    /// Neither field is optional here, and that is the point: a service that
    /// does not report them is a service whose framing this app cannot
    /// reason about, and the contract says refuse rather than guess. The
    /// backend session nearly shipped a refactor that dropped both while its
    /// commit message said "no wire change" — a split that only moves code
    /// still moves the wire, because the wire is assembled from both halves.
    static let knownTransportVersion = 1
    static let knownSchemaVersion = 1

    /// Why this app cannot talk to this service, or nil if it can.
    ///
    /// A *newer* transport is refused; the framing or the file-handoff
    /// convention has changed under us and every subsequent read would be a
    /// guess. An *older* one is refused too, for the same reason in the other
    /// direction. Schema is a warning, not a refusal: a renamed parameter
    /// makes some sliders stop working, which is bad, but it is not a reason
    /// to refuse to show the user their photograph.
    var unsupportedTransport: String? {
        guard transportVersion != Capabilities.knownTransportVersion else { return nil }
        return "This build speaks transport version \(Capabilities.knownTransportVersion); "
             + "the render service speaks \(transportVersion). "
             + (transportVersion > Capabilities.knownTransportVersion
                ? "The service is newer than the app — update the app."
                : "The service is older than the app — rebuild it from this checkout.")
    }

    var schemaMismatch: String? {
        guard schemaVersion != Capabilities.knownSchemaVersion else { return nil }
        return "Parameter schema version \(schemaVersion); this build was written against "
             + "\(Capabilities.knownSchemaVersion). Some controls may not reach the engine."
    }

    /// Which executor is actually rendering. The client had no way to ask
    /// this and it cost real time: with the engine on a branch the app did
    /// not have, every render ran on the CPU core and the only symptom was
    /// that things felt slow. A number in a log is not a substitute for the
    /// app knowing, so this is read at `open` and shown in the status bar.
    struct Backend: Decodable, Sendable {
        /// `"metal"` · `"mlx"` · `"cpu"` (contract §6, 2026-09-10).
        let renderCore: String?
        let gpu: String?
        let gpuAvailable: Bool?
        let workingPrecision: String?
        let host: String?
        /// Whether concurrent requests are safe. The client stays serial
        /// regardless until `configure_transport` is opted into.
        let concurrent: Bool?
        /// The engine's LRU over whole sessions (RFC-013 §2). Worth having on
        /// screen next to `render_core`: it is the difference between
        /// "switching frames is slow" and "the cache evicts on every switch".
        let sessionCache: SessionCache?
        struct SessionCache: Decodable, Sendable {
            let entries: Int?, maxEntries: Int?
            let hits: Int?, misses: Int?, evictions: Int?
            let bytes: Int?, enabled: Bool?
            enum CodingKeys: String, CodingKey {
                case entries, hits, misses, evictions, bytes, enabled
                case maxEntries = "max_entries"
            }
            var summary: String {
                "cache \(entries ?? 0)/\(maxEntries ?? 0) · \(hits ?? 0) hit / \(misses ?? 0) miss"
                + ((evictions ?? 0) > 0 ? " · \(evictions!) evicted" : "")
            }
        }
        enum CodingKeys: String, CodingKey {
            case gpu, concurrent, host
            case renderCore = "render_core", gpuAvailable = "gpu_available"
            case workingPrecision = "working_precision", sessionCache = "session_cache"
        }
        /// What the status bar shows. `nil` from a service too old to report
        /// one is not the same as "cpu", and saying so is the point.
        var label: String {
            switch renderCore {
            case "metal": "Metal"
            case "mlx": "MLX"
            case "cpu": "CPU"
            case let other?: other
            case nil: "unreported"
            }
        }
        /// True only when we know we are *not* on the GPU-native core. Drives
        /// the warning, so a service that does not report the field is not
        /// accused of anything.
        var isSlowPath: Bool { renderCore == "cpu" || renderCore == "mlx" }
    }

    enum CodingKeys: String, CodingKey {
        case version, engine, tiers, backend
        case maxMP = "max_mp", transportVersion = "transport_version", schemaVersion = "schema_version"
    }
}

struct OpenResponse: Decodable, Sendable {
    let sessionID: String
    let meta: Meta
    let detectedInput: DetectedInput
    let params: [String: ParamValue]
    /// `open` echoes the full capabilities block, so the client learns which
    /// executor it got without a second round trip.
    let capabilities: Capabilities?
    struct Meta: Decodable, Sendable { let width: Int, height: Int, megapixels: Double, source: String }
    struct DetectedInput: Decodable, Sendable {
        let inputColorSpace: String
        let inputCctfDecoding: Bool
        let inputColorSpaceSource: String
        let rawEngine: String?
        enum CodingKeys: String, CodingKey {
            case inputColorSpace = "input_color_space", inputCctfDecoding = "input_cctf_decoding"
            case inputColorSpaceSource = "input_color_space_source", rawEngine = "raw_engine"
        }
    }
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", meta, params, capabilities
        case detectedInput = "detected_input"
    }
}

struct SolveRequest: Encodable, Sendable {
    let sessionID: String
    var target = "both"
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", target }
}

struct SolveResponse: Decodable, Sendable {
    let solvedParams: [String: Double]
    enum CodingKeys: String, CodingKey { case solvedParams = "solved_params" }
}

struct SetParamsRequest: Encodable, Sendable {
    let sessionID: String
    let paramsDelta: [String: ParamValue]
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", paramsDelta = "params_delta" }
}

struct SetParamsResponse: Decodable, Sendable {
    let invalidated: String
    let params: [String: ParamValue]
}

struct RenderRequest: Encodable, Sendable {
    let sessionID: String
    var paramsDelta: [String: ParamValue]?
    var tier = "live"
    /// preview_render only: "shoot" forces the film side to run.
    var layer: String?
    var targetPx: Int?
    var output = "rgba16"
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", paramsDelta = "params_delta", tier, layer, output
        case targetPx = "target_px"
    }
}

struct RenderResponse: Decodable, Sendable {
    let progressID: String
    let tier: String
    let elapsedMs: Double
    let reprint: Bool
    let negativeWasCached: Bool
    let previewPath: String?
    let exportPath: String?
    /// [client-added] raw 16-bit RGBA, `width`×`height`, row-major, top row first.
    let rawPath: String?
    let width: Int?
    let height: Int?
    enum CodingKeys: String, CodingKey {
        case progressID = "progress_id", tier, reprint, width, height
        case elapsedMs = "elapsed_ms", negativeWasCached = "negative_was_cached"
        case previewPath = "preview_path", exportPath = "export_path", rawPath = "raw_path"
    }
}

/// `preview_stock_lut`'s reply, pixels aside.
///
/// No paths any more: the engine hands back a texture the way every other
/// render does, so what is left here is the metadata — how long the table
/// lookup took, which film the table was baked against, and whether that is
/// the film this session is using.
struct StockLUTResponse: Decodable, Sendable {
    let printStock: String
    let tier: String
    let applyMs: Double
    let applyBackend: String
    let lutSource: String
    let pairedFilm: String
    let declaredPairing: Bool
    /// Present exactly when the session's film is not `pairedFilm`. The table
    /// is baked through a specific negative's dye spectra as well as through
    /// the paper, so a mismatched film is an approximation whose error nobody
    /// has measured (PRD §7.3) — which is worth saying rather than hiding.
    let warning: String?
    enum CodingKeys: String, CodingKey {
        case tier, warning
        case printStock = "print_stock", applyMs = "apply_ms", applyBackend = "apply_backend"
        case lutSource = "lut_source", pairedFilm = "paired_film", declaredPairing = "declared_pairing"
    }
}

/// One print stock's entry in `spk_print_lut_catalog`.
struct PrintLUTEntry: Decodable, Sendable {
    let pairedFilm: String
    let declaredPairing: Bool
    let lutSize: Int
    enum CodingKeys: String, CodingKey {
        case pairedFilm = "paired_film", declaredPairing = "declared_pairing", lutSize = "lut_size"
    }
}

struct ExportRequest: Encodable, Sendable {
    let sessionID: String
    var format = "tiff"
    var bitDepth = 16
    var output = "rgba16"
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", format, bitDepth = "bit_depth", output }
}

/// `export_di`'s reply, pixels aside.
///
/// The three files are the client's business now, so no paths cross: the
/// engine returns the normalised-density picture as a texture and the LUT as
/// a pointer (`spk_print_lut_table`), and `Exporter` writes the TIFF, the
/// `.cube` and the optional print preview from those.
struct ExportDIResponse: Decodable, Sendable {
    let printStock: String
    let lutSize: Int
    let pairedFilm: String
    let declaredPairing: Bool
    let warning: String?
    enum CodingKeys: String, CodingKey {
        case warning
        case printStock = "print_stock", lutSize = "lut_size"
        case pairedFilm = "paired_film", declaredPairing = "declared_pairing"
    }
}

/// The service's own error taxonomy (`service/errors.py`).
struct ServiceError: Error, Decodable, Sendable, CustomStringConvertible {
    let code: String
    let category: String
    let message: String
    let param: String?
    let traceback: String?
    var description: String { "\(category): \(message)" + (param.map { " (\($0))" } ?? "") }
}

enum Method: String, Sendable {
    case capabilities, paramsSchema = "params_schema", open, getParams = "get_params"
    case setParams = "set_params", solve, previewRender = "preview_render", reprint, export
    case previewStockLUT = "preview_stock_lut", progress, cancel, exportDI = "export_di"
    /// `close` is deliberately absent: the engine has a `close()` but it is
    /// not dispatchable over the wire, and a `Method` case for it would be a
    /// call that always fails.
    case warmUp = "warm_up"
}

/// `warm_up` — pay the first frame's fixed setup before the user is looking
/// (RFC-013 §3). Every field is optional on the wire, but pass the stocks the
/// frame will actually open with: the engine builds a pipeline for the pair it
/// is given, and warming a pair the first `open` will not use is pure waste.
struct WarmUpRequest: Encodable, Sendable {
    var filmStock: String?
    var printStock: String?
    enum CodingKeys: String, CodingKey { case filmStock = "film_stock", printStock = "print_stock" }
}

struct WarmUpResponse: Decodable, Sendable {
    let alreadyWarm: Bool?
    let renderCore: String?
    let totalMs: Double?
    let steps: [Step]?
    /// A step that failed is **not** fatal: the work is simply paid again
    /// inside `open`. Log it and carry on (handoff §3.1).
    struct Step: Decodable, Sendable {
        let name: String
        let ok: Bool?
        let ms: Double?
    }
    enum CodingKeys: String, CodingKey {
        case steps
        case alreadyWarm = "already_warm", renderCore = "render_core", totalMs = "total_ms"
    }
    /// The names of the steps the engine reported as failed.
    var failedSteps: [String] { (steps ?? []).filter { $0.ok == false }.map(\.name) }
}
