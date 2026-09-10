# ARCHITECTURE.md

How the spektrafilm runtime is put together, with the performance and memory
characteristics measured on this fork. Written for someone about to modify the
pipeline.

**§0 is the map of the whole product** and is the section to read if you have
just arrived. §1–§6 are the render pipeline and are unchanged in numbering
(RFC-003 cites §3). §7 is the macOS frontend, §8 is the executor layer and the
native host that does not exist yet.

---

## 0. The product, end to end

spektrafilm is two programs and a pipe. Nothing in the repo is a single
application, and most confusion in past sessions came from reasoning about one
half while the other was the thing that had changed.

```
  ┌─ modern_UI/Spektrafilm ──────────────┐        ┌─ src/spektrafilm ─────────────────┐
  │  SwiftUI + Metal, macOS app          │        │  Python render service            │
  │                                      │        │                                   │
  │  Session (@Observable, @MainActor)   │        │  service/service.py   the wire    │
  │  Renderer  ── Metal canvas, Layer 2  │        │  service/engine.py    the engine  │
  │  ServiceClient ──────────────────────┼── () ──┼─▶ runtime/pipeline.py  ~24 nodes  │
  │                                      │ stdio  │        │                          │
  │  RAW decode (Core Image)             │        │        ├─ backends/metal  (GPU)   │
  │  linear TIFF ────────────────────────┼─ file ─┼─▶      ├─ numba          (CPU)    │
  │  ◀──────────────────── rgba16 dump ──┼─ file ─┼──      └─ reference      (CPU)    │
  └──────────────────────────────────────┘        └───────────────────────────────────┘
```

**The pipe** is newline-delimited JSON-RPC 2.0 over stdio, nine methods, frozen
by `CONTRACT-frontend-backend.md` §1. Small values travel in JSON; images
travel as **paths to files**, never inline and never through shared memory.
The app writes a linear ProPhoto TIFF for `open` and reads back a raw
`rgba16` dump per render (row-major, row 0 = top, Display-P3 *encoded*
uint16). At 45 MP that TIFF is 364 MB in each direction, which is the single
biggest architectural cost in the product and the subject of RFC-012.

**The app spawns the service itself**: it walks up from its own bundle to a
directory containing `src/spektrafilm`, then runs `<repo>/.venv/bin/python -m
spektrafilm.service`. There is one long-lived process per launch and the
transport is single-flight by default.

### Who owns what

`CONTRACT-frontend-backend.md` §4 splits the repo between two concurrent
sessions and is binding:

| path | owner |
|---|---|
| `modern_UI/**` | frontend |
| `src/**`, `tests/**`, `scripts/**`, `rfc/**` | backend |
| `AGENTS.md`, `ARCHITECTURE.md`, `API-SPEC-*`, `CONTRACT-*` | **neither** — say so before editing |

Read the contract before changing anything that crosses the pipe. A field
name, a tier name, a file layout or a version number is a wire change even
when it looks like a refactor — see §8.4.

### Where to read more

| topic | file |
|---|---|
| the wire, ownership, version negotiation | `CONTRACT-frontend-backend.md` |
| the service's methods and semantics | `API-SPEC-callable-render-service.md` |
| the frontend in detail | `modern_UI/Spektrafilm/README.md` |
| the GPU-native render core | `rfc/RFC-011-gpu-native-render-core.md` |
| why the Python process is still here | `rfc/RFC-012-consistent-backend-process.md` |
| what the frontend does when the host lands | `HANDOFF-NATIVE-HOST.md` (nothing) |

---

## 1. The physical model

The simulation walks a photograph through four physical stages:

```
scene light → [camera+film] → latent image → [development] → negative dye densities
            → [enlarger+paper] → latent print → [development] → print dye densities
            → [scanner/viewing] → output RGB
```

