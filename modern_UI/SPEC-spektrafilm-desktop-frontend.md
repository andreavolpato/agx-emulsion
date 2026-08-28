
# Spec — Spektrafilm Desktop (macOS frontend)

| | |
|---|---|
| **Status** | Draft for implementation. Supersedes nothing; sits above `API-SPEC-callable-render-service.md` as its consumer. |
| **Scope** | Personal tool. Not a commercial product, not distributed for sale. |
| **Read this if** | You are building the SwiftUI client, or changing the service in a way the client depends on. |
| **Date** | 2026-08-28 |

---

## 0. What this is

A macOS app that is a **darkroom print station**, not a photo editor and not an asset
manager. It takes a negative-side image, prints it, and lets you control the print the
way a printer controls a print: exposure, filter pack, dodge and burn. Nothing else.

The structural model is the film DI suite, and it is worth stating precisely because
the whole design follows from it:

> In a real DI, the print emulation transform lives in the **viewing chain**, not in the
> file. The colorist works on wide-latitude scan data while *seeing* it through the print
> LUT. The transform is baked only at final delivery.

This app is that suite. The canvas is the monitor with the print transform applied. The
sliders are the grade. Export is delivery. There is no "hand the intermediate to another
tool and keep working" step, because that step does not exist in the workflow this is
modelled on.

### Scope consequences of "personal tool"

Because there is exactly one user, and that user wrote the engine's frontend spec:

- No onboarding, no tooltips explaining what a filter pack is, no guard rails.
- No licence gymnastics. Spektrafilm is GPL-3.0; not distributing means no distribution
  obligation, and distributing under GPL is fine too. The author-permission email is
  optional now, not blocking.
- No error UX beyond "show what the service said."
- **Local exposure moves into v1**, but as Layer 2 masks (§5.2 item 3), which need no
  engine change. The physically correct `Enlarger` variant (§1.5) is deferred until
  measured need justifies it — see the mask target table.

### Non-goals, permanently

| Not building | Why |
|---|---|
| Colour wheels, lift/gamma/gain, hue/sat **inside the physical chain** | Colour is produced by the spectral dye simulation. A grading node between film and paper makes the physical claim false. `API-SPEC §4` states this explicitly: point at the filter pack and the stock picker instead. |
| Any editing control whose position in the chain is ambiguous | The two layers (§3.1) must be visually and structurally separate. A control that could be read as either is worse than not having it. |
| Output-side temperature / tint | Same category. Colour temperature maps to the enlarger filter pack, which already exists. |
| Catalog, library, ratings, keywords | Not an asset manager. The folder is the project. |
| Multi-image batch render queue | Engine is single-flight (`API-SPEC §10.5`, numba `workqueue`). Copy/paste settings covers the real need. |
| A DCP / Lightroom profile pack | Structurally cannot carry grain, halation, glare, DIR couplers, or per-image solve. Throws away the reason the engine is better than a LUT product. |

---

## 1. Service gaps that must be closed first

The client cannot be built against the service as it stands. These are ordered by
whether they block the architecture or just the feature.

### 1.1 Persistent negative cache keyed by file — **blocks folder workflow**

`open` is 6.98 s at 45 MP and the service holds one session. Browsing a folder at 7 s
per image is not usable.

Required: a disk cache keyed on `(file content hash, shoot-layer params hash)` storing
the live-tier negative as raw `.npy`. Returning to a previously opened frame becomes an
`mmap`, not a render. This is distinct from `API-SPEC §7`'s spill policy — that is memory
reclamation within one session; this is persistence across sessions.

Cache location: `~/Library/Caches/com.hanze.spektrafilm/negatives/`. Bounded by total
size, LRU eviction, default 20 GB.

### 1.2 Split `open` into `decode` and `develop` — **enables prefetch**

`open` currently fuses RAW decode with the film-side render. Splitting them lets the
client prefetch-decode neighbouring frames while the user is looking at the current one.
Prefetch queue is managed client-side and serialised, because the transport is
single-flight.

### 1.3 Expose the negative and the print LUT to the client — **enables real-time**

The interactive path is: client holds the live-tier negative in a Metal texture, applies
the print chain on GPU, composites at 60 fps. This requires the negative to leave the
Python process, which it currently never does.

New methods:

