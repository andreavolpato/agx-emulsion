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
    /// The crop tool's pivot, source-normalised. Every crop-tool drag is
    /// converted through the edit space this point defines, so a gesture and
    /// the picture it is dragging cannot disagree about where the centre is.
    var cropPivot: CGPoint { get }
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
        /// A fresh rectangle being drawn level on screen: `from` is the
        /// **edit-space** point the drag started at.
        case draw(from: CGPoint)
        /// The ⌘ line. `from` is edit space too — the space the user is
        /// drawing in (see `mouseDown`).
        case straighten(from: CGPoint, origin: Geometry)
        /// Turning the photograph. `centre` is the frame's centre in **view**
        /// points and `from` the pointer's bearing about it at mouse-down;
        /// the angle between them is the turn.
        case rotate(origin: Geometry, centre: CGPoint, from: Double)
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
        // `.cursorUpdate` so entering the canvas asks for the cursor too, not
        // only moving inside it — the crop tool's cursor is position- and
        // modifier-dependent, and neither of those has to change for the
        // pointer to arrive somewhere new.
        let ta = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
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
            // The crop tool's view is locked to the whole turned photograph,
            // so a resize there is a **refit** and not `resize`'s
            // keep-the-centre — which is what the line above just did, and
            // which is wrong while the tool is up: half the picture would end
            // up outside the canvas the moment the window changed size.
            if renderer.editingCrop { renderer.fitRotatedPhoto() }
            host?.viewportChanged()
        }
        scheduleDraw()
    }

    private func local(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    // MARK: scroll / pinch

    override func scrollWheel(with e: NSEvent) {
        guard let renderer else { return }
        // Locked in the crop tool: the view is fitted to the whole photograph
        // and the user cannot move it (see `Renderer.fitRotatedPhoto`). The
        // wheel does nothing at all there rather than fighting the lock.
        guard host?.tool != .crop else { return }
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
        guard host?.tool != .crop else { return }   // locked, as above
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
            // Locked in the crop tool: the view is fitted to the whole
            // photograph and the user cannot move it.
            guard host.tool != .crop else { return }
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
            // No bail for a click outside the frame: outside is where the
            // rotate gesture lives, grey surround and turned corners
            // included.
            let g = host.geometry
            let size = host.sourceImageSize
            let v = renderer.viewport
            // ⌘-drag draws a line that should be horizontal, and the frame
            // straightens to it. Lightroom's and Capture One's gesture, the
            // only one that beats nudging a slider by eye.
            //
            // Measured in **edit space**, not in source space: "level" means
            // level on the screen the user is drawing on, and that is the
            // space the photograph is turned in. A line drawn there at λ
            // leaves the picture level at `θ + λ` — with the points put
            // through S first this would be `θ + (λ + θ)` and the straighten
            // would overshoot by twice the angle it started from.
            if e.modifierFlags.contains(.command) {
                let from = editPoint(atView: p, v)
                cropDrag = .straighten(from: from, origin: g)
                let s = g.sourcePoint(forEdit: from, pivot: host.cropPivot, imageSize: size)
                host.straightenPreview(StraightenLine(from: s, to: s))
                return
            }
            // ⌥ draws a new rectangle, level on screen and anywhere — inside
            // the current crop too. Lightroom's gesture, and the only way to
            // redraw a crop without first moving the old one out of the way.
            if e.modifierFlags.contains(.option) {
                cropDrag = .draw(from: editPoint(atView: p, v))
                return
            }
            let n = sourcePoint(atView: p, renderer, host)
            // A grab area that is a constant size on screen: 10 pt, converted
            // through the viewport so it is not enormous at 12 % zoom and
            // unhittable at 400 %.
            let tolerance = CanvasNSView.handleGrab / max(v.scale, 1e-6)
            if let handle = g.handle(at: n, in: size, tolerance: tolerance) {
                let c = g.centre
                cropDrag = .handle(handle, origin: g,
                                   grabOffset: CGSize(width: n.x - c.x, height: n.y - c.y))
            } else {
                let centre = viewPoint(ofSource: g.centre, g, host, v)
                // A rotation in flight: the view holds still until this one
                // ends (mouse-up), so the picture never rescales under the
                // hand that is turning it.
                renderer.beginRotation()
                cropDrag = .rotate(origin: g, centre: centre,
                                   from: CanvasNSView.bearing(from: centre, to: p))
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

    // MARK: edit space
    //
    // While the crop tool is up the canvas draws the photograph **turned**
    // about the pivot, so the crop frame is level on screen — Capture One's
    // tool, the one that lets you judge a straighten against a level frame.
    // Every position a crop gesture reads is therefore an edit-space point,
    // mapped to the source through `sourcePoint(forEdit:pivot:imageSize:)`.
    // Nothing else in the canvas changes: the finished view and the exported
    // file never see this mapping.

    /// View point → edit space, normalised to the W×H box the viewport spans.
    /// Deliberately **unclamped** — outside the box is a real place on the
    /// turned photograph, and what a point out there means is decided in
    /// source space, after the mapping.
    private func editPoint(atView p: CGPoint, _ v: ViewportState) -> CGPoint {
        let ip = v.imagePoint(atView: p)
        return CGPoint(x: ip.x / max(v.image.width, 1), y: ip.y / max(v.image.height, 1))
    }

    /// View point → source point, unclamped. What a *hit test* gets: clamping
    /// first would drag a pointer that is a long way outside the frame onto
    /// its edge, where it would read as a grip and start resizing instead of
    /// turning the photograph.
    private func sourcePoint(atView p: CGPoint, _ renderer: Renderer, _ host: CanvasHost) -> CGPoint {
        let e = editPoint(atView: p, renderer.viewport)
        return host.geometry.sourcePoint(forEdit: e, pivot: host.cropPivot, imageSize: host.sourceImageSize)
    }

    /// The same, clamped into the frame. For the drags that move or resize
    /// the crop: a drag that leaves the image still has a meaning (`Geometry`
    /// fits whatever comes out of it), and the clamp belongs in source space,
    /// where the frame's edges actually are — the edit box's edges are
    /// diagonal lines on the photograph.
    private func clampedSourcePoint(atView p: CGPoint, _ renderer: Renderer, _ host: CanvasHost) -> CGPoint {
        let s = sourcePoint(atView: p, renderer, host)
        return CGPoint(x: s.x.clamped(to: 0...1), y: s.y.clamped(to: 0...1))
    }

    /// Where a source point is on screen, through E — the frame's centre for
    /// a rotate drag. With the pivot on the crop's centre (the tool's normal
    /// state) this is simply the middle of the frame; after the crop has been
    /// moved it is wherever that same point of the photograph now sits.
    private func viewPoint(ofSource s: CGPoint, _ g: Geometry, _ host: CanvasHost,
                           _ v: ViewportState) -> CGPoint {
        let e = g.editPoint(forSource: s, pivot: host.cropPivot, imageSize: host.sourceImageSize)
        return v.viewPoint(atImage: CGPoint(x: e.x * v.image.width, y: e.y * v.image.height))
    }

    /// The pointer's bearing about a view point, in degrees, clockwise from
    /// east — y grows downward in this view, which is the convention every
    /// rotation in `Geometry` uses.
    static func bearing(from centre: CGPoint, to p: CGPoint) -> Double {
        atan2(p.y - centre.y, p.x - centre.x) * 180 / .pi
    }

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
            let size = host.sourceImageSize
            switch drag {
            case .handle(.body, let origin, let grab):
                let n = clampedSourcePoint(atView: p, renderer, host)
                let target = CGPoint(x: n.x - grab.width, y: n.y - grab.height)
                let delta = CGSize(width: target.x - origin.centre.x, height: target.y - origin.centre.y)
                host.geometryChanged(origin.moved(by: delta, in: size))
            case .handle(let handle, let origin, _):
                let n = clampedSourcePoint(atView: p, renderer, host)
                host.geometryChanged(origin.resized(handle: handle,
                                                    to: origin.unrotated(n, in: size), in: size))
            case .draw(let from):
                // Drawn in edit space, so it is level on screen *and* level in
                // the turned photograph — which is why the angle is kept. It
                // used to be zeroed here, back when the rectangle was drawn
                // axis-aligned to the frame instead; zeroing it now would
                // spin the picture under the rectangle the user just drew.
                let to = editPoint(atView: p, renderer.viewport)
                let w = abs(to.x - from.x), h = abs(to.y - from.y)
                guard w * size.width > Geometry.minSide, h * size.height > Geometry.minSide else { return }
                let centre = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                let s = host.geometry.sourcePoint(forEdit: centre, pivot: host.cropPivot, imageSize: size)
                // Same pixels, same shape: S is a rotation, and in both
                // spaces one unit of x is one width of the source.
                host.geometryChanged(host.geometry.redrawn(
                    as: CropRect(x: s.x - w / 2, y: s.y - h / 2, width: w, height: h),
                    in: size, anchor: anchorFor(from: from, to: to)))
            case .rotate(let origin, let centre, let from):
                // The picture follows the hand: a clockwise drag turns the
                // photograph clockwise, which is a *smaller* angle (positive
                // is clockwise here, and the photograph is drawn at −θ).
                // Recomputed from `origin` every event, like the other drags,
                // so a turn that hits ±45° and comes back does not drift.
                var delta = CanvasNSView.bearing(from: centre, to: p) - from
                while delta > 180 { delta -= 360 }
                while delta <= -180 { delta += 360 }
                host.geometryChanged(origin.straightened(to: origin.angle - delta, in: size))
            case .straighten(let from, _):
                // The preview is stored in source space, like every other
                // overlay line, and drawn back through E — so it sits under
                // the cursor, which is the live proof that S and E invert
                // each other. The angle is measured in edit space (mouseUp).
                let to = editPoint(atView: p, renderer.viewport)
                host.straightenPreview(StraightenLine(
                    from: host.geometry.sourcePoint(forEdit: from, pivot: host.cropPivot, imageSize: size),
                    to: host.geometry.sourcePoint(forEdit: to, pivot: host.cropPivot, imageSize: size)))
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
            // Both ends in edit space, which is where the line has to come
            // out level — so the angle *adds* to the one already there. Put
            // through S instead, the same sum would overshoot by θ: the drawn
            // line's slope in the photo is already `λ + θ`.
            let to = editPoint(atView: local(e), renderer.viewport)
            if let deg = Geometry.straightenAngle(from: from, to: to, in: host.sourceImageSize) {
                host.geometryChanged(origin.straightened(to: origin.angle + deg, in: host.sourceImageSize))
            }
        }
        cropDrag = nil
        // The end of a rotation is where the view refits — once, at the angle
        // the gesture ended on. Every other drag leaves it alone: the crop can
        // not leave the photograph and the photograph is fitted, so nothing a
        // move or a resize does can put the frame off screen.
        if host?.renderer.rotationHeld == true { host?.renderer.endRotation() }
        host?.straightenPreview(nil)
        scheduleDraw()
    }

    override func mouseMoved(with e: NSEvent) {
        guard let renderer, let host else { return }
        let p = local(e)
        // The readout samples the photograph, so in the crop tool it wants
        // the *source* point — the edit point put through S — and nil
        // outside the frame, because `Session.sample` indexes the texture
        // with it and 0…1 is the contract there.
        if host.tool == .crop {
            let n = sourcePoint(atView: p, renderer, host)
            host.hovered(normalised: (0...1).contains(n.x) && (0...1).contains(n.y) ? n : nil)
            cropCursor(at: p).set()
        } else {
            host.hovered(normalised: renderer.viewport.normalised(atView: p))
        }
    }

    override func mouseExited(with e: NSEvent) { host?.hovered(normalised: nil) }

    // MARK: cursor

    /// What the pointer means in the crop tool: on the frame it draws, off it
    /// it turns the photograph, and ⌥ draws a new rectangle anywhere.
    private func cropCursor(at p: CGPoint) -> NSCursor {
        guard let renderer, let host else { return .arrow }
        if NSEvent.modifierFlags.contains(.option) { return .crosshair }
        let n = sourcePoint(atView: p, renderer, host)
        let tolerance = CanvasNSView.handleGrab / max(renderer.viewport.scale, 1e-6)
        return host.geometry.handle(at: n, in: host.sourceImageSize, tolerance: tolerance) == nil
            ? CanvasNSView.rotateCursor
            : .crosshair
    }

    /// AppKit has no rotate cursor, so the SF Symbol is rendered into one.
    /// Built once, and the hot spot is the middle: a rotate cursor that
    /// points with its corner points at nothing.
    private static let rotateCursor: NSCursor = {
        guard let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                   accessibilityDescription: "Rotate")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) else { return .crosshair }
        let s = symbol.size
        let size = NSSize(width: s.width + 4, height: s.height + 4)
        let image = NSImage(size: size, flipped: false) { _ in
            let box = NSRect(x: 2, y: 2, width: s.width, height: s.height)
            // A white halo, so the glyph reads over a dark photograph and
            // over the grey surround alike.
            for dx in [-1.0, 1.0] as [CGFloat] {
                for dy in [-1.0, 1.0] as [CGFloat] {
                    CanvasNSView.tinted(symbol, .white)
                        .draw(in: box.offsetBy(dx: dx, dy: dy))
                }
            }
            CanvasNSView.tinted(symbol, .black).draw(in: box)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()

    /// A symbol drawn in one flat colour. Symbol images are templates, and
    /// drawing a template paints it in its own black — so the shape is drawn
    /// first and then filled through it (`sourceAtop`), which tints only the
    /// pixels the glyph actually covers.
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// The cursor is answered here as well as from `mouseMoved` because
    /// AppKit re-applies the cursor from the window's cursor rects every time
    /// they are invalidated, and SwiftUI invalidates them on every update.
    /// With the default implementation the rotate cursor would flick back to
    /// the rect's crosshair between moves.
    override func cursorUpdate(with event: NSEvent) {
        if host?.tool == .crop {
            cropCursor(at: local(event)).set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    /// ⌥ turns a drag into a draw, so the cursor has to follow the modifier
    /// on its own. Nothing else tells the view: `mouseMoved` is not sent for
    /// a bare modifier press, and AppKit's cursor rects only re-arm on
    /// movement too — so without this, holding ⌥ over the frame leaves the
    /// rotate cursor up until the mouse happens to twitch.
    override func flagsChanged(with event: NSEvent) {
        if host?.tool == .crop {
            // The last known pointer position: a flags change carries one,
            // but it is the position at the *previous* event when the mouse
            // itself has not moved, and the window's own is the live one.
            let p = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            cropCursor(at: p).set()
        } else {
            super.flagsChanged(with: event)
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        if let menu = host?.contextMenu() { NSMenu.popUpContextMenu(menu, with: e, for: self) }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { syncViewport() }

    func draw(in view: MTKView) { host?.renderer.draw(in: view) }

    override func resetCursorRects() {
        switch host?.tool {
        case .hand: addCursorRect(bounds, cursor: .openHand)
        // The crosshair stays as the *fallback* the rect machinery restores —
        // but it is not the answer: the crop tool's cursor depends on where
        // the pointer is, so `cursorUpdate(with:)` overrides this rect with
        // `cropCursor(at:)` on every pass. (Grips get their own look from
        // `CropOverlay`, which draws them.)
        case .crop: addCursorRect(bounds, cursor: .crosshair)
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
        case 6 where !e.modifierFlags.contains(.command) && host.tool != .crop:  // z
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
