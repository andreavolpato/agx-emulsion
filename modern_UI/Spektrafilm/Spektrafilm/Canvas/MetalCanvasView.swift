//  MetalCanvasView.swift — the MTKView, its gestures, and nothing else.
//
//  Gesture model (Capture One): two-finger scroll pans, pinch or ⌘/⌥-scroll
//  zooms about the cursor, double-click toggles fit ↔ 100 %, drag pans in the
//  hand tool. The view is flipped so mouse coordinates share the shader's
//  top-left origin. Every change goes through `ViewportState` and then
//  `scheduleDraw()`; the view never redraws on its own. Read `scheduleDraw`'s
//  comment before replacing it with `needsDisplay` — that is the version that
//  shipped a blank canvas.

import AppKit
import MetalKit
import SwiftUI

enum CanvasTool: String, CaseIterable, Sendable { case select, hand, crop }

/// A straighten gesture in progress, in source-normalised coordinates.
struct StraightenLine: Equatable, Sendable { var from: CGPoint; var to: CGPoint }

@MainActor
protocol CanvasHost: AnyObject {
    var renderer: Renderer { get }
    var tool: CanvasTool { get }
    var pickerActive: Bool { get }
    func viewportChanged()
    func picked(normalised: CGPoint)
    var geometry: Geometry { get }
    /// The live tier's pixel size. The geometry is normalised against it, and
    /// the rotation is rigid in *pixels*, so the hit tests need it.
    var sourceImageSize: CGSize { get }
    func geometryChanged(_ geometry: Geometry)
    /// Return: keep the crop and leave the tool. Esc: put the crop back the
    /// way it was on entering the tool, and leave. Both are no-ops outside
    /// the crop tool.
    func commitCrop()
    func cancelCrop()
    /// The line being drawn for a ⌘-drag straighten, or nil. Published so
    /// `CropOverlay` can draw it; the gesture itself stays in the view.
    func straightenPreview(_ line: StraightenLine?)
    /// The selected mask's grips, source-normalised. Empty unless a mask with
    /// draggable geometry is selected.
    var maskHandles: [MaskHandle] { get }
    func maskHandleDragged(_ handle: MaskHandle, to normalised: CGPoint)
    func toggledOriginal(_ on: Bool)
    func contextMenu() -> NSMenu?
    func hovered(normalised: CGPoint?)
    func stepFrame(_ delta: Int)
}

/// The view is its own `MTKViewDelegate`. A separate coordinator object has
/// to be owned by something — `MTKView.delegate` is weak — and getting that
/// ownership wrong means the delegate silently disappears and the canvas
/// stops drawing. One object, one lifetime, no way to forget to wire it.
final class CanvasNSView: MTKView, MTKViewDelegate {
    weak var host: CanvasHost?
    private var drawScheduled = false
    private var dragStart: CGPoint?
    /// The crop gesture in flight. `.none` when the crop tool is not being
    /// dragged; the rest carry what the drag needs to be idempotent — every
    /// mouse move recomputes from `origin` rather than accumulating, so a
    /// gesture that hits the frame edge and comes back does not drift.
    /// A mask grip being dragged. Masks are edited with the *select* tool,
    /// the way Lightroom does it: a grip takes the drag, and anywhere else
    /// still pans.
    private var maskDrag: MaskHandle?

