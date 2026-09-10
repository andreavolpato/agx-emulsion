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

spektrafilm is **one application with a C++ render engine linked into it**, and
a Python engine beside it that ships to nobody and is the reference every
number is measured against. It used to be two programs and a pipe; RFC-014
deleted the pipe (2026-09-10).

```
  ┌─ modern_UI/Spektrafilm ─── one binary, ~20 MB ────────────────────────┐
  │  SwiftUI + Metal, macOS app                                           │
  │                                                                       │
  │  Session (@Observable, @MainActor)                                    │
  │  Renderer  ── Metal canvas, Layer 2                                   │
  │  EngineClient ── actor, JSON in / MTLTexture out                      │
  │        │                                                              │
  │        │  spk_engine.h, a hand-written extern "C" surface             │
  │        ▼                                                              │
  │  ┌─ engine/ ── C++20, compiled into this target ──────────────────┐   │
  │  │  core/      the setup maths: colour, profiles, curves,         │   │
  │  │             couplers, CAM16, the Hanatos LUT                   │   │
  │  │  gpu/       a five-verb interface + its Metal backend          │   │
  │  │  shaders/   the kernels, MSL, in spektrafilm.metallib          │   │
  │  │  pipeline/  the 21-node graph, the session, the C ABI          │   │
  │  └────────────────────────────────────────────────────────────────┘   │
  │  Resources/engine/  baked constants, 28 film profiles, the metallib   │
  │  RAW decode (Core Image) ── linear ProPhoto float ──▶ spk_open        │
  └───────────────────────────────────────────────────────────────────────┘

  ┌─ src/spektrafilm ── development dependency, never shipped ────────────┐
  │  the reference and the test oracle: numba, colour-science, scipy.     │
  │  engine/tests/parity_*.py drive the *shipping* binary through ctypes  │
  │  and compare against it.                                              │
  └───────────────────────────────────────────────────────────────────────┘
```

**There is no pipe, and no Python at run time.** The engine takes pixels and
returns an `MTLTexture` the canvas draws — RFC-014 §2.2's zero copy. What that
deleted, concretely: a 364 MB TIFF crossing the boundary in each direction on
every `open`, `_write_rgba16` (10 ms of a 30.6 ms reprint), JSON-RPC framing, a
workspace directory, a subprocess, and the requirement that a repository
checkout with a 2.2 GB virtualenv sit next to the `.app`.

**The method surface did not change.** `EngineClient.call(_:_:as:)` takes the
same `Method` and the same Codable request/response types the stdio client
took, and the engine reports the same `transport_version` and `schema_version`
(both 1). Parameters still cross as JSON, because they are small, the schema
already exists, and a struct-per-parameter boundary breaks every time a slider
is added. Renders are the one exception and go through
`EngineClient.render(_:_:)`, because a texture cannot travel through a
`Decodable`.

**What is still Python.** `src/spektrafilm` is the reference implementation and
the oracle for five parity harnesses (§8.6). It is a development dependency. It
is also still the *only* implementation of three wire methods — `export`,
`export_di`, `preview_stock_lut` — which the engine refuses by name rather than
answering wrongly (§8.7).

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
| **the native engine: what was built, what parity measures, what is left** | `rfc/RFC-014-native-cpp-engine.md` §8 |
| the wire, ownership, version negotiation | `CONTRACT-frontend-backend.md` |
| the method surface and semantics | `API-SPEC-callable-render-service.md` |
| the frontend in detail | `modern_UI/Spektrafilm/README.md` |
| the GPU-native render core (the kernels this port inherited) | `rfc/RFC-011-gpu-native-render-core.md` |
| why the Python process *was* still here | `rfc/RFC-012-consistent-backend-process.md` |

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

