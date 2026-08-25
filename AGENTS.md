# AGENTS.md — working notes for AI sessions on this fork

Fork of `andreavolpato/spektrafilm`. This file records conventions and, more
importantly, the traps that cost real debugging time. Read the traps section
before touching the pipeline.

---

## Environment

The package is **not** installed system-wide. A venv lives at `.venv`:

```bash
cd "/Users/xiaojinqiu/Documents/Summer 2026/spektrafilm"
.venv/bin/python ...            # always use this interpreter
```

Recreate if needed:

```bash
uv venv --python 3.13 .venv
uv pip install --python .venv/bin/python \
  numpy scipy colour-science scikit-image matplotlib opt-einsum numba \
  pyfftw rawpy exiv2 OpenImageIO lensfunpy mlx
uv pip install --python .venv/bin/python --no-deps -e .
```

GUI deps (napari, pyside6) are deliberately omitted — the runtime core does
not import them. Add them only if working on `spektrafilm_gui`.

Always pass `-W ignore`: the PCHIP LUT preparation emits monotonicity warnings
that bury real output.

---

## Fixed experimental setup

Do not change these without a reason; every recorded number assumes them.

| | |
|---|---|
| film profile | `kodak_portra_400` |
| print profile | `kodak_portra_endura` |
| baseline image | `tests/baseline/_DSC2439_16mp_linear_prophoto.tif` (16.00 MP, 3264×4901, float32 linear ProPhoto) |
| smoke image | `tests/baseline/_smoke_1mp.tif` (1 MP, for fast iteration) |
| device precision | float32 on macOS (see Traps) |
| grain sampler | `exact` (RFC-002); `--sampler scipy` for the old stream |
| working precision | `float32` (the default since RFC-006; `float64` is the validation baseline) |

Regenerate the baseline from the source NEF:

```bash
.venv/bin/python tests/baseline/make_baseline.py tmp/_DSC2439.NEF \
    tests/baseline/_DSC2439_16mp_linear_prophoto.tif
```

Run a render with instrumentation:

```bash
.venv/bin/python -W ignore tests/baseline/run_reference.py \
    tests/baseline/_DSC2439_16mp_linear_prophoto.tif tests/baseline/out \
    --no-glare --backend mlx --tag my_experiment
```

Compare two renders:

```bash
.venv/bin/python -W ignore tests/baseline/compare.py \
    tests/baseline/out/reference_A.exr tests/baseline/out/reference_B.exr \
    --tag A_vs_B
```

---

## Traps

### 1. The pipeline is nondeterministic by default

`model/glare.py` draws an **unseeded** lognormal field on every call, and
`print_render.glare` / `film_render.glare` are both active by default. Two
renders with identical config and the same backend differ by up to **0.042** —
larger than most differences you will be trying to measure.

**Glare is the only unseeded stage.** Grain looks stochastic but is not: with
`fixed_seed=None` the model takes `seed = [0, 1, 2]` (note the inverted-looking
branch) and `grain_sampler='exact'` derives every chunk's stream from a fixed
`SeedSequence`, so grain reproduces run to run and across worker counts.

**Any per-pixel comparison must still disable both.** `run_reference.py
--no-glare` plus omitting `--grain` does this. With both off the pipeline is
bit-exact (`np.array_equal` True) run to run.

This cost an hour of chasing a phantom port bug. Before concluding a change
broke something, run the same config twice and check it reproduces.

### 2. Measured profiles contain NaN

Portra 400 has 22 NaN in `channel_density` and 20 in `base_density`; Portra
Endura has 22 in `channel_density`. They mark wavelengths with no measurement
data, mostly at the UV and IR ends.

The reference path lets them propagate to NaN transmittance, then zeroes them
in `density_to_light`. Any replacement must reproduce that. See
`prepare_spectral_constants` in `utils/fused_spectral.py`, which neutralises
them at build time by zeroing the affected `illum_x_sens` rows.

### 3. `fastmath=True` deletes NaN checks

Numba's `fastmath` asserts no-NaN, so an `if np.isnan(x)` guard inside a
`fastmath` kernel is not reliably preserved. Handle NaN by sanitising
constants outside the loop, never with an in-loop branch.

### 4. Chunks must outnumber workers

For `parallel_pointwise`: one chunk per worker puts every chunk in flight
simultaneously, so concurrency re-multiplies exactly what chunking divided.
12 chunks / 12 workers → 6.86 GB. 64 chunks / 12 workers → 1.64 GB, same wall
time. Also: write into a preallocated output; `np.concatenate` at the end
holds a full-size copy and discards the win.

