//  Methods.swift — Codable request/response types for the render service.
//
//  One type per method in `spektrafilm/service/service.py`. The field names
//  are the wire names; where a response field's meaning is not obvious from
//  its name, the comment says what the backend actually puts there, taken
//  from the source rather than from the PRD's intent.
//
//  Nothing here spawns a process. The transport is defined so the panel can
//  be built against a real contract and so the gaps in that contract (listed
//  at the bottom of this file) are visible in code rather than in a document
//  nobody re-reads.

import Foundation

// MARK: - capabilities

struct Capabilities: Codable, Sendable {
    let version: String
    let engine: String
    let maxMP: Double
    let backend: Backend
    /// Longest edge in pixels per tier. Measured on this machine:
    /// live 1600, preview 3400, full `null` (unbounded).
    let tiers: [String: Int?]
    let transportVersion: Int
    let schemaVersion: Int

    struct Backend: Codable, Sendable {
        let spectral: String
        let gpu: String
        let gpuAvailable: Bool
        let workingPrecision: String

        enum CodingKeys: String, CodingKey {
            case spectral, gpu
            case gpuAvailable = "gpu_available"
            case workingPrecision = "working_precision"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, engine, backend, tiers
        case maxMP = "max_mp"
        case transportVersion = "transport_version"
        case schemaVersion = "schema_version"
    }
}

// MARK: - open

struct OpenRequest: Encodable, Sendable {
    let imagePath: String
    var paramsDelta: [String: ParamValue]?
    enum CodingKeys: String, CodingKey {
        case imagePath = "image_path", paramsDelta = "params_delta"
    }
}

struct OpenResponse: Decodable, Sendable {
    let sessionID: String
    let meta: Meta
    /// What the service *inferred* about the input, not what it was told.
    /// RFC-010's rule: the API says what it inferred and how. Surface this;
    /// a silently mis-read colour space is a whole-image saturation error
    /// with no crash to notice.
    let detectedInput: DetectedInput
    let params: [String: ParamValue]

    struct Meta: Decodable, Sendable {
        let width: Int, height: Int, megapixels: Double, source: String
    }

    struct DetectedInput: Decodable, Sendable {
        let inputColorSpace: String
        let inputCctfDecoding: Bool
        /// How the colour space was arrived at: `rawpy-decode`, `ICC`,
        /// `metadata`, `float-linear-default`, `8bit-web-default`,
        /// `untagged-default`, `unknown-fallback`, `probe-failed`.
        let inputColorSpaceSource: String
        /// `dcraw` for RAW input, `nil` for everything else.
        let rawEngine: String?

        enum CodingKeys: String, CodingKey {
            case inputColorSpace = "input_color_space"
            case inputCctfDecoding = "input_cctf_decoding"
            case inputColorSpaceSource = "input_color_space_source"
            case rawEngine = "raw_engine"
        }
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", meta, params
        case detectedInput = "detected_input"
    }
}

// MARK: - solve

struct SolveRequest: Encodable, Sendable {
    let sessionID: String
    /// `"exposure"`, `"filter_pack"`, or `"both"`.
    var target: String = "both"
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", target }
}

/// The solve's output.
///
/// **Asymmetry worth knowing before wiring this up.** In `service.py::_m_solve`
/// the filter-pack half calls `apply_database_neutral_print_filters(params)`,
/// which mutates the session's params in place — those three neutrals stick.
/// The exposure half only *computes* an EV and returns it; it never writes
/// `camera.exposure_compensation_ev`. So a caller that solves and then renders
/// gets the solved filter pack but not the solved exposure unless it sends the
/// EV back through `set_params` itself. Listed in the gaps at the bottom.
struct SolveResult: Codable, Sendable {
    var exposureCompensationEV: Double?
    var cFilterNeutral: Double?
    var mFilterNeutral: Double?
    var yFilterNeutral: Double?

    enum CodingKeys: String, CodingKey {
        case exposureCompensationEV = "exposure_compensation_ev"
        case cFilterNeutral = "c_filter_neutral"
        case mFilterNeutral = "m_filter_neutral"
        case yFilterNeutral = "y_filter_neutral"
    }
}

struct SolveResponse: Decodable, Sendable {
    let solvedParams: SolveResult
    enum CodingKeys: String, CodingKey { case solvedParams = "solved_params" }
}

// MARK: - set_params

struct SetParamsResponse: Decodable, Sendable {
    /// `"shoot"`, `"print"` or `"none"` — which cache layer the delta killed.
    let invalidated: String
    let estCost: EstCost
    let params: [String: ParamValue]

    /// A hint for choosing "drag live" against "show a progress bar", not a
    /// promise — the service says so itself. Numbers are that machine's warm
    /// float32 + MLX timings.
    struct EstCost: Decodable, Sendable {
        let path: String                    // "reprint" | "full_render"
        let secondsByTier: [String: Double]
        enum CodingKeys: String, CodingKey {
            case path, secondsByTier = "seconds_by_tier"
        }
    }