> **These are the *Python reference's* numbers, and they are the reason RFC-014
> exists — not what the shipped app does.** For the engine that actually
> renders, see §8.7: 45 MP is 0.87 s at the full tier and 0.13 s at the live
> one. This section is kept because it is still where the *model's* cost lives,
> and because the reference is what every parity harness runs against.

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
Service/EngineClient.swift   the C++ engine, in this process (§8)
Service/RenderScheduler.swift  sent-vs-wanted coalescing of slider deltas
Panels/ Windows/ Controls/   the interface
```

### 7.2 The two layers, which is the load-bearing distinction

| | Layer 1 | Layer 2 |
|---|---|---|
| what | film, paper, camera, enlarger | exposure, contrast, curves, colour balance |
| where | the **engine** | a **Metal compute kernel in the app** |
| cost | an engine call: ~10 ms live, ~170 ms full | one draw, sub-millisecond |
| panel | left | right |

A Layer 1 edit sends a `params_delta` and waits for pixels. A Layer 2 edit
never leaves the app. Putting a control on the wrong side is not a cosmetic
mistake — it is the difference between a slider that tracks the mouse and one
that does not. The gap is narrower than it was (a live-tier reprint is ~10 ms
now, not 190) but it is still a gap, and it still runs on a debounce.

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

## 8. The native engine

RFC-014, implemented 2026-09-10. Read `rfc/RFC-014-native-cpp-engine.md` §8
first if you are about to change any of this; it records what parity measures,
why each bar is where it is, and the bugs already found.

### 8.1 Layout

```
engine/include/spektrafilm/spk_engine.h   the whole C ABI
engine/src/core/        setup maths — no GPU, no pixels, testable on its own
      blob, json, colour, spectral, profile, params, curves, cam16,
      hanatos, printing, setup_cache
