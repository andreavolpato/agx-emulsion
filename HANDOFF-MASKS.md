# Handoff: masks (蒙版) — dodge and burn, and the interface for it

| | |
|---|---|
| **Status** | Designed in the frontend spec, drawn nowhere, built not at all. The sidecar has no field for it, the shader has no stage for it, and the engine has no surface for the physically correct version. |
| **Why it is not just plumbing** | The drawing this frontend was built from has **no mask interface in it**. Everything else in the app could be measured against `reference_layout/`; this has to be designed. That is the substance of this task, and §3 is a proposal, not a specification. |
| **Read first** | `modern_UI/frontend_architecture.md` for the layout and the two-layer rule. The mask model itself is `modern_UI/SPEC-spektrafilm-desktop-frontend.md` §5.2 item 3 and §1.5 (recover it from git — it is deleted in the working tree). |
| **Date** | 2026-09-08 |

---

## 1. What a mask is here, and what it is not

A mask is **a shape, a value in stops, and a target**. Nothing else.

That is narrower than Capture One's layers or Lightroom's masking, and the
narrowness is the point: the physical justification for this tool is that it
is what a printer's hands do under the enlarger. Dodging holds light back from
a region; burning adds it. There is no local contrast, no local saturation,
no local anything else, because none of those are things a pair of hands under
an enlarger can do.

Resist widening it. A mask that carries a full adjustment set is a different
product, and the moment it exists the two-layer architecture stops meaning
anything.

### The two application points

| target | applied | cost | physics |
|---|---|---|---|
| `Enlarger` | before the paper curve, via a per-pixel exposure multiplier | a `reprint`, ~200 ms | **correct** — this is dodging and burning |
| `After print` | Layer 2, in the client shader | < 1 ms | an approximation |

**Both exist deliberately.** `API-SPEC §2` measured the global version of
exactly this difference: +1 stop via `enlarger.print_exposure` against a flat
×2 gain on the print-referred tap gave **mean abs 0.126, max 0.343**, and the
visible signature was that the correct version compresses highlights as
exposure rises while the flat gain preserves the original contrast ratio.
Burning a sky after the print keeps the sky's original contrast instead of
acquiring the paper's rolloff — and that rolloff is the reason you burn a sky
in the first place.

But the size of that error scales with the adjustment. Half a stop is nearly
indistinguishable; two stops is not. And an AI-selected mask at half a stop is
very likely better than a hand-painted one at the physically correct stop.

**So `After print` ships first and is the default.** The mask geometry is
identical either way — only the application point changes — so nothing is
wasted, and how many stops you actually push in practice is what decides
whether the engine work in §5 is worth doing.

---

## 2. Mask sources

Where a mask comes from is orthogonal to what it does: every source produces
the same single-channel float texture, so adding sources does not widen the
parameter surface at all.

| tier | source | framework | note |
|---|---|---|---|
| 1 | linear gradient, radial, brush | own Metal | no dependencies |
| 1 | luminance range | own Metal | read from the **negative's density**, which is physically meaningful — "burn everything above this density" is a printer's instruction |
| 2 | subject / foreground | Vision | the "AI-fused" one — this is the model behind Apple's subject lifting |
| 2 | people, person parts | Vision | |
| 3 | point-to-select anything | SAM / MobileSAM via Core ML | separate model asset, deferred |

Tier 3 is what would cover **sky**, which Vision cannot segment and which is
the canonical thing to burn. That is the argument for pulling it forward; the
argument against is that it is a self-contained lump of model download,
versioning and Core ML conversion that couples to nothing else here. Decide it
on how often sky is the thing being burned.

### The Vision call, verified against this SDK

Both the classic `VN*` classes and the Swift-first API compile on macOS 15.
Use the Swift-first one. **This sequence typechecks** — the argument labels
are not the ones the older documentation suggests:

```swift
import Vision

let handler = ImageRequestHandler(ciImage)
let request = GenerateForegroundInstanceMaskRequest()
guard let observation = try await handler.perform(request) else { return }

let instances: IndexSet = observation.allInstances
let mask: CVPixelBuffer = try observation.generateMask(for: instances)
let scaled: CVPixelBuffer = try observation.generateScaledMask(
    for: instances, scaledToImageFrom: handler)
```

