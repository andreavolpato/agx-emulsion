# RFC-001: MLX/Metal Backend for the spektrafilm Runtime

| | |
|---|---|
| **Status** | Draft |
| **Author** | Hanze Qiu |
| **Created** | 2026-08-24 |
| **Target** | Apple Silicon (M3 Max, 36 GB unified) → later A-series |
| **Upstream** | `andreavolpato/spektrafilm` @ `3bb2c2d` |

---

## 1. Motivation

The Python runtime is correct and is the reference implementation, but it has two
properties that block interactive full-resolution use:

1. **Peak memory scales at ~1.4 kB/pixel** when the spectral LUTs are disabled
   (the library default). A 45 MP frame needs ~63 GB; a 16 MP frame needs ~22 GB.
   On a 36 GB machine the 45 MP path swaps or dies.
2. **Throughput is ~10 s at 6 MP** (README), so full-resolution work is a
   batch operation rather than an interactive one.

Both trace to the same root cause: the pipeline materialises whole-image
intermediates in `float64`, and two stages expand to `(H, W, 81)` spectral
tensors to compute what is algebraically a 3-in/3-out function.

This RFC specifies a GPU backend that removes both problems, and — as a
precondition — the CPU-side restructuring that makes a GPU port expressible at
all.

### Non-goals

- Bit-exact equivalence with the NumPy path. See §6 for the equivalence bar.
- Porting the GUI, the LUT creator, or the profile fitting tools.
- iOS delivery. Architecturally in scope, not in this RFC's milestones.

---

## 2. Background: where the memory goes

Measured per-pixel cost of live buffers in the default (`use_*_lut=False`) path:

| buffer | bytes/px |
|---|---|
| `(H,W,3) float64` | 24 |
| `(H,W,81) float64` | **648** |
| `(H,W,81) bool` (the `np.isnan` mask in `conversions.py:24`) | 81 |
| `(H,W,3,3) float64` (grain sub-layers) | 72 |

Peak inside `printing._film_cmy_to_print_log_raw` (`printing.py:81-88`):
`density_spectral` (648) + `transmitted` (648) + nan mask (81) + in/out (48)
≈ **1.4 kB/px**. `scanning._return_callable_cmy_to_log_xyz` repeats it.

Contributing secondary costs:

- `run_topology` (`topology.py:60`) accumulates every intermediate tap into one
  `state` dict and frees nothing until the run returns — 7 × `(H,W,3) float64`
  = 168 B/px held simultaneously.
- `_preprocess` (`pipeline.py:192`) upcasts the `float32` RAW to `float64`.
- `printing.py:80` allocates `np.zeros_like(cmy_film_density)` and overwrites it
  at line 88 without reading it.
- `_film_cmy_to_print_log_raw` returns `log10(...)` (line 91) and `expose`
  immediately computes `10**` of it (line 53). Same in scanning (line 120 → 74).
  Two full-image transcendental passes that cancel, present only because the
  optional LUT interpolates in log space.

---

## 3. Design

### 3.1 The central transform: fuse, don't tabulate

Both spectral stages compute

$$\text{out}_m = \sum_{\lambda} I(\lambda)\,S_m(\lambda)\;10^{-\left(\sum_k c_k D_k(\lambda) + D_{\text{base}}(\lambda)\right)}$$

Three inputs, three outputs, 81 accumulation steps, **no intermediate storage
required**. Expressed as a fused kernel, the 81-axis lives in registers:

```
for each pixel (c0, c1, c2):
    a0 = a1 = a2 = 0
    for l in 0..80:
        d = c0*D[l,0] + c1*D[l,1] + c2*D[l,2] + Dbase[l]
        t = exp2(-d * log2(10))
        a0 += t*IS[l,0];  a1 += t*IS[l,1];  a2 += t*IS[l,2]
```

- `IS[l,m] = I(l)·S_m(l)` is precombined at parameter-change time (constant
  across pixels), removing one multiply from the inner loop.
