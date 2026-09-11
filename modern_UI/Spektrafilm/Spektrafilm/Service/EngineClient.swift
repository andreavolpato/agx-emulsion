//  EngineClient.swift — the render engine, in this process.
//
//  Replaces `ServiceClient`: no subprocess, no JSON-RPC framing, no workspace
//  directory, no `<repo>/.venv/bin/python`. The engine is C++ compiled into
//  this binary (RFC-014), reached through the `extern "C"` surface in
//  `spk_engine.h`, and it renders into an `MTLTexture` this app's own
//  `MTLDevice` can draw.
//
//  **The method surface is deliberately unchanged.** `call(_:_:as:)` takes the
//  same `Method` and the same `Encodable` request types and returns the same
//  `Decodable` response types as the stdio client did, because the engine
//  still speaks the same parameter schema and reports the same two version
//  numbers (contract §2). Requests are encoded to JSON, handed across as a
//  `const char*`, and the reply is decoded from the JSON that comes back. That
//  is not vestigial: parameters are small, the schema already exists, and a
//  struct-per-parameter boundary would break every time a slider is added
//  (RFC-014 §2.1).
//
//  What *did* change, and had to:
//
//  - **Renders return a texture, not a path.** `render(_:_:)` returns a
//    `RenderOutcome` carrying the `MTLTexture` the engine rendered into. The
//    old path wrote a raw rgba16 file and the client read it back — 10 ms of a
//    30.6 ms reprint, and a 364 MB file at the full tier. That file is gone.
//  - **`open` takes pixels, not a path.** `open(_:paramsDelta:)` hands the
//    engine an `EngineFrame` — the decode rendered into a shared `MTLBuffer`
//    — and the engine borrows it for the call (`spk_open_device`). There used
//    to be a file here: the importer wrote a 364 MB linear TIFF and this class
//    read it back, 6.4–7.1 s of a 45 MP open against a 47 ms render
//    (HANDOFF-OPEN-PATH). `call(.open, …)` is refused by name, like the
//    render methods, because what it needs does not fit through JSON.
//
//  Still an `actor`, but for a different reason than before. The stdio client
//  had to be serial because the wire was one request at a time and numba's
//  workqueue layer was not threadsafe. Neither is true now — the engine
//  reports `concurrent: true` and locks per session — so this serialises only
//  to keep one engine handle's lifecycle simple, and could be relaxed with
//  measurement behind it.

import Foundation
import Metal

/// One render's result: the reply the frontend already knows how to read, plus
/// the texture it used to have to load from a file.
///
/// `@unchecked Sendable` because `MTLTexture` is not `Sendable` and a texture
/// is exactly what this exists to carry. The same compromise `DetailEntry`
/// makes, for the same reason.
struct RenderOutcome: @unchecked Sendable {
    let response: RenderResponse
    let texture: MTLTexture?
}

/// `preview_stock_lut`'s result: the same kind of texture a render returns,
/// plus the metadata that says which table produced it.
struct StockLUTOutcome: @unchecked Sendable {
    let meta: StockLUTResponse
    let texture: MTLTexture?
    let width: Int
    let height: Int
}

/// `export_di`'s picture half. The `.cube` is fetched separately, through
/// `printLUTTable(_:)`, because it is a table rather than an image.
struct DIOutcome: @unchecked Sendable {
    let meta: ExportDIResponse
    let texture: MTLTexture?
    let width: Int
    let height: Int
}

