//  CanvasArea.swift — the viewport and its gestures.
//
//  Capture One's model, deliberately: the image is fitted and centred, zoom
//  is about the cursor, pan exists only where the image overflows the
//  viewport, and the frame can never be dragged off-screen. The clamping
//  lives in `Renderer.samplingTransform`; this file only produces intent.
//
//  Gesture assignment follows the Mac convention rather than a web one:
//  two-finger scroll pans, pinch zooms, ⌘-scroll zooms, double-click toggles
//  fit ↔ 100%. Scroll is *not* bound to zoom, because on a trackpad that
//  makes every attempt to pan resize the image instead.

import SwiftUI

struct CanvasArea: View {
    @Environment(Session.self) private var session

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.canvasVoid
                if let renderer = session.renderer {
                    MetalCanvasView(renderer: renderer,
                                    uniforms: uniforms,
                                    zoom: session.zoom,
                                    pan: session.pan,
                                    fitToWindow: session.fitToWindow)
                        .onScroll { delta, zooming in
                            handleScroll(delta, zooming: zooming, viewport: geo.size)
                        }
                        .gesture(panGesture(viewport: geo.size))
                        .gesture(magnify(viewport: geo.size))
                        .onTapGesture(count: 2) { session.toggleFitOr100(viewport: geo.size) }
                } else {
                    Label("No Metal device", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if session.decoded == nil { EmptyState() }
            }
            .clipped()
            .task(id: session.selection) { await decodeCurrent() }
            .onChange(of: geo.size) { _, size in session.viewport = size }
            .onAppear { session.viewport = geo.size }
        }
    }

    private var uniforms: CanvasUniforms {
        var u = CanvasUniforms()
        let a = session.adjustments
        u.layer2Enabled = session.adjustmentsBypassed ? 0 : 1
        u.exposure   = Float(a.exposure)
        u.highlights = Float(a.highlights)
        u.shadows    = Float(a.shadows)
        u.blackPoint = Float(a.blackPoint)
        u.whitePoint = Float(a.whitePoint)
        return u
    }

    // MARK: - gestures

    private func handleScroll(_ delta: CGSize, zooming: Bool, viewport: CGSize) {
        if zooming {
            session.zoomBy(1 + delta.height * 0.004, viewport: viewport)
        } else {
            session.panBy(dx: -delta.width, dy: -delta.height, viewport: viewport)
        }
    }

    private func panGesture(viewport: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                session.panBy(dx: -g.translation.width + session.dragConsumed.width,
                              dy: -g.translation.height + session.dragConsumed.height,
                              viewport: viewport)
                session.dragConsumed = g.translation
            }
            .onEnded { _ in session.dragConsumed = .zero }
    }

    private func magnify(viewport: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { g in
                session.setZoom(session.zoomAtGestureStart * g.magnification, viewport: viewport)
            }
            .onEnded { _ in session.zoomAtGestureStart = session.zoom }
    }

    // MARK: - decode

    private func decodeCurrent() async {
        guard let frame = session.current, let renderer = session.renderer else { return }
        session.busy = .init(label: "Decoding", determinate: nil)
        session.lastError = nil
        do {
            let url = frame.url
            let decoded = try await Task.detached(priority: .userInitiated) {
                try ImageDecoder.decode(url)
            }.value
            // Live tier: 1600 px longest edge, matching the service's own
            // `TIERS["live"]`, so the canvas and a future `reprint` agree on
            // resolution without a second scaling decision.
            renderer.load(decoded, maxEdge: 1600)
            session.decoded = decoded
            session.fidelity = .input
            session.fitToWindow = true
            session.pan = .zero
            session.busy = nil
            session.status = "\(decoded.decoder.label) · "
                + String(format: "%.1f MP", decoded.megapixels)
        } catch {
            session.busy = nil
            session.decoded = nil
            renderer.clear()
            session.lastError = error.localizedDescription
        }
    }
}

private struct EmptyState: View {
    @Environment(Session.self) private var session

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "film")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(session.folder == nil ? "Open a folder" : "Select a frame")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - scroll events

/// SwiftUI has no scroll-wheel gesture on macOS. This is the minimum AppKit
/// reach-through: a local monitor, scoped to the view's lifetime, reporting
/// the delta and whether a zoom modifier is held.
extension View {
    func onScroll(_ handler: @escaping (CGSize, Bool) -> Void) -> some View {
        modifier(ScrollMonitor(handler: handler))
    }
}

private struct ScrollMonitor: ViewModifier {
    let handler: (CGSize, Bool) -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    let zooming = event.modifierFlags.contains(.command)
                        || event.modifierFlags.contains(.option)
                    handler(CGSize(width: event.scrollingDeltaX,
                                   height: event.scrollingDeltaY), zooming)
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
