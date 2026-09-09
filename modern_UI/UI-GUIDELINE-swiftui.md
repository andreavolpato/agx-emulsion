# UI implementation guideline — Spektrafilm Desktop

| | |
|---|---|
| **Status** | Binding. Read before writing any UI code. |
| **Companion to** | `SPEC-spektrafilm-desktop-frontend.md` (what to build) — this doc is *how*. |
| **Target** | macOS 15+, Apple Silicon only, Swift 6, SwiftUI + AppKit interop |
| **Date** | 2026-08-28 |

---

## 0. Read this first

**This is a native macOS application. It ships as a signed `.app` bundle.**

The frontend spec describes panels, canvases and sliders. Those words also exist in web
development, and an agent reading that spec has been observed to start writing HTML. That
is wrong and the output is unusable.

### Forbidden, without exception

- HTML, CSS, JavaScript, TypeScript
- React, Vue, Svelte, or any web framework
- Electron, Tauri, `WKWebView`, or any embedded browser
- Canvas-in-a-webview, WebGL, WebGPU
- Storyboards and XIBs
- Any cross-platform UI toolkit (Qt, GTK, Flutter, Compose)

If a proposed implementation involves a DOM, it is wrong. If it involves a `<div>`, stop
and re-read this section.

### Why, concretely

1. The canvas is a Metal texture pipeline running a 3D LUT lookup on a large image. It
   must own its own drawable and its colour space. A browser cannot be given a
   `CAMetalLayer` with `displayP3`.
2. Colour management is the entire point of this application. `API-SPEC §4` records a
   double-encoding bug that cost a session to find. A web view adds another uncontrolled
   colour transform between the pixels and the screen.
3. Vision framework mask generation (`VNGenerateForegroundInstanceMaskRequest`) has no web
   equivalent.
4. The app spawns and manages a long-lived Python subprocess over stdio. That is a
   `Process` with pipes, not a fetch call.

### The one legitimate use of a browser engine

None in this app.

---

## 1. Project shape

```
Spektrafilm.xcodeproj
  Spektrafilm/                     app target
    SpektrafilmApp.swift           @main, Scene
    Windows/
      EditorWindow.swift           the three-pane + filmstrip layout
    Canvas/
      MetalCanvasView.swift        NSViewRepresentable wrapping MTKView
      Renderer.swift               MTKViewDelegate, command encoding
      Shaders.metal                LUT sample, layer-2 adjustments, masks 
      TextureStore.swift           negative / LUT / ROI texture lifetimes
    Panels/
      FilmPanel.swift              left column — layer 1
      InspectorPanel.swift         right column — read-only scopes
      AdjustmentsGroup.swift       layer 2
      Filmstrip.swift              bottom
    Controls/
      ScrubSlider.swift            the custom slider (§5)
      CurveView.swift              read-only characteristic curves
      SplitContainer.swift         resizable columns (§3)
    Service/
      ServiceClient.swift          actor, Process + JSON-RPC
      Methods.swift                Codable request/response types
    Model/
      Session.swift                @Observable app state
      Sidecar.swift                Codable, per-image params
    Masks/
      MaskEngine.swift             geometry → texture
      VisionMasks.swift            Vision request wrappers
  Resources/
    python/                        embedded interpreter + engine (§9)
```

No package manager needed for the app itself. Everything used is in the SDK.

**Swift 6 language mode, strict concurrency on.** Turning it off later is much harder than
starting with it.

---

## 2. App and window

```swift
@main
struct SpektrafilmApp: App {
    @State private var session = Session()

    var body: some Scene {
        Window("Spektrafilm", id: "editor") {
            EditorWindow()
                .environment(session)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands { EditorCommands() }
    }
}
```

`Window`, not `WindowGroup` — one session at a time, matching `API-SPEC §7.2`'s scope. A
second window would imply a second service session, which does not exist.

**Force dark.** Every serious image editor does, because a light UI surrounding an image
biases perception of its tonality. This is not a preference to expose.

Use `@Observable` (Swift Observation), not `ObservableObject`. Fine-grained invalidation
matters here: a slider drag must not invalidate the filmstrip.

---

## 3. Resizable columns — build it, do not fight the framework

The layout is: left column | canvas | right column, with a filmstrip pinned below. Both
columns resize by dragging, collapse to zero, and remember their widths.

### Do not use `NavigationSplitView`

It models hierarchical navigation (sidebar → content → detail) and carries behaviour this
app does not want: sidebar toggle animations, automatic collapse at narrow widths,
`.toolbar` placement assumptions. Fighting it costs more than replacing it.