actor EngineClient {
    enum State: Sendable, Equatable { case stopped, starting, running, failed(String) }

    private(set) var state: State = .stopped
    private var engine: OpaquePointer?
    private var session: OpaquePointer?
    private var sessionID: String?
    private let device: MTLDevice
    let resources: URL

    /// Kept for source compatibility with the callers that used to need it.
    /// Nothing spawns a process any more, so nothing can terminate.
    var onTermination: (@Sendable (String) -> Void)?

    init(device: MTLDevice, resources: URL? = nil) {
        self.device = device
        self.resources = resources ?? EngineClient.defaultResources()
    }

    /// Where the baked constants, the film profiles and the Metal library are.
    ///
    /// In the shipped app they are in the bundle, which is the whole point:
    /// the app carries its own engine and its own data and does not walk up to
    /// a checkout. `SPEKTRAFILM_ENGINE_RESOURCES` and the repo fallback exist
    /// for a build run out of the tree, where `engine/build.sh bundle` may not
    /// have been run yet — and the fallback is *named* so a frame that renders
    /// from the repo instead of the bundle is visible rather than surprising.
    /// The bundle that carries Resources/: the app, or the test bundle.
    ///
    /// `Bundle.main` is wrong here and wrong in a way that only shows up under
    /// test: the unit-test target is standalone (no TEST_HOST), so
    /// `Bundle.main` is Xcode's test agent and every lookup misses. Same
    /// resolution `StockCatalog` uses, for the same reason.
    static var bundle: Bundle { Bundle(for: BundleToken.self) }
    private final class BundleToken {}

    static func defaultResources() -> URL {
        if let env = ProcessInfo.processInfo.environment["SPEKTRAFILM_ENGINE_RESOURCES"],
           !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        if let bundled = bundle.url(forResource: "spektrafilm_constants", withExtension: "bin",
                                    subdirectory: "Resources/engine") {
            return bundled.deletingLastPathComponent()
        }
        var url = bundle.bundleURL
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            let candidate = url.appending(path: "engine/resources")
            if FileManager.default.fileExists(atPath: candidate.appending(path: "spektrafilm_constants.bin").path) {
                return candidate
            }
        }
        return bundle.bundleURL.appending(path: "Contents/Resources/Resources/engine")
    }

    /// True when the engine is reading its resources from the app bundle
    /// rather than from a checkout. Surfaced in `capabilities` so the status
    /// bar can say which — the lesson of a whole session spent measuring an
    /// engine nobody was running.
    var resourcesAreBundled: Bool {
        resources.path.hasPrefix(EngineClient.bundle.bundleURL.path)
    }

    func start() throws {
        guard state != .running, state != .starting else { return }
        state = .starting
        let constants = resources.appending(path: "spektrafilm_constants.bin")
        guard FileManager.default.fileExists(atPath: constants.path) else {
            let why = "the engine's resources are missing at \(resources.path); "
                    + "run engine/build.sh bundle"
            state = .failed(why)
            throw ClientError.noResources(resources.path)
        }
        // The app's own device goes in, so the engine renders into textures
        // this app can draw and nothing is copied across a process boundary.
        guard let handle = resources.path.withCString({ path in
            spk_engine_create(path, Unmanaged.passUnretained(device).toOpaque())
        }) else {
            let why = String(cString: spk_last_error(nil))
            state = .failed(why)
            throw ClientError.engine(why)
        }
        engine = handle
        state = .running
    }

    func stop() {
        releaseSession()
        if let engine { spk_engine_destroy(engine) }
        engine = nil
        state = .stopped
    }

    private func releaseSession() {
        if let session { spk_session_release(session) }
        session = nil
        sessionID = nil
    }

    enum ClientError: Error, CustomStringConvertible {
        case noResources(String), notRunning, engine(String), rpc(ServiceError)
        case badResponse(String), needsRenderPath(Method), needsFrame
        var description: String {
            switch self {
            case .noResources(let p): "the engine's resources are missing at \(p)"
            case .notRunning: "the render engine is not running"
            case .engine(let m): m
            case .rpc(let e): e.description
            case .badResponse(let s): "bad response: \(s)"
            case .needsRenderPath(let m):
                "\(m.rawValue) returns a texture; call EngineClient.render(_:_:) instead"
            case .needsFrame:
                "open takes pixels; call EngineClient.open(_:paramsDelta:) with an EngineFrame"
            }
        }
    }

    private func lastError() -> String {
        guard let engine else { return "the render engine is not running" }
        return String(cString: spk_last_error(engine))
    }

    /// Take ownership of a `char*` the engine allocated and decode it.
    private func decode<R: Decodable>(_ buffer: UnsafeMutablePointer<CChar>?, as: R.Type) throws -> R {
        guard let buffer else { throw ClientError.badResponse("no reply") }
        defer { spk_string_free(buffer) }
        let data = Data(bytes: buffer, count: strlen(buffer))
        do { return try JSONDecoder().decode(R.self, from: data) }
        catch { throw ClientError.badResponse(String(decoding: data.prefix(400), as: UTF8.self)) }
    }

    private func encode<P: Encodable>(_ params: P) throws -> String {
        String(decoding: try JSONEncoder().encode(params), as: UTF8.self)
    }

    // MARK: - the method surface

    func call<P: Encodable, R: Decodable>(_ method: Method, _ params: P,
                                          as: R.Type = R.self) async throws -> R {
        if state != .running { try start() }
        guard let engine else { throw ClientError.notRunning }
        let handle = engine

        switch method {
        case .capabilities:
            return try decodeOwned(String(cString: spk_capabilities(handle)), as: R.self)
        case .paramsSchema:
            return try decodeOwned(String(cString: spk_params_schema(handle)), as: R.self)

        case .warmUp:
            let req = params as? WarmUpRequest
            var out: UnsafeMutablePointer<CChar>?
            let status = spk_warm_up(handle, req?.filmStock, req?.printStock, &out)
            guard status == SPK_OK else { throw ClientError.engine(lastError()) }
            return try decode(out, as: R.self)

        case .open:
            throw ClientError.needsFrame

        case .getParams:
            var out: UnsafeMutablePointer<CChar>?
            guard let session, spk_get_params(session, &out) == SPK_OK else {
                throw ClientError.engine(lastError())
            }
            return try decode(out, as: R.self)

        case .setParams:
            guard let session else { throw ClientError.notRunning }
            var out: UnsafeMutablePointer<CChar>?
            let json = try encode((params as? SetParamsRequest)?.paramsDelta ?? [:])
            guard json.withCString({ spk_set_params(session, $0, &out) }) == SPK_OK else {
                throw ClientError.engine(lastError())
            }
            return try decode(out, as: R.self)

        case .solve:
            guard let session else { throw ClientError.notRunning }
            let target = (params as? SolveRequest)?.target ?? "both"
            var out: UnsafeMutablePointer<CChar>?
            guard target.withCString({ spk_solve(session, $0, &out) }) == SPK_OK else {
                throw ClientError.engine(lastError())
            }
            return try decode(out, as: R.self)

        case .progress:
            guard let session else { throw ClientError.notRunning }
            var out: UnsafeMutablePointer<CChar>?
            guard spk_progress(session, nil, &out) == SPK_OK else {
                throw ClientError.engine(lastError())
            }
            return try decode(out, as: R.self)

        case .cancel:
            if let session { spk_cancel(session, nil) }
            return try decodeOwned("{}", as: R.self)

        case .reprint, .previewRender, .export, .exportDI, .previewStockLUT:
            // Every one of these produces an `MTLTexture`, and a texture
            // cannot travel through a `Decodable`. Rather than invent a JSON
            // shape that omits the only thing the caller wanted, they are
            // reached through `render(_:_:)`, `previewStockLUT(_:tier:)` and
            // `exportDI(printStock:)`, and this path refuses by name.
            //
            // The last three used to be refused as *unimplemented*
            // (ARCHITECTURE §8.8). They are implemented now; what is left is
            // that the reply does not fit through this door.
            throw ClientError.needsRenderPath(method)
        }
    }

    func call<R: Decodable>(_ method: Method, as: R.Type = R.self) async throws -> R {
        try await call(method, [String: String](), as: R.self)
    }

    /// A render, with the texture the engine drew into.
    ///
    /// `.export` is `.reprint` at the full tier and is spelled separately
    /// because the caller means something different by it: the reference's
    /// `RenderEngine.export` reuses the working-resolution negative when one
    /// is warm and renders the film side when it is not, which is exactly
    /// `spk_reprint`'s own contract.
    func render(_ method: Method, _ request: RenderRequest) async throws -> RenderOutcome {
        if state != .running { try start() }
        return try renderTexture(method, request)
    }

    // MARK: - the baked print LUTs

    /// Which print stocks have a shipped preview LUT, and what each was baked
    /// against. Empty when none are bundled — which is a fact about the
    /// build, so callers hide the feature rather than failing at it.
    func printLUTCatalog() throws -> [String: PrintLUTEntry] {
        if state != .running { try start() }
        guard let engine else { throw ClientError.notRunning }
        let json = String(cString: spk_print_lut_catalog(engine))
        return (try? JSONDecoder().decode([String: PrintLUTEntry].self, from: Data(json.utf8))) ?? [:]
    }

    /// One stock's table, copied out of the engine.
    ///
    /// The pointer the engine hands over is valid for the engine's lifetime,
    /// so wrapping it would work and would also be a dangling read the first
    /// time someone tears the engine down while a `.cube` is being written.
    /// 431 kB copied once per export is not worth that.
    func printLUTTable(_ printStock: String) throws -> (size: Int, table: [Float]) {
        if state != .running { try start() }
        guard let engine else { throw ClientError.notRunning }
        var pointer: UnsafePointer<Float>?
        var size: UInt32 = 0
        guard printStock.withCString({ spk_print_lut_table(engine, $0, &pointer, &size) }) == SPK_OK,
              let pointer, size > 1 else { throw ClientError.engine(lastError()) }
        let count = Int(size) * Int(size) * Int(size) * 3
        return (Int(size), Array(UnsafeBufferPointer(start: pointer, count: count)))
    }

    /// Flip to another print stock by table lookup rather than by re-running
    /// the print+scan chain.
    ///
    /// Measured on this engine at 45 MP, warm, against a reprint of the same
    /// tier: **2.0 ms against 9 ms** at live, 9.5 against 34 at preview,
    /// 47 against 167 at full. About 4x, because the cached negative goes
    /// through one trilinear sample instead of the print chain's dozen nodes
    /// — not the 190x in HANDOFF-PRINT-LUT §3.1, which was this kernel
    /// against *scipy on the CPU* and is the wrong comparison for a user who
    /// would otherwise have got a real reprint.
    ///
    /// What it leaves out is `scanning.glare` — spatial and stochastic, and
    /// not representable in a pointwise table — and the *user's* print grade:
    /// the table bakes the chain at the bake's own settings, so print
    /// exposure and the filter pack do not reach it. Both are why this is a
    /// look preview and `.export` still runs the real pipeline.
    func previewStockLUT(_ printStock: String, tier: String = "live") async throws -> StockLUTOutcome {
        if state != .running { try start() }
        guard let session else { throw ClientError.notRunning }
        var result = spk_result()
        var reply: UnsafeMutablePointer<CChar>?
        let status = printStock.withCString { stock in
            tier.withCString { t in spk_preview_stock_lut(session, stock, t, &result, &reply) }
        }
        guard status == SPK_OK else { throw ClientError.engine(lastError()) }
        let texture = result.texture.map { Unmanaged<MTLTexture>.fromOpaque($0).takeRetainedValue() }
        let meta: StockLUTResponse = try decode(reply, as: StockLUTResponse.self)
        return StockLUTOutcome(meta: meta, texture: texture,
                               width: Int(result.width), height: Int(result.height))
    }

    /// The DI package's picture: the full-tier negative normalised to [0, 1]
    /// by the print LUT's own density axes. Layer 2 does not apply to it and
    /// must not be baked in — it is pre-print by definition.
    func exportDI(printStock: String? = nil) async throws -> DIOutcome {
        if state != .running { try start() }
        guard let session else { throw ClientError.notRunning }
        var result = spk_result()
        var reply: UnsafeMutablePointer<CChar>?
        let status: spk_status
        if let printStock {
            status = printStock.withCString { spk_export_di(session, $0, &result, &reply) }
        } else {
            status = spk_export_di(session, nil, &result, &reply)
        }
        guard status == SPK_OK else { throw ClientError.engine(lastError()) }
        let texture = result.texture.map { Unmanaged<MTLTexture>.fromOpaque($0).takeRetainedValue() }
        let meta: ExportDIResponse = try decode(reply, as: ExportDIResponse.self)
        return DIOutcome(meta: meta, texture: texture,
                         width: Int(result.width), height: Int(result.height))
    }

    // MARK: - the two calls that are not just JSON

    private func decodeOwned<R: Decodable>(_ json: String, as: R.Type) throws -> R {
        let data = Data(json.utf8)
        do { return try JSONDecoder().decode(R.self, from: data) }
        catch { throw ClientError.badResponse(String(json.prefix(400))) }
    }

    /// Open one frame: the engine borrows `frame`'s buffer for this call, runs
    /// `spk_take_rgb` into its own source, and keeps nothing of the caller's —
    /// so the caller can (and should) drop `frame` as soon as this returns.
    ///
    /// One session at a time, matching the engine's own shape and the
    /// frontend's: `open` on a new frame replaces the old one.
    func open(_ frame: EngineFrame, paramsDelta: [String: ParamValue]?) throws -> OpenResponse {
        if state != .running { try start() }
        guard let engine else { throw ClientError.notRunning }
        releaseSession()

        var reply: UnsafeMutablePointer<CChar>?
        let delta = try encode(paramsDelta ?? [:])
        let started = Date()
        var image = spk_device_image(buffer: Unmanaged.passUnretained(frame.buffer).toOpaque(),
                                     width: UInt32(frame.width),
                                     height: UInt32(frame.height),
                                     channels: UInt32(frame.channels))
        let handle: OpaquePointer? = delta.withCString { deltaPtr in
            withUnsafePointer(to: &image) { spk_open_device(engine, $0, deltaPtr, &reply) }
        }
        // What the engine does with the buffer: one kernel to its own
        // three-channel source, and the pipeline for the stock pair. There is
        // no host copy left to time — that was 235 ms of 727 MB at 45 MP.
        EngineClient.logOpen(String(format: "engine.open: %d×%d, %.0f MB borrowed, %.0f ms",
                                    frame.width, frame.height,
                                    Double(frame.buffer.length) / 1e6,
                                    Date().timeIntervalSince(started) * 1000))
        guard let handle else { throw ClientError.engine(lastError()) }
        session = handle
        let decoded: OpenResponse = try decode(reply, as: OpenResponse.self)
        sessionID = decoded.sessionID
        return decoded
    }

    private func renderTexture(_ method: Method, _ request: RenderRequest) throws -> RenderOutcome {
        guard let session else { throw ClientError.notRunning }
        // A `params_delta` on a render is applied first, which is what the
        // wire's `reprint(params_delta:)` meant.
        if let delta = request.paramsDelta, !delta.isEmpty {
            var out: UnsafeMutablePointer<CChar>?
            let json = try encode(delta)
            guard json.withCString({ spk_set_params(session, $0, &out) }) == SPK_OK else {
                throw ClientError.engine(lastError())
            }
            if let out { spk_string_free(out) }
        }

        var result = spk_result()
        // `preview_render` forces the film side to run; `reprint` reuses the
        // cached negative. That is the same distinction the two engine
        // entry points make.
        let status = request.tier.withCString { tier in
            method == .previewRender
                ? spk_render(session, tier, &result)
                : spk_reprint(session, tier, &result)
        }
        guard status == SPK_OK else { throw ClientError.engine(lastError()) }

        // `+1`, per spk_engine.h: the engine handed over its only reference and
        // ARC owns it from here. `takeUnretainedValue` would free the pixels
        // out from under the canvas the moment this scope ended.
        let texture = result.texture.map { Unmanaged<MTLTexture>.fromOpaque($0).takeRetainedValue() }
        let response = RenderResponse(
            progressID: withUnsafeBytes(of: result.progress_id) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            },
            tier: request.tier,
            elapsedMs: result.elapsed_ms,
            reprint: result.reprint != 0,
            negativeWasCached: result.negative_was_cached != 0,
            previewPath: nil,
            exportPath: nil,
            // No file is written any more, and saying so with `nil` is better
            // than inventing a path nothing can open.
            rawPath: nil,
            width: Int(result.width),
            height: Int(result.height))
        return RenderOutcome(response: response, texture: texture)
    }

    // MARK: - the open-path log

    /// On the same switch the canvas and the session read
    /// (`SPEKTRAFILM_CANVAS_LOG=1`), so that one run prints one story.
    ///
    /// Kept after the file handoff it was written to expose had gone, for the
    /// reason it was written: `Session`'s clock once called 6.2 s of reading a
    /// TIFF back `service.open`, a name that sounded like the engine working,
    /// and it took two sessions to notice (HANDOFF-OPEN-PATH §7). A number
    /// that names its cause is the cheap defence against that happening again.
    ///
    /// Read here rather than borrowed from `Renderer.logDraws`, which is
    /// main-actor-isolated and out of reach from this actor.
    private nonisolated static let logsOpenPath =
        ProcessInfo.processInfo.environment["SPEKTRAFILM_CANVAS_LOG"] == "1"

    private nonisolated static func logOpen(_ message: String) {
        guard logsOpenPath else { return }
        FileHandle.standardError.write(Data("session: \(message)\n".utf8))
    }
}