`GeneratePersonInstanceMaskRequest` and `GeneratePersonSegmentationRequest`
follow the same shape. All of it runs on the Neural Engine and costs almost
nothing at preview resolution.

**Store the click, not just the index.** `allInstances` is an ordered set and
an instance's index is only stable for one run of one model version. A mask
that stores "instance 2" will silently select something else after an OS
update. Store the **normalised point the user clicked** as well, and resolve
the instance by finding the one whose mask covers that point; keep the index
only as a hint.

---

## 3. The interface — a proposal

The drawing has no mask UI, so this is a design decision with reasoning
attached rather than a measurement to match.

### 3.1 Where the list lives: left panel, below Enlarger

```
  Film Profile
  Print Profile
  Camera
  Features
  Enlarger          ← base exposure and filter pack
  Masks             ← dodge and burn, after the base exposure is set
```

Three reasons for the left panel rather than the right:

1. **A mask's value is exposure in stops**, and the physically correct
   application point is the enlarger. That is Layer 1 in intent, whichever
   target it currently uses.
2. **It matches the order of the work.** A printer sets the base exposure and
   the filter pack, then dodges and burns. The section reads in that order.
3. **It keeps the layer boundary honest.** Putting a control that means
   "enlarger exposure, locally" in the Layer 2 panel would say the opposite of
   what it does.

The per-mask target chip carries the nuance: the section is Layer 1 in intent,
and the chip says whether this particular mask is applied there or
approximated after the print.

### 3.2 The section

A list of rows in a well, plus an add menu in the section's `•••`.

```
 ▽  ⬚  Masks                                              •••
┌──────────────────────────────────────────────────────────┐
│  ◉  Subject            −0.8 EV   After print        👁 ⌫ │
│  ○  Sky (gradient)     +1.2 EV   After print        👁 ⌫ │
│  ○  Brush 1            −0.3 EV   Enlarger           👁 ⌫ │
└──────────────────────────────────────────────────────────┘
```

- **Selected row** carries the white frame, exactly as the film and paper
  lists do. Selecting a row is what puts the canvas into editing that mask —
  there is no separate mask tool in the top bar, which keeps the top bar
  matching the drawing and matches how Lightroom enters masking.
- **Expanding a row** (or selecting it) reveals its controls in the same well:

| control | for | notes |
|---|---|---|
| Amount | all | `ScrubSlider`, stops, −3…+3, zero tick at 0, double-click to reset |
| Target | all | `After print` / `Enlarger` — `Enlarger` disabled with a one-line reason until §5 lands |
| Invert | all | |
| Feather | gradient, radial, subject | in per-cent of the shorter edge |
| Size / Flow | brush | |
| Range | luminance | two handles over the negative's density histogram — reuse `HistogramPlot` |
| Refine | subject, person | grow / shrink in pixels, then feather |

- **Add** from the section menu: Brush · Linear Gradient · Radial · Luminance
  Range · Subject · People. The Vision entries run immediately on the
  live-tier preview and drop a finished mask into the list.

### 3.3 On the canvas

- While a mask row is selected, the canvas draws the mask as a **red 50 %
  tint**, the convention every comparable app uses, with a "show overlay"
  toggle in the section header for checking the print underneath.
- Geometric masks draw with handles: a gradient shows its axis with two grips
  plus a rotate handle; a radial shows its ellipse with four grips and a
  feather ring.
- Brush strokes paint on drag, `⌥` erases, `[` and `]` size the brush — the
  bindings every painting app shares.
- Vision masks are not editable by hand in v1. If refinement turns out to be
  needed, add brush-on-top-of-generated rather than making the generated mask
  a stroke list.
- `Escape` deselects the mask and returns the canvas to the current tool.

### 3.4 What this costs in the existing layout

Nothing structural. It is one more `PanelSection` in `LeftPanel`, one more
canvas interaction mode alongside crop, and one more overlay in the shader.
The four cards, their geometry and the two-layer rule are untouched.

---

## 4. Implementation shape

### 4.1 Storage — geometry, never pixels