    private enum CropDrag {
        case handle(CropHandle, origin: Geometry, grabOffset: CGSize)
        case draw(from: CGPoint)
        case straighten(from: CGPoint, origin: Geometry)
    }
    private var cropDrag: CropDrag?

    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var renderer: Renderer? { host?.renderer }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncViewport()
        // ←/→ step frames, and they only reach `keyDown` when the canvas is
        // first responder. Claim it on entering a window, unless something is
        // already being typed into — an editable slider value must keep its
        // arrow keys (HANDOFF §6).
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !(window.firstResponder is NSTextView) else { return }
            window.makeFirstResponder(self)
        }
    }

    override func layout() {
        super.layout()
        syncViewport()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(ta)
        trackingArea = ta
    }

    /// Ask for one draw on the next runloop turn.
    ///
    /// **Not `needsDisplay = true`.** The documented on-demand recipe for
    /// `MTKView` is `isPaused` + `enableSetNeedsDisplay` + `needsDisplay`, and
    /// on this macOS it does not fire the delegate: measured with the view in
    /// a window, visible, unpaused-for-display and correctly sized, every
    /// state change set `needsDisplay` and **no draw followed** — the canvas
    /// stayed blank while the pipeline behind it worked. Only the initial
    /// layout pass and live resizes ever drew.
    ///
    /// `MTKView.draw()` runs the delegate immediately, so it is the mechanism
    /// that actually holds. It is coalesced to one call per runloop turn (a
    /// slider drag sets several pieces of state per event) and deferred, so a
    /// draw can never re-enter a SwiftUI layout pass that is still running.
    func scheduleDraw() {
        needsDisplay = true          // keeps live-resize redraws working
        guard !drawScheduled else { return }
        drawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.drawScheduled = false
            guard self.window != nil, self.bounds.width > 0, self.bounds.height > 0 else { return }
            self.draw()
        }
    }

    func syncViewport() {
        guard let renderer, bounds.width > 0, bounds.height > 0 else { return }
        let bs = window?.backingScaleFactor ?? 2
        var vp = renderer.viewport
        vp.backingScale = bs
        if vp.viewport != bounds.size { vp.resize(viewport: bounds.size) }
        if vp != renderer.viewport {
            renderer.viewport = vp
            host?.viewportChanged()
        }
        scheduleDraw()
    }

    private func local(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    // MARK: scroll / pinch

    override func scrollWheel(with e: NSEvent) {
        guard let renderer else { return }
        let p = local(e)
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 4
            let factor = pow(1.0025, -dy)
            renderer.viewport.zoom(by: factor, about: p)
        } else {
            let dx = e.hasPreciseScrollingDeltas ? e.scrollingDeltaX : e.scrollingDeltaX * 10
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 10
            renderer.viewport.pan(by: CGSize(width: dx, height: dy))
        }
        host?.viewportChanged()
        scheduleDraw()
    }

    override func magnify(with e: NSEvent) {
        guard let renderer else { return }
        renderer.viewport.zoom(by: 1 + e.magnification, about: local(e))
        host?.viewportChanged()
        scheduleDraw()
    }

    // MARK: mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        guard let renderer, let host else { return }
        let p = local(e)
        if e.clickCount == 2 {
            renderer.viewport.toggleHundred(about: p)
            host.viewportChanged()
            scheduleDraw()
            return
        }
        if host.pickerActive, let n = renderer.viewport.normalised(atView: p) {
            host.picked(normalised: n)
            return
        }
        switch host.tool {
        case .crop:
            guard let n = renderer.viewport.normalised(atView: p) else { return }
            let g = host.geometry
            let size = host.sourceImageSize
            // ⌘-drag draws a line that should be horizontal, and the frame
            // straightens to it. Lightroom's and Capture One's gesture, and
            // the only one that beats nudging a slider by eye.
            if e.modifierFlags.contains(.command) {
                cropDrag = .straighten(from: n, origin: g)
                host.straightenPreview(StraightenLine(from: n, to: n))
                return
            }
            // A grab area that is a constant size on screen: 10 pt, converted
            // through the viewport so it is not enormous at 12 % zoom and
            // unhittable at 400 %.
            let tolerance = CanvasNSView.handleGrab / max(renderer.viewport.scale, 1e-6)
            if let handle = g.handle(at: n, in: size, tolerance: tolerance) {
                let c = g.centre
                cropDrag = .handle(handle, origin: g,
                                   grabOffset: CGSize(width: n.x - c.x, height: n.y - c.y))
            } else {
                cropDrag = .draw(from: n)
            }
        default:
            // A mask grip claims the drag before the pan does, and only
            // within the same 10 pt it is drawn inside.
            if let h = maskHandle(near: p) { maskDrag = h; return }
            dragStart = p
        }
    }

    /// The mask grip under a view point, if any. Positions come from the
    /// host, so this and `MaskOverlay` cannot disagree about where a grip is.
    private func maskHandle(near p: CGPoint) -> MaskHandle? {
        guard let host, let renderer else { return nil }
        let handles = host.maskHandles
        guard !handles.isEmpty else { return nil }
        let size = host.sourceImageSize
        let v = renderer.viewport
        var best: (MaskHandle, CGFloat)?
        for h in handles {
            let o = host.geometry.outputPoint(forSource: h.position, imageSize: size)
            let q = CGPoint(x: v.offset.x + o.x * v.image.width * v.scale,
                            y: v.offset.y + o.y * v.image.height * v.scale)
            let d = hypot(q.x - p.x, q.y - p.y)
            if d <= CanvasNSView.handleGrab, best == nil || d < best!.1 { best = (h, d) }
        }
        return best?.0
    }

    /// Radius of a crop grip's grab area, in view points.
    static let handleGrab: CGFloat = 10

    override func mouseDragged(with e: NSEvent) {
        guard let renderer, let host else { return }
        let p = local(e)
        if let h = maskDrag {
            // Through the crop: the grip is anchored to the source and the
            // canvas is showing the output.
            if let out = renderer.viewport.normalised(atView: p) {
                host.maskHandleDragged(h, to: host.geometry.sourcePoint(forOutput: out, imageSize: host.sourceImageSize))
            }
            return
        }
        if let drag = cropDrag, host.tool == .crop {
            // Clamped rather than dropped: a drag that leaves the image still
            // has a meaning, and `Geometry` fits whatever comes out of it.
            let ip = renderer.viewport.imagePoint(atView: p)
            let img = renderer.viewport.image
            let n = CGPoint(x: (ip.x / max(img.width, 1)).clamped(to: 0...1),
                            y: (ip.y / max(img.height, 1)).clamped(to: 0...1))
            let size = host.sourceImageSize
            switch drag {
            case .handle(.body, let origin, let grab):
                let target = CGPoint(x: n.x - grab.width, y: n.y - grab.height)
                let delta = CGSize(width: target.x - origin.centre.x, height: target.y - origin.centre.y)
                host.geometryChanged(origin.moved(by: delta, in: size))
            case .handle(let handle, let origin, _):
                host.geometryChanged(origin.resized(handle: handle,
                                                    to: origin.unrotated(n, in: size), in: size))
            case .draw(let from):
                let x0 = min(from.x, n.x), y0 = min(from.y, n.y)
                let w = abs(n.x - from.x), h = abs(n.y - from.y)
                guard w * size.width > Geometry.minSide, h * size.height > Geometry.minSide else { return }
                var g = host.geometry
                g.crop = CropRect(x: x0, y: y0, width: w, height: h)
                // A fresh rectangle is drawn axis-aligned to the *frame*, so
                // it starts unstraightened; the angle is a separate decision
                // and re-applying the old one would rotate a rectangle the
                // user just drew square.
                g.angle = 0
                host.geometryChanged(g.constrained(in: size, anchor: anchorFor(from: from, to: n)))
            case .straighten(let from, _):
                host.straightenPreview(StraightenLine(from: from, to: n))
            }
            return
        }
        if let s = dragStart {
            renderer.viewport.pan(by: CGSize(width: p.x - s.x, height: p.y - s.y))
            dragStart = p
            host.viewportChanged()
            scheduleDraw()
        }
    }

    /// While drawing a rectangle the aspect constraint must grow from the
    /// corner the drag started at, not from the centre.
    private func anchorFor(from: CGPoint, to: CGPoint) -> CGPoint {
        CGPoint(x: to.x >= from.x ? 0 : 1, y: to.y >= from.y ? 0 : 1)
    }

    override func mouseUp(with e: NSEvent) {
        dragStart = nil
        maskDrag = nil
        if case .straighten(let from, let origin) = cropDrag, let host, let renderer {
            let n = renderer.viewport.normalised(atView: local(e)) ?? from
            if let deg = Geometry.straightenAngle(from: from, to: n, in: host.sourceImageSize) {
                host.geometryChanged(origin.straightened(to: origin.angle + deg, in: host.sourceImageSize))
            }
        }
        cropDrag = nil
        host?.straightenPreview(nil)
        scheduleDraw()
    }

    override func mouseMoved(with e: NSEvent) {
        guard let renderer else { return }
        host?.hovered(normalised: renderer.viewport.normalised(atView: local(e)))
    }

    override func mouseExited(with e: NSEvent) { host?.hovered(normalised: nil) }

    override func rightMouseDown(with e: NSEvent) {
        if let menu = host?.contextMenu() { NSMenu.popUpContextMenu(menu, with: e, for: self) }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { syncViewport() }

    func draw(in view: MTKView) { host?.renderer.draw(in: view) }

    override func resetCursorRects() {
        switch host?.tool {
        case .hand: addCursorRect(bounds, cursor: .openHand)
        case .crop: addCursorRect(bounds, cursor: .crosshair)   // grips get their own in CropOverlay
        default: addCursorRect(bounds, cursor: host?.pickerActive == true ? .crosshair : .arrow)
        }
    }

    // MARK: keys

    override func keyDown(with e: NSEvent) {
        guard let renderer, let host else { return }
        switch e.keyCode {
        case 49: host.toggledOriginal(true)                              // space
        case 123: host.stepFrame(-1)                                     // ←
        case 124: host.stepFrame(1)                                      // →
        case 6 where !e.modifierFlags.contains(.command):                // z
            renderer.viewport.toggleHundred(about: CGPoint(x: bounds.midX, y: bounds.midY))
            host.viewportChanged(); scheduleDraw()
        // Return commits the crop, Esc abandons it — every crop tool in every
        // editor, and the pair of keys a photographer's hands already know.
        // They are handled here rather than as menu shortcuts because Return
        // and Esc belong to whatever has focus; as a global ⌘-less menu key
        // they would fire while a slider value was being typed into.
        // (`where` binds to its own pattern, so both spellings carry it.)
        case 36 where host.tool == .crop, 76 where host.tool == .crop:   // ⏎ / ⌤
            host.commitCrop()
        case 53 where host.tool == .crop:                                // esc
            host.cancelCrop()
        default: super.keyDown(with: e)
        }
    }

    /// Esc reaches a view through `cancelOperation` when the responder chain
    /// gets to interpret it first (a sheet, a menu, a field). Same action, so
    /// the key works whichever route it takes.
    override func cancelOperation(_ sender: Any?) {
        if host?.tool == .crop { host?.cancelCrop() } else { super.cancelOperation(sender) }
    }

    override func keyUp(with e: NSEvent) {
        if e.keyCode == 49 { host?.toggledOriginal(false) } else { super.keyUp(with: e) }
    }
}