- `exp2` is a hardware instruction; `pow(10, x)` is not.
- Memory drops **1.4 kB/px → 48 B/px** (input + output only).
- This is **exact**. It is strictly more accurate than the existing
  `use_enlarger_lut` / `use_scanner_lut` path, which interpolates a 17³ grid.

The constant tables are 81×3 `float32` = 972 B each — they fit in threadgroup
memory with room to spare.

This kernel is the highest-value single change in the RFC and it is valuable on
CPU alone. It lands as a Numba kernel in M1 before any Metal code exists.

### 3.2 Precision policy

The brief specifies Float16. Adopted **for storage**, with `float32` compute and
accumulation. Rationale:

- The memory goal is served entirely by fp16 *storage*. Halving compute
  precision buys nothing on Apple GPUs for this workload, which is not
  ALU-bound after §3.1.
- fp16 has hard failure modes in this pipeline:
  - **`1e-10` underflows to zero.** fp16's smallest subnormal is ≈5.96e-8. The
    epsilon in `np.log10(np.fmax(raw, 0.0) + 1e-10)` (`printing.py:61`,
    `scanning.py:120`) becomes exactly 0, so `log10(0) = -inf` propagates. The
    epsilon must be raised to ≥1e-4 or the clamp restructured.
  - **Linear irradiance spans ~20 stops** after highlight boost and halation.
    fp16's 5-bit exponent covers 6e-5…65504, which is ~30 stops nominal but
    loses relative precision badly near both ends.
  - **81-term accumulation in fp16** loses ~1e-3 relative — visible as banding in
    smooth gradients, which is exactly where this pipeline is scrutinised.
- Policy: textures and inter-stage tensors `float16`; all reductions,
  transcendentals, and the `§3.1` accumulator in `float32`.

This is the standard GPU mixed-precision pattern and it delivers the memory
target without the cliffs. If measurement shows fp32 storage is affordable at
16 MP, storage precision is a one-line change.

### 3.3 Backend choice: MLX, with explicit evaluation barriers

| option | verdict |
|---|---|
| **MLX** | **Chosen.** NumPy-shaped API, unified memory, auto Metal compilation, `mx.fast.metal_kernel` for custom MSL where needed. Lowest friction; most of the pipeline is elementwise and maps to MLX ops directly. |
| PyObjC + raw Metal | More control, much more boilerplate. Reserve for kernels MLX can't express. |
| pybind11 C++ shim | Only if shipping demands it. |

**Critical caveat: MLX is lazily evaluated.** A long unevaluated graph keeps every
intermediate alive, which is precisely the failure mode this RFC exists to fix.
The backend must place explicit `mx.eval()` barriers at each pipeline node
boundary and drop Python references to consumed taps. Treated as a correctness
requirement, not an optimisation — it is called out in the M3 acceptance
criteria.

### 3.4 Topology restructuring (prerequisite)

`runtime/topology.py` already has the right abstraction (`Node(reads, writes,
run, label)`), but the current graph is 6 coarse nodes that each bundle several
physically distinct effects. `filming.expose` alone does spectral upsampling,
exposure compensation, highlight boost, diffusion filter, lens blur, in-emulsion
scatter, back-reflection halation, and the log conversion.

Split to one node per effect:

```
rgb_pre → upsample → boost → diffusion_filter → lens_blur
        → scatter → halation → log_e_film
        → curves → dir_couplers → grain → cmy_film
```

This is required, not cosmetic:

- Each node can then be classified **pointwise / spatial / stochastic**, which is
  what determines its GPU kernel shape. That classification is currently
  impossible because the categories are tangled inside two functions.
- It gives each node a declared spatial support, which is what a tile scheduler
  needs to compute halos.
- It delivers the independent bypass/reorder controls wanted for the
  professional tuning surface.

Node classification drives the port:

| class | nodes | Metal shape |
|---|---|---|
| pointwise | upsample, boost, curves, spectral stages, gamut compress, output CCTF | fused elementwise kernels |
| spatial | diffusion_filter, lens_blur, scatter, halation, coupler diffusion | separable convolution passes |
| stochastic | grain | counter-based RNG kernel |

