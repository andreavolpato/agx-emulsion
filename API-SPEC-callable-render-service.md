# API Spec — Callable Render Service (implementation reference)

| | |
|---|---|
| **Status** | Reference for implementation. Not a rewrite of the engine — see `PRD-callable-render-api.md` for product rationale, this doc for exact call sequences. |
| **Read this if** | You are the session building the Tauri-facing service, or the frontend that calls it. |
| **Probe evidence** | `tests/baseline/probe_callable_api.py` — run it, results below are from an actual run, 2026-08-25, on the 16 MP reference image. |
| **Date** | 2026-08-25 |

This document exists because the PRD's §11 open questions turned out to be
answerable by reading and running the existing engine, not by designing new
engine surface. Everything below was verified against `src/spektrafilm`, not
assumed. Where a claim is "confirmed", it means: read the source, or ran it,
or both — file:line citations are given so you can re-verify after the code
moves.

---

## 1. The three calls that matter, mapped to engine code

Do not build a new abstraction layer. `SimulationPipeline` already has the
three primitives a render service needs:

| service call | engine call | confirmed |
|---|---|---|
| `open` | `pipeline = SimulationPipeline(digest_params(params)); negative = pipeline.process(image, inject=Tap.RGB_IN, collect=Tap.CMY_FILM)` | `pipeline.py:107-142`, `topology.py:125-215`. Live in production: `scripts/scan_negative_demasked.py:142`. |
| `reprint` | mutate `pipeline.enlarger.*` / `pipeline.print_render.*` / `pipeline.scanner.*` **in place on the same `pipeline` object**, then `pipeline.process(negative, inject=Tap.CMY_FILM, collect=Tap.RGB_OUT)` | Bit-exact equivalence to a from-scratch full render with the same params, verified below (§2). |
| full render (shoot-side change) | new `SimulationPipeline(digest_params(new_params))`, `pipeline.process(image)` (defaults: `inject=RGB_IN`, `collect=RGB_OUT`) | Standard path, unchanged. |

`SimulationPipeline.process`'s `inject`/`collect` kwargs are the entire
mechanism. `TapsParams` (`runtime/params_schema.py:208-217`) even carries
these as schema fields already, so a params-delta JSON patch can set them
directly instead of the service special-casing tap selection.

**Do not use `Pipeline.soft_update()`** (`pipeline.py:166-195`) for the
service's `reprint`/`set_params`. It's a narrower, older mechanism — in-place
field mutation plus a recompute of the midgray print-balance reference, no tap
re-seeding — that the current `spektrafilm_gui` doesn't even use (see §3). It
predates the tap-alias system `prune_identity_nodes` builds and can drift from
it. Build on `inject`/`collect` instead; it is what `scan_negative_demasked.py`
already validates in production.

---

## 2. Confirmed: reprint is cheap AND bit-exact — with one caveat

Ran `tests/baseline/probe_callable_api.py --no-matrix` on the 16 MP reference
(`tests/baseline/_DSC2439_16mp_linear_prophoto.tif`), grain and glare disabled
(see caveat below):

```
open (rgb_in -> cmy_film):          2.65s
reprint (cmy_film -> rgb_out):      3.15s
full re-render (rgb_in -> rgb_out): 5.05s
max abs diff:  0.000e+00
mean abs diff: 0.000e+00
reprint speedup vs full render: 1.6x
RESULT: PASS
```

Bit-exact, not just close. This is the strongest evidence the PRD's cache
architecture (§2-3) is sound: `reprint` really is "the same computation,
minus the film-side nodes", not an approximation.

