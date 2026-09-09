# Frontend architecture — Spektrafilm Desktop

| | |
|---|---|
| **What this is** | The record of what the interface *is*: its geometry, its tokens, its view tree, and how a pixel gets from a RAW file to the canvas. |
| **What it is not** | A task list. Open work is in `../HANDOFF-FRONTEND-POLISH.md` and `../HANDOFF-MASKS.md`; how to build and test is in `Spektrafilm/README.md`. |
| **Authority** | The drawing, `reference_layout/SVG_link/sample_frontend.svg`. Where this document and the drawing disagree, the drawing wins and this document is stale. |
| **Date** | 2026-09-08 |

---

## 1. The window

Four floating cards on a flat ground. Nothing is nested inside anything else,
which is why the layout survives every window size: the two side panels are
fixed width and the centre column absorbs the remainder.

```
 ┌───────────────────────────── 1920 × 1080 pt ──────────────────────────────┐
 │  9                                                                     9  │
 │ ┌────────────┐ 8 ┌──────────────────────────────────┐ 8 ┌──────────────┐  │ 7
 │ │            │   │            top bar 41            │   │              │  │
 │ │            │   ├──────────────────────────────────┤ 8 │              │  │
 │ │    left    │   │                                  │   │    right     │  │
 │ │    328     │   │             canvas               │   │     286      │  │
 │ │            │   │          (fills the rest)        │   │              │  │
 │ │            │   ├──────────────────────────────────┤ 8 │              │  │
 │ │            │   │          filmstrip 125           │   │              │  │
 │ └────────────┘   └──────────────────────────────────┘   └──────────────┘  │ 7
 └───────────────────────────────────────────────────────────────────────────┘
```

Every number is the SVG's, divided by two — the drawing is a 3840 × 2160
canvas, which is this window at 2×. The built interface departs from it twice,
both deliberately: the gutter is 6 rather than 8, and the left panel's header
starts 70 pt in so the window's traffic lights can share that row the way they
share Xcode's sidebar header.

| card | SVG rect (x, y, w, h) | points |
|---|---|---|
| left panel | 17.9, 14.1, 656.9 × 2131.8 | x 9, y 7, **328 × full height** |
| top bar | 690.5, 15.5, 2547.9 × 82.7 | x 345, y 7, **41 tall** |
| filmstrip | 690.5, 1895.3, 2547.9 × 250.6 | x 345, **125 tall** |
| right panel | 3250.1, 15.5, 572.3 × 2131.8 | x 1625, **286 × full height** |

Outer margin 9 × 7, gutter 8, corner radius 15. `Tools/compare-layout.py`
measures a capture against this table; the checked-in captures sit within 2 pt
on every card.

### Behaviour of the frame

- **Side panels never resize.** A wider window gives the canvas the extra
  room; a narrower one takes it from the canvas. Panel width therefore trades
  against how much of the frame you see at once, never against what you can
  inspect — zoom does that.
- **The left card's header shares its row with the traffic lights**, the way
  Xcode's sidebar header does — and it genuinely shares it.
  `.windowStyle(.hiddenTitleBar)` floats the three window buttons over the
  content at a centre 15.75 pt from the window's top, which is 13 pt above a
  44 pt header row's centreline: the lights sat high and slightly left of a
  glyph row that sat low and to the right, and nothing in the corner lined up
  with anything else. `Windows/TrafficLights.swift` **places** them instead of
  avoiding them — leading `outerX + 12`, the card's own content inset, and
  centre `outerY + panelHeaderHeight / 2`. `panelHeaderLeading` then follows
  from where the button row ends rather than being tuned by hand. This is the
  one place the built interface departs from the drawing, which puts the
  import glyph at x 12; every other card keeps its 12 pt. The window server
  draws the buttons, so no offscreen capture (`Tools/snapshot.sh`) can see
  this row at all — `Tools/capture-live.sh` is the check, and it measured
  leading x 21, centre y 28.75. The header row, the top bar's empty
  middle and the Browse header are the window's drag surfaces
  (`WindowDragHandle`), since hiding the titlebar removes the usual one.
- **The gutter is 6, not the drawing's 8.** Four gutters of ground between the
  cards is a lot of screen for nothing; `Tools/compare-layout.py` applies the
  2 pt difference, so it still measures the drawing rather than the deviation.
