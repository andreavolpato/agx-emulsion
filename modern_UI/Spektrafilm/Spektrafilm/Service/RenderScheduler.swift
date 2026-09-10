//  RenderScheduler.swift — turns a stream of parameter edits into the fewest
//  service calls that still land the latest value.
//
//  The transport is single-flight and a reprint costs ~200 ms, so the UI must
//  never queue one request per slider tick. The scheduler keeps two values —
//  what the service *has* (`sent`) and what the user *wants* (`wanted`) — and
//  a single loop that, whenever they differ, waits a short debounce, sends
//  one delta for the whole difference, and applies the result only if no
//  newer frame was opened in the meantime (a generation counter). Shoot-layer
//  edits, which re-run the film side, get a longer debounce than print-layer
//  edits, which reprint from the cached negative.

import Foundation

@MainActor
final class RenderScheduler {
    private let client: EngineClient
    private(set) var sent = FilmParams.default
    private var wanted = FilmParams.default
    private var loop: Task<Void, Never>?
    private var generation = 0
    private var sessionID: String?
    var onResult: (@MainActor (RenderOutcome, Int) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onBusy: (@MainActor (Bool) -> Void)?

    init(client: EngineClient) { self.client = client }

    /// True while an edit has been requested but not yet accepted by the
    /// service. The detail renderer checks this before spending the transport
    /// on a 6–17 s full-resolution render: the transport is single-flight, so
    /// a detail render would sit in front of the user's next slider release.
    var pending: Bool { wanted != sent }

    /// A new service session: what it holds now, and which generation it is.
    func reset(sessionID: String, params: FilmParams) -> Int {
        loop?.cancel(); loop = nil
        generation += 1
        self.sessionID = sessionID
        sent = params
        wanted = params
        return generation
    }

    func invalidate() {
        loop?.cancel(); loop = nil
        generation += 1
        sessionID = nil
    }

    func request(_ params: FilmParams) {
        wanted = params
        guard sessionID != nil else { return }
        if loop == nil { loop = Task { await run() } }
    }

    private func run() async {
        let gen = generation
        defer { loop = nil }
        while !Task.isCancelled, gen == generation, let sid = sessionID {
            let (delta, layers) = wanted.delta(from: sent)
            if delta.isEmpty { return }
            let shoot = layers.contains(.shoot)
            try? await Task.sleep(for: .milliseconds(shoot ? 220 : 40))
            if Task.isCancelled || gen != generation { return }
            // Re-read after the debounce: the user kept dragging.
            let target = wanted
            let (d2, l2) = target.delta(from: sent)
            if d2.isEmpty { continue }
            onBusy?(true)
            do {
                var req = RenderRequest(sessionID: sid, paramsDelta: d2)
                let r: RenderOutcome
                if l2.contains(.shoot) {
                    req.layer = "shoot"
                    r = try await client.render(.previewRender, req)
                } else {
                    r = try await client.render(.reprint, req)
                }
                if gen == generation {
                    sent = target
                    onResult?(r, gen)
                }
            } catch {
                if gen == generation {
                    onError?("\(error)")
                    // Do not spin on a failing delta: accept it as sent.
                    sent = target
                }
            }
            onBusy?(false)
        }
    }
}
