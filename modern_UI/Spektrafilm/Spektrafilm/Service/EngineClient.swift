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
//  - **`open` reads the frame here.** The engine takes pixels, not a path, so
//    the linear ProPhoto TIFF the importer already writes is decoded on this
//    side and passed as a buffer. `OpenRequest` is unchanged, so nothing above
//    this class had to learn about it.
//
//  Still an `actor`, but for a different reason than before. The stdio client
//  had to be serial because the wire was one request at a time and numba's
//  workqueue layer was not threadsafe. Neither is true now — the engine
//  reports `concurrent: true` and locks per session — so this serialises only
//  to keep one engine handle's lifecycle simple, and could be relaxed with
//  measurement behind it.

import CoreImage
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
        case badResponse(String), unsupported(Method), needsRenderPath(Method)
        var description: String {
            switch self {
            case .noResources(let p): "the engine's resources are missing at \(p)"
            case .notRunning: "the render engine is not running"
            case .engine(let m): m
            case .rpc(let e): e.description
            case .badResponse(let s): "bad response: \(s)"
            case .unsupported(let m):
                "\(m.rawValue) is not implemented by the native engine yet"
            case .needsRenderPath(let m):
                "\(m.rawValue) returns a texture; call EngineClient.render(_:_:) instead"
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
            guard let req = params as? OpenRequest else {
                throw ClientError.badResponse("open needs an OpenRequest")
            }
            return try openFrame(req, as: R.self)

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

        case .reprint, .previewRender:
            // A render's result is an `MTLTexture`, and a texture cannot
            // travel through a `Decodable`. Rather than invent a JSON shape
            // that omits the only new thing, the render methods are reached
            // through `render(_:_:)` and this path refuses by name.
            throw ClientError.needsRenderPath(method)

        case .export, .exportDI, .previewStockLUT:
            // Not ported. `export` writes a file, `export_di` writes three and
            // needs the shipped print-preview LUTs, and `preview_stock_lut`
            // needs the `.cube` machinery -- none of which is on the path from
            // opening a frame to seeing it, and all of which is a subsystem
            // rather than a node. Refused by name rather than silently
            // returning something wrong.
            throw ClientError.unsupported(method)
        }
    }

    func call<R: Decodable>(_ method: Method, as: R.Type = R.self) async throws -> R {
        try await call(method, [String: String](), as: R.self)
    }

    /// A render, with the texture the engine drew into.
    func render(_ method: Method, _ request: RenderRequest) async throws -> RenderOutcome {
        if state != .running { try start() }
        return try renderTexture(method, request)
    }

    // MARK: - the two calls that are not just JSON

    private func decodeOwned<R: Decodable>(_ json: String, as: R.Type) throws -> R {
        let data = Data(json.utf8)
        do { return try JSONDecoder().decode(R.self, from: data) }
        catch { throw ClientError.badResponse(String(json.prefix(400))) }
    }

    private func openFrame<R: Decodable>(_ request: OpenRequest, as: R.Type) throws -> R {
        guard let engine else { throw ClientError.notRunning }
        let url = URL(fileURLWithPath: request.imagePath)
        let frame = try EngineClient.readLinearRGB(url)

        // One session at a time, matching the engine's own shape and the
        // frontend's: `open` on a new frame replaces the old one.
        releaseSession()

        var reply: UnsafeMutablePointer<CChar>?
        let delta = try encode(request.paramsDelta ?? [:])
        let handle: OpaquePointer? = frame.pixels.withUnsafeBufferPointer { buffer in
            var image = spk_image(data: buffer.baseAddress,
                                  width: UInt32(frame.width),
                                  height: UInt32(frame.height),
                                  channels: 3)
            return delta.withCString { deltaPtr in
                withUnsafePointer(to: &image) { imagePtr in
                    spk_open(engine, imagePtr, deltaPtr, &reply)
                }
            }
        }
        guard let handle else { throw ClientError.engine(lastError()) }
        session = handle
        let decoded: R = try decode(reply, as: R.self)
        if let open = decoded as? OpenResponse { sessionID = open.sessionID }
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

    // MARK: - the frame

    struct Frame {
        let pixels: [Float]
        let width: Int
        let height: Int
    }

    /// Read the importer's linear ProPhoto TIFF into tightly packed float32
    /// RGB, top row first.
    ///
    /// The engine takes pixels rather than a path, so this is where the file
    /// stops being the interface. Two details are load-bearing:
    ///
    /// - **No vertical flip.** `CIContext.render(_:toBitmap:...)` already
    ///   writes the buffer top row first, unlike `render(_:to:)` into a Metal
    ///   texture, which needs one (see `ImageDecoder.makePreviewTexture`).
    ///   Adding one here on the strength of "Core Image's origin is
    ///   bottom-left" produced a correctly developed, upside-down photograph
    ///   -- no crash, nothing in a log, and it survived a 27-case parity suite
    ///   because that suite hands the engine an array and never comes through
    ///   this function. `testTheFrameIsReadTopRowFirst` pins it.
    /// - **The bitmap is requested in linear ProPhoto**, the space the
    ///   importer wrote and the space `io.input_color_space` names. Asking
    ///   Core Image for the working space instead would apply a conversion the
    ///   engine then applies again.
    static func readLinearRGB(_ url: URL) throws -> Frame {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw ImageDecoder.Failure.unsupported(url)
        }
        guard let space = ImageDecoder.linearProPhoto else { throw ImageDecoder.Failure.noColorSpace }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { throw ImageDecoder.Failure.unsupported(url) }

        let placed = image.transformed(by: .init(translationX: -extent.origin.x,
                                                 y: -extent.origin.y))

        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            ImageDecoder.context.render(placed,
                                        toBitmap: raw.baseAddress!,
                                        rowBytes: width * 16,
                                        bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                        format: .RGBAf,
                                        colorSpace: space)
        }
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[3 * i] = rgba[4 * i]
            rgb[3 * i + 1] = rgba[4 * i + 1]
            rgb[3 * i + 2] = rgba[4 * i + 2]
        }
        return Frame(pixels: rgb, width: width, height: height)
    }
}