In the sidecar, per mask: a `kind`, its geometry, `amountStops`, `target`,
`inverted`, `feather`, and for Vision masks the request type plus the
normalised seed point. Strokes are points with radius and flow.

Geometry is small and resolution-independent; a rasterised mask is neither,
and at 45 MP it is 90 MB per mask. This is `Sidecar`'s existing pattern —
`CropRect` is normalised for the same reason.

### 4.2 Rasterisation — one texture, not N

Masks are additive in stops, so accumulate all of them into a **single
`r16Float` texture holding the local exposure offset in stops**, rebuilt
whenever any mask changes and cached until then. The shader then samples one
texture regardless of how many masks exist.

Build it with a compute kernel per mask kind (gradient and radial are
closed-form; brush is stamps along the stroke; luminance reads the negative;
Vision masks upload the `CVPixelBuffer` and scale it).

### 4.3 The shader stage

`After print` masks belong in `layer2` in `Shaders.metal`, and they must go
**where global exposure goes** — in the pseudo-linear domain, so that "one
stop" means one stop:

```metal
// after white balance, before contrast — the same place exposureGain acts
float stops = maskStops.sample(lin, uv).r;
if (stops != 0.0) {
    c = pow(max(c, 0.0), 2.2) * exp2(stops);
    c = pow(c, 1.0 / 2.2);
}
```

Add `maskStops` as a third texture on the existing kernel and one flag in
`Layer2Uniforms`. Order of operations is fixed and documented; masks go after
exposure and before the curve, matching the spec's fixed order.

### 4.4 Resolution

Geometric masks are generated at whatever resolution they are drawn into, so
they are free. Vision masks must be **regenerated at export resolution**, not
upscaled from the preview — `generateScaledMask(for:scaledToImageFrom:)` takes
the handler, so run the request again against the full-resolution image at
export time. Budget for it: it is the only part of the mask path that is not
instant.

---

## 5. The engine gap, for the `Enlarger` target

This is the only genuinely new engine surface in the whole frontend spec:

```
reprint {session_id, params_delta, exposure_mask?}
  exposure_mask: {path, shape}     # single-channel float, stops, 0 = neutral
```

The printing stage must accept a per-pixel exposure multiplier where it
currently takes a scalar. Physically it is exactly what it says: more or less
enlarger exposure over a region, so the held-back region then travels the
paper's characteristic curve at its new position and picks up the rolloff that
belongs there.

The client writes the mask to the workspace as a raw `.npy`-style dump and
passes the path — the same file-handoff convention `rgba16` output already
uses, since a full-resolution float mask must not go through JSON.

**Do not build this first.** Ship `After print`, watch how many stops actually
get pushed, and let that decide. The measurement to make is trivial and worth
recording: log the distribution of `amountStops` across a few weeks of real
edits.

---

## 6. Build order

1. The section, the list, and one mask kind — **linear gradient**, `After
   print` only. Proves the whole path: sidecar → geometry → texture → shader.
2. Radial and brush. Same path, more kernels.
3. The canvas overlay and handles. This is where the interaction design
   either works or does not, and it is worth iterating on before adding
   sources.
4. Vision subject and people. Roughly twenty lines of request plumbing given
   §2's verified sequence, plus the seed-point resolution.
5. Luminance range from the negative's density.
6. Export path: regenerate Vision masks at full resolution, bake into the
   exported file.
7. Only then, if the stops justify it: §5's `exposure_mask` and the
   `Enlarger` target.

---

## 7. Open questions

1. **Is one list right, or one list per target?** The spec says one list with
   a per-mask target, and that is what §3 proposes. If in practice every mask
   ends up on the same target, the chip is noise and the section header should
   carry it instead.
2. **Should a mask be able to move between targets after the fact?** The
   geometry is identical, so technically yes, and it would make the
   approximation-versus-correct comparison a one-click A/B. That is a good
   argument for building the chip as a real toggle rather than a label.
3. **Sky.** Vision cannot do it, tier 3 can, and it is the canonical burn.
   This is the single biggest factor in whether the feature feels finished.
4. **Does the red overlay fight the image?** Every app uses it and every app's
   users turn it off. Consider a marching-ants outline as the default and the
   tint on a held key.