### 3.5 Per-stage mapping

| stage | implementation |
|---|---|
| RGB → tc, b | pointwise; 3×3 matrix constant, `_tri2quad` inline |
| tc_lut lookup | 192×192 texture, hardware bilinear. Prebake at 2× resolution rather than porting the Mitchell bicubic — cheaper and visually identical |
| density curves | 3 × 256 samples → 1D texture, linear filtering, free |
| DIR couplers | 3×3 matmul + separable blur + subtract + second curve sample |
| Gaussian blurs | two 1-D passes via threadgroup memory; large σ via downsample→blur→upsample |
| diffusion filter | **no FFT** — `_radial_components` already expresses the PSF as `Σ wᵢ exp(-r/λᵢ)`; realise as separable Gaussian mixture, removing `fftconvolve`'s 4× padding cliff |
| spectral stages | §3.1 fused kernel |
| grain | §3.6 |
| gamut compression | pointwise; `C_max(L,h)` → 2D texture |

### 3.6 Grain

The one stage that cannot be a mechanical port. `np.random.seed(seed)` per
channel (`grain.py:23`) is order-dependent and has no GPU analogue.

Replace with a **counter-based RNG** (Philox 4×32-10) keyed on
`(global_x, global_y, channel, sublayer, image_seed)`. Stateless, deterministic
per pixel, no inter-thread sequencing. This change is independently required for
tiled CPU rendering — without it every tile draws the identical noise field and
seams appear — so it is worth doing regardless of the GPU work.

Distribution samplers port from `utils/fast_stats.py` essentially 1:1:
Knuth for Poisson λ<10, Hörmann PTRS for λ≥10; BTRS for Binomial. Note λ here is
`pixel_area_um² / particle_area_um²` ≈ 125 at 5 µm/px, so the large-λ path
dominates.

**Consequence for validation:** grain output will not match the NumPy baseline
per-pixel, by construction. See §6.2.

---

## 4. Test baseline

### 4.1 Input

Source: `tmp/_DSC2439.NEF` (Nikon Z7 II, 45 MP).

**Decision: the baseline is a linear float TIFF, not a DNG.**

The brief asked for a 16 MP DNG. For a Python-vs-Metal equivalence test that is
the wrong artifact, because both backends would decode it through the same
`rawpy` path — RAW decoding is a shared prefix that adds a confounding variable
and tests nothing about the port. Removing it from the comparison is better
experimental design.

Procedure:
1. Decode the NEF once via `load_and_process_raw_file` → linear ACES2065-1.
2. Convert to linear ProPhoto RGB (the documented pipeline input space).
3. Downsample 45 MP → 16 MP (Lanczos, `skimage.transform.resize`).
4. Write `tests/baseline/_DSC2439_16mp_linear_prophoto.tif`, 32-bit float.

Both backends then consume byte-identical input. Deterministic and re-runnable.

DNG conversion remains available if wanted for the iPhone-path work later, but
it requires Adobe DNG Converter, which is **not installed on this machine** —
that would be a separate task with a manual install step.

### 4.2 Configuration

Baseline runs use `use_enlarger_lut=True`, `use_scanner_lut=True`,
`lut_resolution=17` — matching what the GUI sets (`params_mapper.py:105`) — so
the reference is the configuration a user actually experiences, and so the
NumPy baseline fits in 36 GB at 16 MP.

A second reference run with LUTs off provides the ground truth against which
§3.1's exactness claim is checked.

---

## 5. Output format

`save_image` already supports PNG (`io.py:288`); only the GUI's default filename
is `.jpg` (`controller.py:328-330`).

Two changes:
1. Default the GUI export name to `.png`.
2. **Add 16-bit PNG.** The current PNG branch is uint8-only, which is lossless
   but no more editable than JPEG in terms of tonal headroom. PNG supports
   uint16 natively and OIIO writes it. `bit_depth=16` on a `.png` should produce
   uint16 — this is what actually delivers the stated "higher post-editing
   possibility."

