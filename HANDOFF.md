# HANDOFF — 2026-08-24

State of the MLX/Metal port. Read `AGENTS.md` first (traps), then
`ARCHITECTURE.md` (how the pipeline fits together), then this.

**Nothing is committed.** All work is uncommitted in the working tree.

---

## 1. Where the optimisation stands

All numbers: 16 MP (3264×4901), Portra 400 → Portra Endura, M3 Max / 36 GB.

### Exact path (LUTs off, no grain, no glare)

| | wall time | peak RSS | bytes/px |
|---|---|---|---|
| before this work | *not runnable* — ~31 GB projected | | ~1944 (spectral alone) |
| after M1 (fused spectral) | 17.29 s | 13.31 GB | 832 |
| **after M1.5 (parallel pointwise)** | **8.14 s** | **6.15 GB** | **384** |

M1 made the exact LUT-free path *possible* at this size. M1.5 made it
**2.12× faster and 2.16× leaner**.

### Full-quality path (LUTs on, grain, glare — what a user experiences)

| | wall time | peak RSS |
|---|---|---|
| before | 33.13 s | 13.07 GB |
| **after** | **24.10 s** | **6.66 GB** |

**1.37× faster, 1.96× leaner.** The speedup is smaller here because grain
(~16 s) dominates and is untouched.

### Component wins

| change | result |
|---|---|
| fused spectral integral (numba) | 32× faster, **81× less memory** (1944 → 24 B/px), exact to 2.4e-15 |
| same kernel on Metal (MLX) | 46× faster than the numba version; 6.8 ms at 16 MP, 384 MB |
| `parallel_pointwise` on `compress_rgb` | 7.0× faster (9.61 → 1.37 s), 4.4× less memory (7.29 → 1.64 GB), **bit-exact** |

### Quality: nothing sacrificed

| comparison | ΔE mean | ΔE max | PSNR | verdict |
|---|---|---|---|---|
| numba fused vs original array path | — | — | — | exact, 2.4e-15 |
| MLX float32 vs numba | 0.000017 | 0.000257 | 142 dB | **PASS** |
| M1.5 vs pre-M1.5 | 0.000017 | 0.000257 | 142 dB | unchanged |
| parallel vs serial | 0.0 | 0.0 | ∞ | bit-identical |

ΔE 1.0 is the just-noticeable threshold for flat patches side by side. The
worst pixel in the whole image is 0.00026 — roughly four orders of magnitude
below visibility.

---

## 2. What was built

| file | purpose |
|---|---|
| `utils/fused_spectral.py` | fused spectral integral, numba, exact |
| `utils/spectral_dispatch.py` | backend switch `reference \| numba \| mlx` + constant cache |
| `utils/parallel_pointwise.py` | chunked thread-parallel wrapper for pointwise stages |
| `backends/mlx_spectral.py` | custom Metal kernel via `mx.fast.metal_kernel` |
| `tests/baseline/make_baseline.py` | NEF → 16 MP linear ProPhoto TIFF |
| `tests/baseline/run_reference.py` | instrumented runner (wall time + peak RSS) |
| `tests/baseline/compare.py` | ΔE2000 / PSNR / MS-SSIM + stochastic PSD mode |
| `tests/baseline/verify_fused.py` | exactness + memory check for the fused kernel |
| `rfc/RFC-001-metal-mlx-backend.md` | the RFC, updated with all measured results |

Modified: `stages/printing.py`, `stages/scanning.py` (wired the fused kernel and
the parallel wrapper), `params_schema.py` (added `spectral_backend`),
`utils/io.py` (16-bit PNG), `spektrafilm_gui/controller.py` (PNG export default).

---

## 3. Findings worth not rediscovering

**The port was aimed at the wrong stage.** The spectral integral — the thing
the RFC was written around — is 2.6% of wall time. Output gamut compression was
50%. Profile before porting.