```
get_live_negative  {session_id}
  -> {path, shape, dtype, domain}          # domain must state density vs linear

get_print_lut      {film_stock, print_stock}
  -> {path, size, input_domain, output_space, cctf_encoded}
```

`cctf_encoded` is load-bearing. `API-SPEC §4` records a double-encoding bug that came
from re-applying a gamma to an already-encoded array. The client must never hand-roll a
curve; it reads this flag and either uploads as-is or converts primaries only.

**Validation required before committing to this path:** confirm that
`density offset → LUT` is equivalent to `reprint` when grain and glare are disabled.
`print_exposure` and the filter shifts should be pure log-domain offsets, but that is an
assumption about the enlarger node, not a verified fact. Reuse the equivalence-test shape
from `API-SPEC §2`. If it fails, the client falls back to `reprint` at ~193 ms on release,
with no live GPU compositing.

Also: LUT grids are baked over each film's own characteristic-curve range. Offsetting
walks off the end of the grid. Either clamp client-side or bake with widened range.

### 1.4 Deterministic grain — **correctness**

`settings.grain_sampler = 'stochastic'` is unseeded. The same image, closed and reopened,
exports differently. Add `grain_seed` to the shoot layer; persist it in the sidecar.

### 1.5 Local exposure mask — **new engine surface, required for dodge and burn**

Dodge and burn is spatially non-uniform `print_exposure`. In the engine this means the
printing stage must accept a per-pixel exposure multiplier rather than a scalar.

```
reprint {session_id, params_delta, exposure_mask?}
  exposure_mask: {path, shape}    # single-channel float, stops, 0 = neutral
```

This is the only genuinely new engine capability in this spec. Everything else is
plumbing over what `API-SPEC §1` already established.

Physically this is exactly what it says: more or less enlarger exposure over a region.
It is not a curves adjustment and not a local contrast tool.

**Why this cannot be deferred to Lightroom.** In the darkroom, dodging happens *before*
the paper responds — the held-back region receives less exposure and then travels the
paper's characteristic curve at that new position, picking up the rolloff that belongs
there. Doing the same operation on an exported print-referred TIFF moves pixels that have
already passed through the shoulder.

`API-SPEC §2` measured the global version of exactly this: +1 stop via
`enlarger.print_exposure` against a flat ×2 gain on the print-referred tap gave mean abs
diff 0.126 / max 0.343, and the visible signature was that the correct version compresses
highlights as exposure rises while the flat gain preserves the original contrast ratio.
The local case is the same mechanism. Burning down a sky externally keeps the sky's
original contrast instead of acquiring the paper's rolloff at that density — and the
rolloff is the reason for burning the sky in the first place.

This is the one local operation that must stay in this app. See §5.2 item 3 for what does
not have to.

### 1.6 Bake-on-demand for `preview_stock_lut` — **small**

`API-SPEC §10.4` lists this as an unimplemented gap. Baking is 0.01–0.25 s. Needed so the
stock picker can offer arbitrary film × paper pairs, including the five print stocks with
no declared pairing.

### 1.7 Remove from scope

- The service-side undo ring. Params are tens of bytes; the client owns history. With
  grain baked into the cached negative, undo is deterministic re-`reprint`.
- `cancel` mid-render. Not achievable on stdio (`API-SPEC §10.4`) and not needed once
  §1.3 lands: print-side interaction never touches the service during drag.

---

## 2. Input colour management

This section exists because it is the one place where an upstream choice silently
invalidates the physics.

### 2.1 The requirement

Spectral upsampling assumes its input is **colorimetric** — tristimulus values under a
standard observer. Given that, it reconstructs a plausible spectrum, which the dye layers
then respond to.

Feed it sensor-native RGB and the upsampler treats the sensor's spectral mismatch as if it
were the scene's actual spectrum. The error is amplified through the dye response, not
cancelled by it.

### 2.2 What this means for Capture One inputs

| C1 profile | What it is | Suitable as input |
|---|---|---|
| **No Color Correction** | Sensor-native RGB, linear transform only. The purple response curves are the sensor's spectral sensitivity diverging from the CIE observer. | **No.** Sounds more "raw", is structurally wrong. |
| **ProStandard** | Colorimetric-leaning, preserves hue relationships across saturation. | **Yes.** Closest available to what the model wants. |
| Standard camera profiles | Vendor "pleasing" rendering. | No. Applies one look before the film look. |