---

## 6. Equivalence metric

Requirement: differences between NumPy and MLX output must be **not visible to
the human eye**. Operationalised in two modes, because grain is stochastic.

### 6.0 Sources of nondeterminism

Grain is **not** the only stochastic stage. `model/glare.py`'s
`compute_random_glare_amount` draws an **unseeded** lognormal field via
`fast_lognormal_from_mean_std` on every call, and `print_render.glare` /
`film_render.glare` are both active by default.

Measured consequence: two renders with **identical configuration and the same
backend** differ by up to **0.042** — larger than the difference between the
reference and fused backends being tested. Any per-pixel equivalence test
that leaves glare on is measuring glare noise, not the port.

With glare disabled the pipeline is bit-exact run to run (max abs diff
`0.0`), and the backends then compare cleanly:

| comparison | max abs diff |
|---|---|
| reference vs reference (2 runs) | 0.0 |
| numba fused vs reference | 7.99e-15 |
| mlx float32 vs reference | 1.97e-06 |

Deterministic mode must therefore disable **grain and glare**. Separately,
glare should be given a seed parameter so it can be made reproducible without
being switched off — it is a visual feature, not just noise, and the tiled
renderer will hit the same seam problem with it that grain has.

### 6.1 Deterministic mode (grain and glare disabled)

Per-pixel comparison in a perceptually uniform space.

| metric | bar | rationale |
|---|---|---|
| **ΔE2000 mean** | < 0.5 | Half of the classic 1.0 JND for side-by-side flat patches |
| **ΔE2000 p99** | < 1.0 | 1.0 = JND under ideal comparison conditions |
| **ΔE2000 max** | < 2.0 | Bounds isolated outliers (e.g. LUT cell boundaries) |
| **PSNR** | > 50 dB | Conventional "visually lossless" floor |
| **MS-SSIM** | > 0.999 | Catches structural artifacts ΔE averages away |

ΔE2000 is computed via `colour.difference.delta_E_CIE2000` after converting both
outputs to CIELAB under the output color space's whitepoint. MS-SSIM via
`skimage.metrics`. No new dependencies.

**Gradient banding check.** The metrics above are averages and can mask
fp16 quantisation banding, which is the specific risk of §3.2. Add a synthetic
16-bit gray-ramp and a saturated-hue sweep to the test set, and assert the
second derivative along the ramp has no steps exceeding 1 LSB at 16-bit.

### 6.2 Stochastic mode (grain enabled)

Per-pixel comparison is meaningless — different RNG, different noise field.
Compare distributions instead:

| metric | bar |
|---|---|
| per-channel grain mean | within 1% |
| per-channel grain RMS | within 2% |
| skewness, kurtosis | within 5% |
| radially-averaged PSD | correlation > 0.98 |

The moments mirror what `grain.py`'s `__main__` block already reports. The PSD
check is the one that matters: grain is characterised by its spatial frequency
distribution, and a sampler that gets the moments right but the correlation
structure wrong will look obviously wrong while passing a moments-only test.

### 6.3 Reporting

The harness emits a side-by-side PNG, a ΔE heatmap, and a JSON metrics blob per
run, so regressions are inspectable rather than just numeric.

---

## 7. Memory budget

Target at 16 MP:

| path | peak |
|---|---|
| NumPy, LUTs off (today) | ~22 GB |
| NumPy, LUTs on (today) | ~7 GB |
| NumPy + §3.1 + tap freeing + fp32 | ~1.5 GB |
| MLX, fp16 storage | **~0.4 GB** |

Instrumentation: peak RSS via `resource.getrusage` on CPU, `mx.get_peak_memory()`
on MLX, asserted in the harness. A run that exceeds its declared budget fails
the test — memory is a tested property, not an observed one.

---

## 7a. Measured results (2026-08-24)

All figures on M3 Max / 36 GB, Portra 400 → Portra Endura, from
`tests/baseline/`.

### Reference pipeline, 16 MP