- **Collapsing removes a card from the stack**, so the canvas grows into its
  place rather than being overlapped. The pill tab on each canvas edge brings
  it back. `⌘\` folds both side panels; `⇧⌘F` the filmstrip.
- **Minimum window 1100 × 700**, which leaves the canvas 460 pt wide.
- Collapse state persists under `ui2.`-prefixed `UserDefaults` keys. The
  prefix is load-bearing: the previous version of this app shipped under the
  same bundle identifier and its leftover `leftCollapsed`, `filmstripCollapsed`,
  `dock.*` and `panel.*` values opened this one with everything folded away.

---

## 2. Tokens

All of them live in `Theme/Theme.swift`, each quoting the SVG value it came
from. No view file carries a literal colour or metric that could have come
from there — that is what keeps the interface matching the drawing when one
number moves.

| role | value | from |
|---|---|---|
| ground (window, canvas surround, wells) | `#5F5F5F` | `.st2` |
| card | `#2C2D2B` | `.st5` |
| text and glyphs | `#FAF8F4` | `.st4` / `.st9` |
| dim (slider tracks, captions) | `#898989` | `.st6` |
| plot ground / grid | `#1E1F1E` / `#3A3B39` | — |
| accent (active curve tab only) | `#EE8A2B` | — |
| selection | a 1 pt `#FAF8F4` frame | the drawing's white outline |