extension CanvasNSView {
    /// The whole configuration of the canvas view, in one place so the tests
    /// exercise the same code the app runs — `MetalCanvasView.makeNSView` adds
    /// nothing.
    ///
    /// The pixel format here is the one that crashed on the first real launch:
    /// `CAMetalLayer` rejects most texture formats and raises an ObjC
    /// exception rather than returning an error, so it must be a *drawable*
    /// format. See `Renderer.drawableFormat`.
    @MainActor
    static func configured(host: CanvasHost) -> CanvasNSView {
        let view = CanvasNSView(frame: .zero, device: host.renderer.device)
        view.host = host
        view.delegate = view
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = Renderer.drawableFormat
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColor(red: 0x5F / 255.0, green: 0x5F / 255.0, blue: 0x5F / 255.0, alpha: 1)
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = ImageDecoder.displayP3
            layer.wantsExtendedDynamicRangeContent = false
        }
        view.layer?.backgroundColor = CGColor(srgbRed: 0x5F / 255.0, green: 0x5F / 255.0, blue: 0x5F / 255.0, alpha: 1)
        let renderer = host.renderer
        renderer.needsDraw = { [weak view] in view?.scheduleDraw() }
        return view
    }
}

struct MetalCanvasView: NSViewRepresentable {
    let host: CanvasHost

    func makeNSView(context: Context) -> CanvasNSView {
        CanvasNSView.configured(host: host)
    }

    func updateNSView(_ view: CanvasNSView, context: Context) {
        view.host = host
        view.window?.invalidateCursorRects(for: view)
        view.scheduleDraw()
    }
}