| run | wall time | peak RSS | bytes/px |
|---|---|---|---|
| NumPy, LUTs on, grain on | 33.1 s | 13.07 GB | 817 |
| NumPy, LUTs on, grain off | 31.8 s | 12.9 GB | ~810 |

Fits in 36 GB, confirming 16 MP as a workable baseline size. The LUTs-off
path was not run at 16 MP — extrapolating the measured 1944 B/px puts it at
~31 GB, which would thrash.

### Fused spectral kernel vs. reference array path (§3.1)

| size | max rel err | time (ref → fused) | peak alloc (ref → fused) | bytes/px |
|---|---|---|---|---|
| 0.26 MP | 2.1e-15 | 170 → 7.0 ms (24×) | 510 → 6.3 MB (81×) | 1944 → 24 |
| 4.19 MP | 2.4e-15 | 2763 → 85 ms (32×) | 8154 → 101 MB (81×) | 1944 → 24 |

**Exact** to float64 reassociation noise, as claimed. The memory reduction is
81× — the full `(H,W,81)` collapse.

### MLX/Metal kernel, 16 MP (3264×4901)

| backend | time | vs NumPy-fused | peak GPU | max rel err |
|---|---|---|---|---|
| NumPy fused (f64) | 315.8 ms | 1× | — | — |
| **MLX float32** | **6.8 ms** | **46×** | 384 MB | 1.3e-6 |
| **MLX float16** | **6.9 ms** | **46×** | **192 MB** | 2.7e-3 |

Against the *original* array path (extrapolated ~11 s at 16 MP), the MLX
kernel is roughly **1600× faster** using **192 MB instead of ~31 GB**.

**Two findings that revise the RFC:**

1. **fp16 is not faster than fp32 here** (6.9 vs 6.8 ms). The kernel is
   compute-bound on the 81-iteration loop, not bandwidth-bound, so half
   precision buys memory (2×) and nothing else. §3.2's "fp16 for storage,
   fp32 for compute" is therefore the right call for the wrong reason — and
   if the fp16 error proves visible, reverting storage to fp32 costs only
   memory, not speed.
2. **fp16 storage error is 2.7e-3 relative.** That is ~0.7 LSB at 8-bit but
   ~180 LSB at 16-bit. Whether it is *visible* is exactly what §6.1's ΔE2000
   bars decide; this is the open question blocking a precision decision, and
   it must be answered on the real image, not on synthetic uniform noise.

### Harness validation (§6)

| check | result |
|---|---|
| reference vs itself | ΔE2000 = 0.000000, PSNR = inf, MS-SSIM = 1.0 — **PASS** |
| grain vs no-grain (sensitivity) | ΔE mean 3.07, p99 12.07, max 27.7 — **FAIL**, as it must |

The harness both confirms identity and detects a real difference, so a PASS
carries information.

---

## 7b. M1.5 results: chunked-parallel pointwise stages

Profiling the 16 MP run showed the port had been aimed at the wrong stage.
The fused spectral integral is 2.6% of wall time; **output gamut compression
is ~50%**:

| sub-step of scanning.scan_print | time |
|---|---|
| `compress_rgb` [cam16ucs] | 8.52 s |
| `XYZ_to_RGB` | 0.96 s |
| cctf encode | 0.81 s |
| `10**log_xyz` | 0.32 s |
| spectral integral (MLX) | 0.17 s |

`compress_rgb` runs a full CAM16 forward *and* inverse per pixel. It cannot be
tabulated (a 65^3 LUT still errs 6.9e-3, because the Reinhard knee has a sharp
corner at `threshold = 0` and CAM16 destabilises outside the plausible range)
and it cannot be masked (with `threshold = 0` the knee is never formally
identity). But it is **purely pointwise**, so it parallelises with no halo.

Two non-obvious requirements to get both speed and memory:

1. **Chunks must outnumber workers.** One chunk per worker puts every chunk in
   flight at once, so concurrency re-multiplies what chunking divided:
   12 chunks / 12 workers gave 6.86 GB; 64 chunks / 12 workers gave 1.64 GB at
   the same wall time.
