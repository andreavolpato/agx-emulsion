//  ServiceClient.swift — the stdio JSON-RPC client. Defined, not yet launched.
//
//  Step one of the build deliberately does not hook this up: the shell is
//  verified on its own first (UI-GUIDELINE §10 steps 1–3), and the service is
//  step 4. What exists here is the transport, correct and complete, so that
//  wiring it up later is a call site change and not a redesign.
//
//  An `actor`, because the transport is single-flight by design and not by
//  accident: `transport.py` handles one request at a time on the main thread
//  because numba's `workqueue` threading layer is not threadsafe and aborts
//  the *process* on concurrent entry (API-SPEC §10.5). The actor makes that a
//  compile-time property instead of a convention someone breaks later.
//
//  One process per app launch, never per request: API-SPEC §10.5 measured a
//  1.76 s import plus a one-time JIT cost, and flat RSS with no drift over 12
//  consecutive reprints. Process-per-request pays the import on every slider
//  release.

import Foundation

actor ServiceClient {
    enum Failure: Error, LocalizedError {
        case notRunning
        case terminated(status: Int32, stderr: String)
        case badResponse(String)
        case service(ServiceError)

        var errorDescription: String? {
            switch self {
            case .notRunning: "the render service is not running"
            case .terminated(let s, let e): "the render service exited (\(s))\n\(e)"
            case .badResponse(let m): "malformed response: \(m)"
            case .service(let e): e.message
            }
        }
    }

    private var process: Process?
    private var toService: FileHandle?
    private var fromService: FileHandle?
    private var stderrTail: [String] = []
    private var nextID = 1
    /// Bytes read from stdout that do not yet form a complete line. The
    /// service writes one JSON object per line; a pipe read does not respect
    /// that boundary, so partial lines must be carried across reads.
    private var inbox = Data()

    // MARK: - lifecycle

    /// Launch `python -m spektrafilm.service --workspace <dir>`.
    ///
    /// `interpreter` is the bundled standalone CPython once bundling lands
    /// (UI-GUIDELINE §9); during development it is the repo's `.venv`.
    func start(interpreter: URL, repoRoot: URL, workspace: URL) throws {
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = interpreter
        p.arguments = ["-m", "spektrafilm.service", "--workspace", workspace.path]
        p.currentDirectoryURL = repoRoot

        var env = ProcessInfo.processInfo.environment
        // §9: the bundled interpreter must not be shadowed by a user
        // site-packages directory.
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe

        // An unread stderr pipe eventually fills and blocks the child, and the
        // tail is the only diagnostic when the service dies mid-render.
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.appendStderr(text) }
        }

        try p.run()
        process = p
        toService = inPipe.fileHandleForWriting
        fromService = outPipe.fileHandleForReading
        inbox = Data()
    }

    func stop() {
        toService?.closeFile()
        process?.terminate()
        process = nil; toService = nil; fromService = nil
    }

    var isRunning: Bool { process?.isRunning ?? false }
    var recentStderr: String { stderrTail.suffix(40).joined(separator: "\n") }

    private func appendStderr(_ text: String) {
        stderrTail.append(contentsOf: text.split(separator: "\n").map(String.init))
        if stderrTail.count > 200 { stderrTail.removeFirst(stderrTail.count - 200) }
    }

    // MARK: - calling

    func call<Response: Decodable>(_ method: Method,
                                   _ params: some Encodable = EmptyParams(),
                                   as: Response.Type = Response.self) throws -> Response {
        let line = try roundTrip(method: method.rawValue, params: params)
        let envelope = try JSONDecoder().decode(Envelope<Response>.self, from: line)
        if let error = envelope.error {
            // `data` carries the service's own taxonomy; the JSON-RPC `code`
            // is only a transport code and says nothing about the category.
            throw Failure.service(error.data ?? ServiceError(
                code: "transport", category: "bug",
                message: error.message, param: nil, traceback: nil))
        }
        guard let result = envelope.result else {
            throw Failure.badResponse("neither result nor error")
        }
        return result
    }

    private func roundTrip(method: String, params: some Encodable) throws -> Data {
        guard let toService, let fromService, process?.isRunning == true else {
            throw Failure.notRunning
        }
        nextID += 1
        let request = Request(id: nextID, method: method, params: params)
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)                                  // newline framing
        try toService.write(contentsOf: payload)

        while true {
            if let newline = inbox.firstIndex(of: 0x0A) {
                let line = inbox[inbox.startIndex..<newline]
                inbox.removeSubrange(inbox.startIndex...newline)
                if !line.isEmpty { return Data(line) }
                continue
            }
            let chunk = fromService.availableData
            if chunk.isEmpty {
                let status = process?.terminationStatus ?? -1
                throw Failure.terminated(status: status, stderr: recentStderr)
            }
            inbox.append(chunk)
        }
    }

    // MARK: - wire shapes

    struct EmptyParams: Encodable, Sendable {}

    private struct Request<P: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: P
    }

    private struct Envelope<R: Decodable>: Decodable {
        let result: R?
        let error: ErrorBody?

        struct ErrorBody: Decodable {
            let code: Int
            let message: String
            let data: ServiceError?
        }
    }
}
