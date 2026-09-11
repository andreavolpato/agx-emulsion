# Filmify — the SwiftUI frontend

> **Read §1, §3, §4 and §7 with this one correction.** This document was
> written 2026-09-08, when the app talked to a Python render service over
> stdio. RFC-014 (2026-09-10) deleted that service: the C++ engine is compiled
> into this target and reached through a hand-written C ABI, with no
> subprocess, no `.venv` and no Python at run time. **Wherever this document
> says "the service", read "the engine"; where it says `src/`, read
> `engine/`.** The layout geometry, the buffer system, the white-balance
> redesign and the defect table are all still accurate. The current map is
> `../../ARCHITECTURE.md` §0 and `../../README.md`.

| | |
|---|---|
| **What this is** | The native macOS app: the drawing in `modern_UI/reference_layout/` built to the pixel, rendering through the C++ engine compiled into it. |
| **State** | Builds, runs, renders real RAWs end to end **in the actual app** (`design/snapshots/live-window.png`). 139 Swift tests pass. Layout measured within 2 pt of the drawing at 1920×1080; verified at 1512×982 and 3360×1418. |
| **Governed by** | `../UI-GUIDELINE-swiftui.md` (how), `../../API-SPEC-callable-render-service.md` (the method surface). |
| **Layout of record** | `../frontend_architecture.md` — geometry, tokens, view tree, data path. |
| **Open work** | `../../HANDOFF-OPEN-PATH.md`, `../../HANDOFF-DISTRIBUTION.md` |
| **Date** | 2026-09-08 · annotated 2026-09-11 |

```
open Spektrafilm.xcodeproj                      # or:
xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm -derivedDataPath build/DerivedData build
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmFrontend -derivedDataPath build/DerivedData test   # the non-rendering subset, ~2 s
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests -derivedDataPath build/DerivedData test      # 139 tests, includes the render
Tools/snapshot.sh [image.NEF]                  # layout captures at three sizes (offscreen)
Tools/capture-live.sh [image.NEF]              # the REAL window, through the window server
Tools/compare-layout.py ../design/snapshots/window-16x9.png
SPEKTRAFILM_CANVAS_LOG=1 …                     # one line per draw, and why a render was dropped
```

**Two test schemes.** `SpektrafilmFrontend` runs the non-rendering subset — UI,
layout and behaviour — finishing in about two seconds and generating no pixels.
`SpektrafilmTests` is the full 139, including the classes that open a real
negative and render it. Run the full one when the change touches
`Service/Methods.swift`, `Model/Params.swift`'s wire names, or anything in
`engine/`: a frontend edit can break those silently, and the schema parity
harness is what catches a renamed field.

The app finds the engine's data in its own bundle, at `Resources/engine/`
(`EngineClient.defaultResources()`). The environment override is
`SPEKTRAFILM_ENGINE_RESOURCES`, and a checkout walk-up survives only as a
developer convenience for a build run out of the tree. `engine/build.sh bundle`
is what puts the resources there — a pre-build phase fails the build when they
are missing.

---

## 1. Layout — how the drawing became numbers

`sample_frontend.svg` is a 3840×2160 canvas: a 1920×1080 window at 2×. Every
metric in `Theme/Theme.swift` is the SVG value ÷ 2, with the SVG line quoted
beside it. The four cards:

| card | SVG rect | points |
|---|---|---|
| left panel | 17.9, 14.1, 656.9 × 2131.8 | x 9, y 7, **328** wide, full height |
| top bar | 690.5, 15.5, 2547.9 × 82.7 | x 345, **41** tall |
| filmstrip | 690.5, 1895.3, 2547.9 × 250.6 | **125** tall |
| right panel | 3250.1, 15.5, 572.3 × 2131.8 | **286** wide |

Corner radius 15, gutter 6, ground `#5f5f5f`, card `#2c2d2b`, wells are the
ground colour punched through the card, text `#faf8f4`, one accent
(`#ee8a2b`) on the active curve tab. Type: 12 pt semibold for titles and list
items (cap height 8.45 pt measured from the glyph paths), 11 pt labels,
10.5 pt monospaced-digit values.

Two deliberate departures from the drawing. The gutter is **6**, not 8 — four
gutters of ground between the cards is a lot of screen for nothing. And the
left panel's header starts **70 pt in**, so the window's traffic lights can
share that row the way they share Xcode's sidebar header; every other card
keeps the drawing's 12 pt. `Tools/compare-layout.py` applies both offsets, so
it still checks the drawing's geometry rather than the deviations.