    enum CodingKeys: String, CodingKey {
        case invalidated, params, estCost = "est_cost"
    }
}

// MARK: - reprint / preview_render / export

struct ReprintRequest: Encodable, Sendable {
    let sessionID: String
    var paramsDelta: [String: ParamValue]?
    /// `"live"` (≤1600 px), `"preview"` (≤3400 px), `"full"`.
    var tier: String = "live"
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", paramsDelta = "params_delta", tier
    }
}

struct RenderResponse: Decodable, Sendable {
    let progressID: String
    let tier: String
    let pathKind: String
    let elapsedMs: Double
    /// True only when the cheap path was *actually* taken. The service
    /// reports this separately from the request's intent on purpose: asking
    /// for a reprint against a cold negative is a ~2.5 s film-side render at
    /// the preview tier, not a 193 ms one, and the client's cost model needs
    /// to be able to tell those apart.
    let reprint: Bool
    let negativeWasCached: Bool
    /// A 16-bit TIFF in the workspace. Note the path is **stable per
    /// (session, tier, kind)** and overwritten in place on every call, so it
    /// is not usable as a cache key — see the gaps below.
    let previewPath: String?
    let exportPath: String?

    enum CodingKeys: String, CodingKey {
        case progressID = "progress_id", tier, elapsedMs = "elapsed_ms"
        case pathKind = "path_kind", reprint
        case negativeWasCached = "negative_was_cached"
        case previewPath = "preview_path", exportPath = "export_path"
    }
}

// MARK: - preview_stock_lut

struct StockLUTRequest: Encodable, Sendable {
    let sessionID: String
    let printStock: String
    var filmStock: String?
    var tier: String = "live"
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", printStock = "print_stock"
        case filmStock = "film_stock", tier
    }
}

struct StockLUTResponse: Decodable, Sendable {
    let previewPath: String
    /// Only ever `"shipped"` today. PRD §7.3 allows `"baked"`; the service
    /// returns a `no_lut_for_stock` user error instead.
    let lutSource: String
    let applyMs: Double
    let applyBackend: String            // "gpu" | "cpu"
    /// The film this LUT was baked against. If it differs from the session's
    /// film the response carries `warning` — the print+scan chain is coupled
    /// to the negative's dye spectra as well as the paper's curve, so the
    /// preview is an approximation with unmeasured error. Show the warning;
    /// do not swallow it.
    let pairedFilm: String
    let declaredPairing: Bool
    let warning: String?

    enum CodingKeys: String, CodingKey {
        case previewPath = "preview_path", lutSource = "lut_source"
        case applyMs = "apply_ms", applyBackend = "apply_backend"
        case pairedFilm = "paired_film", declaredPairing = "declared_pairing"
        case warning
    }
}

// MARK: - errors

/// The service's own taxonomy (`service/errors.py`, PRD §7.7). Preserved
/// rather than flattened to a string, because the three categories deserve
/// different UI: a `user` error is a bad input to correct, a `resource`
/// error is a limit to work under, and a `bug` is something to report with
/// its traceback intact.
struct ServiceError: Error, Decodable, Sendable {
    let code: String
    let category: String       // "user" | "resource" | "bug"
    let message: String
    let param: String?
    let traceback: String?

    var isBug: Bool { category == "bug" }
}

/// A method name, so call sites cannot typo one into a runtime failure.
enum Method: String, Sendable {
    case capabilities, params_schema, open, get_params, set_params, solve
    case preview_render, reprint, export, preview_stock_lut, progress, cancel
}

// MARK: - Gaps in the contract, as of 2026-08-28
//
// Recorded here because they are what 联调 has to resolve, and a comment in
// the type that would carry the field is harder to lose than a document.
//
// 1. `get_live_negative` and `get_print_lut` (frontend SPEC §1.3) DO NOT
//    EXIST on the service. They are what would let the negative leave the
//    Python process and be composited on the GPU at 60 fps. Without them the
//    interactive path is `reprint` at ~193 ms on release — which SPEC §1.3
//    names as the explicit fallback, so the shell is built to that and gains
//    the live path later without restructuring.
//
// 2. Render output is a TIFF at a path that is *reused*: `_render` writes
//    `{kind}_{session}_{tier}.tif` and overwrites it every call. Two renders
//    in flight would race on one file, and the path cannot key a cache. The
//    client must read the file before issuing the next call of the same kind.
//
// 3. `solve` does not apply the EV it computes (see `SolveResult`). Round-trip
//    it through `set_params`, or exposure silently stays where it was.
//
// 4. `cancel` cannot arrive mid-render on stdio (API-SPEC §10.4). Supersede
//    client-side by discarding results, and send shoot-layer changes only on
//    release.
//
// 5. No `grain_seed` (frontend SPEC §1.4). `grain_sampler` is unseeded, so the
//    same image closed and reopened exports differently. Until it lands, do
//    not claim reopening reproduces a previous export.
//
// 6. No `exposure_mask` (frontend SPEC §1.5), so `Enlarger`-target masks
//    cannot exist yet. `After print` masks are Layer 2 and need no service
//    change at all.