engine/src/gpu/         gpu.hpp (the interface) + metal_gpu.cpp (metal-cpp)
engine/src/shaders/     the kernels; built by build.sh, not by Xcode
engine/src/pipeline/    image, blur, pipeline (21 nodes), engine (the C ABI)
engine/tools/           bake_resources.py
engine/tests/           five parity harnesses + two C++ drivers
engine/build.sh         lib | dylib | metallib | tests | bundle | all
```

The engine compiles **into the app target** (`Tools/gen-project.py` lists the
translation units; C++20, metal-cpp on the header path, a hand-written bridging
header). One target, not two: a separate static-library target would only add a
second place for the include paths to drift.

### 8.2 The C ABI

Three rules, and they are the ones to keep:

1. **Nothing throws.** Every entry point is `noexcept`; failure is a negative
   `spk_status` plus `spk_last_error`. A C++ exception unwinding into Swift is
   undefined behaviour.
2. **Ownership never crosses** — with exactly one documented exception. The
   caller owns the device and the input pixels; the engine owns what it
   allocates. The exception is `spk_result.texture`, returned **+1**, because
   the frontend caches the last eight frames' textures and a texture whose
   pixels the engine reused on the next render would silently become a
   different photograph. Swift takes it with `takeRetainedValue()`; C calls
   `spk_result_free`.
3. **Parameters are JSON.**

A C ABI rather than Swift's C++ interop (which Xcode 26.6 supports and which
works): it is ABI-stable across toolchains, it keeps the boundary narrow, and
it is callable from `ctypes` — which is what lets the parity harnesses drive
the **shipping binary** rather than a reimplementation of it.

### 8.3 The GPU layer

Five verbs — alloc/upload, dispatch, flush, read, texture — and nothing above
`gpu.hpp` names Metal. This is the abstraction the MSL-only decision was taken
*with*: a Vulkan backend would implement `Gpu` and supply its own SPIR-V for
the same kernel names.

**Buffer lifetime is the part to understand before changing anything here.**
Buffers are reference-counted into a pool (`gpu::BufferRef`), and two
conditions must both hold before one is handed out again:

- **free** — its last handle dropped, so no *future* dispatch names it;
- **idle** — the command buffer that last named it has completed.

Only the first was true in the first version, and a later kernel overwrote a
buffer an earlier one had not read: 25 of 27 render-parity cases wrong, no
crash and no error. A freed buffer waits on a pending list and becomes
reusable at `flush`. The pipeline therefore flushes at node boundaries, which
is also where the reference evaluates (`mx.eval`; AGENTS trap 5), and
`Blur::mixture` flushes between components because a four-component halation
scatter is where one node holds the most memory at once.

Reclaiming only at the end of a frame instead cost **6.4 s and 3.2 GB at 24 MP
against 0.4 s** — a number that looks exactly like a CPU fallback and is not
one.

### 8.4 The kernels

MSL, compiled by `engine/build.sh` into `spektrafilm.metallib` and shipped as
a resource — **not** compiled by Xcode. The app target sets
`MTL_FAST_MATH = YES` for its own canvas shader, and letting the engine's
kernels inherit that is RFC-014 §5.1 trap 1: `exp` and fma contraction drift by
up to 1.1e-5, past the float32 bar, silently.

Every body transferred verbatim from `backends/metal/*.py`. What was added is
what MLX supplied for free: `take_rgb`, `affine3`, `mul`, `transpose3`, a max
reduction, a strided sample for the meter, the rgba16 conversion, the two
transfer-function kernels, and `spk_math_probe`.

`spk_math_probe` computes `a*b - a*b`, which is exactly `0.0` under fast math
and the fma error term under safe math. `spk_engine_create` refuses to start if
it comes back zero, and `engine/tests/check_math_guard.sh` builds a deliberately
fast-math library to prove the guard can fire.

### 8.5 Caches, and why a slider is fast

Three caches exist on the Python side and all three had to be ported; missing
them made every non-live slider cost 160–250 ms:

| what | why it is expensive | keyed on |
|---|---|---|
| the CAM16 C_max table | 64 × 720 cells × 18 bisections ≈ 830,000 CAM16 inversions | output colourspace |
| the Hanatos tc_lut | a 192×192×81 contraction plus a 192×192 ray-polygon remap | film stock **+ the sensitivity array itself** |
| the session's negative | the whole film side | invalidated by a shoot-layer edit only |

`core/setup_cache.hpp` holds the first two on the *engine*, shared by every
pipeline it builds. The tc_lut's key folds in the sensitivity rather than the
stock name because that is where the camera's UV/IR cut lands.

The negative cache is why the layer table in `service/schema.py` is a
correctness concern rather than metadata: a `print`-layer edit reuses the
cached negative and a `shoot`-layer edit must not.

### 8.6 Parity: what is actually measured

Python stays the oracle. All five drive the shipping binary.

| harness | holds | result |
|---|---|---|
| `parity_setup.py` | 227 setup quantities vs colour-science/scipy/numpy | 0 failed, 86 bit-exact |
| `parity_schema.py` | the wire schema and digested params, 6 stock pairs | identical |
| `parity_render.py` | the picture, 27 configurations, 1 MP frame, vs numba | 0 failed, max 2.3e-5 |
| `parity_session.py` | all 39 wire fields applied to a *live* session | 0 failed |
| `parity_grain.py` | grain's mean/std/skew at 9 densities | 0 failed |

Plus `gpu_smoke` (the boundary) and `check_math_guard.sh` (that the guard
fires).

The render bar is **measured, not asserted**: 3e-5 absolute, because the
already-validated Python Metal core reaches 1.9e-5 against the same numba
reference on the same frame and this engine reaches 2.3e-5. Do not tighten it
to float32 epsilon — no GPU path over 21 nodes meets that — and do not loosen
it without saying what you measured. It is paired with a count-level bar so a
systematic shift cannot hide under the absolute one.

`parity_session.py` exists because the render suite opens a *fresh* session per
case and so never took the path a user takes: open once, then move sliders.
That gap hid a bug that broke twelve print-layer fields outright.

### 8.7 Speed and size, measured

45 MP, warm, on an M3 Max:

| tier | first | reprint |
|---|---|---|
| live 1600 px | 0.13 s | 0.01 s |
| preview 3400 px | 0.25 s | 0.04 s |
| full 7800×5800 | 0.87 s | 0.17 s |

A non-live slider is 0.2–3.4 ms of `set_params` plus a reprint. Opening a
24 MP RAW through the app is ~2.0 s, of which ~1.6 s is Core Image rendering
the linear TIFF to a float bitmap — now the largest single cost on that path.

Bundle **20 MB**, of which 11 MB is baked resources (6.0 MB of colour
constants, of which 5.97 MB is the Hanatos irradiance spectra kept float16 as
the reference stores them; 5.8 MB of profiles for all 28 stocks). Both are
data, both are trimmable, neither is code.

### 8.8 What is not ported

The engine refuses these **by name** rather than answering wrongly:

- `export` — the render exists, the file writer does not;
- `export_di` — three files plus the shipped print-preview LUTs;
- `preview_stock_lut` — needs the `.cube` machinery.

`Exporter.swift` still calls them and will surface the refusal. None is on the
path from opening a frame to seeing it; each is a subsystem rather than a node.

Also open: `native/` (the stdio proxy host) and `scripts/gpu_native/native_host_spike/`
are dead and should be deleted; per-node timings are off unless
`SPEKTRAFILM_NODE_TIMINGS=1` (§8.9); Xcode's Debug configuration compiles the
engine at `-O0`, which is ~1.7× on the setup maths and nothing on the kernels.

### 8.9 Node timings measure encode time unless you ask

Dispatches batch into one command buffer, so a wall-clock timer around a node
body measures how long it took to *encode* — 0.003 ms for a full-frame matmul,
three orders of magnitude below the truth. `progress.node_times` is therefore
**empty** unless `SPEKTRAFILM_NODE_TIMINGS=1`, which flushes per node and gives
up the batching for the run. An empty field is honest; a plausible wrong number
in front of someone bisecting a slow frame is not.

