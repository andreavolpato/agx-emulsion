# RFC-011: A GPU-native render core — no numba, no NumPy, no Python in the hot path

| | |
|---|---|
| **Status** | Implemented on `gpu/native-metal`; parity table and timings measured 2026-09-10 |
| **Date** | 2026-09-10 |
| **Supersedes** | the *scope* of HANDOFF-METAL-BACKEND ("no language port"); its accuracy bar (§2) is kept verbatim |
| **Depends on** | RFC-002 (grain model), RFC-003 (node topology), RFC-005 (`mx.fast.metal_kernel` is bare Metal), RFC-006 (float32 taps), RFC-007 A (colour-science stays at setup time) |
| **Scope** | `backends/metal/**` (new), `runtime/topology.py`, `runtime/pipeline.py`, `service/service.py`, `scripts/gpu_native/**`, `tests/test_metal_native.py` |
| **Hardware of record** | Apple M3 Max, 30-core GPU, 36 GB unified memory; macOS 25.6; MLX 0.32.2; numba 0.67.0 |
| **Frame of record** | `_DSC2439.NEF` decoded to linear ProPhoto float32, 5520×8288 = **45.75 MP**; Portra 400 → Portra Endura; ProPhoto in, Display P3 out |

---

## 0. The result, in the numbers that were asked for

Same math, same measured data, same 23 node boundaries; only the executor
changed. Shipped service configuration (float32, auto-exposure, grain and
glare on), warm, best of three:

| tier | pixels | numba + 5-node MLX (`gpu_backend='mlx'`) | **GPU-native core (`'metal'`)** | |
|---|---|---|---|---|
| live, full render | 1600 px, 1.70 MP | 0.569 s | **0.042 s** | 13.5× |
| live, reprint | | 0.197 s | **0.012 s** | 16× |
| preview, full render | 3400 px, 7.70 MP | 2.376 s | **0.173 s** | 13.7× |
| preview, reprint | | 0.820 s | **0.046 s** | 18× |
| full, full render | 45.75 MP | 13.684 s | **0.990 s** | 13.8× |
| full, reprint | | 4.733 s | **0.237 s** | 20× |
| peak RSS, one session, all three tiers | | 10.49 GB | **3.99 GB** | |