Wells are the *ground* colour punched through a card, not a lighter card. The
type ramp is 12 pt semibold for section titles and list items (cap height
8.45 pt, measured off the drawing's glyph paths), 11 pt labels, 10.5 pt
monospaced-digit values, 9 pt captions.

The only colour in the interface besides the accent is the filter-pack and
white-balance slider tracks, at low saturation.

---

## 3. View tree

```
SpektrafilmApp                      one Window scene, one Session, dark forced
└── EditorWindow                    Browse or Print, drag-and-drop, export sheet
    ├── BrowseView                  the Browse state: grid, breadcrumb, sort
    ├── LeftPanel                   Layer 1
    │   ├── header                  import · export · ⋮
    │   ├── FilmProfileSection      film list, covers, cine badge, white frame
    │   ├── PrintProfileSection     papers grouped Still / Cine, declared-pair dot
    │   ├── CameraSection           Format · Vignetting · Exp. Comp. · white balance
    │   ├── FeaturesSection         Grain · Halation · Glare
    │   └── EnlargerSection         Brightness · Yellow · Magenta
    ├── CanvasArea
    │   ├── MetalCanvasView         MTKView (SnapshotCanvas in capture mode)
    │   └── CollapseTab × 4
    ├── TopBar                      tools · status · zoom pill · fit · fullscreen
    ├── Filmstrip                   thumbnails, selection frame, three-state badge
    └── RightPanel                  Layer 2
        ├── header                  adjustments · bypass · ⋮
        ├── HistogramSection        live RGB + luma, EXIF caption
        ├── WhiteBalanceSection     Temperature · Tint  (post-print)
        ├── ExposureSection         Exposure · Contrast · Brightness · Saturation
        │                           Highlights · Shadows · Black · White
        ├── CurveSection            5 channels, histogram behind, draggable points
        └── ColorBalanceSection     Master / 3-Way wheels
```

A section is one file in `Panels/Sections/`, added or removed by one line in
its panel. Sections never reference each other; anything two of them must
agree on lives in `Session`.

### The two layers

The panel a control sits in *is* its layer, and that is the whole rule.

- **Left — Layer 1**, the engine. Every control maps to one `params_delta`
  field in `Model/Params.swift`, which mirrors `service/schema.py` and knows
  each field's layer. A shoot-layer change re-runs the film side; a print-layer
  change reprints from the cached negative.
- **Right — Layer 2**, the client. `Model/Adjustments.swift`, applied in the
  `layer2` compute kernel in under a millisecond, reaching no service at all.
  The bypass switch in the right header shows the pure simulation.

**Masks are in the right panel**, and that is a reversal of
`../HANDOFF-MASKS.md` §3.1, which argued for the left. That argument followed
from the dodge-and-burn model — a mask was a value in stops, whose correct
application point is the enlarger, which is Layer 1. The user rejected that
model in favour of Lightroom's, where a mask carries a *set of adjustments*.
That makes masking Layer 2 by construction: it runs in the `layer2` kernel,
costs under a millisecond, and reaches no service. The panel a control sits in
is its layer, and that rule outranks the earlier argument for breaking it.
Selecting a mask opens a **sublayer** inside the section — inset, with an
accent rail — because the local sliders are otherwise identical to the global
ones two sections above, and that is the one way this interface could mislead.

Two controls break the panel rule and say so in their own comments:
**Vignetting** (Layer 2, but placed in Camera where a photographer looks for
it) and the **white balance block** (neither layer — it is a decode setting,
§4).

---

## 4. The data path

```
open a selection
  ├─ one file (Open With / Edit With / one drop)  →  Print, immediately
  └─ a folder or several files                    →  Browse, and render nothing

select(frame)
  ├─ Core Image decode           CIRAWFilter, boost 0, no gamut map, no lens correction
  │    ├─ preview texture        Display P3, 1600 px  → canvas at once, "preview" badge
  │    └─ half-float TIFF        linear ProPhoto      → ~/Library/Caches/…/linear/
  ├─ service.open(tiff)          film side → live-tier negative
  ├─ service.solve(exposure)     the auto-exposure baseline, shown under Exp. Comp.
  └─ service.reprint(rgba16)     raw 16-bit RGBA → texture → canvas, badge clears

the zoom crosses 100 % / 200 %
  └─ service.reprint(tier: preview|full) → a bigger texture for the same frame
```

The service detects the half-float TIFF as linear ProPhoto, so RAW decode is
Apple's rather than LibRaw's, and white balance becomes a client decision with
a real control instead of a hardcoded `as_shot`. The sidecar records
`decoder: coreimage`.

**Colour, stated once.** Textures hold Display P3 *encoded* values. The
`CAMetalLayer` colour space is Display P3, the pixel format is never an
`_srgb` one, and the shader applies no transfer curve. Encode happens exactly
once, at texture upload. A washed-out canvas means a second encode crept in.

**Orientation.** Row 0 of every texture is the top of the image: the decoder
preview is rendered with a vertical flip (Core Image's origin is bottom-left),
the service's `rgba16` dump is numpy row-major, and the canvas view is
`isFlipped` so mouse and shader share the top-left origin.

### Buffers

`Canvas/TextureStore.swift`. Sizes are for the 1600 px live tier.

| texture | source | kept |
|---|---|---|
| source preview | Core Image decode | last 8 frames |
| print (live tier) | `reprint` rgba16 | last 8 frames |
| detail (preview/full tier) | `reprint` at the zoom's tier | one frame only — a full-res rgba16 texture is 360 MB |
| adjusted | `layer2` kernel output | one, re-run on edit |
| curve table | CPU, 256 × 5 r32Float | one |

Switching frames shows that frame's last print immediately, flagged
**preview** until the service catches up. The two neighbouring frames are
decoded in the background so their `open` skips the RAW decode.

### Crop and straighten

A crop is an **oriented rectangle** — a normalised rect plus the angle it is
rotated by about its own centre (`Model/Geometry.swift`) — not "rotate the
image, then crop the result". The source never moves, so straightening
resamples nothing twice and setting the angle back to zero restores the
rectangle you had.

Every mutation returns something that **fits**: `fitted(in:)` shrinks the
rectangle about its centre until all four corners are inside the frame. That
is why an 8° straighten costs about 20 % of the frame's width, visibly, in the
Crop section's pixel readout — instead of exporting a picture with transparent
triangles in the corners.

The geometry is applied while *sampling*, both on the canvas
(`canvasFragment` → `geometryMap`) and at export (the `geometryResample`
kernel, deliberately the same function). Before this the crop was a dimmed
overlay that only appeared while the crop tool was active and was applied at
export with `CGImage.cropping`: the canvas showed an uncropped frame, export
wrote a cropped one, and neither could rotate at all.

While the crop tool is up the canvas shows the **whole frame** with the
outside dimmed, and the viewport is expressed against the source; leaving the
tool re-expresses it against the crop and refits. `Renderer.logicalSize(forSource:)`
is the one place that decision is made. The detail tier follows the *cropped*
long edge, so a 20 % crop of a 45 MP frame no longer escalates to a
full-resolution render for detail the crop threw away.

### Masks

A mask is a **region plus its own adjustments** (`Model/Mask.swift`). A region
is a union of `add` components minus `subtract` components — "the sky, minus
the trees" is two components in one mask — and the first component is always
additive because there is nothing to subtract from yet. Four kinds ship:
linear gradient, radial gradient, luminance range and colour range. All four
are **closed-form**, so coverage is evaluated per pixel from parameters at
whatever resolution the canvas is showing: a radial is exact at 400 % zoom and
costs no memory at any tier. `brush` exists in the model and in the shader as
component kind 4, with `MaskUniform.rasterSlice` and a texture-array binding
waiting for it, and is deliberately absent from the add menu until something
rasterises strokes.

A mask's tone controls are the **same** controls, the same ranges and the same
arithmetic as the global panel's — `Layer2Uniforms.tone` is one function with
two callers — so "+1 stop" means one stop wherever it was typed. What a mask
does not carry is as deliberate: no curves, no colour balance, no vignette. A
curve is a global statement about a tone scale and a vignette is a lens.

Coverage is computed against the print *before* the global adjustments, so a
luminance- or colour-range mask selects what the photograph has in it rather
than what the exposure slider just did to it. Masks are anchored to the
**source**, not the crop, so re-cropping leaves a mask on the face; the canvas
shows the crop, so every handle goes source → output → view through
`Geometry.outputPoint(forSource:imageSize:)`. Eight masks, six components
each, one uniform buffer, no allocation.

### Browse and Print

Two states, one window (frontend SPEC §5.1). **Browse** is a grid of the
session — thumbnails only, no decode, no render — and is where a folder or a
multi-file drop lands. **Print** is the four-card layout, entered by clicking a
cell. A single file is a handoff and goes straight to Print. Before this, a
folder open rendered the alphabetically-first frame: ~7 s and a 363 MB TIFF on
a guess the user had not made.

The grid cell's badge is the filmstrip's three-state model: no pip = never
rendered, filled = the print matches the sidecar, hollow = the parameters
changed after it was made.

### Resolution follows the zoom

The live tier is 1600 px because a reprint has to fit inside a slider drag.
Past 100 % zoom it is interpolated, and grain and halation — the reasons to
zoom — are exactly what interpolation destroys. So the canvas asks for a
higher tier and swaps it in when it lands:

| zoom | tier | long edge |
|---|---|---|
| below 100 % | live | 1600 |
| 100 % | preview | 3400 |
| 200 % | full | native |

A frame no larger than the live tier never escalates. The request is debounced
700 ms and never starts while the scheduler owes the service a render — the
transport is single-flight, so a full-resolution render (17 s cold, 6 s warm on
a 45 MP frame) would sit in front of the user's next slider release. Zooming
back out is instant: the detail texture stays resident and the live tier comes
back without a render.

The viewport is expressed against the **live** tier's pixel size, not the
texture's. `Renderer.canvasUniforms` scales by `logicalWidth / textureWidth`,
so a 5504 px texture and a 1600 px one occupy the same rectangle on screen.

### The decode cache

`Import/LinearCache.swift` bounds `~/Library/Caches/com.hanze.spektrafilm/linear`
at 4 GB, LRU by modification date, pruned before each write. Each entry is the
source at full resolution (363 MB for 45 MP), so the ceiling is about eleven
frames. The TIFF is written *after* the decode task's cancellation guard, so a
superseded white-balance value leaves no file behind.

### Scheduling

`Service/RenderScheduler.swift` holds *sent* against *wanted* and runs one
loop: debounce (40 ms print, 220 ms shoot), send one delta for the whole
difference, apply the result only if the generation still matches. A slider
drag produces a handful of reprints, never one per tick, and a stale reply can
never overwrite a newer frame.

Layer 2 bypasses all of it. Zoom and pan are a sampling transform
(`ViewportState`) and cost nothing; at 100 % and above the sampler is nearest,
so grain reads as grain.

### The canvas draws on demand

`isPaused` with an explicit `scheduleDraw()` that calls `MTKView.draw()`,
coalesced to one per runloop turn. **Not `needsDisplay`** — the documented
recipe does not fire the delegate in the running app, and the canvas stayed
blank while everything behind it worked. The view is its own `MTKViewDelegate`
so there is no separate object whose lifetime can be got wrong.

`SPEKTRAFILM_CANVAS_LOG=1` prints one line per draw with the base texture, the
viewport and whether a drawable was available, plus one line for any render
dropped before upload.

---

## 5. Files

```
Theme/Theme.swift            every colour, metric and font in the interface
Windows/EditorWindow.swift   Browse or Print; CanvasArea; drop; export sheet
Windows/BrowseView.swift     the Browse grid, breadcrumb and sort
Windows/TopBar.swift         tools, status, zoom, elapsed time, detail tier
Windows/CollapseTab.swift    the edge pills
Panels/LeftPanel.swift       Layer 1 column
Panels/RightPanel.swift      Layer 2 column
Panels/Filmstrip.swift       library strip
Panels/Sections/*.swift      one file per section
Controls/ScrubSlider.swift   the only slider: drag anywhere, ⌥ fine, ⇧ snap,
                             double-click to zero, editable value
Controls/SectionHeader.swift disclosure header + Well + PanelSection
Controls/CurveEditor.swift   channel tabs, draggable points, readout
Controls/ColorWheel.swift    Master / 3-Way colour balance
Controls/HistogramView.swift Canvas-drawn RGB + luma
Controls/KelvinSlider.swift  the white-balance block
Controls/FormatPicker.swift  the pill menu
Canvas/MetalCanvasView.swift MTKView, gestures, scheduleDraw
Canvas/Renderer.swift        Metal state, Layer 2 pass, histogram, offscreen render
Canvas/TextureStore.swift    the buffer table
Canvas/ViewportState.swift   zoom and pan arithmetic, no view code
Windows/TrafficLights.swift  the window buttons, moved onto the header row
Canvas/Shaders.metal         layer2 · canvas quad · histogram
Model/Session.swift          all state, on the main actor
Model/Params.swift           Layer 1, mirrors service/schema.py
Model/Adjustments.swift      Layer 2 + the shader uniform block
Model/CurveMath.swift        monotone cubic, no view code
Model/Geometry.swift         the oriented crop, straighten, turns and flips
Model/Mask.swift             masks: components, per-mask adjustments, uniforms
Canvas/MaskOverlay.swift     the selected mask's axis, ellipse and grips
Model/Sidecar.swift          <image>.spektra.json (schema 3)
Canvas/CropOverlay.swift     handles, thirds grid, straighten line
Model/StockCatalog.swift     Resources/StockCatalog.json
Import/ImageDecoder.swift    Core Image RAW + flat decode, linear ProPhoto out
Import/Library.swift         one file or one folder, no subfolders
Import/ThumbnailCache.swift  ImageIO previews off the main actor
Import/LinearCache.swift     the bounded on-disk decoded-TIFF cache
Service/ServiceClient.swift  actor, one long-lived python -m spektrafilm.service
Service/Methods.swift        typed requests and responses
Service/RenderScheduler.swift coalescing
Export/Exporter.swift        JPEG · PNG · TIFF · DI package
Tools/gen-project.py         regenerate the pbxproj from the filesystem
Tools/gen-catalog.py         regenerate the stock catalog and covers
Tools/snapshot.sh            offscreen layout captures at three window sizes
Tools/capture-live.sh        the real window, through the window server
Tools/compare-layout.py      a capture against the drawing
```

---

## 6. Renamed from the drawing

| drawing | built | why |
|---|---|---|
| Enlarger: Cyan / Magenta | Brightness / Yellow / Magenta | a dichroic head grades on two axes; the engine has `y_filter_shift` and `m_filter_shift` and no cyan. Brightness (print exposure, in stops, brighter positive) is the enlarger's main control and the drawing omitted it. |
| Color Temp / Tint with "As Shot ☐" | preset pill + eyedropper + two gradient tracks | §4 of `Spektrafilm/README.md` |
| Curve tabs 亮度 / 红色 / … | RGB · Luma · Red · Green · Blue | the rest of the interface is English |
| Features: hollow squares | hollow off, filled on | it is a state, not a decoration |