The uncorrected sensor divergence is real information about the camera, but it is not
recoverable — you cannot infer which spectrum produced a given triplet without the
camera's spectral sensitivity curves. Different project.

### 2.3 What the engine actually asks for

The engine's README states the contract directly: it expects **linear scene-referred
files, with or without a transfer function**, and the author's own manual workflow is
darktable with `filmic` / `sigmoid` disabled, exposure set to preserve information without
clipping, exported as **32-bit float TIFF in linear ProPhoto RGB**.

So linear TIFF is not a degraded path — it is the author's recommended one, and RAW import
is described as the *simpler* option, not the more correct one. Correct earlier framing in
this spec accordingly.

Two things follow:

- **Producing linear ProPhoto from Core Image is squarely in-contract.** It is the same
  artifact darktable produces, from a decoder that is native, supports ProRAW, and does
  not require using darktable.
- **The exposure step in that workflow is manual and is not the auto-solve.** The author
  sets exposure at export to avoid clipping while preserving information. The engine's
  `solve` finds an EV on the film's characteristic curve — it cannot recover highlights
  that were already clipped at decode. Decode-time headroom is a separate decision the
  client must make, not something `solve` absorbs.

### 2.4 Product consequence

- **Decode in-app**, whichever decoder. That is what makes colorimetry controllable, and
  §2.2's finding is about which profile the decode targets, not about RAW versus TIFF.
- Decode targets linear ProPhoto RGB, colorimetric (not sensor-native), with headroom held
  back from clipping.
- Externally prepared TIFFs are accepted as a first-class input. The open panel states the
  expected form — linear scene-referred, ProPhoto, colorimetric profile — rather than
  silently accepting whatever arrives.
- The sidecar records which decoder produced the negative.

### 2.5 rawpy → Core Image migration

Currently LibRaw via rawpy; input white balance is `user_wb` (four multipliers).

Migrating to `CIRAWFilter` buys ProRAW support and Apple's demosaic. Requirements:

- `boostAmount = 0`, `boostShadowAmount = 0`, `isGamutMappingEnabled = false`,
  `isDraftModeEnabled = false`. Otherwise Apple's tone rendering is applied and the film
  model receives already-tone-mapped data.
- **The two decoders do not agree.** Different demosaic, different camera matrices,
  different highlight recovery. Switching changes the output and invalidates any solve
  calibration. Sidecar must record `decoder: libraw | coreimage` and version, or reopening
  old work after an app update silently changes every image.
- **ProRAW caveat, to be stated not hidden:** ProRAW is linear DNG with Deep Fusion /
  Smart HDR local tone mapping baked in. It is Apple's computational-photography output
  wrapped in DNG, not sensor response. Running a physical film model over it is running
  the model on something already tone-mapped. It will look fine; the physical-accuracy
  claim does not hold for that input.

### 2.6 Input white balance — decision: minimal

A `scene_wb` control belongs to the shoot layer (it is physically a lens filter or a
change of illuminant), so any change invalidates the negative and costs a full re-render.

Given the minimal-invasion stance and that upstream has already set WB, v1 ships a
**two-position illuminant match** (daylight / tungsten) rather than a continuous
temperature slider, and only for RAW input. It exists to pair correctly with tungsten
cine stocks (`kodak_vision3_200t`, `500t`), not to grade.

---

## 3. Architecture

```
SwiftUI shell
  ├─ MTKView canvas (NSViewRepresentable)
  │    CAMetalLayer.colorspace = Display P3
  │    compute: exposure mask → density offset → print LUT → display
  ├─ ImageIO thumbnails (independent of service)
  └─ ServiceClient
       Process + stdio pipes, JSON-RPC 2.0, serialised
       └─ python -m spektrafilm.service
```

**Why SwiftUI, honestly.** Not memory — the memory is in the Python engine's film-side
buffers (12.34 GB at 45 MP), and a UI framework moves that by a few hundred MB. The real
reasons are that Metal and Display P3 colour management are native, and that the
interactive path in §1.3 wants a GPU texture the UI already owns.

**Why not migrate the engine to Swift.** The memory peak lives in the hardest-to-port
part (spectral integral, DIR couplers, Poisson grain), so a port starting from the cheap
end does not address the stated motive. If memory is the goal, the lever is **tiling with
halo** for the spatial operators, which works in Python and would be required in Swift
anyway. Halation's radius is large but it is low-frequency and can run downsampled.

