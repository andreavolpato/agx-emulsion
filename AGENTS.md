# AGENTS.md — working notes for AI sessions on this fork

Fork of `andreavolpato/spektrafilm`. This file records conventions and, more
importantly, the traps that cost real debugging time. Read the traps section
before touching the pipeline.

---

## What this repo is, in one screen

**Two programs and a pipe.** A native macOS app under `modern_UI/`, a Python
render service under `src/`, newline-delimited JSON-RPC 2.0 between them over
stdio with images passed as file paths. `ARCHITECTURE.md` §0 is the map; read
it before reasoning about a symptom, because most confusion in past sessions
came from debugging one half while the other was what had changed.

**Two sessions work here concurrently**, split by
`CONTRACT-frontend-backend.md` §4: frontend owns `modern_UI/**`, backend owns
`src/**`, `tests/**`, `scripts/**`, `rfc/**`. `AGENTS.md`, `ARCHITECTURE.md`,
`API-SPEC-*` and `CONTRACT-*` belong to neither — **say so before editing one**.
§4.1 also forbids rebasing or force-pushing a branch the other side may have
read, and `git stash` / `git clean -fdx` / `git checkout -- .` at the repo root.

**The C++ pieces do not do what their name suggests.** There are two, and
neither is a native render engine — see `ARCHITECTURE.md` §8.5.
`native/spektrafilm-native-host` works and speaks the wire, but it is a
*proxy*: it launches `<repo>/.venv/bin/python -m spektrafilm.service` and
forwards JSON-RPC, so the Python dependency and the bundling problem are
exactly where they were. `scripts/gpu_native/native_host_spike/` is a 17.5 kB
verification harness that proved MLX kernels are byte-identical from C++;
nothing spawns it. **Rendering is Python + Metal in both cases.**

**The engine that renders is chosen by which checkout the app resolves**, not
by a setting. See trap 14.

---

## Environment

The package is **not** installed system-wide. A venv lives at `.venv`:

```bash
cd "/Users/xiaojinqiu/Documents/Summer 2026/spektrafilm"
.venv/bin/python ...            # always use this interpreter
```

There are **two checkouts** of this repo, each with its own venv, each venv's
editable install pinned to its own `src` (see trap 14):

```
~/Documents/Summer 2026/spektrafilm       ui/frontend-fixes    ← the app uses this one
~/Documents/Summer 2026/spektrafilm-gpu   gpu/native-metal
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
| smoke image | `tests/Test_image/_smoke_1mp.tif` (1 MP, for fast iteration) |
| 45 MP frame | `tests/Test_image/Nikon Z7ii/_DSC2439.NEF` (5504×8256) |
| device precision | float32 on macOS (see Traps) |
| grain sampler | `exact` (RFC-002); `--sampler scipy` for the old stream |
| working precision | `float32` (the default since RFC-006; `float64` is the validation baseline) |

> **`tests/baseline/` no longer exists.** The user deleted it and
> `HANDOFF-GPU-WIRING.md` §3.3 says **do not restore it**. Every command this
> section used to give — `make_baseline.py`, `run_reference.py`,
> `tests/baseline/compare.py`, and the 16 MP linear ProPhoto TIFF that most
> recorded numbers in this file and in `ARCHITECTURE.md` were measured against
> — is gone with it. Those numbers stay as history; you cannot reproduce them
> as written, and a number you cannot reproduce is not a baseline to compare
> against. The five `tests/test_regression_baselines.py` cases that need its
> `.npz` fixtures **skip**, with the regeneration command in the skip message.
>
> The smoke image survived at a new path, and the suite looks in both places
> (`tests/test_rfc012_engine_seam.py:24`). Use `tests/Test_image/_smoke_1mp.tif`
> for anything that needs a small frame, and the Nikon NEF above for anything
> that needs a real one.

Parity against the numba reference — this is the harness that replaced the
above, and the one RFC-011 held every ported node to at float32 storage
epsilon:

```bash
.venv/bin/python -W ignore scripts/gpu_native/parity.py \
    tests/Test_image/_smoke_1mp.tif                 # every implemented node
.venv/bin/python -W ignore scripts/gpu_native/parity.py \
    tests/Test_image/_smoke_1mp.tif --node filming.expose.upsample --end-to-end