### Do not use `HSplitView`

It works, but gives no programmatic control over divider position, no clean way to
collapse to zero, and no way to persist positions without reaching into the backing
`NSSplitView`.

### Build `SplitContainer`

Roughly sixty lines, fully predictable.

```swift
struct SplitContainer<Left: View, Center: View, Right: View>: View {
    @AppStorage("leftWidth")  private var leftWidth:  Double = 312
    @AppStorage("rightWidth") private var rightWidth: Double = 260
    @Binding var leftCollapsed: Bool
    @Binding var rightCollapsed: Bool

    let left: Left, center: Center, right: Right

    private let leftRange  = 240.0...460.0
    private let rightRange = 200.0...400.0

    var body: some View {
        HStack(spacing: 0) {
            if !leftCollapsed {
                left.frame(width: leftWidth)
                Divider.draggable(width: $leftWidth, range: leftRange, edge: .leading)
            }
            center.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !rightCollapsed {
                Divider.draggable(width: $rightWidth, range: rightRange, edge: .trailing)
                right.frame(width: rightWidth)
            }
        }
    }
}
```

The draggable divider:

```swift
struct DraggableDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let edge: HorizontalEdge

    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 10)          // generous hit target
                    .contentShape(.rect)
                    .onHover { NSCursor.resizeLeftRight.set($0) }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                let base = startWidth ?? width
                                if startWidth == nil { startWidth = width }
                                let delta = edge == .leading
                                    ? g.translation.width
                                    : -g.translation.width
                                width = (base + delta).clamped(to: range)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}
```

### Rules that matter

- **1 pt visible divider, 10 pt hit target.** A 1 pt hit target is unusable and a 10 pt
  visible divider is ugly.
- **`minimumDistance: 0`** or the first few pixels of every drag are swallowed.
- **Capture the start width on drag begin.** Accumulating `translation` into `width` every
  frame drifts, because `translation` is measured from the gesture's origin, not the last
  event.
- **Clamp, never let the canvas reach zero.** The columns collapse; the canvas does not.
- **`@AppStorage` for persistence.** This is a personal tool; `UserDefaults` is the right
  amount of machinery.
- **Do not animate the drag.** Any implicit animation on `width` makes the divider lag the
  cursor. If `EditorWindow` has an ambient `.animation` modifier, scope it away from here.
- **`Tab` toggles both collapse flags.** Animate *that* — a 0.18 s `.easeOut` — because it
  is a discrete state change, not a continuous drag.

### Filmstrip height

Same pattern vertically, one divider, 96 pt default, range 72–200, collapsible.

---

## 4. Canvas

### Structure

```swift
struct MetalCanvasView: NSViewRepresentable {
    let renderer: Renderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.isPaused = true                    // draw on demand
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = false
        view.autoResizeDrawable = true

        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
            layer.wantsExtendedDynamicRangeContent = false
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        renderer.apply(state)
        view.needsDisplay = true
    }
}
```

### Non-negotiable colour rules

These come straight from `API-SPEC §4`'s recorded bug and are the easiest thing in this
project to get silently wrong.

1. **Never apply a gamma curve in the shader.** The engine's output has already passed
   `output_cctf_encoding`. Read `cctf_encoded` from `get_print_lut` and trust it.
2. **Never use an `_srgb` pixel format for already-encoded data.** `.bgra8Unorm_srgb`
   applies a decode on read and an encode on write. The data is P3-encoded already;
   `.rgba16Float` or `.rgba16Unorm` with the layer's colour space set is correct.
3. **Set the layer colour space, do not convert in the shader.** ColorSync handles the
   display transform. Converting primaries manually and *also* letting the layer convert
   is the same class of double-application as the gamma bug.
4. **Layer 2 adjustments operate on encoded values, deliberately.** They are adjustments
   to a scan, per frontend spec §3.1. Do not linearise first — that would make them
   physically-flavoured operations, which they are not, and would change their behaviour
   from what the reference apps do.

### Draw on demand, never on a display link

`isPaused = true` and `enableSetNeedsDisplay = true`. A continuously rendering `MTKView`
burns battery for an image that changes only when something is dragged. Set
`needsDisplay = true` on state change, on scroll, on gesture.

### Texture inventory