If a port happens later, port the interactive path only (§1.3 already does this in Metal),
keep Python for `open` and `export`, which are cold and seconds-scale.

**Controls are custom-drawn.** SwiftUI `Slider` has the wrong precision and no scrub feel.
Numeric field + drag track + double-click-to-zero, C1's model.

### 3.1 Two layers

The app has two editing layers with different natures, and keeping them distinct is the
single most important structural decision in this spec.

```
RAW / linear TIFF
      ↓
  film → paper → scan            LAYER 1 — physical simulation
      ↓                          engine, Python, ~193 ms
  print output  ← the baseline
      ↓
  exposure / highlights / shadows / curve / masks
      ↓                          LAYER 2 — ordinary editing
  display                        client, Metal, < 16 ms
```

**Layer 1** is everything this project is about: measured sensitometry, spectral dye
response, the paper's characteristic curve. Nothing may be inserted into it that is not
physically part of a darkroom.

**Layer 2** operates on the print output as if it were a scan of a print — which is
exactly what it is. Black point, white point, curves, local exposure. This is not
dishonest, because scanning a print and adjusting the scan is a real step in a real
workflow. It is a *different* step, and it comes after.

Layer 2 lives entirely in the client. It is pointwise or simple-spatial, runs in the
Metal shader that is already compositing the canvas, and **requires no service changes
at all** — it is absent from the backend gaps list by design.

#### The zero point

Layer 2's neutral state is the unmodified output of Layer 1 at the default stock pair.
Every Layer 2 control reads zero on a fresh image; nothing is pre-applied. The baseline
is a real render, not a look.

This is what makes the default stock pair (§9) a character decision rather than a
default value: it is the zero all subsequent editing is relative to.

#### Three rules that keep the layers from merging

1. **Visually separate.** Layer 2 gets its own panel group, below a clear divider, with
   its own heading. At no point should it be unclear which layer a control belongs to.
2. **Bypassable.** One switch disables Layer 2 entirely and shows the pure simulation.
   This is the only way to tell, later, whether a look came from the stock or from a
   curve — and the only stable reference for judging engine changes.
3. **Curves are legal here and only here.** Earlier drafts of this spec banned curve
   editing outright. That ban applies to Layer 1, where a curve node would falsify the
   physical model. On the print output it is just an adjustment to a scan.

---

## 4. Resolution tiers and latency budget

| interaction | path | budget | canvas state |
|---|---|---|---|
| drag print exposure / filter / D&B | client Metal, live negative | < 16 ms | `preview` dot visible |
| release | `reprint`, live tier | ~200 ms | dot clears |
| idle 1 s | `preview_render`, 8 MP, background | 2–3 s | whole-frame refresh |
| zoom past live tier, first time | full-res film side, then ROI | 7–14 s, then ~1 s | `soft` indicator until ready |
| zoom / pan after that | ROI render, print side only | ~1 s | `soft` clears on arrival |
| switch stock | `preview_stock_lut` → `reprint` on release | 10 ms → 200 ms | as above |
| shoot-layer change | send on release only, full re-render | 1–7 s | canvas dims, spinner |
| export | `export` | 14 s+ | bottom progress, non-blocking |

The `preview` dot is not decoration. The client-side path skips `scanning.glare`, which is
spatial and stochastic and cannot be represented in the LUT (`API-SPEC §2`). The difference
is visible. The dot says which one is on screen.

Shoot-layer drags send nothing until release, because `cancel` cannot arrive mid-render.

---

## 5. Interface

### 5.0 Canvas viewport

The canvas is a Metal viewport, not a fitted image view. Free pan and zoom, 5%–800%,
pinch and scroll, `Z` toggles fit ↔ 100% at the cursor. **The canvas is never sized by the
layout** — panel widths change how much you see at once, not what you can inspect.

This removes a constraint the docked layout would otherwise impose. It does not remove
the resolution constraint, which is real and has to be designed around.

#### Zoom is free only within the resident buffer

| zoom range | served by | cost |
|---|---|---|
| fit → live tier native (2 MP) | resident negative, GPU | free |
| beyond that → 100% | ROI render of the visible region | first one is expensive |