```

Use the **1 MP** frame, not the 45 MP one: parity is a correctness question, a
run takes seconds, and a check you can afford on every change is worth more
than one you run at the end. The rest of `scripts/gpu_native/` —
`profile_render.py`, `tier_timings.py`, `grain_moments.py`,
`concurrency_check.py` — is the measurement kit that replaced the deleted
`run_reference.py`.

Whole-app timings, including the render, come from the frontend's own
instrument — see "The frontend and the service" above. It is usually the right
tool even for a backend change, because it measures what the user experiences
rather than what a script measures.

---

## The frontend and the service

`modern_UI/Spektrafilm/README.md` is the detailed document; `ARCHITECTURE.md`
§7 is the summary. What you need to run it:

```bash
cd modern_UI/Spektrafilm
python3 Tools/gen-project.py        # REGENERATE after adding/removing any Swift file
xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm \
    -configuration Debug -derivedDataPath build/DerivedData build
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmFrontend \
    -configuration Debug -derivedDataPath build/DerivedData test   # ~2 s, no render
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests \
    -configuration Debug -derivedDataPath build/DerivedData test   # + the real service
```

`project.pbxproj` is **generated from the filesystem** by `Tools/gen-project.py`
(ids are path hashes, so it is byte-stable). A new `.swift` file that is not in
the project fails the build with `cannot find X in scope`, which reads like a
missing import. Run the generator first.

**Two test schemes, and the difference matters.** `SpektrafilmFrontend` skips
`ServiceIntegrationTests` — the only class that spawns Python and renders. Use
it while iterating. Run `SpektrafilmTests` whenever you touch
`Service/Methods.swift`, `Model/Params.swift`'s wire names, or anything under
`src/spektrafilm/service/`: that skipped class is what guards the wire, and
`ParamsTests.testWireNamesMatchTheServiceSchema` is what catches a renamed
field before it becomes a runtime rejection.

Capturing the interface:

```bash
Tools/snapshot.sh [image.NEF]        # offscreen, three window sizes
Tools/capture-live.sh [image.NEF]    # the REAL window, via the window server
SPEKTRAFILM_CANVAS_LOG=1 …           # one line per draw, plus the open-path timings
```

`snapshot.sh` renders through `cacheDisplay`, which **cannot see a
`CAMetalLayer`** and substitutes an offscreen render of the canvas. That blind
spot hid a drawable pixel format `CAMetalLayer` rejects (the app crashed on
launch) and a redraw that never reached the view (blank canvas, correct
numbers). `capture-live.sh` is the only capture that proves the canvas draws,
and it needs a live GUI session — if `CGWindowListCopyWindowInfo` reports
almost no on-screen windows, the failure is environmental, not a regression.

The app's own timing instrument, which you should not delete:

```
$ SPEKTRAFILM_CANVAS_LOG=1 …/Spektrafilm --snapshot 1600x900 /tmp/o.png \
      --open "tests/Test_image/Nikon Z7ii/_DSC2439.NEF" --wait 180 2>&1 >/dev/null \
  | grep "open path"
session: open path (ms): decode 96 · preview-texture 230 · linear-tiff 12
         · service.open 922 · solve 117 · reprint 36 · TOTAL 1415 · core=metal
