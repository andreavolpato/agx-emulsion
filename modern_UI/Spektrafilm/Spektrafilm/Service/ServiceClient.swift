//  ServiceClient.swift — one long-lived render service over stdio.
//  JSON-RPC 2.0 over stdio, one request at a time.
//
//  An actor, so the single-flight property of the transport is enforced by
//  the compiler instead of by convention. Large data never crosses this
//  channel: the service writes files and returns paths.
//
//  Single-flight was originally a *requirement* — numba's `workqueue` layer
//  is not threadsafe (API-SPEC §10.5). On the GPU-native core it is no longer
//  one: the service verified concurrent entry and reports
//  `capabilities.backend.concurrent`, with an opt-in `configure_transport`
//  that makes replies arrive in completion order. This client stays serial
//  until that is tested here, but it no longer *assumes* the next line is its
//  reply — see `call`. Turning it on is a frontend decision with a real prize
//  behind it (a full-resolution render behind a live slider drag) and a real
//  risk in front of it, and it should not ride along with anything else.

import Foundation

actor ServiceClient {
    enum State: Sendable, Equatable { case stopped, starting, running, failed(String) }

    private(set) var state: State = .stopped
    private var process: Process?
    private var stdin: FileHandle?
    private var reader: LineReader?
    private var nextID = 1
    let workspace: URL
    let repo: URL

    /// Called on the main actor when the process ends unexpectedly.
    var onTermination: (@Sendable (String) -> Void)?

    init(repo: URL, workspace: URL) {
        self.repo = repo
        self.workspace = workspace
    }

    static func defaultRepo() -> URL {
        if let env = ProcessInfo.processInfo.environment["SPEKTRAFILM_REPO"] {
            return URL(fileURLWithPath: env)
        }
        if let stored = UserDefaults.standard.string(forKey: "repoPath"), !stored.isEmpty {
            return URL(fileURLWithPath: stored)
        }
        // The app lives at <repo>/modern_UI/Spektrafilm/...; walk up until
        // `src/spektrafilm` is found.
        var url = Bundle.main.bundleURL
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appending(path: "src/spektrafilm").path) { return url }
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Documents/Summer 2026/spektrafilm")
    }

    /// The environment the service process is launched with.
    ///
    /// Pulled out of `start()` for one reason: `PYTHONPATH` here is
    /// load-bearing in a way that is invisible at the call site, and a
    /// property that only exists in a comment is a property that rots. This
    /// is testable; the comment was not.
    ///
    /// **`PYTHONPATH` is not redundant with the editable install.** It looks
    /// it — `spektrafilm` is installed editable in the venv, so the
    /// interpreter resolves the package without help. But an editable install
    /// pins a `.pth` to *one* checkout's `src`, whichever `pip install -e` was
    /// run from, and it keeps pointing there however many worktrees exist and
    /// whichever one the app was built from. `PYTHONPATH` takes precedence
    /// over that `.pth`, and it is what guarantees the engine that renders is
    /// the engine sitting next to the binary the user launched.
    ///
    /// Without it, a build from one worktree renders with another worktree's
    /// engine, silently, and the only symptom is that the picture is subtly
    /// not what the code in front of you says it should be. That is
    /// HANDOFF-GPU-WIRING §0 verbatim — the session that landed a day of work
    /// against a backend nobody was running. It is also why the app is immune
    /// to a trap that bare `python` and `pytest` are not: the backend session
    /// measured a no-op A/B across two worktrees because both arms imported
    /// the same pinned source (contract §5, 2026-09-10).
    static func childEnvironment(repo: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONPATH"] = repo.appending(path: "src").path
        return env
    }

    func start() throws {
        guard state != .running, state != .starting else { return }
        state = .starting
        let env = ProcessInfo.processInfo.environment
        let nativeHost = env["SPEKTRAFILM_NATIVE_HOST"].flatMap { value in
            value.isEmpty ? nil : URL(fileURLWithPath: value)
        }
        let python = repo.appending(path: ".venv/bin/python")
        let executable = nativeHost ?? python
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            state = .failed("no service executable at \(executable.path)")
            throw ClientError.noServiceExecutable(executable.path)
        }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = executable
        p.arguments = nativeHost == nil
            ? ["-W", "ignore", "-m", "spektrafilm.service", "--workspace", workspace.path]
            : ["--repo", repo.path, "--workspace", workspace.path]
        p.currentDirectoryURL = repo
        p.environment = ServiceClient.childEnvironment(repo: repo)
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        let stderrLog = workspace.appending(path: "service.stderr.log")
        FileManager.default.createFile(atPath: stderrLog.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: stderrLog)
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { try? errHandle.write(contentsOf: d) }
        }
        let term = onTermination
        p.terminationHandler = { proc in
            let reason = "render service exited (status \(proc.terminationStatus)); see \(stderrLog.path)"
            Task { @MainActor in term?(reason) }
        }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        reader = LineReader(handle: outPipe.fileHandleForReading)
        state = .running
    }

    func stop() {
        process?.terminate()
        process = nil
        state = .stopped
    }

    enum ClientError: Error, CustomStringConvertible {
        case noServiceExecutable(String), notRunning, badResponse(String), rpc(ServiceError), transport(String)
        var description: String {
            switch self {
            case .noServiceExecutable(let p): "no service executable at \(p)"
            case .notRunning: "render service is not running"
            case .badResponse(let s): "bad response: \(s)"
            case .rpc(let e): e.description
            case .transport(let s): s
            }
        }
    }

    /// Just the id, so a reply can be matched before it is known what shape
    /// its result should be.
    private struct IDProbe: Decodable { let id: Int? }

    private struct Envelope<R: Decodable>: Decodable {
        let id: Int?
        let result: R?
        let error: RPCError?
        struct RPCError: Decodable { let code: Int; let message: String; let data: ServiceError? }
    }

    /// Send one request and wait for its reply. Serialised by the actor.
    func call<P: Encodable, R: Decodable>(_ method: Method, _ params: P, as: R.Type = R.self) async throws -> R {
        if state != .running { try start() }
        guard let stdin, let reader else { throw ClientError.notRunning }
        let id = nextID; nextID += 1
        let enc = JSONEncoder()
        let paramsData = try enc.encode(params)
        let paramsJSON = String(decoding: paramsData, as: UTF8.self)
        let line = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method.rawValue)\",\"params\":\(paramsJSON)}\n"
        try stdin.write(contentsOf: Data(line.utf8))

        // Match the reply by its JSON-RPC id rather than taking the next line
        // on faith. Today the transport answers in order and this loop always
        // matches on the first read — but "the next line is my reply" is an
        // assumption about the *server*, and the server now has a
        // `configure_transport` switch that makes replies arrive in
        // completion order (contract §6, 2026-09-10). This is the client-side
        // prerequisite for ever turning that on, and until then it costs one
        // extra decode of a two-field struct per call.
        //
        // A line with a different id is logged and skipped rather than
        // thrown on: in the in-order world it cannot happen, and if it ever
        // does the useful behaviour is to keep looking for the answer that
        // was asked for.
        var reply: Data?
        for _ in 0..<32 {
            guard let line = await reader.readLine() else {
                state = .failed("service closed its output")
                throw ClientError.transport("render service closed its output")
            }
            let probe = try? JSONDecoder().decode(IDProbe.self, from: line)
            if probe?.id == nil || probe?.id == id { reply = line; break }
            FileHandle.standardError.write(Data(
                "service: skipped a reply for id \(probe?.id ?? -1) while waiting for \(id)\n".utf8))
        }
        guard let reply else { throw ClientError.transport("no reply for request \(id)") }
        let env: Envelope<R>
        do { env = try JSONDecoder().decode(Envelope<R>.self, from: reply) }
        catch { throw ClientError.badResponse(String(decoding: reply.prefix(400), as: UTF8.self)) }
        if let e = env.error {
            throw ClientError.rpc(e.data ?? ServiceError(code: "rpc_\(e.code)", category: "bug", message: e.message, param: nil, traceback: nil))
        }
        guard let r = env.result else { throw ClientError.badResponse("no result") }
        return r
    }

    func call<R: Decodable>(_ method: Method, as: R.Type = R.self) async throws -> R {
        try await call(method, [String: String](), as: R.self)
    }
}

/// Reads newline-delimited messages from a pipe on a background thread.
final class LineReader: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Data?, Never>] = []
    private var lines: [Data] = []
    private var closed = false

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] h in
            let d = h.availableData
            self?.push(d)
        }
    }

    private func push(_ d: Data) {
        lock.lock()
        if d.isEmpty { closed = true } else {
            buffer.append(d)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if !line.isEmpty { lines.append(line) }
            }
        }
        var wake: [(CheckedContinuation<Data?, Never>, Data?)] = []
        while !waiters.isEmpty, (!lines.isEmpty || closed) {
            let w = waiters.removeFirst()
            wake.append((w, lines.isEmpty ? nil : lines.removeFirst()))
        }
        lock.unlock()
        for (w, l) in wake { w.resume(returning: l) }
    }

    func readLine() async -> Data? {
        await withCheckedContinuation { c in
            lock.lock()
            if !lines.isEmpty { let l = lines.removeFirst(); lock.unlock(); c.resume(returning: l); return }
            if closed { lock.unlock(); c.resume(returning: nil); return }
            waiters.append(c)
            lock.unlock()
        }
    }
}
