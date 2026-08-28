//  MetalCanvasView.swift — NSViewRepresentable around MTKView.
//
//  Updates, never re-makes (UI-GUIDELINE §11). `updateNSView` pushes state
//  onto the renderer and sets `needsDisplay`; it does not rebuild the view,
//  which would drop the resident texture on every state change.

import SwiftUI
import MetalKit

struct MetalCanvasView: NSViewRepresentable {
    let renderer: Renderer
    var uniforms: CanvasUniforms
    var zoom: Double
    var pan: CGPoint
    var fitToWindow: Bool

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.isPaused = true                       // draw on demand
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = false
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColor(red: 0.055, green: 0.055, blue: 0.055, alpha: 1)

        if let layer = view.layer as? CAMetalLayer {
            // ColorSync performs the display transform from here. The shader
            // must not also convert — UI-GUIDELINE §4 rule 3.
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
            layer.wantsExtendedDynamicRangeContent = false
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        renderer.uniforms = uniforms
        renderer.zoom = zoom
        renderer.pan = pan
        renderer.fitToWindow = fitToWindow
        view.needsDisplay = true
    }
}