Colour is modelled **spectrally**, not as RGB matrices. The spectral axis is
`SPECTRAL_SHAPE = (380, 780, 5)` → **81 wavelengths**, fixed in `config.py`.
Density curves are sampled on `LOG_EXPOSURE = linspace(-3, 4, 256)`.

Three distinct transforms carry the colour:

**(a) RGB → film exposure** — Hanatos 2025 spectral upsampling
(`utils/spectral_upsampling.py`). Input RGB becomes XYZ under CAT16 adaptation
to the film's reference illuminant, splits into brightness `b = X+Y+Z` and
chromaticity `xy`, and `_tri2quad` warps the xy triangle into a unit square.
A 192×192×81 LUT of irradiance spectra is indexed by that coordinate, then
collapsed **at build time** against the film's spectral sensitivity into a
192×192×3 `tc_lut`. Runtime is a bicubic 2D lookup times `b`. The 81-axis
never touches the image here — this half was already optimal.

**(b) Exposure → density** — `interpolate_exposure_to_density` against 256-sample
characteristic curves, then DIR couplers (a 3×3 donor→receiver inhibition
matrix applied to silver density, spatially diffused, subtracted from log
exposure, re-interpolated against back-solved pre-coupler curves), then grain.

**(c) Density → light → response** — the spectral integral:

$$\text{out}_m = \sum_{\lambda} I(\lambda)\,S_m(\lambda)\;10^{-\left(\sum_k c_k D_k(\lambda) + D_{\text{base}}(\lambda)\right)}$$

Runs twice: in printing (S = paper sensitivity, I = enlarger illuminant) and in
scanning (S = CIE 1931 CMFs, I = viewing illuminant). **This was the memory
sink** — see §4.

---

## 2. Runtime structure

```
runtime/
  pipeline.py      SimulationPipeline — builds services + stages, owns topology
  topology.py      Node / Tap / run_topology — the dispatcher
  process.py       Simulator, simulate(), simulate_preview()
  params_schema.py all parameter dataclasses
  params_builder.py init_params(), digest_params()
  stages/          filming.py, printing.py, scanning.py
  services/        resize, enlarger, spectral LUT cache, colour reference
```

The pipeline is a **tap graph**. Each `Node` declares which taps it reads and
writes; `run_topology` fires nodes whose inputs are present and returns when
the requested `collect` tap exists.

```
rgb_in → preprocess → rgb_pre → filming.expose → log_e_film
       → filming.develop → cmy_film → printing.expose → log_e_print
       → printing.develop → cmy_print → scanning.scan → rgb_out
```

Taps are addressable: `pipeline.process(img, collect=Tap.CMY_PRINT)` returns an
intermediate. **This is the best debugging tool in the codebase** — bisecting a
discrepancy by tap localises it in one pass.

`io.scan_film = True` swaps the print+scan branch for a direct film scan.

### Node granularity (resolved by RFC-003)

The graph was six nodes, each bundling several physically distinct effects.
RFC-003 split it into ~24 effect-level nodes, which is what made per-node
backend selection, per-node precision, and dead-node elimination possible.
`_declare_topology` builds the full graph; `_build_topology` returns it after
`prune_identity_nodes` has dropped the no-ops and aliased their taps.

Each `Node` carries `kind` (pointwise / spatial / stochastic), `support` (halo
px, `inf` for global operators), `backend`, `precision`, and `run_mlx`. That
contract surface is also the seam a future native backend would attach to: a
`run_native` alongside `run_mlx`, ported node by node against the Python
float64 reference (RFC-007 5).

---

## 3. Stage classification

The partition that matters for any port:

| class | stages | shape |
|---|---|---|
| **pointwise** | spectral upsampling, boost, curves, both spectral integrals, gamut compression, XYZ→RGB, CCTF | fused elementwise; parallelises with no halo; LUT-able in principle |
| **spatial** | diffusion filter, lens blur, scatter, halation, DIR coupler diffusion | separable convolutions; tiling needs halos |
| **stochastic** | grain, **glare** | needs counter-based RNG for reproducibility/tiling |