### 5. MLX is lazily evaluated

An unevaluated graph retains every intermediate — precisely the failure this
port exists to fix. Place explicit `mx.eval()` barriers at node boundaries.
Treat as a correctness requirement, not tuning.

Also: expressing a stage in stock MLX ops allocates an array per operation.
`compress_rgb` in stock MLX would be ~3.8 GB of intermediates at 16 MP. Only a
**fused** kernel gets memory to input+output. Putting something on the GPU
fixes speed; only fusion fixes memory.

### 6. float16 is not free

fp16's smallest subnormal is ≈5.96e-8, so the `1e-10` epsilon in
`np.log10(np.fmax(raw, 0.0) + 1e-10)` underflows to exactly 0 and `log10(0)`
gives `-inf`. Measured fp16 storage error on the spectral kernel is 2.7e-3
relative. fp16 is also **not faster** here (6.9 ms vs 6.8 ms) — the kernels
are compute-bound, not bandwidth-bound. Use float32 on macOS.

### 7. colour-science silently promotes to float64

`colour.RGB_to_RGB`, `RGB_to_XYZ` etc. return float64 regardless of input
dtype. The RAW loader's docstring claims float32 output; it returns float64
once a colourspace conversion runs.

Also: `colour.RGB_to_RGB(x, 'sRGB', 'sRGB', apply_cctf_encoding=True)` runs a
full colourspace conversion with an identity matrix just to apply a transfer
function. `colour.cctf_encoding` is 2.5× faster — but gives a 3.0e-4
difference, so verify which curve variant is wanted before swapping.

**This used to defeat float32 entirely** — casting at the door did nothing,
because the first colourspace conversion upcast straight back (measured 5.61
vs 5.57 GB at 16 MP). **Fixed in RFC-006**: the kernels are dtype-preserving
now and `working_precision` is enforced on node *inputs* as well as outputs.
The two colour-science call sites in `scanning.py` are the pattern to copy —
`_scan_xyz_to_rgb` became a matmul against the identity-trick matrix (exact
to 1.3e-15), and `_scan_cctf` keeps `colour.RGB_to_RGB` verbatim but runs it
through `parallel_pointwise(..., out_dtype=...)` so the float64 it insists on
returning exists one chunk at a time. Do not swap `RGB_to_RGB` for the bare
`cctf_encoding`: for a same-space call the former also applies a
near-identity CAT02 round-trip matrix, and dropping it moves output by 3.8e-4.

### 8. Approximating a distribution can preserve RMS and still change the look

`fast_stats` reproduces grain RMS granularity to within 0.14% and flattens
**skewness to zero at every density**. Skewness is `1/sqrt(mu)` and `mu` rises
with density, so it encodes film's shadow-vs-highlight grain character
(+0.165 in shadows, +0.022 in highlights). Matching the second moment is not
evidence that a noise model is equivalent — check the third.

Use `grain_sampler='exact'` (default): Poisson-thinned, exact, 27× faster than
scipy. `use_fast_stats` is preview-only. See RFC-002 §3.4.

### 9. Grain draws are i.i.d. — chunking them creates no seam

The per-pixel draws have no spatial correlation, so partitioning them produces
a different realisation and no boundary artefact. Seams come only from the
blurs (`grain_blur`, micro-structure), which need ~4 px halos if you ever tile
them. Do not avoid chunking the draws out of seam fear; do not chunk the blurs
without halos.

### 10. `skimage.transform.rescale` is a hidden 7 s at 45 MP

`auto_exposure` builds a 256px preview with `rescale(..., order=0)`; for a
45 MP frame that full-resolution pass measured **7.1 s** — it was the single
biggest line in the decoupled profile (more than the actual multiply, 0.02 s,
or the meter, 0.003 s). The preview only needs a sparse sample of the frame,
so `small_preview` now uses a nearest stride-slice (`image[::step, ::step]`),
which is O(1) and collapses auto_exposure to ~0.1 s. GPU wouldn't have fixed
this — it was a CPU downscale, not a pointwise multiply. Profile before
concluding a stage is GPU-bound: isolate the sub-steps.

---

## Conventions

- Match surrounding style: the codebase uses NumPy-style docstrings, explicit
  named parameters, and numba `@njit(parallel=True, cache=True)` for hot loops.
- New backends go behind a `settings.*_backend` string. The spectral backend
  default is now `'mlx'` (MLX-first, RFC-001); if MLX is unavailable the
  render raises loudly rather than silently using the CPU path. Never change
  a default that alters output without saying so.