2. **Write into a preallocated output.** `np.concatenate` of the results holds
   a full-size copy at the end and discards the win.

Threads, not processes: NumPy releases the GIL in its elementwise ufuncs, so a
thread pool gets real parallelism without paying macOS `spawn` startup and a
~2 s colour-science re-import per worker.

### Measured, 16 MP

| | before M1.5 | after M1.5 |
|---|---|---|
| wall time | 17.29 s | **8.14 s** (2.12x) |
| peak RSS | 13.31 GB | **6.15 GB** (2.16x) |
| bytes/px | 832 | **384** |
| `scanning.scan_print` | 11.3 s | **2.31 s** (4.9x) |

Output bit-exact vs the serial path; end-to-end DeltaE vs the pre-M1.5 render
unchanged at mean 0.000017 / max 0.000257 (that residual is numba-vs-MLX
float32, not the wrapper).

This also confirms the §7a open question: `compress_rgb` *was* the dominant
memory term. Total peak fell 7.2 GB, and its standalone allocation fell from
7.29 GB to 1.64 GB.

### Remaining profile after M1.5

| stage | time | % |
|---|---|---|
| filming.expose | 2.66 s | 32.7% |
| scanning.scan_print | 2.31 s | 28.4% |
| preprocess | 1.46 s | 17.9% |
| filming.develop | 865 ms | 10.6% |
| printing.expose | 758 ms | 9.3% |

`filming.expose` is now the leading term and has not been broken down yet.

---

## 8. Milestones

| # | deliverable | validation |
|---|---|---|
| **M0** ✅ | Environment, 16 MP baseline TIFF, eval harness, NumPy reference outputs | **Done** — harness verified at ΔE = 0, sensitivity check fails correctly |
| **M1** ◐ | Fused spectral kernel (Numba) ✅ exact + 32× + 81× less memory. Still open: tap freeing, dead-alloc and log-roundtrip removal, wiring the kernel into the stages | Matches reference to 2.4e-15 |
| **M2** | Topology split into per-effect nodes | Existing baselines unchanged |
| **M3** ◐ | MLX backend: spectral kernel ✅ (46×, 192 MB). Still open: remaining pointwise stages, `mx.eval()` barriers, end-to-end wiring | §6.1 bars met, grain disabled; memory budget asserted |
| **M4** | MLX spatial stages (blurs, halation, diffusion filter) | §6.1 bars met with spatial effects on |
| **M5** | MLX grain with Philox RNG | §6.2 bars met |
| **M6** | 16-bit PNG, GUI export default | Round-trip test |

M1 and M2 are upstreamable independently of any GPU work and are worth landing
on their own merits.

---

## 9. Risks

| risk | severity | mitigation |
|---|---|---|
| MLX lazy graph retains intermediates, defeating the memory goal | **high** | Explicit `mx.eval()` barriers; memory asserted in tests (§7) |
| fp16 banding in smooth gradients | **high** | fp32 compute (§3.2); explicit ramp test (§6.1) |
| `1e-10` epsilon underflow in fp16 | high | Identified; raise epsilon or restructure clamp |
| Grain PSD mismatch after RNG swap | medium | PSD check in §6.2; tune dye-cloud blur to match |
| MLX lacks a primitive some stage needs | medium | `mx.fast.metal_kernel` escape hatch |
| Numba↔MLX divergence in curve interpolation at knots | low | Shared test vectors at curve breakpoints |

---

## 10. Open questions

1. Should the MLX backend live in-tree behind a `backend=` parameter, or as a
   separate package depending on spektrafilm? In-tree is better for testing;
   out-of-tree avoids forcing an MLX dependency on Linux users. **Worth asking
   upstream before M3.**
2. Does upstream want the fused spectral kernel (M1) as a PR? It is a clear win
   for all users and independent of the GPU work.
3. Tiling is deferred here because 16 MP fits without it. It becomes mandatory
   for a Photos-extension memory budget and should be its own RFC.