Glare being stochastic is easy to miss and is the source of the pipeline's
default nondeterminism (see AGENTS.md).

---

## 4. Memory model

Per-pixel cost of live buffers, float64:

| buffer | bytes/px |
|---|---|
| `(H,W,3)` | 24 |
| `(H,W,81)` | 648 |
| `(H,W,81) bool` | 81 |
| `(H,W,3,3)` grain sublayers | 72 |

**The original sink**: the spectral stages materialised `density_spectral`
(648) + `transmitted` (648) + a NaN mask (81) ≈ **1.4 kB/px**, twice. At 45 MP
that is ~63 GB.

**The fix** (`utils/fused_spectral.py`): the integral is 3-in/3-out, so the
81-axis can live in registers. Measured **1944 → 24 B/px, 81× less, 32×
faster, exact to 2.4e-15**.

Secondary costs that remain:

- `run_topology` used to accumulate every tap in one dict and free nothing —
  7 × `(H,W,3) float64` = 168 B/px at once. `free_taps` now drops each tap once
  its last reader has fired, and (RFC-005) does so *before* the per-node
  precision cast, since the cast allocates a second buffer for the same tap.
- `_preprocess` (`pipeline.py:192`) upcasts float32 input to float64.
- `printing.py:80` allocated a `zeros_like` that was immediately overwritten
  (**removed**).
- The `log10` → `10**` round trip between the spectral call and its caller —
  two full-image transcendental passes that cancel, present only because the
  optional LUT interpolates in log space. Still present.
- NumPy expression chains allocate one full-resolution temporary per operator.
  Measured on the CAM16 gamut compression: **19.67× the input** in temporaries,
  ~20 GB of churn at 45 MP for one stage. Fusing it into a single numba pass
  brought that to 2.00× (RFC-007 A). This is the dominant remaining allocation
  pattern wherever a stage is still written as NumPy expressions.
- MLX's device buffer pool held **1.76 GB with active memory at 0.00 GB**.
  Full-resolution runs now cap it to zero (`unpooled_device_memory`); preview
  runs keep it, since there the next render is imminent. This is what collapsed
  the run-to-run spread in peak RSS from 1.80 GB to 0.20 GB.
- Python's cyclic GC is **not** a lever here: rendering with `gc.disable()`
  changes peak RSS by 0.01 GB. The collector reclaims 415 objects across a full
  render, none of them arrays, and zero arrays over 50 MB are reachable through
  cycles. NumPy buffers are freed by refcount. Tap dtype, reference lifetime,
  and promotion copies are what govern the footprint.

---

## 5. What has been added on this fork

```
utils/fused_spectral.py       fused spectral integral (numba), exact
utils/fused_gamut_cam16.py    fused CIECAM16 gamut compression (RFC-007 A)
utils/fused_tc_b.py           fused front half of spectral upsampling
utils/spectral_dispatch.py    backend switch: reference | numba | mlx
utils/parallel_pointwise.py   chunked thread-parallel wrapper for pointwise stages
utils/precision.py            working_precision invariant (RFC-006)
utils/lazy_colour.py          keeps colour-science out of the import path (RFC-012)
model/colour_baked.py         21.9 KiB of baked constants replacing 148 MB of deps
data/baked/colour_constants.npz
backends/mlx_spectral.py      custom Metal kernel via mx.fast.metal_kernel
backends/metal/               the GPU-native render core (RFC-011) — see §8
service/                      the JSON-RPC render service — see §0 and §8.3
modern_UI/Spektrafilm/        the macOS app — see §7
tests/baseline/               baseline generation, instrumented runner, ΔE harness
scripts/gpu_native/           parity harness + the native-host spike (§8.5)
rfc/RFC-001 … RFC-012
```

