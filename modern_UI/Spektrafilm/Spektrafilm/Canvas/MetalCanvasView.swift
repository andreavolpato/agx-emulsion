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

@MainActor
protocol CanvasHost: AnyObject {
    var renderer: Renderer { get }
    var tool: CanvasTool { get }
    var pickerActive: Bool { get }
    func viewportChanged()
    func picked(normalised: CGPoint)
    func cropDragged(rect: CropRect)
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
    private var cropStart: CGPoint?
    private var cropOrigin = CropRect.full
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
            if let n = renderer.viewport.normalised(atView: p) {
                cropStart = n
                cropOrigin = renderer.crop
            }
        default:
            dragStart = p
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let renderer, let host else { return }
        let p = local(e)
        if let cropStart, host.tool == .crop {
            let n = renderer.viewport.normalised(atView: p) ?? CGPoint(x: p.x.clamped(to: 0...1), y: p.y.clamped(to: 0...1))
            let x0 = min(cropStart.x, n.x), y0 = min(cropStart.y, n.y)
            let w = abs(n.x - cropStart.x), h = abs(n.y - cropStart.y)
            if w > 0.01 && h > 0.01 {
                host.cropDragged(rect: CropRect(x: x0, y: y0, width: w, height: h))
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

    override func mouseUp(with e: NSEvent) {
        dragStart = nil
        cropStart = nil
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
        case 6 where !e.modifierFlags.contains(.command):                // z
            renderer.viewport.toggleHundred(about: CGPoint(x: bounds.midX, y: bounds.midY))
            host.viewportChanged(); scheduleDraw()
        default: super.keyDown(with: e)
        }
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
