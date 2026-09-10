//  Session.swift — all application state, on the main actor.
//
//  One `Session` per app. It owns the library, the current frame's sidecar,
//  the renderer, the service client and the scheduler, and it is the only
//  thing views bind to. The flows worth knowing:
//
//    select(frame)  →  decode (Core Image, off main)  →  preview on canvas
//                   →  linear TIFF in the cache        →  service.open
//                   →  solve(exposure)                 →  the Exp. Comp. baseline
//                   →  reprint(live)                   →  print on canvas
//    params edit    →  scheduler.request               →  reprint/preview_render
//    adjustments    →  renderer.layer2 (no service)    →  redraw
//    decode edit    →  re-decode → new TIFF → reopen
//    zoom ≥ 100 %   →  reprint(preview/full)           →  detail texture swapped in
//    open(folder)   →  Browse, nothing rendered        →  select() enters Print

import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class Session: CanvasHost {
    // MARK: library
    private(set) var frames: [Frame] = []
    private(set) var frameStates: [URL: FrameState] = [:]
    var selection: URL?
    var libraryTitle: String = ""

    // MARK: the current frame
    var sidecar = Sidecar()
    var params: FilmParams {
        get { sidecar.params }
        set { guard newValue != sidecar.params else { return }
              pushUndo()
              sidecar.params = newValue; scheduler.request(newValue); markStale(); scheduleSave() }
    }
    var adjustments: Adjustments {
        get { sidecar.adjustments }
        set { guard newValue != sidecar.adjustments else { return }
              pushUndo()
              let curvesChanged = newValue.curves != sidecar.adjustments.curves
              sidecar.adjustments = newValue
              renderer.layer2 = newValue.uniforms
              if curvesChanged { renderer.setCurves(newValue.curves) } else { renderer.needsDraw?() }
              scheduleSave() }
    }
    var decode: DecodeSettings {
        get { sidecar.decode }
        set { guard newValue != sidecar.decode else { return }
              pushUndo()
              sidecar.decode = newValue; scheduleSave(); scheduleReopen() }
    }
    /// Crop, straighten, quarter turns and flips. Every mutation goes
    /// through `Geometry`'s own fitted-by-construction methods, so nothing
    /// assigned here can put a corner outside the frame.
    var geometry: Geometry {
        get { sidecar.geometry }
        set { guard newValue != sidecar.geometry else { return }
              pushUndo()
              sidecar.geometry = newValue
              renderer.geometry = newValue
              scheduleSave()
              // A crop changes how many source pixels a given zoom is
              // showing, so it changes which tier the canvas needs.
              updateDetailTier() }
    }
    /// The live tier's pixel size, which is what the geometry is normalised
    /// against. Zero before the first image lands.
    var sourceImageSize: CGSize { renderer.sourceSize ?? .zero }

    // MARK: masks (蒙版) — Layer 2, local
    //
    // A mask is a region plus its own adjustments (`Model/Mask.swift`), so it
    // runs in the same kernel the right panel does and reaches no service.
    // Everything here is one write path: change the list, repack, redraw.

    var masks: [EditMask] {
        get { sidecar.masks }
        set { guard newValue != sidecar.masks else { return }
              pushUndo()
              sidecar.masks = newValue
              syncMasks()
              scheduleSave() }
    }
    /// The mask being edited. Its region is tinted red on the canvas (unless
    /// the overlay is off) and its handles are draggable.
    var selectedMaskID: UUID? { didSet { guard oldValue != selectedMaskID else { return }; syncMasks() } }
    /// The red coverage tint. Every editor has one and every editor's users
    /// turn it off, so it is a toggle rather than a mode.
    var maskOverlayVisible = true { didSet { guard oldValue != maskOverlayVisible else { return }; syncMasks() } }
    /// The colour-range component waiting for an eyedropper click, if any.
    var maskColorPick: UUID?

    var selectedMask: EditMask? {
        get { masks.first { $0.id == selectedMaskID } }
        set {
            guard let newValue, let i = masks.firstIndex(where: { $0.id == newValue.id }) else { return }
            var list = masks; list[i] = newValue; masks = list
        }
    }

    /// Repack for the kernel. Disabled and empty masks are dropped here
    /// rather than branched on per pixel, so the shader's loop is only over
    /// masks that can actually do something.
    private func syncMasks() {
        // `FeatureFlags.masks` is off while the user redesigns the system.
        // The sidecar still carries whatever masks it had — nothing is
        // deleted — but none of them reaches a pixel, so a frame saved with
        // masks looks the same as one saved without while the feature is
        // withdrawn. That is the difference between hiding a feature and
        // hiding its effect, and only the second one is honest.
        guard FeatureFlags.masks else {
            guard !renderer.masks.isEmpty || renderer.maskOverlay >= 0 else { return }
            renderer.masks = []
            renderer.maskOverlay = -1
            renderer.needsDraw?()
            return
        }
        let live = masks.filter { $0.enabled && !$0.isEmpty }.prefix(EditMask.maxCount)
        renderer.masks = live.map { $0.uniform() }
        renderer.maskOverlay = maskOverlayVisible
            ? Int32(live.firstIndex { $0.id == selectedMaskID }.map(Int32.init) ?? -1)
            : -1
        renderer.needsDraw?()
    }

    /// The draggable grips on the selected mask's geometry, in
    /// source-normalised coordinates. `CanvasNSView` hit-tests these and
    /// `MaskOverlay` draws them, so the two cannot disagree about where a
    /// grip is.
    var maskHandles: [MaskHandle] {
        guard FeatureFlags.masks else { return [] }
        guard let m = selectedMask, m.enabled, sourceImageSize.width > 1 else { return [] }
        let size = sourceImageSize
        return m.components.flatMap { c -> [MaskHandle] in
            switch c.kind {
            case .linearGradient:
                [MaskHandle(component: c.id, role: .a, position: c.a),
                 MaskHandle(component: c.id, role: .b, position: c.b)]
            case .radialGradient:
                [MaskHandle(component: c.id, role: .centre, position: c.a),
                 MaskHandle(component: c.id, role: .radiusX, position: MaskGeometry.point(on: c, at: 0, imageSize: size)),
                 MaskHandle(component: c.id, role: .radiusY, position: MaskGeometry.point(on: c, at: .pi / 2, imageSize: size)),
                 MaskHandle(component: c.id, role: .rotate, position: MaskGeometry.point(on: c, at: 0, scale: 1.3, imageSize: size))]
            default: []
            }
        }
    }

    /// Apply a grip drag. `n` is where the pointer is, source-normalised.
    func maskHandleDragged(_ h: MaskHandle, to n: CGPoint) {
        guard var m = selectedMask, let i = m.components.firstIndex(where: { $0.id == h.component }) else { return }
        var c = m.components[i]
        let size = sourceImageSize
        // Long-edge units, matching `toLongEdge` in the shader — the radii
        // are in them, so the arithmetic has to be too or a drag on a 3:2
        // frame resizes the wrong axis.
        let long = max(size.width, size.height)
        let sx = size.width / long, sy = size.height / long
        switch h.role {
        case .a: c.a = n
        case .b: c.b = n
        case .centre:
            let d = CGSize(width: n.x - c.a.x, height: n.y - c.a.y)
            c.a = n
            // A linear component in the same mask does not move with a
            // radial's centre, but a radial's own geometry is its centre, so
            // there is nothing else to carry.
            _ = d
        case .radiusX, .radiusY, .rotate:
            let dx = (n.x - c.a.x) * sx, dy = (n.y - c.a.y) * sy
            if h.role == .rotate {
                c.angle = atan2(dy, dx) * 180 / .pi
            } else {
                let a = c.angle * .pi / 180
                let ex = dx * cos(a) + dy * sin(a)
                let ey = -dx * sin(a) + dy * cos(a)
                if h.role == .radiusX { c.radii.width = max(abs(ex), 0.01) }
                else { c.radii.height = max(abs(ey), 0.01) }
            }
        }
        m.components[i] = c
        selectedMask = m
    }

    func addMask(_ kind: MaskComponentKind) {
        guard masks.count < EditMask.maxCount else {
            lastError = "Eight masks is the limit."
            return
        }
        var m = EditMask.make(kind)
        // Names repeat in Lightroom too, but a number is worth more than a
        // second "Radial Gradient" in the list.
        let n = masks.filter { $0.name.hasPrefix(kind.label) }.count
        if n > 0 { m.name = "\(kind.label) \(n + 1)" }
        masks.append(m)
        selectedMaskID = m.id
    }

    func deleteMask(_ id: UUID) {
        masks.removeAll { $0.id == id }
        if selectedMaskID == id { selectedMaskID = masks.last?.id }
    }

    func duplicateMask(_ id: UUID) {
        guard masks.count < EditMask.maxCount, var m = masks.first(where: { $0.id == id }) else { return }
        m.id = UUID()
        m.name += " copy"
        m.components = m.components.map { var c = $0; c.id = UUID(); return c }
        masks.append(m)
        selectedMaskID = m.id
    }
    private(set) var decoded: DecodedImage?
    /// The source's native long edge. The escalation decision is about the
    /// *file's* resolution, not the live tier's 1600 px: a 45 MP frame needs a
    /// real render long before a 2 MP one does.
    private(set) var sourceLongEdge: CGFloat = 0
    private(set) var exif: EXIFReadout?

    // MARK: ui state
    //
    // Keys are namespaced. The previous version of this app shipped under the
    // same bundle identifier and left its own `leftCollapsed`,
    // `filmstripCollapsed`, `dock.*` and `panel.*` values behind, so an
    // unprefixed key is not this app's state — it is whatever that build last
    // wrote, and it opened this one with both panels and the filmstrip folded
    // away for no reason the user could see.
    static let uiKey = "ui2."
    var leftCollapsed = UserDefaults.standard.bool(forKey: Session.uiKey + "leftCollapsed") { didSet { UserDefaults.standard.set(leftCollapsed, forKey: Session.uiKey + "leftCollapsed") } }
    var rightCollapsed = UserDefaults.standard.bool(forKey: Session.uiKey + "rightCollapsed") { didSet { UserDefaults.standard.set(rightCollapsed, forKey: Session.uiKey + "rightCollapsed") } }
    var topCollapsed = UserDefaults.standard.bool(forKey: Session.uiKey + "topCollapsed") { didSet { UserDefaults.standard.set(topCollapsed, forKey: Session.uiKey + "topCollapsed") } }
    var filmstripCollapsed = UserDefaults.standard.bool(forKey: Session.uiKey + "filmstripCollapsed") { didSet { UserDefaults.standard.set(filmstripCollapsed, forKey: Session.uiKey + "filmstripCollapsed") } }
    var tool: CanvasTool = .select {
        didSet {
            guard oldValue != tool else { return }
            // Entering the crop tool shows the whole frame; leaving it fits
            // the crop. The renderer does both from this one flag.
            renderer.editingCrop = tool == .crop
            // What Esc goes back to. Taken on the way *in*, so a crop the user
            // spent a minute on is not lost by leaving the tool with the
            // mouse and coming back — only Esc discards, and only back to
            // where this session of the tool started.
            cropEntryGeometry = tool == .crop ? geometry : nil
            renderer.needsDraw?()
        }
    }
    /// The crop as it was when the crop tool was entered. See `cancelCrop`.
    private var cropEntryGeometry: Geometry?

    /// Return: keep what is on screen and leave the tool.
    func commitCrop() {
        guard tool == .crop else { return }
        cropEntryGeometry = nil
        tool = .select
    }

    /// Esc: put the crop back to where the tool was entered and leave.
    ///
    /// Not an undo step of its own — `geometry`'s setter already pushes one —
    /// so ⌘Z after an Esc reaches the edit before the crop, which is what
    /// "cancel" is supposed to have left behind.
    func cancelCrop() {
        guard tool == .crop else { return }
        if let g = cropEntryGeometry, g != geometry { geometry = g }
        cropEntryGeometry = nil
        tool = .select
    }
    /// An observable mirror of the renderer's viewport, so `CropOverlay` can
    /// draw handles in view coordinates. The renderer is not `@Observable`
    /// and should not become so — it is touched per draw.
    private(set) var viewportSnapshot = ViewportState()
    /// The ⌘-drag straighten line, while one is being drawn.
    private(set) var straightenPreview: StraightenLine?
    /// Which executor the service is rendering with, once `open` has said.
    /// Shown in the status bar: "it feels slow" is not diagnosable without
    /// it, and the app ran a whole session on the CPU core because nothing
    /// asked.
    private(set) var backend: Capabilities.Backend?
    var renderCore: String? { backend?.renderCore }
    var curvePickerActive = false
    var wbPickerActive = false
    var pickerActive: Bool { curvePickerActive || wbPickerActive || maskColorPick != nil }
    var zoomPercent = 100
    var isFit = true
    /// Mirrors `Renderer.showOriginal` so the canvas badge can react: the
    /// renderer is a plain class, not `@Observable`.
    var showingOriginal = false

    // MARK: before / after
    //
    // Capture One's split: the decoded frame on the left of a draggable line,
    // the print on its right, both through the same crop. The shader does the
    // pixels (`canvasFragment`); `Canvas/CompareOverlay.swift` does the line,
    // the handle and the two labels, because a one-point line drawn into the
    // image would be resampled with it.
    //
    // These mirror the renderer, which is not `@Observable` — the same
    // arrangement `viewportSnapshot` uses and for the same reason.

    var comparing = false {
        didSet {
            guard oldValue != comparing else { return }
            renderer.compareSplit = comparing
        }
    }
    /// 0…1 across the output. Stored here so the overlay can bind to it.
    var comparePosition: Double = 0.5 {
        didSet {
            let clamped = comparePosition.clamped(to: 0...1)
            if clamped != comparePosition { comparePosition = clamped; return }
            renderer.comparePosition = Float(comparePosition)
        }
    }
    /// There has to be something to compare against: the decode preview, which
    /// arrives with the frame.
    var canCompare: Bool { selection != nil && renderer.canCompare }
    var histogram: [Float] = Array(repeating: 0, count: 1024)
    var hoverValue: SIMD3<Float>?      // encoded RGB under the cursor, for the curve readout
    var status = "Open a folder or an image to begin."
    var busy = false
    var previewSoft = false            // the canvas shows a stale/interpolated print
    var serviceReady = false
    var lastError: String?
    var exportProgress: Double?
    var lastRenderMs: Double = 0
    private var statusBase: String?
    var stockWarning: String?
    var showExport = false

    /// The app lands in Browse when a *folder* or several files are opened:
    /// the grid is the confirmation step and nothing is rendered until a
    /// frame is chosen (frontend SPEC §5.1, HANDOFF-FRONTEND-POLISH §2).
    var browsing = false

    // MARK: the detail tier (resolution follows the zoom)

    /// Which render the current zoom is asking for. `.live` is the resident
    /// 1600 px print; the other two are rendered on demand and swapped in
    /// when they land. A frame no larger than the live tier is already native
    /// and never escalates.
    /// `rank` orders the tiers. A render at a higher rank contains
    /// everything a lower one does, which is what lets the store answer
    /// "this tier or sharper" and turns a zoom-out-and-back into a swap
    /// rather than a re-render.
    enum DetailTier: String, Sendable, CaseIterable {
        case live, preview, full
        var rank: Int { switch self { case .live: 0; case .preview: 1; case .full: 2 } }
        init?(rank: Int) {
            guard let t = DetailTier.allCases.first(where: { $0.rank == rank }) else { return nil }
            self = t
        }
    }
    private(set) var detailTier: DetailTier = .live
    private(set) var detailPending = false
    private var detailTask: Task<Void, Never>?
    private var detailGeneration = 0

    /// Clipboard for ⌘C/⌘V. Film, print and Layer 2 settings only: the decode
    /// block is per-frame (a lens filter) and the crop is framing. Every field
    /// is an offset, so pasting means "same recipe, each frame solves its own
    /// exposure" (frontend SPEC §5.5).
    struct SettingsClip: Sendable { var params: FilmParams; var adjustments: Adjustments }
    private var clipboard: SettingsClip?

    // MARK: undo and the work clock

    private var undoStack: [Sidecar] = []
    private var lastUndoAt = Date.distantPast
    private(set) var workSeconds: Double = 0
    private var workStarted: Date?
    private var workClock: Task<Void, Never>?
    /// Anything that holds the service or the user's attention. Drives the
    /// elapsed-time readout in the top bar; the service cannot report real
    /// progress over a blocking stdio transport (see `startClock`).
    var working: Bool { busy || detailPending || exportProgress != nil }

    // MARK: engine
    let renderer: Renderer
    let client: EngineClient
    let scheduler: RenderScheduler
    let catalog = StockCatalog.shared
    private var serviceSessionID: String?
    var serviceSessionIDForExport: String? { serviceSessionID }
    private var serviceGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var reopenTask: Task<Void, Never>?
    private var prefetch: [URL: Task<URL?, Never>] = [:]
    nonisolated static let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "com.hanze.spektrafilm")
    nonisolated static let liveEdge = 1600

    init(renderer: Renderer? = Renderer()) {
        guard let renderer else { fatalError("Metal is required") }
        self.renderer = renderer
        // The engine is in this process now (RFC-014): no subprocess, no
        // workspace directory, and no walking up to a checkout's `.venv`. It
        // gets the canvas's own `MTLDevice`, so a render lands in a texture
        // the canvas can draw without a copy.
        client = EngineClient(device: renderer.device)
        scheduler = RenderScheduler(client: client)
        scheduler.onResult = { [weak self] r, gen in self?.applyRender(r, generation: gen) }
        scheduler.onError = { [weak self] e in self?.lastError = e; self?.status = e }
        scheduler.onBusy = { [weak self] b in
            guard let self else { return }
            self.busy = b
            if b { self.startClock() }
        }
        renderer.onHistogram = { [weak self] h in self?.histogram = h }
        renderer.onViewportChanged = { [weak self] in self?.viewportChanged() }
        renderer.layer2 = sidecar.adjustments.uniforms
        // Enforce the cache ceiling once at launch, so a directory left over
        // from a build that had no bound is trimmed even if nothing is written
        // this session.
        LinearCache.prepare()
        Task { await client.set(onTermination: { [weak self] reason in
            Task { @MainActor in self?.serviceReady = false; self?.status = reason; self?.lastError = reason }
        }) }
        bootTask = warmUp()
    }

    /// Start the service and pay for its imports before anyone asks it to do
    /// something.
    ///
    /// `call` starts the process lazily, so the first request of the session
    /// was always `open` — and it carried ~1.9 s of Python interpreter start
    /// and module import (numpy, mlx, colour-science) on its back. Measured
    /// through the app: `service.open` 4.5 s cold against 2.6 s for the same
    /// call in a warm process. The app knows at launch that it is going to
    /// need the service, so it should not make the user's first frame pay for
    /// finding that out.
    ///
    /// `capabilities` is the request to warm with: it touches the import path
    /// and the Metal device, and it is how the client learns which executor
    /// it got — so the status bar can say "Metal" before a frame is open
    /// rather than after the first render.
    /// Awaited by the first `open` (see `bootTask`), so warm-up is a *gate*
    /// rather than a race. `ServiceClient` is an actor and serialises calls in
    /// submission order, so `capabilities` normally landed first anyway — but
    /// "normally" is not a guarantee: a frame restored at launch can submit
    /// `open` first, and then the first `open` carries the whole interpreter
    /// start on its back, which is the bug this method exists to prevent.
    @discardableResult
    private func warmUp() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            do {
                let caps: Capabilities = try await self.client.call(.capabilities, as: Capabilities.self)
                self.accept(caps)
                canvasLog("service warm · core=\(caps.backend?.renderCore ?? "?") · engine \(caps.engine)")
            } catch {
                // Deliberately not swallowed. This used to be `try?`, so a
                // capabilities block the client could not decode looked
                // exactly like a service that had not started yet — and the
                // first symptom would have been the *next* thing to fail,
                // several seconds later, somewhere else.
                canvasLog("warm-up failed: \(error)")
                self.serviceBlocked = Session.capabilitiesFailure(error)
                // The boot window must not trap the user in it. A service we
                // cannot talk to is a thing to say in the editor, where the
                // blocking panel and its restart button already live.
                self.bootPhase = .failed(Session.capabilitiesFailure(error))
                return
            }
            self.bootPhase = .warming
            await self.payFirstFrameSetup()
            self.bootPhase = .ready
        }
    }

    /// `warm_up` (RFC-013 §3): build the profile pair and its pipeline before
    /// the first `open` asks for them.
    ///
    /// This is not the same saving as `capabilities`. That one pays the
    /// interpreter start and the imports; this one pays the *pipeline
    /// construction* for a stock pair — the filming `tc_lut`, the enlarger and
    /// scanner LUTs, the fused kernel constants. Measured by the backend at
    /// ~130 ms, removing 124 ms from a 1 MP first open and 169–502 ms from a
    /// 45 MP one.
    ///
    /// It is warmed with the **sidecar's** stocks, not the defaults: the engine
    /// builds a pipeline for the pair it is handed, so warming
    /// `portra_400 / supra_endura` when the restored frame wants
    /// `provia_100f / 2383` pays the cost twice and saves nothing.
    ///
    /// A failed step is not fatal — the work is simply paid again inside
    /// `open` — so this logs and returns rather than blocking the app.
    private func payFirstFrameSetup() async {
        let p = sidecar.params
        do {
            let r: WarmUpResponse = try await client.call(
                .warmUp, WarmUpRequest(filmStock: p.filmStock, printStock: p.printStock),
                as: WarmUpResponse.self)
            warmUpMs = r.totalMs
            let failed = r.failedSteps
            canvasLog("warm_up: \(Int(r.totalMs ?? 0)) ms · core=\(r.renderCore ?? "?")"
                      + (r.alreadyWarm == true ? " · already warm" : "")
                      + (failed.isEmpty ? "" : " · FAILED: \(failed.joined(separator: ", "))"))
        } catch {
            // Older services do not have the method at all, which is fine:
            // the wire addition is optional and a client that skips it behaves
            // exactly as it did before (handoff §"Wire").
            canvasLog("warm_up unavailable or failed: \(error)")
        }
    }

    /// Awaited before the first `open`. Nil once boot has been paid.
    private var bootTask: Task<Void, Never>?
    /// What `warm_up` cost, for the open-path log.
    private var warmUpMs: Double?

    // MARK: - boot
    //
    // RFC-012 §6 and RFC-013 §3: the app has a fixed amount of setup to do
    // before it can render anything, and it should do it while the user is
    // looking at something that says so — the way Photoshop and Capture One
    // start with a small window before their main one.
    //
    // The rule that keeps this from being a slow app with a logo: **the boot
    // window must cover work the app has to do anyway.** Nothing here sleeps,
    // nothing is padded, and if the engine is already warm the window is on
    // screen for a few frames and gone. What it buys is not time — it is that
    // the ~1.3 s of interpreter start and pipeline construction happens
    // somewhere the user can see a reason for it, instead of inside their
    // first photograph.

    enum BootPhase: Equatable, Sendable {
        case starting            // spawning the process, paying imports
        case warming             // building the pipeline for the sidecar's stocks
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .starting: "Starting the render engine…"
            case .warming: "Preparing the film pipeline…"
            case .ready: "Ready"
            case .failed(let why): why
            }
        }
    }

    private(set) var bootPhase: BootPhase = .starting
    /// True once the app is fit to show its main window.
    var booted: Bool { if case .ready = bootPhase { true } else { false } }

    /// Why the app will not render, or nil. Contract §2: "FE refuses to start
    /// against a transport version it does not know, with a visible error
    /// rather than a blank canvas."
    private(set) var serviceBlocked: String?

    /// Take a capabilities block and decide whether we can talk to it.
    private func accept(_ caps: Capabilities) {
        if let why = caps.unsupportedTransport {
            serviceBlocked = why
            serviceReady = false
            return
        }
        serviceBlocked = nil
        backend = caps.backend
        serviceReady = true
        if let why = caps.schemaMismatch { stockWarning = why }
    }

    /// A decoding failure against `capabilities` is a wire problem, and the
    /// message has to say so — `keyNotFound(CodingKeys(stringValue:
    /// "transport_version"))` is true and useless.
    static func capabilitiesFailure(_ error: Error) -> String {
        guard let d = error as? DecodingError else {
            return "The render service did not answer `capabilities`: \(error)"
        }
        let field: String
        switch d {
        case .keyNotFound(let key, _): field = key.stringValue
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            field = ctx.codingPath.map(\.stringValue).joined(separator: ".")
        default: field = "?"
        }
        return "The render service's `capabilities` block is missing or malformed "
             + "at `\(field)`. The app cannot tell which wire it is speaking, so it "
             + "will not render. See CONTRACT-frontend-backend.md §2."
    }

    // MARK: - library

    func open(urls: [URL]) {
        let new = Library.frames(from: urls)
        guard !new.isEmpty else { status = "Nothing openable in the selection."; return }
        frames = new
        frameStates = Dictionary(uniqueKeysWithValues: new.map { ($0.id, Sidecar.load(for: $0.id)?.state ?? .unprocessed) })
        libraryTitle = urls.count == 1 ? urls[0].lastPathComponent : "\(new.count) files"
        renderer.store.removeAll()
        // One file is a handoff — Finder's "Open With", a Capture One "Edit
        // With", a single drop — and it means "develop this". A folder or a
        // multi-file selection is a session to look through, and the old build
        // rendered the alphabetically-first frame there, spending seven seconds
        // and 363 MB on a guess (HANDOFF §2). Now it renders nothing until a
        // frame is chosen.
        if new.count == 1 {
            browsing = false
            select(new[0].id)
        } else {
            enterBrowse()
        }
    }

    private func enterBrowse() {
        browsing = true
        selection = nil
        decoded = nil
        sourceLongEdge = 0
        exif = nil
        stockWarning = nil
        previewSoft = false
        detailTier = .live
        detailPending = false
        detailTask?.cancel(); detailTask = nil
        loadTask?.cancel()
        renderer.dropDetail()
        renderer.setLive(nil)
        renderer.original = nil
        scheduler.invalidate()
        serviceSessionID = nil
        status = "\(frames.count) frames · pick one to develop."
    }

    func openPanel() { let urls = Library.chooseFilesOrFolder(); if !urls.isEmpty { open(urls: urls) } }

    /// Re-read a frame's sidecar state — used after a reset from the grid.
    func refreshState(for url: URL) {
        frameStates[url] = Sidecar.load(for: url)?.state ?? .unprocessed
        if url == selection { sidecar = Sidecar.load(for: url) ?? Sidecar() }
    }

    /// Drop a frame from the session. Never touches the file.
    func remove(_ url: URL) {
        frames.removeAll { $0.id == url }
        frameStates[url] = nil
        renderer.store.invalidatePrint(for: url)
        if frames.isEmpty {
            browsing = false
            selection = nil
            renderer.setLive(nil)
            status = "Open a folder or an image to begin."
        } else if selection == url {
            enterBrowse()
        }
    }

    /// Return to the grid without reopening the folder.
    func browseSession() {
        guard frames.count > 1 else { return }
        flushSave()
        enterBrowse()
    }

    func selectRelative(_ delta: Int) {
        guard let selection, let i = frames.firstIndex(where: { $0.id == selection }) else { return }
        let j = (i + delta).clamped(to: 0...(frames.count - 1))
        if j != i { select(frames[j].id) }
    }

    func select(_ url: URL) {
        guard url != selection || decoded == nil else { return }
        flushSave()
        loadTask?.cancel()
        browsing = false
        selection = url
        previewSoft = false
        sourceLongEdge = 0
        // A new frame invalidates the previous frame's detail render, and the
        // zoom may still be past the threshold — `updateDetailTier` re-asks
        // once the new live print lands.
        detailTier = .live
        detailPending = false
        detailTask?.cancel(); detailTask = nil
        renderer.dropDetail()
        sidecar = Sidecar.load(for: url) ?? Sidecar()
        renderer.layer2 = sidecar.adjustments.uniforms
        renderer.setCurves(sidecar.adjustments.curves)
        renderer.geometry = sidecar.geometry
        selectedMaskID = sidecar.masks.first?.id
        syncMasks()
        decoded = nil
        exif = EXIFReadout.read(url)
        stockWarning = nil
        // Show the last print of this frame instantly if it is resident.
        if let cached = renderer.store.print(for: url) {
            renderer.setLive(cached, logical: CGSize(width: cached.width, height: cached.height)); previewSoft = true
        } else if let src = renderer.store.source(for: url) {
            renderer.setLive(src, logical: CGSize(width: src.width, height: src.height)); previewSoft = true
        } else {
            renderer.setLive(nil)
        }
        renderer.original = renderer.store.source(for: url)
        scheduler.invalidate()
        serviceSessionID = nil
        loadTask = Task { await load(url) }
        prefetchNeighbours(of: url)
    }

    // MARK: - the load pipeline

    /// Wall-clock for one stage of the open path, logged under
    /// `SPEKTRAFILM_CANVAS_LOG=1`.
    ///
    /// This exists because "opening a frame takes eight seconds" is not
    /// actionable and points at the wrong half of the app. The render service
    /// is the visible, instrumented part — it reports `elapsed_ms` and the
    /// status bar shows it — so a slow open reads as a slow *render*. It was
    /// not: with the GPU-native core a live reprint is ~20 ms and the eight
    /// seconds are the client's own RAW decode and the 363 MB TIFF it writes
    /// to hand the frame over. One line per stage is the difference between
    /// knowing that and guessing it.
    struct LoadClock {
        private var last = Date()
        private var total = Date()
        private var parts: [String] = []
        mutating func lap(_ name: String) {
            let now = Date()
            parts.append("\(name) \(Int(now.timeIntervalSince(last) * 1000))")
            last = now
        }
        func summary() -> String {
            "open path (ms): " + parts.joined(separator: " · ") +
            " · TOTAL \(Int(Date().timeIntervalSince(total) * 1000))"
        }
    }

    private func load(_ url: URL) async {
        status = "Decoding \(url.lastPathComponent)…"
        var clock = LoadClock()
        let settings = sidecar.decode
        let device = renderer.device
        let liveEdge = Session.liveEdge
        // Decode and preview only. The 363 MB linear TIFF is written *after*
        // the cancellation guard below, so a superseded white-balance value
        // never leaves a file behind (HANDOFF §3.1.2).
        let decodedImage: DecodedImage? = await Task.detached(priority: .userInitiated) {
            try? ImageDecoder.decode(url, settings: settings)
        }.value
        clock.lap("decode")
        guard !Task.isCancelled, selection == url, let d = decodedImage else { return }
        let preview: TextureBox = await Task.detached(priority: .userInitiated) {
            TextureBox(ImageDecoder.makePreviewTexture(d, device: device, maxEdge: liveEdge))
        }.value
        clock.lap("preview-texture")
        if let tex = preview.texture, !Task.isCancelled, selection == url {
            renderer.store.setSource(tex, for: url)
            renderer.original = tex
            if renderer.store.print(for: url) == nil {
                renderer.setLive(tex, logical: CGSize(width: tex.width, height: tex.height))
                previewSoft = true
            }
        }
        guard !Task.isCancelled, selection == url else { return }
        decoded = d
        sourceLongEdge = max(d.pixelSize.width, d.pixelSize.height)
        if sidecar.decode.whiteBalance == .asShot, let t = d.asShotTemperature, let tn = d.asShotTint,
           (sidecar.decode.temperature != t || sidecar.decode.tint != tn) {
            sidecar.decode.temperature = t; sidecar.decode.tint = tn
        }
        let tiff: URL? = await Task.detached(priority: .userInitiated) {
            try? Session.linearTIFF(for: d, settings: settings)
        }.value
        clock.lap("linear-tiff")
        guard !Task.isCancelled, selection == url, let tiff else {
            status = "Could not decode \(url.lastPathComponent)."; return
        }
        await openInService(tiff: tiff, for: url, clock: &clock)
    }

    private func openInService(tiff: URL, for url: URL, clock: inout LoadClock) async {
        var clock = clock          // `inout` cannot be held across an await
        // The gate, not a race (RFC-013 §2.2). Costs nothing once boot has
        // been paid, and on the path that matters — a frame restored at launch
        // submitting `open` before `capabilities` has landed — it is the
        // difference between the user's first frame paying the interpreter
        // start and it having been paid already.
        if let boot = bootTask {
            await boot.value
            bootTask = nil
            clock.lap("warm-up")
        }
        if serviceBlocked != nil { status = serviceBlocked!; return }
        status = "Developing…"
        busy = true
        startClock()
        defer { busy = false }
        do {
            let req = OpenRequest(imagePath: tiff.path, paramsDelta: sidecar.params.fullDelta)
            let r: OpenResponse = try await client.call(.open, req)
            clock.lap("service.open")
            // `open` echoes the whole block, so the check happens here too:
            // a service can be restarted under a running app.
            if let caps = r.capabilities {
                accept(caps)
                if let why = serviceBlocked { status = why; return }
            }
            guard selection == url, !Task.isCancelled else { return }
            serviceReady = true
            serviceSessionID = r.sessionID
            serviceGeneration = scheduler.reset(sessionID: r.sessionID, params: sidecar.params)
            // What the engine's own auto-exposure chose for this frame. The
            // Exp. Comp. slider is an offset from it, so the UI has to know
            // the baseline to show it (HANDOFF §4). `solve(target:"exposure")`
            // is read-only — the filter-pack half of `solve` writes neutrals
            // onto the session and is deliberately not called, because `open`
            // already applied the database neutrals.
            if let solved = try? await client.call(.solve, SolveRequest(sessionID: r.sessionID, target: "exposure"), as: SolveResponse.self),
               let ev = solved.solvedParams["exposure_compensation_ev"] {
                sidecar.solvedEV = ev
                scheduleSave()
            }
            clock.lap("solve")
            let rr = try await client.render(.reprint, RenderRequest(sessionID: r.sessionID))
            clock.lap("reprint")
            canvasLog(clock.summary()
                      + (warmUpMs.map { "  ·  warm_up \(Int($0)) ms" } ?? "")
                      + "  ·  core=\(renderCore ?? "?")"
                      + (backend?.sessionCache.map { "  ·  \($0.summary)" } ?? ""))
            guard selection == url else { return }
            applyRender(rr, generation: serviceGeneration)
            statusBase = "\(url.lastPathComponent)  ·  \(r.meta.width)×\(r.meta.height)  ·  \(r.detectedInput.inputColorSpace)"
            if let b = backend, b.isSlowPath {
                // Loud, because the symptom is otherwise just "slow" and the
                // cause is usually that the engine is not in this checkout.
                stockWarning = "Rendering on the \(b.label) path, not the GPU core — see HANDOFF-GPU-WIRING.md."
            }
            status = "\(statusBase!)  ·  \(rr.response.reprint ? "reprint" : "render") \(Int(rr.response.elapsedMs)) ms"
            // The user may have moved a slider while the film side was running.
            scheduler.request(sidecar.params)
        } catch {
            lastError = "\(error)"
            status = "\(error)"
            if case EngineClient.ClientError.noResources = error { serviceReady = false }
        }
    }

    private func applyRender(_ outcome: RenderOutcome, generation: Int) {
        let r = outcome.response
        guard generation == serviceGeneration else {
            canvasLog("applyRender dropped: generation \(generation) != \(serviceGeneration)"); return
        }
        guard let url = selection else { canvasLog("applyRender dropped: no selection"); return }
        guard let tex = outcome.texture, let w = r.width, let h = r.height else {
            canvasLog("applyRender dropped: the engine returned no texture"); return
        }
        canvasLog("applyRender uploaded \(w)x\(h)")
        renderer.store.setPrint(tex, for: url)
        renderer.setLive(tex, logical: renderer.sourceSize == nil ? CGSize(width: w, height: h) : nil)
        previewSoft = false
        lastRenderMs = r.elapsedMs
        if let base = statusBase { status = "\(base)  ·  \(r.reprint ? "reprint" : "render") \(Int(r.elapsedMs)) ms" }
        frameStates[url] = .processed
        sidecar.state = .processed
        scheduleSave()
        updateThumbnail(url, from: tex)
        // A resident detail render made from *different* parameters is no
        // longer the print on screen and showing it would be showing a
        // different film. One made from these parameters is still the truth:
        // an undo, or a slider dragged back to where it started, lands here
        // and used to throw away a 17 s render for no reason.
        if detailTier != .live {
            let stamp = printStamp
            if let resident = renderer.store.detail(for: url, stamp: stamp, atLeast: detailTier.rank) {
                detailTier = DetailTier(rawValue: resident.tier) ?? detailTier
                renderer.setDetail(resident.texture)
            } else {
                renderer.dropDetail()
                renderer.store.dropDetail(unless: stamp, for: url)
                scheduleDetail()
            }
        }
    }

    private func markStale() {
        guard let url = selection, frameStates[url] == .processed else { return }
        // The service will catch up within a reprint; only the *thumbnail*
        // goes stale, and it clears when the next render lands.
        frameStates[url] = .stale
    }

    private func updateThumbnail(_ url: URL, from tex: MTLTexture) {
        let box = TextureBox(tex)
        Task.detached(priority: .utility) {
            guard let cg = box.texture?.makeCGImage() else { return }
            let s = 320.0 / Double(max(cg.width, cg.height))
            let w = max(1, Int(Double(cg.width) * s)), h = max(1, Int(Double(cg.height) * s))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: ImageDecoder.displayP3, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let small = ctx.makeImage() { await ThumbnailCache.shared.store(small, for: url) }
            await MainActor.run { NotificationCenter.default.post(name: .thumbnailUpdated, object: url) }
        }
    }

    // MARK: - decode cache

    nonisolated static func linearTIFF(for d: DecodedImage, settings: DecodeSettings) throws -> URL {
        let key = Session.contentKey(d.sourceURL) + "-" + settings.cacheKey
        let dir = LinearCache.directory
        let url = dir.appending(path: key + ".tif")
        if FileManager.default.fileExists(atPath: url.path) {
            LinearCache.touch(url)
            return url
        }
        LinearCache.prepare()
        try ImageDecoder.writeLinearTIFF(d, to: url)
        LinearCache.touch(url)
        return url
    }

    /// File size + mtime + path hash: cheap and good enough for a cache key.
    nonisolated static func contentKey(_ url: URL) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(url.path)|\(size)|\(mtime)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func prefetchNeighbours(of url: URL) {
        guard let i = frames.firstIndex(where: { $0.id == url }) else { return }
        for j in [i + 1, i - 1] where frames.indices.contains(j) {
            let f = frames[j]
            guard prefetch[f.id] == nil, renderer.store.source(for: f.id) == nil else { continue }
            let settings = Sidecar.load(for: f.id)?.decode ?? DecodeSettings()
            let device = renderer.device
            let store = renderer.store
            let edge = Session.liveEdge
            prefetch[f.id] = Task.detached(priority: .background) {
                guard let d = try? ImageDecoder.decode(f.id, settings: settings) else { return nil }
                if let tex = ImageDecoder.makePreviewTexture(d, device: device, maxEdge: edge) { store.setSource(tex, for: f.id) }
                // Preview only. The linear TIFF is 363 MB; writing one for each
                // neighbour filled the cache before the user had looked at
                // anything (HANDOFF §2, §3.1).
                return nil
            }
        }
    }

    private func scheduleReopen() {
        reopenTask?.cancel()
        reopenTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let url = selection else { return }
            loadTask?.cancel()
            renderer.store.invalidatePrint(for: url)
            previewSoft = true
            loadTask = Task { await load(url) }
        }
    }

    // MARK: - sidecar

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            flushSave()
        }
    }

    func flushSave() {
        saveTask?.cancel()
        guard let url = selection else { return }
        try? sidecar.save(for: url)
    }

    // MARK: - white balance

    func setWhiteBalance(_ mode: DecodeSettings.WhiteBalance) {
        var d = decode
        d.whiteBalance = mode
        if let k = mode.kelvin { d.temperature = k; d.tint = 0 }
        else if mode == .asShot, let dec = decoded, let t = dec.asShotTemperature, let tn = dec.asShotTint { d.temperature = t; d.tint = tn }
        decode = d
    }

    func pickNeutral(at n: CGPoint) {
        guard let url = selection, let dec = decoded, dec.isRAW else { return }
        Task.detached(priority: .userInitiated) {
            guard let r = ImageDecoder.neutral(at: n, in: url) else { return }
            await MainActor.run {
                var d = self.decode
                d.whiteBalance = .custom; d.temperature = r.temperature; d.tint = r.tint
                self.decode = d
            }
        }
    }

    // MARK: - CanvasHost

    func viewportChanged() {
        viewportSnapshot = renderer.viewport
        guard renderer.base != nil else { zoomPercent = 0; isFit = true; return }
        zoomPercent = renderer.viewport.zoomPercent
        isFit = renderer.viewport.isFit
        updateDetailTier()
    }
    func picked(normalised n: CGPoint) {
        if wbPickerActive { wbPickerActive = false; pickNeutral(at: n) }
        else if curvePickerActive { curvePickerActive = false; addCurvePoint(at: n) }
        else if let id = maskColorPick { maskColorPick = nil; pickMaskColor(id, at: n) }
    }

    /// Sample the print under the cursor into a colour-range component. Read
    /// from the *base* texture — the print before Layer 2 — because that is
    /// what the shader's coverage test compares against.
    private func pickMaskColor(_ component: UUID, at n: CGPoint) {
        guard let base = renderer.base, let rgb = Session.sample(base, at: n),
              var m = selectedMask, let i = m.components.firstIndex(where: { $0.id == component }) else { return }
        m.components[i].color = SIMD3<Double>(Double(rgb.x), Double(rgb.y), Double(rgb.z))
        selectedMask = m
    }
    func geometryChanged(_ g: Geometry) { geometry = g }
    func straightenPreview(_ line: StraightenLine?) { straightenPreview = line }
    func stepFrame(_ delta: Int) { selectRelative(delta) }
    func toggledOriginal(_ on: Bool) { renderer.showOriginal = on; showingOriginal = on }
    func hovered(normalised n: CGPoint?) {
        guard let n, let base = renderer.base else { hoverValue = nil; return }
        hoverValue = Session.sample(base, at: n)
    }
    func contextMenu() -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Zoom to Fit", action: #selector(zoomFit), keyEquivalent: "").target = self
        m.addItem(withTitle: "Zoom to 100 %", action: #selector(zoomHundred), keyEquivalent: "").target = self
        m.addItem(.separator())
        let copy = m.addItem(withTitle: "Copy Settings", action: #selector(copyMenu), keyEquivalent: "")
        copy.target = self; copy.isEnabled = selection != nil
        let paste = m.addItem(withTitle: "Paste Settings", action: #selector(pasteMenu), keyEquivalent: "")
        paste.target = self; paste.isEnabled = canPasteSettings
        m.addItem(.separator())
        m.addItem(withTitle: "Reset Crop", action: #selector(resetCrop), keyEquivalent: "").target = self
        m.addItem(withTitle: "Export…", action: #selector(exportMenu), keyEquivalent: "").target = self
        return m
    }
    @objc private func zoomFit() { zoomToFit() }
    @objc private func zoomHundred() { zoomTo(fraction: 1) }
    @objc private func copyMenu() { copySettings() }
    @objc private func pasteMenu() { pasteSettings() }
    @objc private func resetCrop() { geometry = .default }
    @objc private func exportMenu() { showExport = true }

    /// What the engine's auto-exposure solved for this frame. The Exp. Comp.
    /// slider is an offset from it, so the UI has to say what the zero means
    /// (HANDOFF §4). The value comes from `solve(target:"exposure")` after
    /// `open` and is stored in the sidecar.
    var solvedEVLabel: String? {
        guard let ev = sidecar.solvedEV else { return nil }
        return String(format: "auto %+.1f EV", ev)
    }

    func zoomToFit() { renderer.viewport.fit(); viewportChanged(); renderer.needsDraw?() }
    func zoomTo(fraction: CGFloat) {
        let v = renderer.viewport
        renderer.viewport.setScale(fraction * v.hundredScale, about: CGPoint(x: v.viewport.width / 2, y: v.viewport.height / 2))
        viewportChanged(); renderer.needsDraw?()
    }
    func zoomStep(_ dir: Int) {
        let v = renderer.viewport
        renderer.viewport.stepZoom(dir, about: CGPoint(x: v.viewport.width / 2, y: v.viewport.height / 2))
        viewportChanged(); renderer.needsDraw?()
    }

    private func addCurvePoint(at n: CGPoint) {
        guard let base = renderer.base, let v = Session.sample(base, at: n) else { return }
        var a = adjustments
        let l = 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z
        var c = a.curves[.rgb]
        let x = CGFloat(l)
        c.insert(CGPoint(x: x, y: c.evaluate(x)))
        a.curves[.rgb] = c
        adjustments = a
    }

    /// Read one pixel of an rgba16Unorm texture (shared storage).
    nonisolated static func sample(_ tex: MTLTexture, at n: CGPoint) -> SIMD3<Float>? {
        guard tex.storageMode == .shared || tex.storageMode == .managed else { return nil }
        let x = Int(n.x * CGFloat(tex.width - 1)), y = Int(n.y * CGFloat(tex.height - 1))
        var px = [UInt16](repeating: 0, count: 4)
        tex.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return SIMD3(Float(px[0]) / 65535, Float(px[1]) / 65535, Float(px[2]) / 65535)
    }

    // MARK: - resolution follows the zoom
    //
    // The live tier is 1600 px on the long edge. Past 100 % zoom it is being
    // interpolated, which is exactly where grain and halation become the
    // reason to zoom — and an interpolated live tier cannot show them
    // (frontend SPEC §5.0). So the canvas asks for a real render at the zoom
    // level and swaps it in when it lands, never blocking the gesture.
    //
    // Measured on the 45 MP Nikon Z7 II frame (5504×8256), full render /
    // reprint:
    //
    //   |         | numba (2026-08) | GPU-native core (RFC-011) |
    //   |---------|-----------------|---------------------------|
    //   | live    | 0.57 / 0.20 s   | 0.042 / 0.012 s           |
    //   | preview | 2.38 / 0.82 s   | 0.173 / 0.046 s           |
    //   | full    | 13.7 / 4.73 s   | 0.990 / 0.237 s           |
    //
    // The escalation was designed around the left-hand column: a render that
    // takes six to seventeen seconds and cannot be cancelled once the service
    // has started it is worth a long wait before committing to. The
    // right-hand column is a different problem, so `detailDebounce` came down
    // from 700 ms to 180 — at 0.99 s cold, waiting 700 ms to decide is most
    // of the cost of just doing it.
    //
    // **The escalation stays two steps, and the reason is now memory rather
    // than time.** A full-tier rgba16 texture at 45 MP is 360 MB; the preview
    // tier is ~90 MB. Going straight to `full` at 100 % zoom would be about
    // as fast and would cost four times the resident memory for detail the
    // viewport cannot show.

    /// 100 % — one image pixel per device pixel.
    nonisolated static let detailZoomFraction: CGFloat = 1.0
    /// 200 % — twice the image pixels the viewport can show, past what the
    /// 3400 px preview tier can feed.
    nonisolated static let fullZoomFraction: CGFloat = 2.0
    nonisolated static let previewEdge = 3400
    /// How long the zoom must be still before a detail render is committed
    /// to. Sized against the *current* cost of that render — see the table
    /// above; it was 700 when a full render was seventeen seconds.
    nonisolated static let detailDebounceMs = 180

    nonisolated static func wantedTier(zoomFraction: CGFloat, imageLongEdge: CGFloat) -> DetailTier {
        guard imageLongEdge > CGFloat(Session.liveEdge) else { return .live }
        if zoomFraction >= Session.fullZoomFraction, imageLongEdge > CGFloat(Session.previewEdge) { return .full }
        if zoomFraction >= Session.detailZoomFraction { return .preview }
        return .live
    }

    /// The Layer 1 parameters a print was made from, as a comparable string.
    /// This is what stamps a detail render, so whether a resident texture is
    /// still the truth is a question about *data* rather than about which
    /// callback happened to run last.
    nonisolated static func printStamp(_ p: FilmParams) -> String {
        p.wire.map { "\($0.name)=\($0.value)" }.joined(separator: ";")
    }

    /// What the *service* currently holds — not `sidecar.params`, which may
    /// already be a slider ahead of it. The live print on screen was made
    /// from `sent`, so stamping the detail render with anything else would
    /// let the two disagree about which film they are showing.
    private var printStamp: String { Session.printStamp(scheduler.sent) }

    /// The long edge of what is actually on screen, in source pixels. A 20 %
    /// crop of a 45 MP frame has a 1651 px long edge, which the live tier
    /// already covers — escalating it would spend a full-resolution render on
    /// detail the crop threw away.
    private var croppedLongEdge: CGFloat {
        guard let live = renderer.sourceSize, max(live.width, live.height) > 0 else { return sourceLongEdge }
        let out = renderer.geometry.outputSize(for: live)
        return sourceLongEdge * max(out.width, out.height) / max(live.width, live.height)
    }

    private func updateDetailTier() {
        guard !browsing, let url = selection, decoded != nil, sourceLongEdge > 0 else { return }
        let want = Session.wantedTier(zoomFraction: renderer.viewport.zoomFraction,
                                      imageLongEdge: croppedLongEdge)

        if want == .live {
            guard detailTier != .live else { return }
            detailTier = .live
            detailTask?.cancel(); detailTask = nil
            detailPending = false
            // The texture stays in the store, so zooming back in is a swap.
            renderer.hideDetail()
            return
        }

        // Already showing something at least this sharp. This is the early
        // out that keeps a pan at 400 % free.
        if renderer.showsDetail, detailTier.rank >= want.rank { return }

        // A resident render of this frame, made from these parameters, at
        // this tier *or sharper*. Record the tier that is actually on screen,
        // not the one that was asked for — otherwise the next zoom step
        // thinks it needs a render it already has.
        if let resident = renderer.store.detail(for: url, stamp: printStamp, atLeast: want.rank) {
            detailTask?.cancel(); detailTask = nil
            detailPending = false
            detailTier = DetailTier(rawValue: resident.tier) ?? want
            renderer.setDetail(resident.texture)
            return
        }

        // Nothing resident. Leave an identical request that is already on its
        // way alone; anything else starts one.
        if want == detailTier, detailPending || detailTask != nil { return }
        detailTier = want
        detailTask?.cancel(); detailTask = nil
        detailPending = false
        scheduleDetail()
    }

    private func scheduleDetail() {
        guard detailTier != .live, let url = selection, let sid = serviceSessionID else { return }
        detailGeneration += 1
        let gen = detailGeneration
        let tier = detailTier
        detailTask?.cancel()
        detailTask = Task { [weak self] in
            // Wait for the gesture (and any edit) to stop. The render still
            // cannot be cancelled once the service has started it — `cancel`
            // cannot arrive mid-render on stdio — so some wait is right; it
            // is 180 ms rather than 700 because the thing being deferred is
            // now a second rather than seventeen.
            try? await Task.sleep(for: .milliseconds(Session.detailDebounceMs))
            guard let self, !Task.isCancelled, gen == self.detailGeneration else { return }
            await self.renderDetail(tier: tier, for: url, sessionID: sid, generation: gen)
        }
    }

    private func renderDetail(tier: DetailTier, for url: URL, sessionID: String, generation gen: Int) async {
        // The transport is single-flight, so a detail render sits in front of
        // the user's next slider release. That is a quarter second now rather
        // than six, but single-flight has not changed and `capabilities`
        // still reports `concurrent: false`, so the rule stands: never start
        // one while an edit is owed a render — wait for the scheduler to go
        // idle and ask again, rather than dropping the escalation.
        guard !busy, !scheduler.pending, detailTier == tier, selection == url else {
            if detailTier == tier, selection == url { scheduleDetail() }
            return
        }
        detailPending = true
        startClock()
        // Stamped here, before the call, from what the service holds. The
        // guard above has just established that no edit is owed a render, so
        // `sent` is exactly what this reprint will be made from.
        let stamp = printStamp
        canvasLog("detail \(tier.rawValue) requested for \(url.lastPathComponent)")
        defer { detailPending = false }
        do {
            let outcome = try await client.render(.reprint,
                RenderRequest(sessionID: sessionID, tier: tier.rawValue))
            let r = outcome.response
            guard gen == detailGeneration, selection == url,
                  let tex = outcome.texture, let w = r.width, let h = r.height else { return }
            renderer.store.setDetail(tex, tier: tier.rawValue, rank: tier.rank, stamp: stamp, for: url)
            renderer.setDetail(tex)
            canvasLog("detail \(tier.rawValue) \(w)x\(h) landed in \(Int(r.elapsedMs)) ms")
            if let base = statusBase { status = base }
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: - editing history, clipboard, service

    /// Snapshot before a mutation, coalesced. A slider drag sets its value
    /// dozens of times and only the state before the drag is worth keeping.
    private func pushUndo() {
        let now = Date()
        guard now.timeIntervalSince(lastUndoAt) > 0.5 else { return }
        lastUndoAt = now
        undoStack.append(sidecar)
        if undoStack.count > 60 { undoStack.removeFirst() }
    }

    var canUndo: Bool { !undoStack.isEmpty }

    /// Undo is a deterministic re-render from a snapshot: the params are tiny,
    /// the service never needs to know, and grain is baked into its cached
    /// negative so a reprint is stable (HANDOFF §5).
    func undo() {
        guard selection != nil, let previous = undoStack.popLast() else { return }
        let current = sidecar
        sidecar = previous
        renderer.layer2 = previous.adjustments.uniforms
        renderer.setCurves(previous.adjustments.curves)
        renderer.geometry = previous.geometry
        selectedMaskID = previous.masks.first { $0.id == selectedMaskID }?.id ?? previous.masks.last?.id
        syncMasks()
        if current.decode != previous.decode {
            previewSoft = true
            scheduleReopen()
        } else {
            scheduler.request(previous.params)
        }
        markStale()
        scheduleSave()
        lastUndoAt = .distantPast
        status = "Undo — \(undoStack.count) step\(undoStack.count == 1 ? "" : "s") left."
    }

    var canPasteSettings: Bool { clipboard != nil && selection != nil }

    func copySettings() {
        guard selection != nil else { return }
        clipboard = SettingsClip(params: sidecar.params, adjustments: sidecar.adjustments)
        status = "Copied film, print and adjustment settings."
    }

    /// Offsets only (frontend SPEC §5.5): the decode block is per-frame and
    /// the crop is framing, so neither is copied.
    func pasteSettings() {
        guard let clip = clipboard, selection != nil else { return }
        pushUndo()
        sidecar.params = clip.params
        sidecar.adjustments = clip.adjustments
        renderer.layer2 = clip.adjustments.uniforms
        renderer.setCurves(clip.adjustments.curves)
        scheduler.request(clip.params)
        markStale()
        scheduleSave()
        status = "Pasted settings — each frame keeps its own exposure solve."
    }

    // MARK: - solve, and looking at the original

    var canSolve: Bool { serviceReady && serviceSessionID != nil && !busy }

    /// Ask the engine to solve this frame: auto-exposure **and** the enlarger
    /// filter pack for the paper that is selected.
    ///
    /// The load path already calls `solve(target: "exposure")`, which is
    /// read-only — it reports the baseline the Exp. Comp. slider offsets from
    /// and writes nothing. This is the other half, `target: "both"`, which
    /// *does* write neutrals onto the session, and it is a button rather than
    /// something that happens on open for exactly that reason: it changes the
    /// picture, so the user asks for it.
    ///
    /// The Y/M filter shifts are offsets from the solved neutrals, so they go
    /// back to zero here — leaving a shift on top of a freshly solved pack
    /// means "solve" would visibly not solve.
    func solveNow() {
        guard let sid = serviceSessionID, serviceReady else {
            status = "The render service is not running."; return
        }
        busy = true
        startClock()
        status = "Solving…"
        Task {
            defer { busy = false }
            do {
                _ = try await client.call(.solve, SolveRequest(sessionID: sid, target: "both"),
                                          as: SolveResponse.self)
                guard serviceSessionID == sid else { return }
                var p = params
                p.yFilterShift = 0
                p.mFilterShift = 0
                // The scheduler's `sent` no longer describes the session: the
                // engine wrote neutrals underneath it. Re-open the generation
                // so the next request is a full delta rather than one
                // computed against parameters the engine has moved.
                params = p
                scheduler.invalidate()
                serviceGeneration = scheduler.reset(sessionID: sid, params: p)
                let rr = try await client.render(.reprint, RenderRequest(sessionID: sid))
                guard serviceSessionID == sid else { return }
                applyRender(rr, generation: serviceGeneration)
                status = "Solved  ·  reprint \(Int(rr.response.elapsedMs)) ms"
                scheduleSave()
            } catch {
                lastError = "\(error)"
                status = "\(error)"
            }
        }
    }

    /// The Python process can die; `ServiceClient.start()` is idempotent, so a
    /// restart is a stop and a reload from the sidecar (HANDOFF §5).
    func restartService() {
        loadTask?.cancel()
        Task {
            await client.stop()
            serviceReady = false
            serviceSessionID = nil
            scheduler.invalidate()
            renderer.dropDetail()
            renderer.store.dropDetail()
            guard let url = selection else { status = "Render service stopped."; return }
            status = "Restarting the render service…"
            loadTask = Task { await load(url) }
        }
    }

    /// Elapsed time for the current piece of work. The service cannot report
    /// real progress: `reprint` does not return until the render is finished,
    /// and the transport is single-flight, so `progress` can never be polled
    /// while a render is in flight. Elapsed time is the honest substitute.
    private func startClock() {
        guard workClock == nil else { return }
        workStarted = Date()
        workSeconds = 0
        workClock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                if let start = self.workStarted { self.workSeconds = Date().timeIntervalSince(start) }
                if !self.working { break }
            }
            self?.workClock = nil
            self?.workStarted = nil
            self?.workSeconds = 0
        }
    }

    // MARK: - reset helpers

    func resetParams() { params = .default }
    func resetAdjustments() { adjustments = Adjustments(enabled: adjustments.enabled) }
}

/// Metal textures are thread-safe to hand across; the protocol just is not
/// marked Sendable. The box states the intent in one place.
struct TextureBox: @unchecked Sendable { let texture: MTLTexture?; init(_ t: MTLTexture?) { texture = t } }

/// Shares `SPEKTRAFILM_CANVAS_LOG=1` with `Renderer`: the canvas being blank
/// is a whole-pipeline symptom, so both ends of it log under one switch.
@MainActor
func canvasLog(_ message: @autoclosure () -> String) {
    guard Renderer.logDraws else { return }
    FileHandle.standardError.write(Data("session: \(message())\n".utf8))
}

extension Notification.Name { static let thumbnailUpdated = Notification.Name("thumbnailUpdated") }

extension EngineClient {
    func set(onTermination: @escaping @Sendable (String) -> Void) { self.onTermination = onTermination }
}

/// ISO / shutter / aperture for the histogram caption, via ImageIO.
struct EXIFReadout: Sendable {
    var iso: String?, shutter: String?, aperture: String?
    static func read(_ url: URL) -> EXIFReadout? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }
        var r = EXIFReadout()
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { r.iso = "ISO \(iso)" }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double {
            r.shutter = t >= 1 ? String(format: "%.0f s", t) : "1/\(Int((1 / t).rounded())) s"
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { r.aperture = String(format: "f/%g", f) }
        return r
    }
}

extension Session {
    /// The service session id once the current frame is open there, else nil.
    func currentServiceSession() async -> String? { serviceSessionIDForExport }
}