| texture | format | lifetime |
|---|---|---|
| live negative | `.rgba32Float` | per session |
| print LUT | `.type3D`, `.rgba16Float`, `filter: .linear` | per stock pair, cached |
| exposure LUT slices (G9) | 9 × `.type3D` in an argument buffer | per stock pair |
| ROI render | `.rgba16Float` | per zoom region |
| mask | `.r16Float` | per mask |

**Use hardware trilinear filtering for the LUT.** `MTLTextureType.type3D` with
`minFilter/magFilter = .linear` gives interpolation free in the texture unit. Do not write
an interpolation function; `G0` measured that 33³ with hardware filtering is not the error
floor, so a denser grid or a hand-written sampler buys nothing.

### Zoom and pan

Per frontend spec §5.0. Zoom and pan are a transform on the sampling coordinates, not a
re-render — free within the resident buffer.

- `MagnifyGesture` for pinch, `.onScrollWheel` / `NSEvent` monitor for trackpad scroll.
- Zoom about the cursor, not the centre. Compute the pre-zoom point under the cursor in
  image space and solve for the offset that keeps it there.
- Debounce ROI requests to gesture end. Never issue one mid-drag.
- Show the interpolated live tier immediately with the `soft` indicator; swap in the ROI
  when it lands.

---

## 5. Controls

### The scrub slider

The one component worth building carefully; it is used for every parameter in the app.

Requirements, all of which SwiftUI's `Slider` fails:

- Numeric field, editable, monospaced digits (`.monospacedDigit()`), tabular figures so
  the width does not jump while dragging.
- A visible zero tick at the auto-solve value. Print-side sliders show offset from the
  solve (frontend spec §5.2), so the zero must be legible.
- Double-click the track to reset to zero.
- `⌥` held during drag: ×0.25 sensitivity for fine adjustment.
- `⇧` held: snap to whole stops / units of 5.
- Drag anywhere on the track, not just the knob.
- Continuous value updates during drag, with a distinct "commit" event on release — the
  release is what fires `reprint`.

```swift
struct ScrubSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let zero: Double
    var onCommit: () -> Void = {}
    ...
}
```

Build it once, in `Controls/`, and use it everywhere. Do not let a second slider
implementation appear.

### Filter pack sliders

The only coloured controls in the app. Track gradient at ~15% saturation: yellow↔blue,
magenta↔green. Everything else is neutral.

### Read-only curves