Past the live tier's native resolution there is no more data — magnifying it interpolates.
That matters specifically because `API-SPEC §4` measured grain and halation as invisible
below full resolution (grain mean 0.011 / max 0.52; halation mean 0.017 / max 1.21) while
being genuinely present. Inspecting them is the reason to zoom, and an interpolated live
tier cannot show them.

#### ROI rendering

When zoom exceeds the live tier's native resolution, request a render of the visible
region only, at working resolution.

The print side of an ROI render is cheap — a 850×900 pt viewport at 2× is ~3 MP of actual
pixels, roughly a live-tier render's worth of work. **The expensive part is that it needs
the working-resolution negative**, which means the film side must have run at full
resolution once (6.98 s at 45 MP per `API-SPEC §10.3`).

So: first zoom past the free range on a given frame costs one full-resolution film-side
render. Every ROI after that is print-side only and fast. The working negative is cached
to disk alongside the live one (see backend gaps G1, which must store both tiers), so the
cost is once per frame per shoot-layer change, not once per zoom.

Client behaviour:

- Show the interpolated live tier immediately, with a `soft` indicator, and swap in the
  ROI render when it arrives. Never block the zoom gesture on a render.
- Debounce: do not fire an ROI render while the user is still panning or zooming. Fire on
  gesture end.
- One ROI in flight at a time — the transport is single-flight regardless.

#### Consequences elsewhere in this spec

- The **preview tier (8 MP, whole frame)** loses most of its purpose. Its job was
  inspecting grain and halation, which ROI does better and cheaper. Keep it only as the
  idle-time background refresh of the whole-frame view, or drop it — see §9.
- The **100% button** in the Character group (§5.2 item 4) becomes zoom-to-100% at the
  frame centre, not a separate render mode.
- §4's latency table gains a row; the `preview_render` row's justification weakens.

### 5.1 Two states, one window

Transition between them is a continuous canvas animation, not a mode switch.

**Browse.** Full-bleed grid. Breadcrumb and sort at top, nothing else. The grid is a
*worklist*, not a preview surface — it shows what is in this session and how far along
each frame is.

Three thumbnail states:

| state | shown | source |
|---|---|---|
| unprocessed | original | ImageIO embedded JPEG |
| processed | rendered result | cached negative → LUT, downsampled |
| processed, params changed | rendered result + stale marker | same, params hash mismatch |

The third state is mandatory. Without it the grid lies after any edit. Marker is a corner
pip plus slight desaturation.

**Print.** Docked three-sided layout: film and print controls left, read-only scopes and
info right, filmstrip bottom. All three are resizable and collapsible to zero; `Tab`
collapses left and right together.

Starting widths: left **300–320 pt**, right **260 pt**, filmstrip **96 pt**. The right
column holds nothing editable, so it does not need the width the left one does.

Panel width trades off against how much of the frame is visible at once, not against what
can be inspected — §5.0's viewport handles that.

This is the Capture One tool-tab idea (a dense, always-there inspector) with Apple's
material and inset treatment (Photos edit mode, Final Cut inspector). No Liquid Glass; the
material blur alone reads as floating and does not fight the image.

### 5.2 Panel contents, in order

The whole control set. Nothing below this line ships in v1.

**1. Stock**

Film × paper. Cine pairs (Vision3 × 2383/2393) and still pairs at the same level, not
behind an "advanced" disclosure — `API-SPEC §5` establishes that which pair is the default
is a real product decision, and for a cinema-referenced look the cine pair is closer to
what "the film look" means.

Declared pairings shown as such; undeclared pairings allowed but marked, since the LUT is
coupled to both the paper curve and the negative's dye spectra.

**2. Print**

Three controls, all `LIVE_MUTABLE`, all real enlarger parameters.

- Exposure. Labelled **"Print brighter / darker"**, never "enlarger exposure" — the paper
  convention inverts (less enlarger exposure prints brighter) and the UI should not make
  the user hold that in their head.
- Yellow ↔ Blue.
- Magenta ↔ Green.

Filter shifts are labelled by the actual filter axes, not as "hue" or "temperature".

**Zero is the auto-solve value.** Sliders display offset from the solve, not absolute. This
puts `PRD §0`'s model — sliders exist to override the auto-solve — directly into the
interface, and makes paste-settings meaningful across frames.

**3. Masks**

A single mask list serving both layers. Each mask has a shape, a value in **stops**, and a
**target**:

| target | applied | cost | physics |
|---|---|---|---|
| `Enlarger` | before the paper curve, via `exposure_mask` (§1.5) | `reprint`, ~193 ms | correct — this is dodging and burning |
| `After print` | Layer 2, in the client shader | < 16 ms | approximation |

`After print` is the default and ships first. `Enlarger` requires the engine change in
§1.5 and lands later.

**Why both exist.** `API-SPEC §2`'s measurement is real: a flat gain on print-referred
pixels does not reproduce what the paper would have produced, because the paper's shoulder
responds nonlinearly and exposure-dependently. Burning a sky after the print keeps the
sky's original contrast instead of acquiring the rolloff.

But the size of that error scales with the adjustment. Half a stop is nearly
indistinguishable; two stops is not. And an AI-selected mask at half a stop is very likely
better than a hand-painted one at the physically correct stop.

So: use `After print` for a while, watch how many stops you actually push, and let that
decide whether §1.5 is worth building. The mask geometry is identical either way — only
the application point changes — so nothing is wasted.

Client renders the mask to a texture. For `After print` it is applied in the Metal path
directly. For `Enlarger` it is applied in the Metal path during drag and passed to the
service as `exposure_mask` on release.

Explicitly not: local contrast, local saturation, local anything else. The physical
justification for this tool is that it is what a printer's hands do under the enlarger.
Nothing else that a brush could do has that justification.

**Mask sources.** The mask is a single-channel float texture in stops. Where it comes from
is orthogonal to what it does, so adding generated masks does not widen the parameter
surface at all — every source feeds the same one input.

| tier | source | framework | note |
|---|---|---|---|
| 1 | linear gradient, radial, brush | own Metal | no dependencies |
| 1 | luminance range from the negative | own Metal | density-domain, physically meaningful |
| 2 | subject / foreground | `VNGenerateForegroundInstanceMaskRequest` | macOS 14+ |
| 2 | people, person parts | `VNGeneratePersonInstanceMaskRequest`, `VNGeneratePersonSegmentationRequest` | |
| 2 | depth, semantic mattes | `CIImage` auxiliary images | ProRAW / iPhone HEIC only |
| 3 | point-to-select anything | SAM or MobileSAM via Core ML | separate model asset |

Tiers 1 and 2 ship in v1. Tier 2 is roughly twenty lines of Vision request plumbing and
runs on the Neural Engine, so it costs almost nothing and covers subject and person
selection at the same quality tier as Lightroom's equivalents.

Tier 3 is deferred. It is what covers sky and arbitrary regions — Vision has no sky
segmentation — and it is more flexible than a class-based selector since it selects
whatever is pointed at. But model download, versioning, and Core ML conversion form a
self-contained lump of work that couples to nothing else here, so it can land any time.

This is also the point where the Apple Silicon-only decision pays for itself: Vision's
segmentation requests, Core ML, and the Metal render path all target the same hardware,
and there is no fallback path to maintain.

**4. Character**

`grain` and `halation` toggles, plus a **100%** button beside them.

The button is not convenience. `API-SPEC §4` measured both effects as invisible at
thumbnail scale (grain: mean 0.011 / max 0.52; halation: mean 0.017 / max 1.21) while
being genuinely present at full resolution. A toggle whose effect cannot be seen at the
current zoom reads as broken. The button makes it inspectable.

`io.scan_film` is **not** here and is not a checkbox anywhere. It changes what the artifact
is (a scanned negative rather than a print). If it is exposed at all it is a Negative /
Print mode at the top of the panel, not a toggle in a list.

**5. Scope** (collapsed by default)

Two read-only plots. Not editable — an editable curve is the same category error as a hue
slider.

- **Film.** Characteristic curve (log H → density) with the frame's exposure histogram
  overlaid. Shows how much of the frame sits in the toe and shoulder. The auto-solve EV
  positions the histogram on the curve.
- **Paper.** Paper characteristic curve with the negative's density histogram overlaid.
  Print exposure translates this window along the curve.

Curve data comes from the profile JSON directly (CC BY-SA, no RPC needed). Histograms are
computed client-side from the live negative texture.

This is the one place in the interface that explains *why* the highlight rolloff looks the
way it does, which is the difference between this and a filter.

**6. Adjustments** — Layer 2