Side panels are fixed width; the canvas takes whatever the window gives. A
collapsed card leaves the `HStack`/`VStack`, so the canvas grows into its
place, and the pill tab on that canvas edge brings it back. `⌘\` folds both
side panels.

**The test for this** is `Tools/compare-layout.py`: it finds the card-coloured
regions in a capture and diffs their rectangles against the SVG. Run it after
any change to `Theme.Metric` or `EditorWindow`.

---

## 2. What is on screen, and what it talks to

```
Windows/EditorWindow      the four cards; CanvasArea with the collapse tabs
Windows/TopBar            select · hand · crop  …  zoom-in · [100 %] · zoom-out · fit · fullscreen
Panels/LeftPanel          import/export/menu, then the Layer 1 sections
  Sections/FilmProfile    film list with covers; selected = white frame; cine badge
  Sections/PrintProfile   papers grouped Still/Cine; · marks the film's declared paper
  Sections/Camera         Format (film_format_mm) · Vignetting (client) · Exp. Comp. · white balance
  Sections/Features       Grain · Halation (shoot layer) · Glare (print layer)
  Sections/Enlarger       Brightness (stops) · Yellow · Magenta — offsets from the solve
Panels/RightPanel         adjustments tab, bypass switch, then the Layer 2 sections
  Sections/RightSections  Histogram · White Balance · Exposure · Curve · Color Balance
Panels/Filmstrip          thumbnails, selection frame, three-state badge, chevrons
Canvas/MetalCanvasView    MTKView + gestures     Canvas/Renderer   Metal state, Layer 2, histogram
Model/Session             all state              Service/RenderScheduler   coalesced service calls
```

### Two layers, kept apart

- **Layer 1** (left panel) is the engine: every control maps to one
  `params_delta` field in `Model/Params.swift`, which mirrors
  `service/schema.py` and knows each field's layer. A shoot-layer change
  re-runs the film side (`preview_render layer=shoot`, ~0.6 s at the live
  tier); a print-layer change reprints from the cached negative (~200 ms).
- **Layer 2** (right panel, plus Vignetting) is `Model/Adjustments.swift`,
  applied in the `layer2` compute kernel in `Shaders.metal` in under a
  millisecond. Nothing in it reaches the service. The bypass switch (dotted
  circle in the right header, `⇧⌘B`) shows the pure simulation.

Two things on the left are *not* engine parameters and say so in their
comments: **Vignetting** (the engine has none; it is the vignette stage of
Layer 2, placed where a photographer looks for it) and the **white balance
block**, which is a decode setting (§4).

### Renamed from the drawing, with reasons

| drawing | built | why |
|---|---|---|
| Enlarger: Cyan / Magenta | Brightness / Yellow / Magenta | a dichroic head has Y and M; the engine has `y_filter_shift`, `m_filter_shift` and no cyan. Brightness (print exposure, in stops, brighter positive) is the enlarger's main control and was missing. |
| Color Temp / Tint "As Shot ☐" | preset pill + eyedropper + two gradient sliders | §4 |
| Curve tabs 亮度/红色/… | RGB · Luma · Red · Green · Blue | the rest of the UI is English |
| Features: hollow squares | hollow when off, filled when on | a state, not a decoration |

---

## 3. The data path

```
select(frame)
  ├─ Core Image decode (CIRAWFilter, boost 0, no gamut map, WB from the sidecar)
  │    ├─ preview texture, Display P3, 1600 px   → canvas immediately, "preview" badge
  │    └─ half-float linear ProPhoto TIFF        → ~/Library/Caches/com.hanze.spektrafilm/linear/<key>-<wb>.tif
  ├─ service.open(tiff, full params)             → live-tier negative (film side)
  ├─ service.solve(exposure)                     → the auto-exposure baseline (Exp. Comp. sublabel)
  └─ service.reprint(output: rgba16)             → raw 16-bit RGBA → texture → canvas, badge clears

zoom ≥ 100 % / ≥ 200 %
  └─ service.reprint(tier: preview|full)         → a bigger texture for the same frame, swapped in when it lands