This table replaces API-SPEC §6's, which measured a 16 MP frame at settings
the service no longer ships (that file is shared with the frontend session and
is not edited here; the service's `_estimate_cost` table carries these numbers).

Accuracy, deterministic configuration (grain and glare off), 45.75 MP, the
Metal core against the numba reference on the same input:

| | |
|---|---|
| end-to-end dE2000 (Display P3, encoded) | mean **5.9e-5**, p99 2.7e-4, max **7.9e-4** |
| end-to-end max abs (encoded RGB, [0,1]) | 3.4e-6 |
| per node, max abs / max |ref| | ≤ 1.3e-6 on 17 of 19 nodes; 3.5e-6 (`upsample`), 1.4e-5 (`gamut_compress`) — §4 |
| structure in the dE map | none: row/column profile max/mean 1.45, tile grid 0.49–2.15 (content-tracking, §4.2) |

The reference stays runnable, per node, in the same process
(`settings.gpu_backend = ''`), and the harness that produced every number
above is checked in (§8).

---

## 1. Decisions

### 1.1 Option A, with `mx.fast.metal_kernel` as the compiled core

HANDOFF-GPU-NATIVE §1 offered three shapes. This is **A**: the service is
still `python -m spektrafilm.service`, the wire is untouched, and behind it
Python parses JSON, loads profiles, bakes constants and tells the GPU what to
do. The "narrow C ABI, one call per node, buffers never leave the device" is
realised as:

```
Node.run_metal : (*mx.array) -> mx.array          one callable per node
run_topology(backend='metal')                     the graph-execution entry point
```

with the rule that **nothing inside `run_metal` may touch NumPy**. The
dispatcher uploads at the head of a run of such nodes, evaluates at every node
boundary (AGENTS.md trap 5), and downloads only when a node without a Metal
body — or the `collect` tap — needs host memory. Every kernel is hand-written
MSL compiled through `mx.fast.metal_kernel`, which RFC-005 measured at 157 µs
per launch and which *is* bare Metal; a separate Swift/C++ dylib would have
reproduced MLX's buffer management for no measured gain, and would have taken
the reference out of the process (HANDOFF-GPU-NATIVE §3.3). Option B (a native
binary) remains a relink of the same kernels if it is ever wanted.

With the full node set on device, the metric that mattered was residency: at
45 MP the reference crosses the host/device line eighteen times; the core
crosses it twice (upload the input, download `rgba16`), plus one 256-px sample
for auto-exposure.

### 1.2 What "same math" had to mean on a GPU without float64

RFC-006's invariant is *buffers float32, per-pixel arithmetic float64
registers*. Metal has no float64. Every kernel here therefore computes in
float32, and the parity table is the record of what that costs: for seventeen
nodes it is float32 storage epsilon (they were already dominated by the
storage rounding); for two it is measurable and recorded rather than hidden
(§4, DR-1). One place could not be left in float32 at all — the recursive
Gaussian — and got a double-float recurrence instead (DR-2).

### 1.3 The harness came first

`scripts/gpu_native/parity.py` and `backends/metal/parity.py` were built
before any node was ported, exactly as HANDOFF-GPU-NATIVE §3.1 asked: one
node, one input, two executors, three numbers, runnable per node from the
command line, and it **refuses to run** with grain or glare enabled
(`StochasticParamsError`). Nothing in §4 was measured any other way. It walks
the reference topology once and compares each node on the reference's own
input taps as they are produced, freeing taps after their last reader — the
first version pinned every tap (12 GB at 45 MP) and its timings were
dominated by paging.

### 1.4 The grain question, answered by a spike

Before the schedule was committed (§4.3 of the handoff), one afternoon went
into the only question that could have changed the plan's shape: can the
exact Poisson sampler become a Metal kernel that holds the third moment?
**Yes.** Hörmann's PTRS transformed rejection — the algorithm NumPy itself
uses above μ = 10 — is a bounded loop (expected 1.1 iterations) and is exactly
Poisson; below μ = 10 the sequential search is used. Driven by Philox4x32-10
keyed on (pixel, stream, seed), the kernel is tile-invariant and
reproducible, and at 45 MP draws one sub-layer in ~20 ms:

| μ | mean (numpy / metal) | var (numpy / metal) | skew (numpy / metal) | 1/√μ |
|---|---|---|---|---|
| 0.5 | 0.4995 / 0.5003 | 0.499 / 0.501 | 1.4137 / 1.4152 | 1.4142 |
| 3.0 | 3.0003 / 2.9999 | 3.003 / 3.000 | 0.5793 / 0.5783 | 0.5774 |
| 9.5 | 9.4977 / 9.4975 | 9.496 / 9.501 | 0.3243 / 0.3235 | 0.3244 |
| 10.5 | 10.4995 / 10.4982 | 10.499 / 10.497 | 0.3097 / 0.3073 | 0.3086 |
| 36.5 | 36.5042 / 36.4977 | 36.508 / 36.489 | 0.1648 / 0.1639 | 0.1655 |
| 341.4 | 341.405 / 341.393 | 340.76 / 341.41 | 0.0520 / 0.0530 | 0.0541 |
| 2064.2 | 2064.21 / 2064.19 | 2064.99 / 2064.06 | 0.0224 / 0.0207 | 0.0220 |

χ² against the exact pmf at μ = 36.5: 45.3 on 55 dof (p = 0.82); stream
cross-correlation −3e-5; 4 M draws. RFC-002 §3.5's Cornish–Fisher form was
not needed.

---

## 2. What was built, by kind of thing

The layout mirrors HANDOFF-GPU-NATIVE §2. `backends/metal/`:

| file | holds |
|---|---|
| `device.py` | the only place NumPy and MLX meet: `to_device`/`to_host`/`sync`, `bounded_device_cache` |
| `msl.py` | kernel cache; the MSL fragments shared by several kernels (numba-exact `searchsorted`, scipy `reflect`) |
| `kernels.py` | every pointwise node body, the spectral integral with its fused epilogue, halation and DIR couplers as compositions of blurs |
| `blur.py` | FIR (σ < 3) and double-float IIR (σ ≥ 3) Gaussians dispatched per channel as `fast_gaussian_filter` does; the three-Gaussian exponential |
| `cam16.py` | CAM16-UCS gamut compression, a line-for-line port of RFC-007's fused kernel |
| `grain.py` | Philox + PTRS Poisson; fused 3-channel × 3-sub-layer grain; lognormal fields for micro-structure and glare |
| `nodes.py` | binds bodies to a pipeline's stage objects: `attach(pipeline, topology)` |
| `parity.py` | the harness |

### 2.1 Pointwise (14 nodes)

Each is one kernel, one read, one write. `expose.upsample` is the fused
`_rgb_to_tc_b` projection (CAT16 matrix from `tc_b_matrix`, the same identity
trick) followed by the Mitchell bicubic 2-D LUT lookup with the reference's
reflect-and-renormalise edge handling and the `× b` scale, in one launch
(915 → 66 ms at 45 MP). `gamut_compress` is CAM16 forward → UCS knee →
inverse, with every constant coming from the reference's own `_setup_for`
(1226 → 25 ms). The curve nodes (`develop.curves`, `print_curves`, the
couplers' re-interpolation, the grain sub-layer interpolation) share one MSL
`search_right` that reproduces numba's scalar `searchsorted(side='right')`
step for step — which matters because Portra's normalised density curves are
*not* monotonic in the toe (steps of −2.8e-4 at indices 10–25), and "the
right answer" there is whatever bucket the reference lands in.

Fusion *across* pointwise nodes was measured and deferred: with the buffer
cache bounded rather than zeroed (DR-5) a full-frame pointwise node costs
4–5 ms at 45 MP, so the fourteen together are under 70 ms of a 990 ms render.

### 2.2 Spatial (7 nodes)

`halation` and `dir_couplers` are compositions of the reference's own blur
primitives on device, in the reference's order, with the reference's
per-channel dispatch (a channel with σ = 0.52 takes the FIR while its
neighbour at σ = 3.35 takes the IIR, exactly as `fast_gaussian_filter` does
per channel). The FIR is vertical-then-horizontal with scipy `reflect` edges
and truncate 3.0; the IIR is Young & van Vliet with sample-replication edges,
run as a vertical kernel on a transposed copy for the horizontal pass so
every recurrence thread reads coalesced memory. Halation's radius at 45 MP is
15.4·√k px; it runs at full resolution, so the "can it run downsampled"
question (HANDOFF §2.2) never had to be answered — nothing was approximated.

`unsharp` is `x + a·(x − G(x))`. The two lens blurs and the two diffusion
filters are pruned at the shipped defaults; a diffusion filter that is
*enabled* is not ported (DR-8) and runs on the host for that node.

### 2.3 Stochastic (grain, glare)

`grain` is one kernel per frame: per pixel, per channel, the three sub-layer
densities from a shared search, then three exact Poisson draws accumulated in
registers — nine draws per pixel, no `(H, W, 3, 3)` intermediate, then the
micro-structure gate, `− density_min`, and the 0.65 px FIR. At 45 MP with the
shipped defaults: **61 ms** against 3.0 s. Glare draws its lognormal field on
device and is unseeded, as the reference is by design.

### 2.4 The CPU-only logic (HANDOFF §2.4), one by one

| what | what was done |
|---|---|
| `auto_exposure` | The 256-px strided sample is taken on device (`img[::step, ::step]`), the ~44 k-pixel sample is downloaded and the reference `measure_autoexposure_ev` solves on the host; the gain goes back as a float32 scalar exactly as `matching_scalar` narrows it. Bit-exact (max abs 0), 125 → 25 ms. |
| colour-science conversions | Never called per pixel. `RGB_to_RGB(x, cs, cs, encode=True)` becomes the CAT02 round-trip matrix recovered on the identity (1 − 5e-17 off-diagonal for Display P3, kept anyway) followed by the sRGB OETF; `XYZ_to_RGB` is the identity-trick matrix the reference already uses. |
| NaN in the measured profiles | Constants come from `spectral_dispatch.get_constants`, i.e. `prepare_spectral_constants`; the kernel has no NaN branch. |
| characteristic curves | `interp_channel` in `msl.py`: endpoint clamp, right-biased exact match, per-channel axis; not a texture sampler, precisely because the ends of the curve are the toe and the shoulder. |
| RAW decode | Not touched; the service receives a linear TIFF. |
| print LUT bake | Not touched; `preview_stock_lut` still uses `gpu_apply_lut3d`. |

---

## 3. Decision records

**DR-1 — float32 arithmetic is the deviation, and it is recorded per node.**
The bar was float32 *storage* epsilon against a reference that computes in
float64 registers. Seventeen nodes meet it (max abs / max |ref| ≤ 1.3e-6).
Two do not and are recorded: `upsample` at 3.5e-6 (the CAT16 projection and
the perspective divide in float32) and `gamut_compress` at 1.4e-5, dE2000 max
5.0e-4 (a chain of `pow`, `atan2`, `log`, `exp` in float32). Neither is a
tolerance widened; both are findings written down. End to end they sum to
dE2000 max 7.9e-4, four orders of magnitude under the spectral round-trip
error the model already carries (RFC-010 §2.2, 1.7–3.8).

**DR-2 — the recursive Gaussian runs in double-float.** A straight float32
port of the Young–van Vliet recurrence measured max abs **6.2e-3** (1.4e-2 of
range) on the DIR-coupler correction at 45 MP, where the exponential tail's
widest component is σ = 131 px and the filter's poles sit almost on the unit
circle. The reference keeps its recurrence state in float64 (numba unifies
`w1 = w` to float64; the vertical pass declares float64 state arrays) and
stores each pass in float32. The kernel now carries the state as a (hi, lo)
pair with fma-based error-free transforms and splits the coefficients the
same way on the host. Result: 4.5e-7 max abs on the same node (1.3e-6 of
range); the blur alone agrees with `fast_gaussian_filter` to 6e-8 at every
σ from 0.65 to 131. Cost: ~10 ms per pass at 45 MP; the kernel is
memory-bound.

**DR-3 — grain is the same distribution, not the same realisation.** The
Metal sampler is exact Poisson (§1.4) on a Philox stream; NumPy's is exact
Poisson on a PCG64 stream. Per-pixel values differ; per-density statistics do
not (§6). Seeding follows the reference's semantics: `grain_sampler='exact'`
uses a fixed key (reproducible run to run, tile-invariant), `'stochastic'`
draws a fresh key per render, `'scipy'` stays on the host. Regression tests
that pin a grain *realisation* will differ between executors by construction,
as RFC-002 §6 already noted for `'exact'` vs `'scipy'`.

**DR-4 — the scanner's `log10 → 10**` round trip is gone.** The reference
computes `10 ** log10(max(xyz, 0) + 1e-10)` because the optional LUT path
interpolates in log space. On device the epilogue is `max(xyz, 0) + 1e-10`,
which is the same quantity without two float32 transcendental roundings
(max abs 3e-8 against the reference's own rounding). The enlarger's epilogue
(`× factor_midgray + preflash`, then log10) is fused into the spectral kernel.

**DR-5 — the device buffer cache is bounded, not zeroed.** RFC-005's
`unpooled_device_memory` sets MLX's cache limit to zero for full-resolution
runs. With every node allocating its output on device that costs a page-faulted
540 MB allocation per node: a trivial multiply measured 16 ms, and the 45 MP
render 1.62 s. With the cache kept but bounded at four frames (2.2 GB) the
same render is **1.07 s** and the multiply 4.5 ms, at 4.19 GB peak RSS in a
fresh process (unbounded: 1.10 s at 8.6 GB). The cache is released when the
render returns. The `'mlx'` path keeps its previous behaviour.

**DR-6 — live print-side parameters are read at call time.** The service
mutates `print_exposure` and the filter shifts onto the pipeline's own params
between renders. Every Metal body therefore re-derives its cheap constants
(the enlarger illuminant, the print gain, `pixel_size_um`, which
`crop_rescale` sets at process time) on each call; only the Hanatos `tc_lut`
and the CAM16 table are cached, by the services that already cache them for
the reference.

**DR-7 — the reference is kept, per node, forever.** `gpu_backend` selects
`''` (numba), `'mlx'` (RFC-004's five nodes) or `'metal'`. A node this core
does not implement for the current configuration simply has no `run_metal`
and runs its reference body, with the dispatcher paying one download and one
upload around it.

**DR-8 — configurations that fall back to the host for one node.** Camera or
enlarger diffusion filter enabled (FFT PSF); `use_enlarger_lut` /
`use_scanner_lut` (the 17³ LUT path); `rgb_to_raw_method='mallett2019'`;
`grain_sampler='scipy'`; an output colour space other than sRGB / Display P3
(the CCTF); an output gamut algorithm other than `cam16ucs` / `off`; scanner
black/white correction. None is on the service's path; each is a ~60 ms
round trip at 45 MP if enabled, not a wrong picture. Inside grain, a
`blur_dye_clouds_um` large enough to make the per-draw dye-cloud blur active
(σ > 0.4 px; the shipped value gives 0.3 px at 45 MP and less at the tiers)
runs the reference grain body for that frame.

**DR-9 — `concurrent` is reported `false`.** The core has no numba in the hot
path, but contract §3.4 asks for the flag only when concurrent entry is
*verified* safe. Not verified: MLX's default-stream behaviour under two
Python threads issuing kernels, the first-call population of the kernel cache
in `msl.py`, and the two host-side services (`get_filming_tc_lut`,
`_setup_for`) whose caches are unsynchronised dicts. The transport stays
single-flight.

---

## 4. Parity, 45.75 MP, grain and glare off

Per node, reference input taps, Metal body vs numba body. "max abs / max
ref" is the error relative to the tap's own range. Timings are from the
end-to-end run (warm; the per-node harness timings are inflated late in the
walk by host memory pressure and are not quoted).

| node | tap | max abs | mean abs | max abs / max ref | dE2000 max | numba ms | metal ms |
|---|---|---|---|---|---|---|---|
| `preprocess.input_cast` | rgb_cast | 0 | 0 | 0 |  | 1236 | 29 |
| `preprocess.auto_exposure` | rgb_ae | 0 | 0 | 0 |  | 125 | 25 |
| `filming.expose.upsample` | film_raw | 4.8e-06 | 9.7e-08 | 3.5e-06 |  | 915 | 66 |
| `filming.expose.exposure` | film_exposed | 0 | 0 | 0 |  | 12 | 17 |
| `filming.expose.boost` | film_boosted | 0 | 0 | 0 |  | 1 | 0 |
| `filming.expose.halation` | film_halated | 9.5e-07 | 9.0e-09 | 3.8e-07 |  | 3403 | 443 |
| `filming.expose.log` | log_e_film | 2.4e-07 | 1.7e-08 | 3.3e-07 |  | 311 | 24 |
| `filming.develop.curves` | cmy_curves | 1.2e-07 | 9.8e-09 | 8.6e-07 |  | 256 | 19 |
| `filming.develop.dir_couplers` | cmy_couplers | 4.5e-07 | 2.3e-08 | 1.3e-06 |  | 2118 | 310 |
| `printing.expose.enlarger_spectral` | log_raw_print | 1.2e-07 | 1.0e-08 | 1.9e-03 ¹ |  | 3573 | 71 |
| `printing.expose.print_exposure` | log_e_print | 1.2e-07 | 1.3e-08 | 2.6e-02 ¹ |  | 735 | 18 |
| `printing.develop.print_curves` | cmy_print | 2.4e-07 | 2.8e-08 | 3.4e-07 |  | 292 | 17 |
| `scanning.scan_spectral` | scan_xyz | 3.0e-08 | 1.6e-09 | 3.3e-07 | 3.5e-05 | 4262 | 29 |
| `scanning.bw_correction` | scan_bw | 0 | 0 | 0 | 0 | 0 | 0 |
| `scanning.glare` | scan_glared | 0 | 0 | 0 | 0 | 0 | 0 |
| `scanning.xyz_to_rgb` | scan_rgb | 1.2e-07 | 3.1e-09 | 3.7e-05 ¹ | 1.9e-05 | 239 | 16 |
| `scanning.gamut_compress` | scan_compressed | 3.3e-06 | 7.6e-08 | 1.4e-05 | 5.0e-04 | 1226 | 25 |
| `scanning.unsharp` | scan_unsharped | 1.2e-07 | 1.9e-09 | 6.1e-07 | 2.7e-05 | 200 | 45 |
| `scanning.cctf` | rgb_out | 1.2e-07 | 1.7e-08 | 7.6e-07 | 4.7e-05 | 811 | 17 |

¹ Log-domain taps whose range passes through zero (a max |ref| of 4.6e-6
for `log_e_print`): the ratio is meaningless there and the absolute column —
one float32 ulp at 1.0 — is the number to read. `xyz_to_rgb`'s ratio is the
same effect on a tap whose max is 3.2e-3.

The numba column is not the RFC-004 profile: it is this run, on this frame,
with the reference's `input_cast` paying for a 540 MB copy of the input
(1.2 s) that the Metal path's upload absorbs.

### 4.1 Where the per-node error lives

Nodes at or under 1.3e-6 of range are at float32 storage epsilon: the
reference rounds its float64 result to float32 once; the port rounds a few
float32 operations. `upsample` (3.5e-6) and `gamut_compress` (1.4e-5) are
DR-1. The two blur-dominated nodes (`halation` 3.8e-7, `dir_couplers`
1.3e-6) are where DR-2 bought two to four orders of magnitude.

### 4.2 The end-to-end map

`tmp/parity/de2000_map_full.png` (regenerate with §8): dE2000 mean 5.9e-5,
p99 2.7e-4, max 7.9e-4. The map shows the photograph — skin and the white
shirt sit at ~1e-4, the dark background at ~4e-5 — because CAM16's float32
error depends on chroma and lightness. It shows no band, no channel and no
tile seam: row and column profiles peak at 1.45× their mean, the 256-px tile
grid at 0.49–2.15× (a hard seam or band puts an order of magnitude on those).
The live and preview tiers give the same figures (mean 6.0e-5 / max 6.9e-4
and 7.1e-4).

---

## 5. Where the time goes now

45.75 MP, shipped configuration (grain and glare on), warm, `profile_render.py --backend metal`:

| node | numba + MLX | Metal core | |
|---|---|---|---|
| `filming.expose.halation` | 2.967 s | **0.329 s** | 9.0× — five IIR Gaussians (2 transposes + 2 passes each) and one FIR; §7.1 |
| `filming.develop.dir_couplers` | 1.943 s | **0.281 s** | 6.9× — four IIR + one FIR Gaussian |
| `filming.develop.grain` | 3.018 s | **0.061 s** | 49× |
| `filming.expose.upsample` | 0.777 s | 0.057 s | 13.6× |
| `preprocess.crop_rescale` | 0.000 s | 0.041 s | the download-and-upload around the one host node on the path (identity at the defaults) |
| `preprocess.input_cast` | 0.095 s | 0.033 s | the upload |
| `preprocess.auto_exposure` | 0.025 s | 0.029 s | strided sample + host solve |
| `scanning.glare` | 0.694 s | 0.027 s | |
| `scanning.unsharp` | 0.221 s | 0.026 s | |
| `scanning.scan_spectral` | 0.772 s | 0.025 s | |
| `printing.expose.enlarger_spectral` | 0.702 s | 0.023 s | |
| `scanning.gamut_compress` | 1.259 s | 0.020 s | 63× |
| eight remaining pointwise nodes | 1.0 s | 0.043 s | 4–6 ms each |
| **total** | **14.15 s** | **1.03 s** | **13.7×** |
| peak RSS | 8.04 GB | **3.64 GB** | |

Deterministic configuration: 10.60 s → 1.07 s. First render in a process:
21.1 s → 1.86 s (Metal shader compilation replaces numba's JIT; both cached
afterwards, MLX's in memory only).

---

## 6. Grain: the third moment, in the real render

`scripts/gpu_native/grain_moments.py`, preview tier (7.7 MP), seeded
`'exact'` sampler on both executors, noise = grain on − grain off, binned by
the grain-free density. Blue channel (the coarsest grain, `particle_scale`
3.2):

| density | n | RMS numba / metal | skew numba / metal |
|---|---|---|---|
| [0.00, 0.15) | 871 k | 0.02250 / 0.02247 | +0.2572 / +0.2559 |
| [0.15, 0.30) | 2.37 M | 0.03062 / 0.03059 | +0.1466 / +0.1478 |
| [0.30, 0.60) | 2.38 M | 0.03226 / 0.03226 | +0.1098 / +0.1080 |
| [0.60, 0.90) | 742 k | 0.02603 / 0.02599 | +0.0715 / +0.0640 |
| [0.90, 1.30) | 1.34 M | 0.02614 / 0.02610 | +0.0458 / +0.0413 |

Red and green behave the same (the full table is in
`tmp/parity/grain_moments_preview.json` after a run). The skewness falls from
+0.26 in the shadows to +0.04 in the highlights on both executors — the
signature `fast_stats` flattened to zero (RFC-002 §3.4) is intact. The
radial noise power spectrum agrees bin for bin to within ±2 % (ratio
metal/numba over 62 radial bins, all three channels), which is the same
spread two *reference* realisations show against each other; the one
exception is the corner bin of the FFT, which both comparisons blow up.

---

## 7. What is next, in order

1. **Fuse the IIR mixtures.** Halation's three bounces and the exponential
   tails' three components are each `Σ_k w_k G_k(x)`: today that is three
   separate two-pass blurs with two transposes each. One kernel carrying
   three recurrences per thread (read `x` once, write the weighted sum once)
   would roughly halve the two nodes that are now 60 % of the render
   (~0.6 s → ~0.3 s at 45 MP). Parity cost: the reference sums float32-stored
   components, so ~1 ulp.
2. **Contract §3's surfaces.** `geometry` at the head of the graph is a crop
   on the uploaded buffer before `crop_rescale` — cheap on device. ROI render
   with a service-chosen halo is natural here because every spatial kernel
   already knows its support. `exposure_mask` on `reprint` is a multiply at
   `print_exposure`. None needs a wire change beyond the additive fields
   already recorded in contract §5.
3. **Verify concurrency** (DR-9) before reporting it: two sessions rendering
   on two Python threads against one MLX device, kernel-cache population
   under a lock, and the two host caches made thread-safe. Only then
   `concurrent: true`.
4. **Option B** if the Python shell ever shows up in a profile. It does not
   today: at the live tier the whole render is 42 ms and the JSON-RPC round
   trip is a few of them.

---

## 8. How to reproduce every number in this document

```bash
cd spektrafilm-gpu                      # the gpu/native-metal worktree, its own .venv
# fixtures (gitignored): decode the 45 MP NEF to linear ProPhoto once
.venv/bin/python -W ignore scripts/gpu_native/make_fixtures.py "tests/Test_image/Nikon Z7ii/_DSC2439.NEF"

# 1. per-node parity + end-to-end dE2000 map, all three tiers
.venv/bin/python -W ignore scripts/gpu_native/parity.py tmp/_DSC2439_45mp_linear_prophoto.tif --end-to-end --tier full
.venv/bin/python -W ignore scripts/gpu_native/parity.py tmp/_DSC2439_45mp_linear_prophoto.tif --end-to-end --tier live
# 2. per-node profile, shipped configuration, either executor
.venv/bin/python -W ignore scripts/gpu_native/profile_render.py tmp/_DSC2439_45mp_linear_prophoto.tif --backend metal
.venv/bin/python -W ignore scripts/gpu_native/profile_render.py tmp/_DSC2439_45mp_linear_prophoto.tif --backend mlx
# 3. warm per-tier timings the way the service pays them
.venv/bin/python -W ignore scripts/gpu_native/tier_timings.py tmp/_DSC2439_45mp_linear_prophoto.tif --backend metal
# 4. grain moments and spectrum
.venv/bin/python -W ignore scripts/gpu_native/grain_moments.py tmp/_DSC2439_45mp_linear_prophoto.tif --tier preview
# 5. the tests (22, ~3 s; skipped without a Metal device)
.venv/bin/python -W ignore -m pytest -q tests/test_metal_native.py
```

The suite covers: dispatcher residency with a fake device (no GPU needed),
blur parity at every σ the shipped configuration uses, the Poisson kernel's
three moments and tile invariance, the curve interpolator on the
non-monotonic toe, per-node parity on a real frame against the bounds in §4,
end-to-end dE2000 with a structure check, the harness's refusal of
stochastic parameters, and grain skewness per density band.

---

## 9. Geometry at the head of the graph (contract §3.1, added 2026-09-10)

The frontend's crop/straighten (`Model/Geometry.swift`, FE commit 18d55de)
is an oriented rectangle: a normalised crop with a top-left origin, rotated
about its own centre by a straighten angle that is rigid in *pixels*, then
quarter turns, then flips. The engine now carries the same model
(`utils/geometry.py`, `GeometryParams` on `io`, eight scalar transport
fields) and applies it as `preprocess.geometry` immediately after
`decode_input`:

- **before auto-exposure**, so the meter reads the frame the user composed;
- **before `crop_rescale`**, so every node after it pays only the crop's
  share — at 0.99 s for the full frame that is now the largest proportional
  win on the table;
- with the film pixel pitch taken from the *uncropped* frame
  (`ResizingService.source_long_edge`), because the negative's grain does
  not get coarser when a user keeps less of it.

`source_point` is a transliteration of `sourcePoint(forOutput:imageSize:)`
and the sampler of `geometryResample` (pixel centres at (i + 0.5)/N,
bilinear, clamp to edge; output size = round(crop × source), axes swapped for
odd quarter turns). `tests/fixtures/geometry_pairs.json` freezes fifteen
(output uv → source uv) pairs on the 8256×5504 frame for the five cases
`GeometryTests.swift` uses, so either side can check the other without
running its code. Quarter turns and flips are exact pixel permutations; an
axis-aligned crop is an exact slice; the identity is pruned and the render
is bit-identical to one without the node.

On device the node is one gather kernel. A first version mapped
coordinates in float32 and measured 1.2e-4 max abs against the float64
reference on the real frame: a normalised uv on an 8 k-pixel frame carries
only ~5e-4 px of position, and the pipeline amplifies that at hard edges into
dE2000 max 2e-2 with visible edge structure in the map. The kernel now does
the mapping in double-float (the same `DF_HEADER` the recursive Gaussian
uses) in *pixel* units, and splits the sample position into an integer base
and an exact fraction, so the position agrees with float64 to ~1e-7 px.
The frontend's canvas and export kernels are float32 and keep the ~5e-4 px
property; that is a preview-vs-engine difference of a two-thousandth of a
pixel, not a disagreement about which pixels are in the picture.

### 9.1 Measured, 45.75 MP source, 60 % × 66 % crop straightened by 7.5°

`scripts/gpu_native/parity.py ... --geometry 0.2,0.15,0.6,0.66,7.5 --end-to-end`:

| | |
|---|---|
| `preprocess.geometry` vs reference | max abs 1.2e-5, mean 2.0e-9 (max abs / max ref 1.5e-5) |
| end-to-end dE2000 | mean 6.9e-5, p99 2.9e-4, max 1.5e-3; no structure (row/col profile 1.5 / 1.2, tile grid 0.45–1.67) |
| full render, numba → Metal | 6.44 s → **0.41 s** (the crop is 40 % of the frame; the uncropped render is 0.99 s) |
| the node itself | 2.04 s (NumPy gather) → 10 ms |


---

## 10. Concurrency, verified (added 2026-09-10)

DR-9 reported `concurrent: false` because nothing had been checked. This
section is the check, and what it changed.

### 10.1 What the engine does under concurrent entry

`scripts/gpu_native/concurrency_check.py`, M3 Max, 45.75 MP frame:

| test | result |
|---|---|
| 4 pipelines on 4 threads, deterministic config, live and preview tiers, 5 rounds | every output **bit-identical** to the sequential render; no errors |
| the same with grain and glare on (fresh Philox seeds), plus a thread constructing and rendering new pipelines throughout | no errors |
| two 45 MP renders (grain + glare on), sequential vs concurrent | 2.01 s vs 1.76 s: **1.14×** — one GPU, already busy |
| a live-tier render issued while a 45 MP render runs, no yielding | 49 ms alone → **362 ms** |

The one thing that must stay serialised is **pipeline construction**: the
1×1 reference probes in `SimulationPipeline.__init__` go through numba
kernels compiled `parallel=True`, and numba's `workqueue` layer aborts the
process on concurrent entry. `session.BUILD_LOCK` covers it. Rendering on the
Metal core never enters numba (the only remaining host work is colour-science
setup and a strided auto-exposure sample), and MLX accepts kernel launches
from several Python threads on its default stream — 20 rounds × 4 threads
produced no fault and no wrong pixel. The kernel cache in `msl.py` and the
setup caches (`_setup_for`, `tc_b_matrix`) are plain dicts; a race there
compiles or computes a constant twice and stores an equal value, which is
harmless and was exercised by the construction-under-load round.

### 10.2 What the service does with it

- **Locks per session tier**, not one global lock. Different tiers render
  concurrently (they are separate pipeline objects); the same tier queues.
- **Deferred deltas.** `set_params` never blocks behind a render: a delta
  for a tier that is rendering is queued and applied by that thread when it
  finishes. The in-flight render reflects the parameters as of its start; a
  shoot-layer edit that lands mid-render bumps a generation counter so the
  negative being computed is not cached stale.
- **`open` waits** for the previous session's in-flight renders before
  releasing it.
- **The transport stays in-order by default**, because the shipping client
  reads the next line as the reply to its last request. `configure_transport
  {"concurrent": true}` moves request handling to a worker pool; replies then
  arrive in completion order and `progress` / `cancel` are answered on the
  reader thread — so cancel works mid-render for the first time on this
  transport. Turning it off drains the pool before the next request.

### 10.3 The interactive yield

Concurrency alone made a live render *worse* (49 → 362 ms) because the GPU
queue was full of the export's kernels. A background render therefore yields
to a pending live render: `RenderProgress.yield_fn` is called between nodes,
and — because halation and the couplers are single 300 ms nodes — also
between kernel launches inside the blur chains (`device.yield_scope` /
`yield_point`, ~30 ms granularity). The wait is bounded at 1 s per yield
point so a continuous drag cannot starve an export.

Measured through the service (`concurrency_check.py --service`: an `export`
with a live `reprint` arriving 200 ms in):

| | live reprint | export |
|---|---|---|
| alone | 27 ms | 1.03 s render + TIFF write |
| concurrent, no yield | 423 ms | 2.06 s |
| yield between nodes | 285 ms | 1.81 s |
| **yield between kernels** | **44 ms** | 1.99 s |

### 10.4 What this means for batch processing

One GPU renders one 45 MP frame in a second whether or not another render
shares it (1.14× for two). Batch throughput does not come from concurrent
renders on the service; it comes from overlapping the **client's decode**
(Core Image, ~3 s per NEF on this machine) with the service's render, which
the in-order transport already allows — decode image k+1 while `export`
renders image k — and which the concurrent transport makes simpler (issue
the `open` early; it waits for the running export by itself). Multi-session
(several images open at once) is not implemented: a session holds three tier
images and up to three negatives, and at 45 MP that is the memory budget.

`capabilities.backend.concurrent` is now `true` on the Metal core; the
transport block and `configure_transport` are recorded in contract §6, and
the client-side prerequisite (match replies by id) in §5.

---

## 11. The tier downscale (added 2026-09-10, HANDOFF-GPU-WIRING §2.1)

`utils/preview.resize_for_preview` — skimage's anti-aliased resize — survived
the rewrite because it produces a node's input rather than being a node, and
once the render was 37 ms it was the largest single cost in opening a frame:
1.6–2.4 s per tier on the 45 MP source (trap 10, again). It is now ported,
not replaced: `backends/metal/resize.py` reproduces skimage's parameters —
`sigma = max(0, (factor − 1)/2)` per axis, `truncate = 4.0`, and ndimage's
**mirror** edges (skimage's `mode='reflect'` is the numpy-pad name for
ndimage `mirror`, which is where a first attempt with scipy `reflect` bit:
5e-2 at the edges, 1.8e-7 inside) — followed by `ndi.zoom(order=1,
mode='mirror', grid_mode=True)`, with the sample coordinate computed as an
exact rational so the base index is an integer and only the fraction rounds.

| | skimage (CPU) | Metal | max abs vs skimage |
|---|---|---|---|
| 45 MP → live (1600 px) | 1.60 s | **54 ms** | 1.2e-7 |
| 45 MP → preview (3400 px) | 1.84 s | **62 ms** | 1.2e-7 |
| synthetic 300×200 / 257×411×4 / 1000×700 / 4000×2999 | | | 1.8e-7 (edges included) |

`RenderSession._downscale` uses it when the session renders on the Metal
core and returns the result to host, so nothing else in the session changes.
The RGBA frame is uploaded as it is and alpha dropped on device; slicing on
the host first was a 540 MB copy that cost more than the downscale.

`open` on the 45 MP frame, warm: 2.6 s → **278 ms** on an uncompressed
4-channel half TIFF (what the client writes: 8256×5504×4×2 bytes = 364 MB,
which reads in ~0.1 s). The TIFF *read* is the remaining variable, and it is
about compression, not size: measured on the same frame, OIIO reads an
uncompressed half TIFF in 0.07 s (3 ch) / 0.11 s (4 ch), an LZW one in
1.3 / 1.6 s and a ZIP one in 1.1 / 1.35 s, regardless of thread count. So
HANDOFF-GPU-WIRING §2.2's handoff is fine as long as the client keeps
writing it uncompressed.