The spectral backend is `params.settings.spectral_backend`, and its default is
**`"mlx"`**, not `"numba"` — MLX-first since RFC-001; if MLX is unavailable the
render raises rather than silently dropping to CPU. The whole-pipeline
executor is a separate axis: `params.settings.gpu_backend`, `"metal"` for the
GPU-native core of §8.

`parallel_pointwise` is wired into three call sites in `scanning.py`:
`XYZ_to_RGB`, `compress_rgb`, and the CCTF encode.

---

## 6. Where the time goes

Exact path — LUTs off, no grain, no glare — **8.14 s, 6.15 GB**:

| stage | time | % |
|---|---|---|
| filming.expose | 2.66 s | 32.7% |
| scanning.scan_print | 2.31 s | 28.4% |
| preprocess | 1.46 s | 17.9% |
| filming.develop | 865 ms | 10.6% |
| printing.expose | 758 ms | 9.3% |
| spectral integrals (MLX) | 455 ms | 5.6% |

Full-quality path — LUTs on, grain, glare — **24.10 s, 6.66 GB**. The delta
versus 8.14 s is dominated by **grain (~16 s)**, now the single largest item in
the pipeline and entirely un-optimised.

### The 45 MP profile after RFC-007 A

The current frontend metric (deterministic, ProPhoto → Display P3, grain and
glare off, GPU on) is **12.9 s / 13.85 GB**, down from 40.9 s at the start of
the optimisation work:

| node | time | % |
|---|---|---|
| `filming.expose.halation` | 3.30 s | 26.0% |
| `filming.develop.dir_couplers` | 2.40 s | 18.9% |
| `scanning.scan_spectral` | 1.58 s | 12.4% |
| `scanning.gamut_compress` | 1.38 s | 10.8% |
| `printing.expose.print_exposure` | 1.24 s | 9.8% |
| `printing.expose.enlarger_spectral` | 688 ms | 5.4% |
| `filming.expose.upsample` | 587 ms | 4.6% |

**The profile is now spatial-dominated.** The two largest stages do not fuse
the way the pointwise stages did: `halation` is `support=inf` (a global
operator, which also blocks tiling) and `dir_couplers` is a diffusion. Any
plan written against the older pointwise-heavy profile is stale.

### Gamut compression, twice a bottleneck

`compress_rgb` defaults to `cam16ucs` — a full CIECAM16 forward *and* inverse
per pixel, the heaviest of the four available algorithms. It was 8.52 s, ~50%
of wall time.

It resists the obvious optimisations: a 65³ LUT still errs 6.9e-3 (the Reinhard
knee has a sharp corner at `threshold = 0`, and CAM16 destabilises outside the
plausible input range), and it cannot be masked because with `threshold = 0`
the knee is never formally identity.

It is, however, purely pointwise — hence `parallel_pointwise`, which took it to
1.37 s bit-exactly.

RFC-007 A then fused it: `utils/fused_gamut_cam16.py` runs the whole
RGB → XYZ → CAM16 → knee → CAM16⁻¹ → XYZ → RGB chain in a single numba pass,
with colour-science confined to setup (matrices via the identity trick, the
viewing-condition constants, the `C_max` table). Isolated on a real 16 MP tap
that is 7.70 s → 0.32 s and **19.67× → 2.00× the input in temporaries**; in the
pipeline, where the reference was already thread-parallel, it is 4.32 s →
1.38 s at 45 MP. The fused path bypasses `parallel_pointwise` deliberately —
it is internally parallel, and nesting numba's non-threadsafe `workqueue`
layer inside a thread pool aborts the process.

The same treatment applies to the front half of spectral upsampling
(`utils/fused_tc_b.py`): 3.97 s → 0.59 s at 45 MP, matching the reference to
8e-16.