```

Opening a *folder* or several files stops at the Browse grid instead: no
decode, no TIFF, no service call until a frame is chosen. One file is a handoff
and goes straight to Print. The cache is bounded at 4 GB LRU
(`Import/LinearCache.swift`); the TIFF is written only after a decode has
settled, never by a superseded white-balance value.

The service detects the half-float TIFF as linear ProPhoto (verified:
`detected_input.input_color_space == "ProPhoto RGB"`, `input_cctf_decoding ==
false`, asserted by `ServiceIntegrationTests`). RAW decode is therefore
Apple's, not LibRaw's; the sidecar records `decoder: coreimage`.

**Colour rule, stated once.** Textures hold Display P3 *encoded* values (the
engine's `output_cctf_encoding`; the decoder preview is rendered into P3). The
`CAMetalLayer` colour space is Display P3; the pixel format is `rgba16Unorm`,
never `_srgb`; the shader applies no transfer curve. A washed-out canvas means
a second encode crept in — fix it there, not with a slider.

**Orientation.** Row 0 of every texture is the top of the image. The decoder
preview is rendered with a vertical flip because Core Image's origin is
bottom-left; the service's `rgba16` dump is numpy row-major, top first; the
canvas view is `isFlipped`, so mouse points and shader points share the
top-left origin. `RendererTests.testOffscreenRenderOrientation` and
`testDecoderPreviewOrientation` fail the moment any of this flips.

### The buffer system (why it feels snappy)

`Canvas/TextureStore.swift`:

| what | source | kept |
|---|---|---|
| source preview | Core Image decode | last 8 frames |
| print (live tier) | `reprint` rgba16 | last 8 frames |
| detail (preview/full) | `reprint` at the zoom's tier | one frame — a full-res texture is 360 MB |
| adjusted | Layer 2 kernel output | one, re-run on edit |
| curve table | CPU, 256×5 r32Float | one |

- Switching frames shows the frame's last print instantly (or its decode
  preview), flagged **preview** until the service catches up.
- The two neighbouring frames are decoded and their linear TIFFs written in
  the background (`prefetchNeighbours`), so their `open` skips the RAW decode.
- `Service/RenderScheduler.swift` keeps *sent* vs *wanted* params and one
  loop: debounce (40 ms print / 220 ms shoot), send one delta for the whole
  difference, apply the result only if the generation still matches. A slider
  drag produces a handful of reprints, never one per tick, and a stale reply
  can never overwrite a newer frame.
- Layer 2 is a compute pass on the resident texture: no service, no debounce.
- Zoom and pan are a sampling transform (`ViewportState`), free. At ≥100 % the
  sampler is nearest so grain is grain, not a smear.

### Keyboard and mouse

| | |
|---|---|
| scroll / pinch / ⌘-scroll | pan / zoom about the cursor |
| double-click, `Z` | fit ↔ 100 % |
| `⌘+` `⌘−` `⌘0` `⌘1` | zoom steps, fit, 100 % |
| Space (hold) | show the decode — labelled `original · decode` on the canvas |
| ← → , `⌘[` `⌘]` | previous / next frame (the canvas claims first responder on window entry) |
| `V` `H` `C` | select / hand / crop tool |
| `⌘C` `⌘V` | copy / paste settings (film, print, Layer 2 — offsets only) |
| `⌘Z` | undo |
| `⌘\` | fold both side panels |
| `⇧⌘B` | bypass Layer 2 |
| `⌥⌘R` | restart the render service |
| `⌘O` `⌘E` | open, export |

---

## 4. White balance at decode (the redesign)

The drawing's two rows ("Color Temp. / As Shot ☐") became one block:

```
White Bal.   [ As Shot ⌃⌄ ]  ✎
Color Temp.  ──────●──────  6210 K     blue → amber track
Color Tint   ──────●──────  +17        green → magenta track
```

Presets (As Shot · Daylight · Cloudy · Shade · Tungsten · Fluorescent) set the
sliders; dragging a slider flips the pill to Custom; the eyedropper arms a
neutral pick on the canvas (`CIRAWFilter.neutralLocation`). The zero tick on
each track is the camera's as-shot value. A change re-decodes and reopens
(≈350 ms debounce, then the film side), because white balance is a lens filter,
not a print control. Flat files dim the block with a one-line reason.

---

## 5. Export

`Export/Exporter.swift`, `⌘E`, into `<source dir>/_prints/<name>_<film>_<paper>.<ext>`:

| route | what |
|---|---|
| JPEG | Display P3, q 0.95, Layer 2 baked, cropped |
| PNG 8-bit | same, lossless |
| TIFF 16-bit | same, 16-bit; headroom is only the scan margin |
| **DI package** | `<name>_DI.tif` (16-bit: the negative's CMY density normalised 0…1 by the print LUT's own axes) + `<name>_<paper>.cube` (33³, domain 0…1, red fastest) + `<name>_print.tif` check image |

The DI route is the DI-suite workflow: grade the flat negative while viewing
it through the print LUT, bake at delivery. What the LUT carries is the print
stock's colour response only — the print+scan chain is pointwise; grain,
halation and glare are spatial and stay out of it (HANDOFF-PRINT-LUT §2). In
**Photoshop**: open the DI TIFF, add *Layer › New Adjustment Layer › Color
Lookup*, load the `.cube`, grade underneath it in 16-bit. **Capture One**
cannot load `.cube` (verified 2026-09-08); convert to ICC with
`ociobakelut --format icc` and load it under *Base Characteristics › ICC
Profile › Other*. The `.cube` is deliberately plain (no `DOMAIN_MIN/MAX`, no
1D shaper) because Photoshop's support for either is unverified.

Finished routes go: service `export` at full resolution → raw rgba16 → Layer 2
in Metal at full size → crop → ImageIO with a Display P3 tag.

---

## 6. Service changes made for this client (all additive)

In `src/spektrafilm/service/service.py`, marked `[client-added]`:

- `output: "rgba16"` on `reprint`, `preview_render`, `preview_stock_lut`,
  `export`: writes uint16 RGBA (top row first) and returns `raw_path`,
  `width`, `height`. The client deletes the file after upload.
- Output filenames carry a per-process serial; nothing is overwritten.
- `export_di {session_id, out_dir, base_name}` → `{di_path, cube_path,
  print_preview_path, warning?}`.

Tests: `tests/test_service.py::test_rgba16_output_is_raw_top_row_first`,
`::test_export_di_writes_density_tiff_and_cube`. The smoke image the suite
needs is generated by `Tools/make-smoke.py` into `tests/Test_image/`.

---

## 7. Tests — what each one protects

| file | protects |
|---|---|
| `ViewportStateTests` | fit, zoom-about-cursor, the pan clamp, 100 % = one device pixel |
| `CurveMathTests` | monotone spline (no overshoot), point insert/move/remove rules, table layout |
| `ParamsTests` | wire names match `schema.py`, layer routing, stops → `print_exposure`, sidecar round-trip |
| `FrontendPolicyTests` | the tier the zoom asks for, sidecar names that cannot collide, LRU eviction order |
| `RendererTests` | Layer 2 passthrough / bypass / exposure / curves on a 4×2 card; **canvas orientation**; ground outside the image; decoder orientation through Core Image |
| `LayoutTests` | tokens equal SVG ÷ 2; the canvas keeps ≥ 500 pt at all three sizes |
| `ServiceIntegrationTests` | the real Python service over stdio: open, reprint (rgba16), refusal of shoot deltas on reprint, preview_render, export_di. **Skipped by the `SpektrafilmFrontend` scheme** — it is the only class that renders |
| `CanvasViewTests` | drawable pixel format, the view builds and draws, a redraw reaches the delegate, the zoom readout follows the image |
| `Tools/compare-layout.py` | card geometry of a capture against the drawing |
| `Tools/capture-live.sh` | the only check that the canvas actually puts pixels on screen |

The test bundle compiles the app's sources directly (no test host): hosting
tests in the app crashed SwiftUI's environment root on macOS 26.

### 7.1 What running the app found that none of this caught

Four defects, all in the ten lines between "the render is correct" and "the
render is on screen", all invisible to every test and to `snapshot.sh`:

| defect | symptom | why nothing caught it |
|---|---|---|
| `colorPixelFormat = .rgba16Unorm` | **crash on launch**, `CAMetalLayer: invalid pixel format 110` | a valid *texture* format, not a valid *drawable* format. No `MTKView` is ever built offscreen, so no test constructed one. Now: `Renderer.drawableFormat` (rgba16Float) for the drawable, `offscreenFormat` (rgba16Unorm) for captures and export, and two pipeline states. |
| `needsDisplay = true` on a paused `MTKView` | **blank canvas** while the status bar said "reprint 435 ms" | the documented on-demand recipe does not fire the delegate in the running app. Measured: view in a window, visible, correctly sized, closure firing, zero draws. Now `scheduleDraw()` calls `MTKView.draw()`, coalesced per runloop turn. |
| the zoom readout | "Fit · 158,000 %" | computed against a 1×1 placeholder before any image, and never recomputed when one arrived. `Renderer.onViewportChanged` now fires when `setBase` refits. |
| unprefixed `UserDefaults` keys | panels and filmstrip opened folded | the **previous** version of this app shipped under the same bundle id and left `leftCollapsed`, `filmstripCollapsed`, `dock.*`, `panel.*` behind. UI-state keys are now `ui2.`-prefixed. |

The lesson is written into `Tools/capture-live.sh`: `cacheDisplay` cannot see a
`CAMetalLayer` at all, so the offscreen harness substitutes a render of the
canvas and is blind to everything between the renderer and the screen. Only a
window-server capture of the real window closes that gap. Run it before
believing the canvas works.

**`CanvasViewTests` is honest about its limit.** It asserts the drawable
format is one `CAMetalLayer` accepts, that the view builds and draws, that a
redraw request reaches the delegate (this caught a missing `MTKViewDelegate`),
and that the zoom readout follows the image. It does **not** reproduce the
`needsDisplay` failure: in-process, bare or inside `NSHostingView`, it fires
correctly and the test passes against the broken code. That one is guarded by
the live capture, not by a test.

---

## 8. Adding, removing, moving a control

Every section is one view in `Panels/Sections/`. The panel is a list:

```swift
FilmProfileSection(session: session)
PrintProfileSection(session: session)
CameraSection(session: session)      // ← delete this line to remove the section
```

A section is `PanelSection(title, systemImage:, key:) { Well { … } }`, and its
controls bind to `session.params` (Layer 1) or `session.adjustments` (Layer 2)
through `ScrubSlider`, `ToggleRow`, `PillMenu`. Sections do not reference each
other; if two need to agree, that belongs in `Session`.

- **A new engine parameter:** add the field to `FilmParams`, one line in
  `wire` with its layer, one slider in a section. `ParamsTests.
  testWireNamesMatchTheServiceSchema` will remind you to add the wire name.
- **A new Layer 2 control:** add the field to `Adjustments`, map it in
  `uniforms`, add the uniform to *both* `Layer2Uniforms` (Swift and Metal, same
  order), apply it in the `layer2` kernel, add a slider.
- **A new film stock:** drop the profile in the engine, run
  `Tools/gen-catalog.py` (covers go in `Resources/FilmCovers/<id>.jpg`).
- **A new file:** run `Tools/gen-project.py`; the project lists files
  explicitly and the generator is deterministic.

---

## 9. Known limits, stated

- `cancel` cannot arrive mid-render on stdio; the scheduler supersedes by
  generation instead. A film-side change while one is running waits its turn.
  A detail render waits for the scheduler to be idle for the same reason.
- The live tier is 1600 px on the long edge. Zooming past 100 % asks for a
  higher tier (preview at 100 %, full at 200 %) and swaps it in when it lands,
  but that is a **whole-frame** render, not the ROI render frontend SPEC §5.0
  specifies: the service has no crop parameter, so a full-resolution film side
  runs and 360 MB crosses the workspace. First full render on a 45 MP frame:
  17 s cold, 6 s warm.
- The service cannot report progress. `reprint` does not return until the
  render is finished and the transport is single-flight, so `progress` cannot
  be polled while a render runs. The top bar shows elapsed time instead.
- The decode cache is bounded at 4 GB (about eleven 45 MP frames). Frames
  evicted from it re-decode in a few seconds. The handoff's §3.1.3 proposal —
  a 1600 px live-tier TIFF — was not taken, because the service derives every
  tier including export from the file it opens; see the handoff for why.
- `preview_stock_lut` is wired in the client types but not used: a reprint at
  ~200 ms is exact where the LUT is an approximation, and fast enough.
  Recorded, not changed.
- Grain is unseeded in the engine; reopening a frame re-draws it. Reproducible
  exports need `grain_seed` in the shoot layer — a service change.
- Crop is a one-shot drag; no handles, aspect lock or thirds overlay.
- Masks (dodge and burn) are not built; the sidecar has no field for them yet.
- The filmstrip is single-select, with no keyboard navigation or drag-reorder.
  Intentional, recorded so it is not reported as a bug.
- Sidecars are written next to the source files (`<name>.spektra.json`).
  Opening a folder litters it with them. Fine for a personal tool; worth a
  sentence in any README aimed at anyone else.
- The zoom pill's `Fit · N %` and the histogram are correct only once a print
  has landed; before that the decode preview is on screen.
- Interactive gestures (slider scrub, curve drag, wheels) are exercised by
  hand, not by tests; the geometry math beneath them is.
- `capture-live.sh` needs Screen Recording permission for the terminal, and
  drives the real app, so it is slower and less deterministic than
  `snapshot.sh`. It is the acceptance check, not the inner loop.
- The canvas draws on demand. If a future change makes some state fail to
  reach the screen, `SPEKTRAFILM_CANVAS_LOG=1` prints one line per draw with
  the base texture, the viewport and whether a drawable was available, and one
  line for any render dropped before upload.