**The pipeline is nondeterministic by default.** `glare` draws an unseeded
lognormal field; two identical runs differ by 0.042. This masqueraded as a port
bug for an hour. Grain is the other stochastic stage. Disable both for any
per-pixel comparison.

**Profiles contain NaN** (Portra 400: 22 in `channel_density`, 20 in
`base_density`). The reference path zeroes them via `density_to_light`'s mask;
replacements must reproduce that. And `fastmath=True` deletes in-loop `isnan`
guards, so sanitise constants outside the loop instead.

**A naive GPU port would not have fixed the memory.** In stock MLX ops
`compress_rgb` allocates ~20 full-size intermediates ≈ 3.8 GB. Only a *fused*
kernel reaches input+output. GPU fixes speed; fusion fixes memory.

**Chunks must outnumber workers**, and you must write into a preallocated
output. 12 chunks / 12 workers gave no memory benefit; 64 / 12 gave 4.2×.

**NumPy→MLX transfer is cheap** — 17.2 ms round trip at 16 MP. Incremental
porting is viable; no big-bang rewrite needed.

---

## 4. Next steps, in order

1. **Profile `filming.expose`** (2.66 s, now the leading term in the exact
   path). It bundles spectral upsampling, halation and the diffusion filter —
   three different kernel shapes. Break it down before porting anything.
2. **Grain** (~16 s in the full-quality path, the single biggest item overall).
   Needs a counter-based RNG (Philox) keyed on global pixel coordinates. This
   is required regardless of GPU: without it, tiled rendering produces
   identical noise per tile and visible seams.
3. **CAM16-UCS → MLX** (`compress_rgb`, still 1.37 s after parallelisation).
   ~150–200 lines reimplementing the CAM16 forward/inverse. Validate per-patch
   against colour-science, not just end-to-end ΔE — a subtle error there shifts
   every colour while still looking plausible. The chunked CPU version is the
   reference to check against.
4. **Cheap remaining wins**: `XYZ_to_RGB` → direct einsum (0.96 → 0.13 s,
   exact); tap freeing in `run_topology` (~168 B/px); float32 in `_preprocess`;
   remove the `log10`→`10**` round trip.
5. **M2 topology split** — one node per effect. Prerequisite for tiling and for
   any systematic GPU port.

### Deferred deliberately

- **float16** — measured 2.7e-3 relative error and *no* speed benefit (kernels
  are compute-bound). float32 on macOS. Revisit only for iPhone.
- **Tiling** — unnecessary at 16 MP on 36 GB. Becomes mandatory for a Photos
  extension budget. Own RFC.
- **DNG conversion** — not needed for backend equivalence (RAW decode is a
  shared prefix). Would need Adobe DNG Converter, not installed.

---

## 5. Open questions

1. Should the MLX backend live in-tree behind a `backend=` flag, or as a
   separate package? In-tree is better for testing; out-of-tree avoids forcing
   an MLX dependency on Linux users. **Worth asking upstream.**
2. Does upstream want the fused spectral kernel as a PR? It is a clear win for
   all users and independent of the GPU work. Along with it: the dead alloc at
   `printing.py:80`, the `log10`/`10**` round trip, the unseeded glare, and the
   fact that library defaults leave `use_*_lut` off while the GUI turns them on
   (so `simulate()` callers silently hit the ~31 GB path).
3. Licensing, before any distribution: code is GPL-3.0-or-later, profiles are
   CC BY-SA 4.0 with separate attribution terms. macOS direct distribution
   (signed + notarised `.dmg`, outside the App Store) is compatible; iOS is
   not, in practice.

---

## 6. Housekeeping

- `.DS_Store` files and `tmp/` are untracked and should be gitignored.
- `tests/baseline/out/` holds ~1 GB of EXR/PNG renders — gitignore it too.
- Nothing committed yet; suggest a branch (`metal-backend`) before the next
  round of changes.