Below a heavy divider, with its own heading and a **bypass switch** in the header. This is
the boundary between the two layers of §3.1 and the divider should look like one.

| control | note |
|---|---|
| Exposure | stops, on the print output |
| Highlights / Shadows | tone-region recovery within the ⅔ stop of scan headroom |
| Black point / White point | the scanner's job, made adjustable |
| Curve | RGB and per-channel |

All zero on a fresh image. Bypass shows the unmodified Layer 1 output.

**Read the headroom honestly.** What Layer 2 has to work with is the scan-normalisation
margin between the paper's Dmin/Dmax and 0/1 — roughly ⅓ to ⅔ stop at each end. That is
what "post-processing space" means here concretely. The paper's toe and shoulder are
irreversible; no bit depth recovers them. Large tonal moves belong to print exposure in
Layer 1, which is why that control exists and why it sits above the divider.

**Order of operations** is fixed and not user-configurable: exposure → highlights/shadows
→ black/white point → curve → masks. Fixed order keeps the sidecar replayable at export
without storing a node graph.

### 5.3 What is not in the panel

`scanner`, `couplers`, `diffusion`, `preflash`, `unsharp`, film tuning profiles. The Python
GUI's parameter list is the engine's debug surface. Sacrificing paper-diffusion and some of
the print-paper response fidelity is a real loss and an acceptable one.

### 5.4 Keyboard

| key | action |
|---|---|
| Tab | hide / show panel |
| Space (hold) | show original |
| ← → | previous / next frame |
| Z | toggle 100% |
| ⌘E | export |
| ⌘C / ⌘V | copy / paste settings |

### 5.5 Context menus

Grid:

- Open · Reveal in Finder
- **Copy Settings · Paste Settings**
- Reset to Auto
- Export…
- Remove from Session

Canvas: Compare Original · Zoom to 100% · Copy / Paste Settings · Export…

**Paste semantics: offsets only.** Because sliders are offsets from the solve, pasting
offsets means "same print recipe, each frame solves its own exposure" — which is what a lab
does across a roll. Pasting absolute values is a different feature (forcing consistency
across a burst) and is not in v1.

---

## 6. Export

Two routes, following directly from §3.1's two layers: one for work that continues
elsewhere, one for work that is finished.

The LUT-as-deliverable idea is dropped. The LUT is a preview optimisation (10 ms vs
200 ms); shipping it as a format would deliver a kit rather than a result, and would lose
glare, which the full `export` path includes.

### 6.1 Route A — for further editing

TIFF, 16-bit, ProPhoto RGB. Two variants.

| | **Print** | **Print (flat)** |
|---|---|---|
| purpose | a finished print, still editable | maximum finishing headroom |
| colour | paper colour | **identical paper colour** |
| `scanner.white_correction` | on, 0.980 | off / widened |
| `scanner.black_correction` | on, 0.010 | off / widened |
| encoding | ProPhoto native γ1.8 | ProPhoto native γ1.8 |
| Layer 2 | optional — checkbox | optional — checkbox |

ProPhoto γ1.8 rather than linear TIFF: 16-bit integer linear stacks codes in the
highlights and steps visibly in the shadows. γ1.8 is ProPhoto's native encoding and both
Adobe apps treat it as a first-class case.

**Not PNG 16-bit.** Same intent, strictly worse container: ICC handling is unreliable,
Photoshop and Capture One support it less well than TIFF, files are larger, and there is
no float path. If a 16-bit deliverable is wanted, it is a TIFF.

**How much headroom this actually is.** The scan-normalisation margin between the paper's
Dmin/Dmax and 0/1 — roughly ⅓ to ⅔ stop at each end. Say so in the export panel. It is
enough for black and white point, mild contrast, taste shifts. It is not enough to recover
highlights or change overall tonality, because the paper's toe and shoulder are
irreversible compression: they *are* the look. Those moves belong to print exposure, in
Layer 1.

The Layer 2 checkbox is the meaningful choice here. Off exports the pure simulation and
lets the receiving app do everything. On bakes the adjustments already made, so the
external work continues from where this app left off.

### 6.2 Route B — finished

HEIF, JPEG, PNG 8-bit. Display P3, cctf encoded. **Layer 2 always baked in.**

These are deliverables, not intermediates. No headroom question arises, no checkbox.