Worth knowing what it does: a one-sided Reinhard roll-off on CAM16 lightness
`Jp` (identity below 70, asymptotic at 100) plus a chroma knee against
`C_max(Jp, hue)` for the destination cube, preserving hue and lightness. On the
baseline image **0.000%** of pixels are out of gamut (max `d = C/C_max` is
0.903), so the chroma half is insurance; the lightness half touches 13.8% of
pixels and is a real highlight shoulder. Changing the algorithm changes the
picture — it is a look decision, not a free speedup.

---

## 7. The frontend (`modern_UI/Spektrafilm`)

A native macOS app: SwiftUI for the panels, AppKit for the window, Metal for
the canvas. `modern_UI/Spektrafilm/README.md` is the detailed document; this is
what someone modifying the *pipeline* needs to know about the thing consuming
it.

### 7.1 Structure

```
Model/Session.swift      all application state, @Observable, @MainActor
Model/Params.swift       Layer 1 — mirrors service/schema.py field for field
Model/Adjustments.swift  Layer 2 — client-side, never reaches the service
Model/Geometry.swift     the oriented-crop model (crop, straighten, turns, flips)
Model/Sidecar.swift      per-frame settings on disk, schema 3
Canvas/Renderer.swift    Metal state; the Layer 2 compute pass and the canvas draw
Canvas/Shaders.metal     layer2 · geometryResample · histogram · canvasFragment
Service/ServiceClient.swift  spawns and talks to the Python process
Service/RenderScheduler.swift  sent-vs-wanted coalescing over a single-flight pipe
Panels/ Windows/ Controls/   the interface
```

### 7.2 The two layers, which is the load-bearing distinction

| | Layer 1 | Layer 2 |
|---|---|---|
| what | film, paper, camera, enlarger | exposure, contrast, curves, colour balance |
| where | the **engine** | a **Metal compute kernel in the app** |
| cost | a service round trip, tens of ms to seconds | one draw, sub-millisecond |
| panel | left | right |

A Layer 1 edit sends a `params_delta` and waits for pixels. A Layer 2 edit
never leaves the app. Putting a control on the wrong side is not a cosmetic
mistake — it is the difference between a slider that tracks the mouse and one
that does not.

`FilmParams.wire` is the single place the Layer 1 field names live, each tagged
`shoot` or `print`, and `ParamsTests.testWireNamesMatchTheServiceSchema` pins
the set against `service/schema.py`. **A rename on the Python side fails a
Swift test rather than silently rejecting every delta at runtime.**

### 7.3 Resolution tiers

The canvas holds the `live` (1600 px) render and escalates to `preview`
(3400 px) at 100 % zoom and `full` at 200 %, per `Session.wantedTier`. Detail
renders are cached by *rank* — a `full` render satisfies a request for
`preview` — so zooming out and back is a texture swap, not a re-render.

### 7.4 What the frontend does *not* do

- No colour management beyond one transform: the service returns Display-P3
  encoded values, the `CAMetalLayer` is tagged Display P3, ColorSync does one
  conversion. Do not add another.
- No masks, currently. The system is built and withdrawn behind
  `FeatureFlags.masks = false` pending a design the user is writing. The flag
  also stops masks being packed for the kernel, so a sidecar that already has
  them renders as though it did not.
- No bundling. The app requires a checkout of this repo and a built `.venv`
  next to it. See RFC-012.

---

## 8. Executors, and the native host that does not exist yet

### 8.1 Three executors, one topology

The same `~24`-node graph of §2 runs on three things. Which one is running is
reported at `open` as `capabilities.backend.render_core`:

| `render_core` | what runs the nodes | selected by |
|---|---|---|
| `metal` | `backends/metal/` — hand-written MSL through `mx.fast.metal_kernel` | `settings.gpu_backend = "metal"` (default) |
| `mlx` | stock MLX ops, partial coverage | RFC-004 path |
| `cpu` | numba / the reference bodies | no GPU available, or explicitly |

