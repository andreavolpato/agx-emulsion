//  Session.swift — all editor state. @Observable, @MainActor.
//
//  Observation rather than ObservableObject (UI-GUIDELINE §2): fine-grained
//  invalidation matters here, because a print-exposure drag must not
//  invalidate the filmstrip.

import Foundation
import Observation
import SwiftUI

/// A file in the current folder. The folder *is* the session (frontend SPEC
/// §7) — there are no project files.
@Observable
final class Frame: Identifiable {
    let id = UUID()
    let url: URL
    var thumbnail: CGImage?
    var state: FrameState = .unprocessed

    init(url: URL) { self.url = url }

    var isRAW: Bool { ImageDecoder.rawExtensions.contains(url.pathExtension.lowercased()) }

    /// The three thumbnail states of frontend SPEC §5.1. The third is
    /// mandatory: without it the grid lies after any edit.
    enum FrameState { case unprocessed, processed, stale }

}

/// What the canvas is currently showing, and how honest it is.
///
/// This is the `preview` / `soft` indicator of frontend SPEC §4, and it is
/// not decoration: the client-side path skips `scanning.glare`, which is
/// spatial and stochastic and cannot live in a pointwise LUT (API-SPEC §2).
/// The difference is visible, so the badge says which one is on screen.
enum CanvasFidelity: String {
    /// No engine involved — the decoded input, before any film simulation.
    /// This is what step one of the build shows.
    case input   = "input"
    /// GPU-composited preview. Glare is absent.
    case preview = "preview"
    /// Interpolated beyond the resident buffer's native resolution.
    case soft    = "soft"
    /// A real `reprint` from the service. Nothing skipped.
    case exact   = "exact"

    /// Short enough for a toolbar. The explanation is a tooltip, not a label.
    var caption: String {
        switch self {
        case .input:   "Input"
        case .preview: "Preview"
        case .soft:    "Soft"
        case .exact:   "Print"
        }
    }

    var detail: String {
        switch self {
        case .input:   "The decoded input. No film simulation has run."
        case .preview: "GPU preview. Glare is not represented — it is spatial and stochastic and cannot live in a LUT."
        case .soft:    "Magnified past the resident buffer's resolution. Interpolated, not more detail."
        case .exact:   "A full render. Nothing skipped."
        }
    }
}

@Observable
@MainActor
final class Session {
    // --- folder and selection -------------------------------------------
    var folder: URL?
    var frames: [Frame] = []
    var selection: Frame.ID?

    var current: Frame? { frames.first { $0.id == selection } }

    // --- what the canvas holds ------------------------------------------
    var decoded: DecodedImage?
    var fidelity: CanvasFidelity = .input

    /// Absolute magnification: 1.0 is 100%, one image pixel per point. Only
    /// meaningful when `fitToWindow` is false.
    var zoom: Double = 1.0
    /// Captured on gesture begin — `magnification` is measured from the
    /// gesture's origin, not the last event, so accumulating it drifts.
    var zoomAtGestureStart: Double = 1.0
    /// Normalised image-space offset. Clamped in the renderer, never here.
    var pan: CGPoint = .zero
    /// How much of the current drag has already been applied, so a
    /// translation-based gesture can be turned into per-event deltas.
    var dragConsumed: CGSize = .zero
    var fitToWindow = true
    var viewport: CGSize = .zero

    /// Owned here so the panels can report what the canvas actually did
    /// (upload time, pipeline errors) rather than what it was asked to do.
    /// One renderer per session: `NSViewRepresentable` updates the MTKView,
    /// it never re-makes it (UI-GUIDELINE §11).
    let renderer: Renderer? = Renderer()

    // --- parameters ------------------------------------------------------
    /// Resolved values, keyed by transport wire name. Empty until `open`
    /// returns; the placeholders below exist so the panel renders before a
    /// service exists to ask.
    var params: [String: ParamValue] = Session.placeholderParams

    /// The auto-solve result. Print-side sliders display *offset from* this,
    /// not absolute values — frontend SPEC §5.2 item 2 puts PRD §0's
    /// "sliders exist to override the auto-solve" model directly into the
    /// interface, and it is what makes paste-settings meaningful across
    /// frames.
    var solve: SolveResult?

    // --- Layer 2 (frontend SPEC §3.1) ------------------------------------
    /// Lives entirely in the client. Requires no service call at all.
    var adjustments = Adjustments()
    /// Frontend SPEC §3.1 rule 2. The only way to tell, later, whether a look
    /// came from the stock or from a curve — and the stable reference for
    /// judging engine changes.
    var adjustmentsBypassed = false

    // --- layout ----------------------------------------------------------
    var leftCollapsed = false
    var rightCollapsed = false
    var stripCollapsed = false

    // --- status ----------------------------------------------------------
    var status: String = "no folder open"
    var lastError: String?
    var busy: BusyState?

    struct BusyState { var label: String; var determinate: Double? }

    // --- canvas ----------------------------------------------------------

    /// Zoom limits. Below fit there is nothing to see; above 800% the live
    /// tier is pure interpolation and the number stops meaning anything.
    static let zoomRange = 0.05...8.0

    func setZoom(_ value: Double, viewport: CGSize) {
        let fit = renderer?.fitScale(viewport: viewport) ?? 1
        let next = value.clamped(to: Session.zoomRange)
        // Snapping back to Fit rather than allowing a hair-below-fit zoom
        // keeps the two states distinct; a canvas that is 99% fitted with a
        // dead pan is just a bug the user has to diagnose.
        if next <= fit * 1.001 {
            fitToWindow = true
            pan = .zero
        } else {
            fitToWindow = false
            zoom = next
        }
        updateFidelity()
    }