HEIF is the default: better compression than JPEG at the same quality, native P3 and
10-bit support, and macOS handles it everywhere. JPEG for compatibility. PNG 8-bit for
lossless-but-small cases.

### 6.3 Which work belongs where

The test is whether the operation interacts with the paper curve.

| Layer 1, here | Layer 2, here or elsewhere | elsewhere only |
|---|---|---|
| stock choice | exposure, highlights, shadows | retouching, object removal |
| print exposure, filter pack | black/white point, curve | local sharpening, noise reduction |
| grain, halation | local exposure (approximate) | perspective and lens correction |
| dodge & burn (`Enlarger` masks) | | generative fill |

The right column is tonally inert — doing it after the print costs nothing, because it
never needed the paper's response. Route A's headroom exists for the middle and right
columns.

### 6.4 Details

Negative export (`io.scan_film`) is not in the main menu. It is a verification tool, not a
deliverable. Behind an option-key modifier or in a debug menu.

Filenames: `<original>_<film>_<paper>.<ext>` into `<source dir>/_prints/`, so a Capture One
folder sync picks it up without configuration.

---

## 7. Session and persistence

- **No project files.** The folder is the session. Open a folder or drag files in.
- **Sidecar per image:** `<original>.spektra`, JSON, next to the source. Never writes the
  source file.
  - schema version
  - decoder (`libraw` / `coreimage`) + version
  - film, paper
  - solve result (EV, filter pack)
  - offsets from solve
  - `grain_seed`
  - toggles
  - masks: stroke geometry (not rasterised — small and resolution-independent), value in
    stops, and target (`enlarger` / `after_print`)
  - Layer 2 adjustments: exposure, highlights, shadows, black/white point, curve control
    points, and the bypass state
- **Caches** in `~/Library/Caches/`, keyed by content hash, safe to delete: negatives
  (§1.1) and rendered thumbnails.
- Opening from Finder "Open With" or from a Capture One "Edit With" handoff works for
  single or multiple selection.

---

## 8. Build order

1. **Validate §1.3's assumption** — is `density offset → LUT` equivalent to `reprint` with
   grain and glare off? Everything about the interaction model depends on the answer.
2. Service: §1.1 disk cache, §1.2 split open, §1.3 buffer exposure, §1.4 grain seed.
3. Shell: browse grid, ImageIO thumbnails, session model, sidecar.
4. Canvas: Metal, P3, static render from `reprint` only. No live path yet.
5. Panel: stock, print, character. Verify the whole loop end to end.
6. Live path: Metal compositing, `preview` dot, tier scheduling.
7. Scope plots.
8. Layer 2: adjustments group, bypass switch, Metal shader stage, sidecar replay.
9. Tier 1 masks (gradient, radial, brush, luminance range), target `after_print`.
10. Tier 2 masks (Vision subject and person requests).
11. Export, both routes.
12. Later, if measured need justifies it: §1.5 and the `Enlarger` mask target.

Steps 3–5 produce something usable. Everything after is making it fast and complete.

---

## 9. Open decisions

| | |
|---|---|
| ~~Default stock pair~~ | **Settled: `kodak_portra_400` / `kodak_supra_endura`.** This is Layer 2's zero point (§3.1), not merely a default value. Cine pairs remain first-class in the picker per `API-SPEC §5`. |
| Flat export headroom | Whether to print slightly brighter before flat-scanning to reserve more room. Recommendation: no — flat should be the flat scan of *this* look, not a different one. |
| Illuminant match (§2.6) | Ship the two-position control or drop input WB entirely. |
| Core Image migration timing | Now (one decoder, one calibration) or after v1 (avoid re-solving everything mid-build). |
| Preview tier's future | §5.0's ROI rendering does what the 8 MP whole-frame preview tier was for, cheaper. Keep it as an idle whole-frame refresh, or drop the tier and let ROI cover inspection entirely. |
| Tier 3 masks (§5.2) | Whether SAM point-select is pulled into v1. The deciding factor is how often sky is the thing being burned — Vision cannot select it, and burning skies is the canonical use of the tool. |

---

## 10. Worth doing regardless

Shoot one comparison set: the same scene on real Portra, scanned, against Spektrafilm and
against Dehancer. The skin-tone judgement driving this project is currently n=1 and
untransferable — including to future-you, six months from now, deciding whether a change
made things worse. A reference frame is the only thing that settles that, and shooting film
is already something you do.
