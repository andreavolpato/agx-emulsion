# RFC-004: Phased GPU Port (M3)

| | |
|---|---|
| **Status** | Accepted (M3.0) |
| **Date** | 2026-08-24 |
| **Depends on** | RFC-001 (fused spectral, Metal), RFC-002 (grain sampler), RFC-003 (decoupling) |
| **Scope** | `backends/mlx_*`, `runtime/topology.py`, `runtime/pipeline.py`, `runtime/stages/*` |
| **Precision** | float32 compute on device (float64 is not viable on Apple Metal GPUs); float16 *storage* where the ΔE budget allows, float32 accumulate (RFC-001 §3.2) |

---

## 1. Motivation

RFC-003 decoupled the pipeline into ~24 effect-level `Node`s, each classifying
as `pointwise` / `spatial` / `stochastic`. That was the *prerequisite*; the GPU
is still nearly idle. Measured at 45 MP on the frontend path, only the fused
spectral *integral* runs on MLX — and on the LUT-enabled GUI path it fires only
for the 17³ LUT bake and a few 1×1 references. Everything else (spectral
upsampling, exposure, boost, blurs, halation, curves, DIR couplers, grain,
CAM16 gamut compression, colourspace, CCTF, auto-exposure) is CPU
NumPy/colour/scipy/numba.

The profile is flat (top stage ~19% of wall time):

| 45 MP (frontend, split graph, float64) | time |
|---|---|
| `preprocess.auto_exposure` | 7.12 s |
| `filming.expose.upsample` | 5.21 s |
| `filming.develop.grain` | 5.06 s |
| `filming.expose.halation` | 4.33 s |
| `scanning.gamut_compress` | 4.13 s |
| `scanning.cctf` | 2.70 s |
| `filming.develop.dir_couplers` | 2.69 s |
| `scanning.scan_spectral` | 1.75 s |
| **total** | **37.4 s** |

Amdahl again: no hotspot, so the win only appears by moving a *run* of stages to
the GPU and keeping it there. RFC-003 already gave us the dispatch unit (the
`Node`) and the contract surface (`kind`/`backend`/`precision`).

---

## 2. Precision: float32, gated by the human eye

### 2.1 Why float32

Apple Metal GPUs target float32. float64 is not uniformly supported, is often
emulated (slow), and doubles register pressure with no accuracy benefit for a
film-simulation that is validated against a human-eye bar anyway. RFC-001 §3.2
established the GPU mixed-precision pattern: float16 *storage*, float32 compute
and accumulation. This RFC keeps the CPU *reference* path at float64 (it stays
the validation baseline) and moves the production path to float32 on device.

### 2.2 The acceptance gate is visual, not a hard ΔE number

RFC-001 §6.1 proposed hard bars (ΔE2000 mean < 0.5 / p99 < 1.0 / max < 2.0,
PSNR > 50 dB, MS-SSIM > 0.999). At the CPU level, per-node float32 already
breaks that on the GUI config (measured ΔE max 2.42, MS-SSIM 0.9955) — the
culprit is grain + the 17³ LUT + CAM16, not the pointwise matmuls. So RFC-004
does **not** adopt one global number.

The acceptance protocol is:

1. For each phase, render the same input through the **CPU float64 reference**
   and the **GPU float32 path**.
2. Write a sample image for each combination (16-bit PNG + EXR) into
   `tests/baseline/out/rfc004/<phase>/`.
3. Report ΔE2000 (mean / p99 / max), PSNR, MS-SSIM for transparency — but do
   **not** gate on them.
4. **The gate is the user's own eyes on the side-by-side sample files.** If the
   GPU sample is indistinguishable from the CPU reference, the phase is
   approved.

This keeps accuracy reviewable per phase, at the granularity the decoupling now
permits, and avoids a single numbers-threshold debate that the previous
measurements showed is misleading.

---

## 3. Phases

Each phase moves a contiguous set of `Node`s to a GPU backend and keeps them
device-resident for a run (RFC-003 §2.1 / §3.3): one upload at the run head, one
download at the tail, no per-node host↔device round trips.

| phase | nodes moved | GPU approach | buys | risk |
|---|---|---|---|---|
| **P0** | infra + residency; `backend='mlx'` tags | device-array wrapper, run-grouping dispatcher, platform check | the whole model (transfers no longer defeat kernels) | architectural |
| **P1** | `exposure`, `boost`, `log`, `xyz_to_rgb`, `cctf`, `upsample` (colourspace + 2D LUT) | elementwise / small-matrix kernels, `exp2`, hardware lerp | auto_exposure, cctf, xyz↔rgb, most of upsample | low; per-kernel ΔE |
| **P2** | `lens_blur`, `scanner_blur`, `unsharp`, `halation` (scatter + bounce), `dir_couplers` blur | separable 1-D Gaussian/exponential passes via threadgroup memory | blurs + halation + coupler diffusion | medium; halation support is global → no tiling, run full-res on device |
| P3 (later) | `gamut_compress` | fused CAM16-UCS kernel | 4.1 s | high; CAM16 numerics |
| P4 (later) | `grain` | Philox counter-based RNG + distributions + micro-structure blur | 5.1 s | high; determinism, tile-safety, float32 grain |
| P5 (later) | full `upsample`/Hanatos | per-pixel spectral reconstruction kernel | rest of 5.2 s | medium |
| P6 (later) | residency + mempool + fp16 storage; 45 MP acceptance | run-in-graph, device allocator | memory | medium |

### P0 — infrastructure + residency

- Add a shared `mlx` device wrapper and a `run_device_run(path, inputs)` helper
  that keeps a list of `mx.array`s live for the whole run and returns NumPy
  once at the end.
- Tag the nodes a phase moves with `backend=("mlx",)`. The dispatcher groups
  *maximal* consecutive GPU-capable nodes into one device run where the
  boundary taps are float32 arrays (no colour-science promotion between them).
- Non-GPU nodes between runs break residency; the group ends at the first
  non-GPU node.

### P1 — pointwise kernels

- Port `exposure` (scale), `boost` (shifted-exp curve), `log`/`exp`,
  `xyz_to_rgb` (3×3 + adaptation), `cctf` (transfer function), and the
  `upsample` colourspace matrix. These are elementwise/small-matmul and
  precision-safe.
- `upsample`'s 2D bicubic LUT becomes a texture read; the per-pixel 441-λ
  array never materialises.

### P2 — separable spatial kernels

- Port `fast_gaussian_filter` / `fast_exponential_filter` to two 1-D passes
  (threadgroup memory). Use them for `lens_blur`, `scanner_blur`,
  `unsharp`, and the mixer inside `halation` and `dir_couplers`.
- `halation`'s N-bounce loop stays a CPU loop over GPU filters (residency is
  per-filter in P2), tightened to a device-resident run in P6.
- Diffusion filter becomes a Gaussian-mixture PSF, removing the FFT.

---

## 4. Acceptance artifact

The harness that has already validated the split (`tmp/measure_45mp_frontend.py`)
is extended to a CPU/GPU matrix runner producing, for every phase:

- `reference_cpu_<phase>.exr` / `.png` — CPU float64
- `gpu_<phase>.exr` / `.png` — GPU float32
- `deltae_<phase>.json` — ΔE mean/p99/max, PSNR, MS-SSIM

The user reviews the samples; approval is recorded in the phase row above.