**Caveat — grain and glare are unseeded by design (RFC-002 / RFC-008).**
`settings.grain_sampler = 'stochastic'` draws a fresh Poisson realisation on
every independent `SimulationPipeline` construction; glare does the same. Two
independently-built pipelines with identical params will *not* be pixel
identical unless both are disabled, or unless the same pipeline instance is
reused for both draws being compared (which `reprint` naturally does — the
grain realisation is already baked into the cached `Tap.CMY_FILM` negative
and is not re-drawn on reprint, since the film-side nodes don't fire). In
other words: **within one session, reprint is grain-consistent for free**
(the whole point of caching the negative) — the equivalence *test* just has
to disable stochastic sources to compare against an independently-built
full-render pipeline, which draws its own separate grain. Don't read the
15 MP/16 MP timing numbers above as the real product budget — see PRD §6 for
that; this run's numbers are just proof of the caching mechanism, not a perf
budget (they're CPU/current-repo-state dependent).

**16 MP full-render absolute time (~5-7s here) is faster than the PRD's
45 MP number (24.3s) as expected** — but note this run used
`working_precision` and `spectral_backend` defaults from `init_params`, not
necessarily the RFC-007/008-tuned settings the 45 MP number was measured
under. Don't use this run's absolute seconds for the §6 tier decision;
re-measure at 45 MP with the settings the service will actually ship with.

---

## 3. Current GUI does not use either cheap path

`spektrafilm_gui/controller.py:644` calls `self._runtime_simulator.process(image_data)`
with no `inject`/`collect` and no `soft_update`. Every slider nudge in the
existing Tk/napari frontend re-runs the full pipeline. This is why the user
describes it as unusable for interactive work, and it's the concrete baseline
the new service should be measured against — "faster than the current GUI"
is a low, well-defined bar; "faster than the §6 tier for the interaction it's
driving" is the real target.

---

## 4. Mandatory vs toggleable parameter layers (for the frontend)

This is the frontend contract, grounded in what the engine actually gates and
verified visually via `tests/baseline/probe_callable_api.py` (contact sheet
at `tests/baseline/out/callable_api_probe/contact_sheet.png`, 8 labeled
variants, 16 MP reference image, rendered 2026-08-25).

**Corrected 2026-08-25: the first version of this contact sheet was visibly
wrong (flat, hazy, low-contrast) and it was a bug in the probe script, not
the engine — worth recording so it isn't re-litigated.** `io.output_cctf_encoding
= True` means the pipeline's own `scanning.cctf` node (`pipeline.py:317-322`)
already applies the display OETF before `process()` returns — the array is
already gamma-encoded. The probe's PNG display helper applied a *second*
`**(1/2.2)` gamma on top for "display", which raises every value toward mid-
grey and crushes contrast — this is a double-encoding bug, not a color-
management bug, and it only ever affected the probe's own contact-sheet PNG,
never the TIFF/EXR the engine actually writes. Also corrected in the same
pass: the probe was set to `output_color_space="sRGB"`; this project's
reference convention is ProPhoto RGB in / **Display P3** out (matches
`tests/baseline/out/compare_rfc004_p0_p1_p2_displayp3.png` and
`run_reference.py`'s own defaults), so the probe now renders Display P3 and
the contact-sheet PNG converts P3 primaries to sRGB primaries
(`colour.RGB_to_RGB(..., apply_cctf_decoding=True, apply_cctf_encoding=True)`)
purely for correct display in a plain, non-color-managed PNG viewer — the
saved `variant_NN.tif` files stay in Display P3, matching the product's real
output. **Lesson for whoever writes the service's own preview/thumbnail path:
never hand-roll a gamma curve on an array that already went through
`output_cctf_encoding`; either display it as-is (already encoded) or convert
primaries only, never re-apply an OETF.**

| layer | mandatory? | what "off" means in the engine | confirmed in contact sheet |
|---|---|---|---|
| **film + paper stock** | **mandatory** — `RuntimePhotoParams.film`/`.print` are non-optional constructor args and `__post_init__` raises `TypeError` if either isn't a `Profile` (`params_schema.py:282-286`) | N/A — no "off" state exists | variant 1 (film/paper swapped `kodak_portra_400`/`kodak_portra_endura` → `kodak_ektar_100`/`kodak_ektacolor_edge`) visibly changes color response — confirms stock selection actually propagates to the render, not just metadata |
| **enlarger (printing stage)** | optional, as a *whole stage bypass* | `io.scan_film = True` skips the entire printing stage and scans `Tap.CMY_FILM` directly (`pipeline.py:325-341`) — this is the real "disable the enlarger" toggle, not a per-param flag | variant 2 — dramatically different (raw orange negative, inverted tone) because it's genuinely a different pipeline path, not the same print with the enlarger's contribution zeroed. **UI implication: don't expose this as a subtle checkbox; it changes what the artifact *is*** (a scanned negative vs a printed positive), matching PRD §9's demask-negative distinction |
| **scanner** | optional per-correction | `scanner.white_correction`, `scanner.black_correction` (bool), `scanner.unsharp_mask` (tuple, `(0,0)` = off), `scanner.lens_blur` (float, `0` = off) — no single master switch | variants 3 (on) vs 4 (off) — visibly different tonal range/sharpness, confirms these flags reach the render |
| **grain** | optional | `film_render.grain.active` + `.sublayers_active` (both bool) | variant 5 — looks like a no-op at contact-sheet thumbnail scale, but is not: pixel diff against baseline is mean 0.011 / **max 0.52** (measured directly on `variant_00.tif` vs `variant_05.tif`, full res, Display P3). It's real, high-frequency, and gets averaged away by thumbnail downsampling. **Always check 100% crops for grain, never the contact sheet** — the thumbnail will make a working toggle look broken. |
| **halation** | optional | `film_render.halation.active` (bool) | variant 6 — same story: mean diff 0.017 / **max 1.21** against baseline, invisible at thumbnail scale on this flat-lit studio frame because halation is highlight-driven (see PRD §5's halation-boost note) and this frame has no strong specular/backlit source. Confirmed working, just not visible in the grid — **re-test on a frame with a bright practical light or backlit edge if a human needs to visually confirm it, don't rely on this contact sheet for that.** |
| **hue** | **does not exist — do not add one** | no code path | variant 7 uses `enlarger.y_filter_shift`/`m_filter_shift` (the physically real "color mood" lever) instead — visibly a magenta/green cast, correctly not framed as "hue" in the UI copy. See PRD §5's dedicated hue note for the reasoning: color is produced by the spectral dye simulation, not graded, so a generic hue/saturation slider would be the same category of dishonesty as the gain/temp/tint non-goal already in the PRD. If a future session is asked for a "color" slider by a designer who doesn't know this, point them at the filter pack + stock picker, not a new HSV node. |

**Test-writing note for whoever wires this into `set_params`/`params_schema`
validation (PRD §8):** film/paper should be validated as required fields at
the transport-schema level (reject a request missing either, don't let it
fall through to a `TypeError` from `__post_init__`). Every other toggle in
the table above is a normal optional field with an engine-defined default —
the schema's `default` annotation (PRD §8) should match the `dataclass`
default in `params_schema.py`, not be re-decided by the frontend.

---

## 5. Multi-tier resolution architecture — measured, not projected

The frontend needs three resolution tiers, not two: a live-edit tier for
slider drag, a preview tier large enough to actually judge grain/halation
(per §4's finding — both are invisible at small scale, so "preview" must be
big enough to read them), and the real full-resolution export. Measured on
the 16 MP reference image, M-series Mac, `spectral_backend='mlx'`:

| tier | resolution | mechanism | measured time | measured peak RSS |
|---|---|---|---|---|
| **live-edit** | 2 MP (e.g. 1154×1732) | full render (film+print+scan), `gpu_backend=''` (CPU dispatch) | **1.17 s** | 1.39 GB |
| **live-edit, reprint only** | 2 MP | `reprint` from cached negative (`inject=Tap.CMY_FILM`), `gpu_backend=''` | **~390 ms** warm | — |
| **live-edit, reprint only, GPU+f32** | 2 MP | same, `gpu_backend='mlx'`, `working_precision='float32'` | **~260 ms** warm | — |
| **preview** | 8 MP (e.g. 2308×3465) | full render | **3.60 s** | 3.59 GB |
| **full** | 45 MP | full render (cited from RFC-008 Part B, not re-measured this session — re-measure at the settings the service actually ships with, see PRD §6) | 24.33 s | 12.34 GB |

**Reading these numbers against PRD §6's interaction tiers:**
- Full-pipeline 2 MP (1.17 s) does **not** hit the "<100ms real-time drag"
  tier — a shoot-side param change (which invalidates the negative and must
  run the full pipeline even at preview res) lands in PRD §6's
  "100ms-500ms: drag with down-res preview, release for full frame" tier, or
  worse, at 2 MP.
- **`reprint`-only at 2 MP (260-390 ms warm) is the number that actually
  matters for the primary interaction** — PRD §0's "sliders exist to
  *override* the auto-solve" model means print-side sliders (exposure,
  filter pack) are the sliders a user drags continuously, and those go
  through `reprint`, not a full render. This is close to real-time already
  and is the strongest argument for building `reprint` on `inject`/`collect`
  (§1-2) rather than anything else — it's the only path in this table with a
  realistic shot at feeling instant.
- Getting shoot-side changes (which do invalidate the negative) under
  100-500ms at usable preview resolution is the actual open engineering
  problem, not something these numbers solve. `warm-up`/JIT costs (numba,
  ~0.4s first-call) are separate from these steady-state numbers — reuse one
  long-lived pipeline object across a session, not a fresh
  `SimulationPipeline()` per request, or every request pays JIT again.

**Three concrete resolution tiers for the service, following from the
table:**
1. **Live-edit (2 MP or smaller):** always driven by `reprint`
   (`inject=Tap.CMY_FILM`) against a *preview-resolution* cached negative —
   not the full-res one. This means the service caches **two** negatives per
   session, not one: a small one for drag-responsiveness, and the real one
   at working resolution for `export`. Re-render the small negative only
   when a shoot-side param changes (rare, by PRD §0's own design — "sliders
   exist to override the auto-solve", implying most drag interaction is
   print-side).
2. **Preview (8-12 MP):** the tier a user checks grain/halation at before
   committing to a full export. Given §4's finding that these effects are
   easy to miss below 100% crop, this tier exists specifically so a user can
   *see* what they're toggling, not just get a faster preview of color.
   Consider a "zoom to 100%" affordance in this tier rather than only ever
   showing the whole downscaled frame — the whole point is to catch grain
   and halation, which downscaling itself partially erases.
3. **Full (working resolution, up to 45 MP):** `export` only, always shown
   as a progress state per PRD §6, never blocking.

## 6. Memory budget and disk-spill cache design

**Problem this section is for:** PRD §7.2 scopes the service to "one
service, one session, one workspace" — a single open image at a time. Even
within that single-image scope, the three-tier design in §6 above means the
service now holds **multiple resident buffers simultaneously**: a live-edit
negative (2 MP), a preview negative (8-12 MP), and the working-resolution
negative (up to 45 MP), plus whatever the last few `reprint` outputs were if
the frontend wants instant undo/redo across print-side history. At 45 MP a
single float32 RGB buffer is ~0.54 GB (PRD §7.4); the negative tap is the
same order of magnitude. None of this is the "10+ open images" problem a
general asset-management cache would solve — it's "a handful of same-image,
different-resolution/different-history buffers," which is a much smaller and
more tractable problem than a general LRU-over-everything cache.

**Design: a small, explicit, capacity-bounded buffer table, not a generic
cache.**

- The service tracks a fixed, named set of resident buffers per session:
  `{live_negative, preview_negative, working_negative, last_export}` plus a
  bounded ring of recent `reprint` outputs for undo (size configurable,
  default small — e.g. 8 entries at live-edit resolution only, never at
  working resolution).
- Each buffer has a declared resolution tier, so the memory cost is
  predictable up front, not discovered at runtime: live (2 MP) + preview
  (8-12 MP) + working (up to 0.54 GB at 45 MP) + a small undo ring is on the
  order of 1-2 GB total resident — nowhere near the 12+ GB single-render
  peak PRD §6 already documents, because these are cached *taps*
  (post-film-side, pre-print), not the ~7 live intermediate buffers a single
  `run_topology` call holds transiently (and which `free_taps` already frees
  as it goes — see `topology.py:143-149,201-204` — that part of the memory
  story is already handled by the engine, don't re-solve it at the service
  layer).
- **Spill policy:** when the *working-resolution* negative is not the active
  render target (user is dragging live-edit sliders, hasn't touched a
  shoot-side param in N seconds), write it to the session workspace as a
  `.npy` (not re-encoded — a raw dump, so reload is a `mmap`/`np.load`, not a
  decode) and drop the in-memory reference. Reload it lazily the moment
  `export` or a resolution-tier switch needs it. This is the "manually dump
  to disk past a cap" mechanism — but scoped to one specific, predictable
  buffer (the working negative), not a generic cache eviction policy,
  because there's only ever one session and a small, known set of buffers to
  manage.
- **Hard cap as a backstop, not the primary mechanism:** track process RSS
  (same `resource.getrusage(...).ru_maxrss` used throughout this repo's own
  benchmarking scripts, e.g. `tests/baseline/run_reference.py:24-26`) and if
  it crosses a configured ceiling (e.g. 80% of a conservative fraction of
  system RAM), force-spill the working negative and the undo ring
  immediately, before starting the next render — never let a render *start*
  against a buffer table that's already near the ceiling, since PRD §7.6
  already establishes single-flight (one render at a time), so the check has
  a clean place to run: at the top of every service method that's about to
  call `pipeline.process`.
- **What NOT to build:** a general LRU cache with arbitrary keys, TTLs, or
  multi-image eviction. That's solving a multi-session/multi-image problem
  this PRD explicitly doesn't have (§7.2's "one session" scope). If a future
  version adds roll/contact-sheet batch handling (PRD §4, batch solve), that
  is the point to revisit this section — not before, and it should be a new
  RFC, the same way RFC-009 is a new RFC for the fast-look path rather than
  a quiet addition here.

## 7. Experimental non-physical fast-GPU look path

See `rfc/RFC-009-experimental-fast-gpu-look.md` for the full writeup. Short
version: a from-scratch, all-MLX path (`scripts/experimental_fast_gpu_look.py`)
that skips the spectral integral, the measured characteristic curves, and the
Poisson grain model entirely — 202 ms / 1.09 GB peak RSS at 16 MP against the
real pipeline's ~7 s / several GB, a genuine ~35x speedup, **but the
prototype's specific look is flat and lower-contrast than the real pipeline**
(side-by-side: `tests/baseline/out/experimental_fast_gpu_look/comparison.png`)
and needs real color-grading iteration before it's worth shipping, not
another engineering pass. If it ships, it must be an explicit, clearly-labeled
opt-in `render_mode`, never a silent fallback or a "fast preview" default —
see RFC-009 §0, §3.

## 8. Re-running the probe

```
python tests/baseline/probe_callable_api.py                  # both checks
python tests/baseline/probe_callable_api.py --no-matrix       # equivalence only (~15s)
python tests/baseline/probe_callable_api.py --no-check-reprint # contact sheet only (~50s)
```

Outputs land in `tests/baseline/out/callable_api_probe/`:
`contact_sheet.png` (labeled grid, for eyeballing), `variant_00..07.tif`
(full-res float32, for 100% crops — needed for grain/halation per the table
above), `reprint_vs_full.exr` (the diff image, all-zero on a pass).

This script is deliberately **not** part of the pytest suite — it makes no
engine behavior changes, so there's nothing to gate strictly; it's a probe to
re-run by hand whenever the reprint mechanism or the mandatory/optional
param table above is in question, e.g. after a future engine change touches
`run_topology`, `prune_identity_nodes`, or any of the enlarger-service
attribute reads this doc's §1-2 depend on staying live-mutation-safe.