```

**`core=metal` is the first thing to check.** If it says anything else, stop —
nothing else you measure means what you think it means (trap 14). The service
reports `elapsed_ms` for renders and the status bar shows it, so without this
line the *only* visible number is the fastest thing in the pipeline, and a slow
open reads as a slow render. That mistake cost a session.

Snapshot flags for canvas features a test cannot see: `--zoom`, `--geometry`,
`--mask`, `--compare`.

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

**Any per-pixel comparison must still disable both.** Set
`print_render.glare.active = False` and `film_render.grain.active = False` — or
`debug.deactivate_stochastic_effects = True`, which does both. With both off
the pipeline is bit-exact (`np.array_equal` True) run to run.
`scripts/gpu_native/parity.py` disables them by default and only enables them
under `--allow-stochastic`, where it reports timing and no dE. (The old
`run_reference.py --no-glare` flag is gone with `tests/baseline/`.)

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

### 11. Colour bugs are silent, and a uniformly-biased suite reports full confidence

Three colour bugs were live simultaneously on 2026-08-26 with **750 tests
passing**: `input_cctf_decoding=True` raised on the fused path, the service
hardcoded it to False, and `auto_exposure` multiplied its gain into
gamma-encoded data (effective gain `g ** 1.8`). None crashed; two produced
*plausible photographs*.

They survived because **every test and baseline in this repo feeds linear
input**. Encoded integer files — what Capture One, Lightroom and Photoshop
actually export — were never exercised. The suite was not weak, it was
uniformly biased, which is worse: it reported confidence at the moment it knew
nothing.

Before trusting a colour result, ask what the *inputs* to the tests have in
common. See `rfc/RFC-010-color-science-testing.md`; the short version is test
**invariances** (same meaning, different representation → identical render),
not reference pictures.

### 12. The input contract is where the product actually breaks

`spektrafilm` is a camera: it needs scene-linear radiance. Everything hard
about external files is at that boundary, not in the physics.

- **`decode_input` runs at the door** (`preprocess.decode_input`). Everything
  downstream of `preprocess` is linear. Do not move the transfer function back
  into `upsample` — that is what caused the `g ** 1.8` exposure bug.
- **An exposure edit in an external RAW developer is not a gain** if a tone
  curve sits after it. Measured on Capture One: `+1 EV` exported as a ×1.57
  median ratio with a 1.8–2.1× spread across tones. With C1's curve set to
  **Linear Response** it becomes ×2.09 with 1.17× spread, and auto-exposure
  absorbs it (dE 13.7 → 0.94).
- **External decodes are not invertible.** A camera profile (C1's ProStandard,
  Adobe's, dcraw's matrix) cannot be recovered from the exported TIFF. Two
  developers give two different scene estimates and therefore two different
  film looks. Fix the decode as part of the product contract; do not attempt
  an adaptation layer.

### 13. Spectral upsampling has a structural blind spot in purple

`RGB -> spectrum -> XYZ -> RGB` round-trips at **1.7-3.8 dE at every hue**,
worst in the purple/violet band (mean 3.07, rotating ~6° **toward blue**).
Reconstructing a spectrum from three numbers is underdetermined and the
smooth-spectrum prior under-represents the bimodal spectra that non-spectral
colours require. This is structural, not a defect, and it is why a profiled
camera LUT can beat spectral reconstruction on those hues — it never builds a
spectrum. Pinned by `tests/test_spectral_roundtrip_hue.py`; do not raise those
bounds without looking at colours.

### 14. The engine that renders is whichever checkout the app resolved

There are two checkouts and two venvs, and `spektrafilm` is installed
**editable** in each. An editable install pins a `.pth` to *one* `src`
directory — whichever `pip install -e` was run from — and it keeps pointing
there regardless of the current working directory, the branch, or which
worktree you are standing in.

Consequences, all of which have already happened here:

- **A third worktree has no venv, so it borrows one, so it runs that venv's
  source.** A `git worktree add` + `cd` + measure A/B therefore executes the
  *same* code in both arms. The arms agree, and the agreement reads as "no
  effect" — which is exactly how a correct result was nearly retracted on
  2026-09-10. Under `pytest` it is the same: **a worktree test run does not
  necessarily test that worktree.** Set `PYTHONPATH=<worktree>/src`, and check
  `spektrafilm.__file__` before believing any A/B.
- **The app is immune, and only by construction.**
  `ServiceClient.childEnvironment(repo:)` sets `PYTHONPATH=<repo>/src` from the
  bundle-resolved repo, and `PYTHONPATH` takes precedence over the `.pth`. That
  line looks redundant next to an editable install and it is the only thing
  guaranteeing the app renders with the engine sitting next to the binary you
  launched. **Do not delete it as a simplification** — contract §5, and
  `ServiceLaunchEnvironmentTests` fails if two checkouts ever resolve to one
  engine.
- **The original version of this bug cost a whole session.** The GPU core lived
  on a branch the app's checkout did not have, so every render ran on numba and
  the only symptom was that things felt slow. `Capabilities` did not decode
  `backend`, so nothing could report it. See `HANDOFF-GPU-WIRING.md` §0 — and
  check `core=metal` before believing any measurement.

### 15. A refactor that only moves code can still move the wire

The wire is assembled from *both* halves: the Python `capabilities` dict and
the Swift `Capabilities` type that decodes it. A change entirely inside
`src/` can therefore break the contract while its commit message truthfully
says "no wire change" — this happened on 2026-09-10, when an engine/service
split dropped `transport_version` and `schema_version` from `capabilities`.
Neither field is optional on the Swift side, so the result would have been a
refusal to start (contract §2), not a warning.

Before landing anything that touches `_m_capabilities` or a response shape,
print the block and diff it against what the Swift type requires. The full key
set is pinned by a test on each side.

### 16. A check that exists on paper, in a configuration where it can never fire

Three instances of the same failure landed within one day, which is why it is
its own trap rather than three footnotes:

- `deactivate_spatial_effects` never zeroed `grain.micro_structure[0]`, a
  Gaussian blur radius. Invisible because the only test exercising the flag
  went through `lut_mode`, which *also* switches grain off — so the one test
  covering the check ran it where the bug could not be reached.
- `Session.warmUp` called `capabilities` with `try?`. Contract §2's "refuse an
  unknown transport with a visible error" was written down and never built, and
  a block the client could not decode was indistinguishable from a service that
  had not started.
- `test_a_reprint_does_not_touch_colour_science` asserted `not pandas` above an
  `xfail` for `colour` — but pandas-loaded is *entailed by* colour-loaded
  wherever pandas is installed. It passed only on a venv without pandas, i.e.
  not the one the product uses.

The shape to look for: a guard whose only exercise is in a configuration that
disables the thing it guards. Ask what the *inputs* to a passing test have in
common — the same question trap 11 asks about colour.

### 17. This machine is not a benchmark

Timings here are contaminated routinely and by large factors. On 2026-09-10 a
warm `service.open` read 1.86–2.81 s against 922 ms measured hours earlier;
the cause was **Civilization VI holding the GPU at 125 % CPU**, load average
6.2. The same unchanged commit has measured 23.3 s and 18.9 s hours apart.

- Check `ps -Ao %cpu,comm -r | head` and `uptime` before trusting a number,
  and say so in any message that quotes one.
- Measure **interleaved**, never sequentially: alternate arms within one
  session using `_FORCE_REFERENCE_*` or stash/pop.
- Prefer CPU time over wall clock when the question is about imports or
  allocation rather than the GPU.
- `core=metal` and correctness results are not timing-dependent; report those
  separately from speed, which is what makes a contaminated session still
  useful.

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
- **RFC-011 landed: the render core is Metal.** `settings.gpu_backend='metal'`
  runs the whole topology on `backends/metal/` (45 MP, 14.15 s → 1.03 s), held
  to float32 storage epsilon against numba. **numba is the reference and stays
  forever** — it stopped being the runtime, not the truth. Every ported node
  has a `scripts/gpu_native/parity.py` row. 20 of the 21 default nodes are on
  Metal; `preprocess.crop_rescale` has no Metal body (ARCHITECTURE §8.2).
- **RFC-012 landed steps 1, 3 and 4.** The engine is split from the wire
  (`service/engine.py` vs `service/service.py`, "the engine returns pixels, the
  service turns pixels into paths", guarded by an AST check in
  `tests/test_rfc012_engine_seam.py`); the colour constants are baked
  (`model/colour_baked.py`, 21.9 KiB for ~148 MB of dependencies); and a C++
  gate proved MLX kernels are byte-identical from `libmlx.dylib`. **Step 5, the
  native host, is unstarted.** Do not put rendering logic in an RPC handler —
  that seam is what makes option D a deletion rather than a rewrite.
- Anything claiming a speed or memory win must come with a measurement in the
  same message. `tracemalloc` for allocation, `resource.getrusage` for RSS.
- Quality claims need a ΔE number from `compare.py`, not an eyeball.

## Do not

- Do not commit or push unless asked.
- Do not edit `AGENTS.md`, `ARCHITECTURE.md`, `API-SPEC-*` or `CONTRACT-*`
  without telling the other session — contract §4 makes them shared, and a
  unilateral edit makes the other side's context wrong.
- Do not restore `tests/baseline/`. See "Fixed experimental setup".
- Do not delete `PYTHONPATH` from `ServiceClient.childEnvironment` (trap 14) or
  `Session.LoadClock` (the open-path instrument).
- Do not add GPL-incompatible dependencies. The code is GPL-3.0-or-later; the
  profiles under `data/profiles/` are CC BY-SA 4.0 with separate attribution
  obligations.
- Do not change `SPECTRAL_SHAPE`, the profile data, or `LOG_EXPOSURE` — every
  baseline assumes them.