**numba is the reference and stays forever** (RFC-011). It is what every ported
node is checked against at float32 storage epsilon by
`scripts/gpu_native/parity.py`. It stopped being the *runtime* and did not stop
being the truth.

### 8.2 The Metal core

`backends/metal/nodes.py` binds **21 node implementations** onto a pipeline,
baking each node's constants (matrices, curves, LUTs) once from the same stage
objects the reference bodies read — so the two executors are fed identical
measured data.

**21 bindings is not 21 nodes on the GPU, and the difference matters if you are
building a performance model.** The default topology is also 21 nodes, but the
two sets are not the same 21:

- `preprocess.geometry` is bound and **pruned at default params** (an identity
  crop and rotation), so the binding is unused on a default render.
- `preprocess.crop_rescale` is **in the topology with no Metal body** and falls
  back to the reference.

So **20 of the 21 default nodes run on Metal** and `crop_rescale` does not.
Verify with `comm` on the bound labels against `pipeline._topology`, rather
than trusting either count on its own. `msl.py` holds the compiled-kernel cache and the MSL fragments
shared between kernels; `kernels.py` the kernels themselves; `device.py`
residency and `mx.eval()` barriers; `blur.py`, `cam16.py`, `grain.py`,
`resize.py` the heavier stages.

Measured: **45 MP, 14.15 s → 1.03 s.** Held to float32 storage epsilon against
numba.

`resize.py` is worth knowing about because it is not a render node at all — it
is `skimage.transform.resize` with its exact parameters (`sigma = (1/scale −
1)/2`, `truncate=4.0`, `mode='reflect'`, `order=1`), ported because the tier
downscale, not the render, was the largest cost in opening a frame. The trap
there was that skimage's `mode='reflect'` maps to ndimage *mirror*.

### 8.3 The engine / service seam (RFC-012 §5 step 4)

```
service/service.py   the wire:   parse a request, call one engine method,
     (389 lines)                  materialise the result to a path
service/engine.py    the engine: typed arguments in, in-memory results out.
     (779 lines)                  Knows nothing about JSON, files or workspaces.
```

The rule, which is enforced by an AST guard in
`tests/test_rfc012_engine_seam.py`: **the engine returns pixels, the service
turns pixels into paths.** It exists so that removing the process later is a
*deletion* rather than a rewrite — RFC-012's option D links the engine into the
app, at which point `service.py`'s materialisation and JSON parsing go away and
nothing else does.

`session.py` holds the per-frame state: the three tier images (downscaled
lazily, under a per-tier lock — do not make them eager), the cached negative,
and the param deltas applied in place where the schema allows.

### 8.4 Version negotiation, and why a refactor can break the wire

`capabilities` reports `transport_version` and `schema_version`, both `1`.
The frontend **refuses to start** on an unknown `transport_version` and shows a
blocking panel; a `schema_version` mismatch only warns, because a renamed
parameter costs some sliders and is not a reason to refuse to show someone
their photograph. `schema_version` is therefore the cheap one to bump and
`transport_version` the expensive one.

Neither field is optional in the Swift `Capabilities` type. This is deliberate:
a service that cannot say which wire it speaks is one the app cannot reason
about. A refactor that only moves code still moves the wire if the wire is
assembled from both halves — this has already happened once, caught before it
landed.

### 8.5 The native host: a transparent proxy, not option C

RFC-012 picks **option C** (a native binary speaking the same wire) on the way
to **option D** (linking the engine in and deleting the process). Steps 1, 3
and 4 have landed.

`native/spektrafilm-native-host` exists and works: it speaks the wire, reports
`backend.host: "native"`, and the frontend opts into it with
`SPEKTRAFILM_NATIVE_HOST=<path>`. **Read what it does before counting it as
option C.** It is a *proxy*: it `exec`s `<repo>/.venv/bin/python -m
spektrafilm.service` with `PYTHONPATH=<repo>/src` and forwards
newline-delimited JSON-RPC between the app and that process.

