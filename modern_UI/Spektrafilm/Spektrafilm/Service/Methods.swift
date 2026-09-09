//  Methods.swift — Codable request/response types for the render service.
//
//  One type per method in `spektrafilm/service/service.py`. Field names are
//  the wire names. Additions made to the service for this client (all
//  additive, all optional on the wire) are marked `[client-added]`:
//
//    - `output: "rgba16"` on reprint / preview_render / preview_stock_lut
//      writes a raw 16-bit RGBA dump next to the TIFF, so the client uploads
//      it straight into a texture instead of decoding a TIFF whose colour
//      tags it must not trust.
//    - unique output filenames per call (a counter), so a result cannot be
//      overwritten by the next request before it is read.
//    - `export_di` — the DI package: normalised-density negative TIFF plus
//      the print stock's `.cube`.

import Foundation

struct Capabilities: Decodable, Sendable {
    let version: String
    let engine: String
    let maxMP: Double
    let tiers: [String: Int?]
    let transportVersion: Int
    let schemaVersion: Int
    let backend: Backend?

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
        /// Whether concurrent requests are safe. The client stays serial
        /// regardless until `configure_transport` is opted into.
        let concurrent: Bool?
        enum CodingKeys: String, CodingKey {
            case gpu, concurrent
            case renderCore = "render_core", gpuAvailable = "gpu_available"
            case workingPrecision = "working_precision"
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

struct OpenRequest: Encodable, Sendable {
    let imagePath: String
    var paramsDelta: [String: ParamValue]?
    enum CodingKeys: String, CodingKey { case imagePath = "image_path", paramsDelta = "params_delta" }
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

struct StockLUTRequest: Encodable, Sendable {
    let sessionID: String
    let printStock: String
    var tier = "live"
    var output = "rgba16"
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", printStock = "print_stock", tier, output }
}

struct StockLUTResponse: Decodable, Sendable {
    let previewPath: String
    let applyMs: Double
    let pairedFilm: String
    let declaredPairing: Bool
    let warning: String?
    let rawPath: String?
    let width: Int?
    let height: Int?
    enum CodingKeys: String, CodingKey {
        case previewPath = "preview_path", applyMs = "apply_ms", pairedFilm = "paired_film"
        case declaredPairing = "declared_pairing", warning, rawPath = "raw_path", width, height
    }
}

struct ExportRequest: Encodable, Sendable {
    let sessionID: String
    var format = "tiff"
    var bitDepth = 16
    var output = "rgba16"
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", format, bitDepth = "bit_depth", output }
}

struct ExportDIRequest: Encodable, Sendable {
    let sessionID: String
    let outDir: String
    let baseName: String
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", outDir = "out_dir", baseName = "base_name" }
}

struct ExportDIResponse: Decodable, Sendable {
    let diPath: String
    let cubePath: String
    let printPreviewPath: String?
    let warning: String?
    enum CodingKeys: String, CodingKey {
        case diPath = "di_path", cubePath = "cube_path", printPreviewPath = "print_preview_path", warning
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
}