- The GUI (`spektrafilm_gui.params_mapper`) forces `spectral_backend='mlx'`
  so persisted states cannot revert to a CPU path. MLX launches require real
  Metal access, so GPU work (and the GUI itself) must run outside the sandbox.
- RFC-003 pipeline decoupling has landed: `runtime/pipeline.py` builds ~24
  effect-level `Node`s (e.g. `filming.expose.upsample` ... `scanning.cctf`)
  instead of the six monoliths, with the monolith methods kept as thin
  wrappers over the same effect methods. It is a pure refactor (output is
  bit-identical; `tests/test_rfc003_split.py` guards the structure). The split
  itself does **not** cut peak memory at float64 (measured 12.38 GB / 275 B/px
  at 45 MP vs 12.58 GB / 280 B/px pre-split): the biggest temporaries are
  float64 *inside* the kernels (spectral upsampling colour conversion,
  halation blurs, grain sublayers, CAM16 gamut compression). Real memory
  reduction needs kernel-level float32 / per-node precision, which is deferred
  (measured ΔE max 2.42 / MS-SSIM 0.9955 on the GUI config — fails the strict
  bar). Effect labels above are also the timing keys `get_timings()` returns.
- RFC-004 GPU port has landed its P0–P2 kernels: `backends/mlx_ops.py` has the
  device wrapper/residency primitive plus float32 pointwise kernels
  (`gpu_scale`/`gpu_log10`/`gpu_boost`/`gpu_cctf_srgb`) and a separable Gaussian
  Metal kernel (`gpu_separable_gaussian`). They are wired into the pipeline
  behind `settings.gpu_backend='mlx'` (default `''` = CPU reference, unchanged).
  Validation (deterministic, ProPhoto→Display P3): GPU vs CPU float64 gives ΔE
  max 6.1e-5, PSNR 150 dB, MS-SSIM 1.0 — visually identical. The `Node` GPU body
  is `run_mlx` (single-read/write); per-node GPU runs upload+download, so the
  P0 residency *grouping* (a device-resident run) is still to be added, and only
  exposure/boost/log/lens_blur/scanner_blur/cctf are ported (the dominant
  `upsample`, `halation`, `grain`, `gamut_compress` are P3/P4/P5). Keep grain +
  glare OFF for any CPU-vs-GPU ΔE comparison (RFC-001 6.0/6.1): the stochastic
  grain realisation differs once upstream floats to float32.
- RFC-004 P1 pointwise color stages added: `gpu_xyz_to_rgb` (3x3 matmul; the
  matrix is `colour.XYZ_to_RGB(np.eye(3), cs, illuminant=...)`, and the node
  result is `xyz @ matrix`) and `gpu_curve_interp` (a small Metal LUT kernel
  matching `fast_interp`: endpoint clamp, binary search, right-biased exact
  match). Curves and XYZ→RGB are now GPU-wired. At 45 MP (deterministic,
  ProPhoto→Display P3) the GPU path is ΔE max 0.000086 / MS-SSIM 1.0, time
  ~22.6 s vs ~25.4 s CPU, peak 12.2 GB. The precision map (float64 CPU color
  reference vs float32 GPU) is the deliberate RFC-004 policy: `upsample` and
  `gamut_compress` (CAM16) stay float64 for color accuracy; grain/glare stay
  exact (off in A/B).
  **Trap:** the curve `x_axis` must be `(K, 3)` — the scalar density-curve
  gamma must be expanded to 3 channels (`np.repeat(gamma, 3)`), otherwise the
  axis is `(K, 1)` and the kernel reads 3 columns of garbage (measured 2.05
  error). Mirror `interpolate_exposure_to_density`'s `gamma_factor` expansion.
- RFC-005 (dispatch + kernel quality) landed. Four things to know:
  **(1) A GPU tag was silently a precision decision.** A node with
  `backend=('mlx',)` returned float32, which propagated into every downstream
  CPU stage — so removing a tag changed *numerics*, not just placement.
  `Node.precision` is now honoured by the dispatcher and the float32 taps are
  declared explicitly. Never add or remove a `backend` tag without checking
  what it does to the tap dtype.
  **(2) `prune_identity_nodes` aliases taps.** Dead-node elimination must
  rewrite downstream `reads` through the dropped node's read tap, or the
  successor can never fire. Four nodes are pruned at default params (both
  blurs, diffusion filter, unsharp).
  **(3) `to_device` passes `mx.array` through.** Calling it on a device array
  used to round-trip via host (37.5 ms at 45 MP); a single blur did four.
  **(4) Bare-Metal/metal-cpp was measured and rejected**: a Python →
  `mx.fast.metal_kernel` launch is 157 µs, ~0.07% of the render.
  `mx.fast.metal_kernel` already compiles hand-written MSL — those kernels
  *are* bare Metal.