So it does not remove the Python dependency — it still requires the same
checkout and the same built `.venv` that RFC-012 §2 says is why the app cannot
be given to anyone. It adds a process in front of the one that was already
there. Its own `native/README.md` is straight about this ("the transport/process
half of option C, not the final direct C++ render engine… expected to have
essentially the same startup and RSS as the Python service, plus a small proxy
process"), and that is the framing to keep: **it is a seam that proves the wire
is host-transparent, not progress on shipping.** The distribution problem is
untouched until the engine itself stops being Python — RFC-012's option D.

The step-1 gate below is separate, and is what established that option C is
possible at all. It is a **gate**, not a beginning. Step 1's job was to make it safe to
commit to the plan by answering one question that options C and D both rest on:
is `mx.fast.metal_kernel` reachable from MLX's C++ API, and identical there? It
is. That answer is the entire deliverable; the code that produced it is test
scaffolding and is not on any path to becoming the host.

```
scripts/gpu_native/native_host_spike/     7 tracked files, 17.5 kB total
    dump_cases.py   6.1 kB — monkeypatches msl.kernel/launch, calls the REAL
                    kernels, records MSL source, buffers, grid and Python's
                    output bytes. The larger and more important half: it
                    records what the *shipping* kernels dispatch rather than
                    reimplementing them, so the two sides cannot drift.
    host.cpp        5.2 kB — links libmlx.dylib (otool -L shows no Python) and
                    replays those recordings through mlx::core::fast::metal_kernel
    compare.py      compares bytes
    build.sh / run.sh
```

**Nothing spawns the spike.** It is test scaffolding, and it is a different
thing from `native/` above. If you have arrived looking for "the C++ backend",
those two are what the phrase refers to: a verification harness, and a proxy
that launches Python.

What the spike established, and what it constrains:

- `mx.fast.metal_kernel` is reachable from MLX's C++ API and **byte-identical**
  across four kernels chosen for where a differently-compiled host would
  diverge (log10 and its guard, exp, a binary search over a repeated knot, fma
  contraction in the 3×3).
- The negative control is the part that makes that meaningful: recompiling the
  same source under `MathMode::Fast` moves two of them by up to 1.1e-5, so the
  comparison is known to *detect* compile-level differences. **The host must
  keep MLX's default `CompileOptions{MathMode::Safe}`** or colour drifts past
  RFC-011's bar with nothing to say so.
- When the host lands, the frontend changes **nothing** — same wire, same
  methods, same handoff. `capabilities.backend` gains an additive
  `host: "python" | "native"` so a bug report can say which binary made the
  picture. See `HANDOFF-NATIVE-HOST.md`.

### 8.6 What is still Python-shaped

- **`open` still loads colour-science.** RFC-012 §5 step 3 baked the constants
  (21.9 KiB replacing ~148 MB of `colour-science` + `pandas`), and a *reprint*
  now touches colour-science zero times. `open` still reaches it at three call
  sites in `utils/gamut_compression.py` — `RGB_COLOURSPACES`,
  `XYZ_to_CAM16UCS`, `CAM16UCS_to_XYZ`, which build the CAM16-UCS `C_max`
  table. That is a CIECAM16 port, not a constant. Carried as an `xfail` naming
  the three.
  **Do not conclude from `grep -c "colour\." gamut_compression.py` (33) that
  30 more sites need porting** — the rest are alternative Oklab and Jzazbz
  compressors the default pipeline never executes.
- **The 364 MB round trip.** On a 45 MP frame the file handoff is now
  **50–64 % of a render** depending on tier, because RFC-011 made the render
  fast and left `_write_rgba16` fixed. RFC-012 §1.1 measured 33 % and already
  called it the strongest argument in the document; the ratio has got worse
  since.
- **~1.3 s of interpreter and import** at service start, hidden by a warm-up
  request the app fires at launch.