`Canvas` (SwiftUI's, not a web canvas) with `Path`. Two plots per frontend spec §5.2 item
5: film characteristic curve with exposure histogram, paper curve with negative density
histogram. Histograms come from `MPSImageHistogram` on the GPU, not a CPU loop.

**No control points, no dragging, no editing.** These are scopes. The editable curve is
in Layer 2 and is a different component.

### System components — use them

`Picker`, `Toggle`, `DisclosureGroup`, `LazyVGrid`, `.contextMenu`, `.keyboardShortcut`,
SF Symbols. Do not draw an icon by hand; `camera`, `film.stack`, `plusminus.circle`,
`scanner`, `square.and.arrow.down`, `circle.dotted`, `lamp.desk` cover the panel.

---

## 6. Filmstrip

```swift
ScrollViewReader { proxy in
    ScrollView(.horizontal) {
        LazyHStack(spacing: 8) {
            ForEach(session.frames) { frame in
                FilmstripCell(frame: frame)
                    .id(frame.id)
            }
        }
        .padding(.horizontal, 12)
    }
    .onChange(of: session.selection) { _, new in
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
    }
}
```

- `LazyHStack` so a 500-image folder does not build 500 views.
- Thumbnails via `QuickLookThumbnailing` or `CGImageSourceCreateThumbnailAtIndex` — the
  embedded JPEG, never the engine. Cache in an `NSCache` keyed by file hash.
- Thumbnail generation off the main actor; publish results back on it.
- Three-state badge (frontend spec §5.1): nothing / filled dot / hollow dot, bottom-right.
  Not colour, not a banner, not desaturation.

---

## 7. Service client

```swift
actor ServiceClient {
    private let process = Process()
    private let stdin: FileHandle
    private let stdout: FileHandle
    private var nextID = 1

    func call<R: Decodable>(_ method: String, _ params: some Encodable) async throws -> R
}
```

- **An `actor`.** The transport is single-flight by design (`API-SPEC §10.5`: numba's
  `workqueue` threading layer is not threadsafe). The actor makes that a compile-time
  property instead of a convention.
- **One long-lived process per app launch.** `API-SPEC §10.5` measured a 1.76 s import and
  a one-time JIT cost, with no drift or leak over repeated renders. Spawning per request
  pays both every time.
- **Large buffers go through the filesystem, never JSON.** The service writes `.npy` to the
  workspace and returns a path; the client `mmap`s it. Serialising a 45 MP array through
  JSON-RPC is not an option.
- **Handle the process dying.** It will, during development. Detect termination, surface it
  plainly, offer a restart. Do not silently hang on a read.
- Requests that can be superseded (a slider release while an earlier render is in flight)
  are cancelled client-side by discarding the result, since `cancel` cannot arrive
  mid-render on stdio.

---

## 8. Concurrency

- `Session` and all view state are `@MainActor`.
- Rendering, Vision requests, thumbnail generation, and service calls are not.
- `Renderer` is a class owned by the main actor but its command encoding runs on Metal's
  own queue. Do not make it an actor; `MTKViewDelegate` callbacks are already serialised.
- Never `await` inside a gesture handler's synchronous path. Capture the value, fire a
  `Task`, let the UI update from the current state.

---

## 9. Bundling as a `.app`

This is the part with real surprises. Plan for it early; retrofitting is painful.

### Embedding Python

The engine is Python with numba and MLX. It must ship inside the bundle.

- Use a **standalone CPython** build (`python-build-standalone`), not the system Python
  and not Homebrew's. System Python is not guaranteed present and Homebrew paths do not
  exist on other machines.
- Place at `Contents/Resources/python/`. Install the engine and its dependencies into that
  interpreter's `site-packages` at build time via a build phase, not at runtime.
- Launch with `PYTHONHOME` and `PYTHONPATH` set to the bundled paths, and `PYTHONNOUSERSITE=1`
  so a user site-packages directory cannot shadow the bundled one.

### Code signing

- **Every** `.so` and `.dylib` under `Resources/python` must be signed individually. There
  are hundreds (numpy, numba, llvmlite, MLX). A build phase that walks the tree and signs
  each is required; signing only the bundle will fail at launch.
- **numba JIT needs an entitlement.** Hardened runtime blocks writable-executable memory,
  which is exactly what a JIT does. Add
  `com.apple.security.cs.allow-jit`, and if llvmlite still fails,
  `com.apple.security.cs.allow-unsigned-executable-memory`. Symptom without it: the process
  dies on first render with no useful message.
- **Disable the App Sandbox.** This is a personal tool that spawns a subprocess and reads
  arbitrary folders. The sandbox buys nothing here and costs a week.
- Notarisation is only needed for distribution to other machines. For personal use, a
  Development-signed build is enough.

### Metal shaders

Compiled at build time into `default.metallib` by Xcode automatically when `.metal` files
are in the target. Do not compile from source at runtime — it adds a startup cost and a
failure mode for no benefit.

### Caches

`~/Library/Caches/<bundle-id>/` per frontend spec §7. Do not write caches inside the
bundle; it is read-only once signed.

---

## 10. Build order for the UI

Matching frontend spec §8, but scoped to what is drawn:

1. `SplitContainer` with three coloured rectangles. Verify dragging, collapsing, and
   persistence before anything real goes inside.
2. Filmstrip with real thumbnails from a real folder. No engine involved.
3. `MetalCanvasView` displaying a static TIFF loaded from disk, correct P3, correct
   absence of double gamma. **Verify with a known test image before proceeding** — every
   colour bug found later is harder to find.
4. `ServiceClient` and the `open` → `reprint` → `export` loop, driven by system `Slider`s.
5. Replace with `ScrubSlider`. Then curves. Then Layer 2.

Step 3 is the checkpoint. If the canvas shows a slightly washed-out image, that is the
double-encoding bug from `API-SPEC §4`, not a preference — stop and fix it there.

---

## 11. Things that will be tempting and are wrong

| tempting | why not |
|---|---|
| A web view for the curve plot because a JS charting library exists | See §0. `Canvas` + `Path` is fifty lines. |
| `Image` + `.resizable()` for the canvas | No colour space control, no LUT, no zoom performance. |
| A generic "parameter" model driving a generated form | The panel has eleven controls with different behaviours. A generated form makes all of them mediocre. |
| Storing rasterised masks in the sidecar | Store stroke geometry. It is smaller and resolution-independent (frontend spec §7). |
| Rebuilding the canvas view on state change | `NSViewRepresentable` should update, never re-make. Set `needsDisplay`. |
| Adding a second window for the grid view | One session, one service. Make it a mode in the same window. |
| Animating slider values for smoothness | Adds latency to the one interaction that must feel instant. |