- RFC-007 A (CPU fusion) landed: `utils/fused_gamut_cam16.py` and
  `utils/fused_tc_b.py`. 45 MP interleaved A/B: **18.93 s → 12.93 s (-31.7%)**,
  dE2000 max 0.000041, 0 of 16.0 M pixels above dE 0.1. `upsample` 3.97 → 0.59 s,
  `gamut_compress` 4.32 → 1.38 s. The pattern: **colour-science stays at setup
  time** (matrices via the identity trick, viewing-condition constants, the
  C_max table), and only per-pixel math is fused. Use `_FORCE_REFERENCE_CAM16` /
  `_FORCE_REFERENCE_TC_B` to A/B the two paths in one process.
  **Traps, all of which produced plausible-looking wrong output:**
  the CIECAM02 inverse (a,b) solve carries 460/1403, 220/1403, 27/1403 and
  6300/1403 factors (omitting them: dE 33); colour uses a *sign-preserving*
  power for J, so negative achromatic response gives negative J, not 0;
  the GUI default sets `lightness_compression`, so a kernel that skips it
  falls back to the reference and becomes **dead code on every real render**
  while unit tests pass — the A/B is what caught it; the reference accepts any
  `(..., 3)` shape, not just `(H, W, 3)`.
  **Never call a `parallel=True` numba kernel from inside `parallel_pointwise`**
  — numba's `workqueue` layer is not threadsafe and aborts the process.
  `_scan_gamut_compress` bypasses the thread pool for the fused path.
- **RFC-006 landed: `working_precision='float32'` is the default.** The
  invariant is in `utils/precision.py`: full-resolution buffers follow their
  input's dtype, per-pixel arithmetic still runs in float64 registers (a
  float32 load times a float64 constant promotes inside the numba kernel, so
  CAM16 / Hanatos / the spectral integral do the same arithmetic they always
  did — only the *stored* result narrows). Measured at 45 MP, grain on
  (`exact`), glare off: **18.34 s / 12.55 GB at float64 vs 14.25 s / 7.15 GB
  at float32**, dE2000 max 0.00024, MS-SSIM 1.000000, grain PSD correlation
  0.999993. Held across five film/print stock pairs.
  **Trap:** `working_precision='float64'` used to be spelled `precision=None`
  in `run_topology` — "leave every dtype alone". That was only equivalent to
  float64 because every kernel promoted internally. Once the kernels stopped
  promoting, the taps RFC-005 declared `precision='float32'` leaked downstream
  into `grain`, where a rounded input flips Poisson draws and gives a
  *different realisation* — dE max 37.9 against the baseline, which looks like
  a catastrophic colour bug and is actually one node's worth of noise.
  `run_topology` now widens node inputs to the working precision as well as
  narrowing outputs. Side effect: the float64 path is now genuinely float64
  (it previously carried accidental float32 rounding in exposure/boost/
  halation), which moved the float64 baseline by dE max 0.000188 / PSNR 151 dB.
- The 45 MP profile after RFC-007 A is **spatial-dominated**: halation 3.30 s
  (26%), dir_couplers 2.40 s (19%), scan_spectral 1.58 s (12%). Neither of the
  top two fuses the way the pointwise stages did (halation is `support=inf`).
  Estimates written against the old pointwise-heavy profile are stale.
- **Measure interleaved, never sequentially.** This machine drifts: the same
  unchanged commit measured 23.3 s and 18.9 s hours apart. Stash/pop or use the
  `_FORCE_REFERENCE_*` switches and alternate arms within one session.
- Anything claiming a speed or memory win must come with a measurement in the
  same message. `tracemalloc` for allocation, `resource.getrusage` for RSS.
- Quality claims need a ΔE number from `compare.py`, not an eyeball.

## Do not

- Do not commit or push unless asked.
- Do not add GPL-incompatible dependencies. The code is GPL-3.0-or-later; the
  profiles under `data/profiles/` are CC BY-SA 4.0 with separate attribution
  obligations.
- Do not change `SPECTRAL_SHAPE`, the profile data, or `LOG_EXPOSURE` — every
  baseline assumes them.
