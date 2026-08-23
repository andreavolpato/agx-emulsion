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
| precision | float32 on macOS (see Traps) |

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

Grain is the other stochastic stage.

**Any per-pixel comparison must disable both.** `run_reference.py --no-glare`
plus omitting `--grain` does this. With both off the pipeline is bit-exact
(`np.array_equal` True) run to run.

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

---

## Conventions

- Match surrounding style: the codebase uses NumPy-style docstrings, explicit
  named parameters, and numba `@njit(parallel=True, cache=True)` for hot loops.
- New backends go behind a `settings.*_backend` string, defaulting to the CPU
  path. Never change a default that alters output without saying so.
- Anything claiming a speed or memory win must come with a measurement in the
  same message. `tracemalloc` for allocation, `resource.getrusage` for RSS.
- Quality claims need a ΔE number from `compare.py`, not an eyeball.

## Do not

- Do not commit or push unless asked. Nothing is committed on this fork yet.
- Do not add GPL-incompatible dependencies. The code is GPL-3.0-or-later; the
  profiles under `data/profiles/` are CC BY-SA 4.0 with separate attribution
  obligations.
- Do not change `SPECTRAL_SHAPE`, the profile data, or `LOG_EXPOSURE` — every
  baseline assumes them.
