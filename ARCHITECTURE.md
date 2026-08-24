# ARCHITECTURE.md

How the spektrafilm runtime is put together, with the performance and memory
characteristics measured on this fork. Written for someone about to modify the
pipeline.

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
utils/spectral_dispatch.py    backend switch: reference | numba | mlx
utils/parallel_pointwise.py   chunked thread-parallel wrapper for pointwise stages
backends/mlx_spectral.py      custom Metal kernel via mx.fast.metal_kernel
tests/baseline/               baseline generation, instrumented runner, ΔE harness
rfc/RFC-001-metal-mlx-backend.md
```

Backend is selected by `params.settings.spectral_backend` (default `"numba"`).

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