    func zoomBy(_ factor: Double, viewport: CGSize) {
        let base = fitToWindow ? (renderer?.fitScale(viewport: viewport) ?? 1) : zoom
        setZoom(base * factor, viewport: viewport)
        zoomAtGestureStart = zoom
    }

    func zoomIn()  { zoomBy(1.25, viewport: viewport) }
    func zoomOut() { zoomBy(1 / 1.25, viewport: viewport) }

    func zoomTo100() { setZoom(1.0, viewport: viewport); zoomAtGestureStart = zoom }

    func fit() {
        fitToWindow = true
        pan = .zero
        zoomAtGestureStart = renderer?.fitScale(viewport: viewport) ?? 1
        updateFidelity()
    }

    /// Double-click. Capture One's toggle: whichever state you are not in.
    func toggleFitOr100(viewport: CGSize) {
        self.viewport = viewport
        if fitToWindow { zoomTo100() } else { fit() }
    }

    /// Pan in viewport points. Converted to normalised image space here; the
    /// clamp that keeps the frame on screen lives in the renderer, so there
    /// is exactly one place that decides what "off-screen" means.
    func panBy(dx: Double, dy: Double, viewport: CGSize) {
        guard !fitToWindow, let renderer, renderer.textureSize.width > 0 else { return }
        let (scale, _) = renderer.samplingTransform(viewport: viewport)
        pan.x += dx / max(viewport.width, 1) * Double(scale.x)
        pan.y += dy / max(viewport.height, 1) * Double(scale.y)
    }

    private func updateFidelity() {
        // Past 100% the live tier has no more data and the canvas is
        // interpolating. Inspecting grain and halation is the reason to zoom
        // (API-SPEC §4 measured both as invisible below full resolution), so
        // an interpolated view must say so rather than imply detail.
        fidelity = (!fitToWindow && zoom > 1.001) ? .soft : .input
    }

    /// Commit one parameter. The single funnel every module's `onCommit`
    /// goes through, so wiring the service later is one function, not one per
    /// control.
    func commit(_ name: String) {
        guard let layer = Schema.layer(of: name) else { return }
        status = layer == .print ? "\(name) → reprint" : "\(name) → full render"
    }

    // --- derived ---------------------------------------------------------
    func number(_ name: String) -> Double {
        params[name]?.double ?? Schema.range(of: name)?.lowerBound ?? 0
    }
    func flag(_ name: String) -> Bool { params[name]?.bool ?? false }
    func text(_ name: String) -> String { params[name]?.string ?? "" }

    /// A binding onto one transport field, so a control can write straight
    /// into `params` without every panel repeating the unwrap.
    func numberBinding(_ name: String) -> Binding<Double> {
        Binding(get: { self.number(name) },
                set: { self.params[name] = .number($0) })
    }
    func flagBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { self.flag(name) },
                set: { self.params[name] = .flag($0) })
    }
    func textBinding(_ name: String) -> Binding<String> {
        Binding(get: { self.text(name) },
                set: { self.params[name] = .text($0) })
    }

    /// Open a folder, or a file's folder with that file selected. The folder
    /// is the session — there are no project files (frontend SPEC §7).
    func open(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        load(folder: isDir.boolValue ? url : url.deletingLastPathComponent())
        if !isDir.boolValue {
            selection = frames.first { $0.url == url }?.id
        }
    }

    // --- folder loading --------------------------------------------------
    func load(folder url: URL) {
        self.folder = url
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        frames = contents
            .filter { ImageDecoder.openable.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(Frame.init)
        selection = frames.first?.id
        status = frames.isEmpty
            ? "no openable images in \(url.lastPathComponent)"
            : "\(frames.count) frames · \(url.lastPathComponent)"
    }

    static let placeholderParams: [String: ParamValue] = [
        "film_stock":  .text("kodak_portra_400"),
        // Frontend SPEC §9, settled: this pair is Layer 2's zero point, not
        // merely a default value.
        "print_stock": .text("kodak_supra_endura"),
        "print_exposure": .number(1.0),
        "m_filter_shift": .number(0), "y_filter_shift": .number(0),
        "c_filter_neutral": .number(0), "m_filter_neutral": .number(0),
        "y_filter_neutral": .number(0),
        "preflash_exposure": .number(0),
        "exposure_compensation_ev": .number(0),
        "auto_exposure": .flag(true),
        "grain_active": .flag(true), "grain_sublayers_active": .flag(true),
        "halation_active": .flag(true), "halation_amount": .number(1),
        "glare_active": .flag(true),
        "scanner_white_correction": .flag(true),
        "scanner_black_correction": .flag(true),
        "scan_film": .flag(false),
    ]
}

/// Layer 2. Ordinary editing on the print output, treated as a scan of a
/// print — which is exactly what it is (frontend SPEC §3.1).
///
/// Order of operations is fixed and not user-configurable:
/// exposure → highlights/shadows → black/white point → curve → masks.
/// Fixed order is what keeps the sidecar replayable at export without
/// storing a node graph (frontend SPEC §5.2 item 6).
@Observable
final class Adjustments {
    var exposure: Double = 0        // stops, on the print output
    var highlights: Double = 0
    var shadows: Double = 0
    var blackPoint: Double = 0
    var whitePoint: Double = 0

    var isNeutral: Bool {
        exposure == 0 && highlights == 0 && shadows == 0
            && blackPoint == 0 && whitePoint == 0
    }

    func reset() {
        exposure = 0; highlights = 0; shadows = 0; blackPoint = 0; whitePoint = 0
    }
}
