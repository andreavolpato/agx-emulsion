# Handoff: a GPU-native render core — no numpy, no numba, no Python in the hot path

| | |
|---|---|
| **For** | The second session on this repo (`spektrafilm-12`, Fable 5.1), working in the `../spektrafilm-gpu` worktree on branch `gpu/native-metal`. |
| **Read first** | `CONTRACT-frontend-backend.md` — it is short, it is binding, and it is what lets you rewrite the engine without ever opening a Swift file. Then `AGENTS.md` traps 1–11 and `HANDOFF-METAL-BACKEND.md` §2–§3, which are still correct about *accuracy* even though this document overrides them about *scope*. |
| **Status** | Scope set by the user on 2026-09-09. Nothing is built. |
| **Date** | 2026-09-09 |

---

## 0. The premise changed, and you should know by how much

`HANDOFF-METAL-BACKEND.md` opens with "**No language port.** numba is fast
enough." That was the right call for a *port*, and it is the settled position
in RFC-007 §5 D. The user has overridden it:

> a standalone system that is GPU native (abandon numpy, numba or python at
> all) should be possible. Only that a lot of the actions that is CPU only
> needs a complete logic rewrite.

So the target is no longer "move the five hot nodes to Metal". It is **a
render core with no Python interpreter between `open` and `rgba16`**, where
the CPU's remaining job is parsing JSON, loading measured data, and telling
the GPU what to do.

That is a real and defensible goal. Be clear-eyed about what it buys and what
it costs:

**What it buys.** Today `settings.gpu_backend = 'mlx'` routes five of
twenty-three nodes to Metal and measures **1–8 % faster**. That number is not
a disappointment about Metal; it is Amdahl arithmetic on a pipeline whose data
crosses the CPU/GPU line eighteen times. The win in this project has always
been in *residency* — an image that enters GPU memory at decode and leaves at
`rgba16`, never round-tripping. The prize is the whole 13.9 s at 45 MP, not
the 26 % that halation owns.

**What it costs.** Every stage you rewrite is a chance to change the picture
silently, and this codebase has already had three simultaneous colour bugs
live with 750 tests passing (trap 11). A reimplementation has strictly more
of those chances than a port. §3 is therefore not optional.

**The line that does not move.** `HANDOFF-METAL-BACKEND.md` §4 is still
binding: `scripts/experimental_fast_gpu_look.py` is 35× faster and produces a
*different look*, because it skips the spectral integral, the measured
characteristic curves and the Poisson grain model. **Same math, same measured
data, same node boundaries — only the executor changes.** If a stage needs
different math to run well on the GPU, that is an RFC and a labelled
`render_mode`, never a silent substitution. A GPU-native pipeline that is fast
because it stopped being a film simulation has failed at the only thing it was
for.

---

## 1. What "no Python" can actually mean here

The service is a Python process speaking JSON-RPC over stdio, and
`CONTRACT-frontend-backend.md` §1 freezes *the wire*, not the language behind
it. That is the whole degree of freedom you have, and it is enough:

```
  ┌─ what the frontend sees ────────────────────────────────────────┐
  │  python -m spektrafilm.service   ← the command, unchanged        │
  │  ndjson over stdio               ← the framing, unchanged        │
  │  {raw_path, width, height}       ← the handoff, unchanged        │
  └──────────────────────────────────────────────────────────────────┘
        │
        ▼  behind it, your choice:
  A. Python shell + compiled core   — Python parses JSON, loads profiles,
                                      and calls into a Metal render library.
                                      No numpy in the hot path; numpy may
                                      still exist at the edges.
  B. Native binary + Python shim    — the service is a Swift/C++ executable;
                                      `python -m spektrafilm.service` becomes
                                      a launcher for it.
  C. Native binary, full stop       — the frontend's spawn line changes. This
                                      needs a §5 contract request and is the
                                      only one of the three that touches FE.
```

**Recommend A, and design so that B is a later relink rather than a rewrite.**
A keeps `tests/` runnable, keeps the reference path alive (§3.2), and keeps
the profile-loading and solver code — which is genuinely not hot — where it
already works. B is the honest end state once the parity table in §3 is
complete. C buys nothing A and B do not, and spends the one thing the contract
protects.

The mechanical consequence of A: the boundary you build is a **narrow C ABI**,
one call per node plus a graph-execution entry point. Every buffer that
crosses it is a `MTLBuffer` handle, never a host array. The moment a stage
returns a numpy array for another stage to consume, residency is gone and you
have rebuilt today's pipeline with a different accent.

---

## 2. The rewrite, by what kind of thing it is

`runtime/pipeline.py`'s 23 nodes are not one problem. They are four, in
increasing order of how much thinking they need.

### 2.1 Pointwise (14 nodes) — mechanical, do them first

`input_cast · decode_input · expose.exposure · expose.boost · expose.log ·
develop.curves · scan_spectral · bw_correction · xyz_to_rgb ·
gamut_compress · cctf · enlarger_spectral · print_curves · expose.upsample`

These are a per-pixel function of a per-pixel value plus constants. They are
also the whole argument for residency: fourteen kernels that each cost
microseconds and currently cost a full array allocation and a memory
round-trip apiece. **Fuse them into runs.** A fused run of pointwise nodes is
one kernel, one read, one write — and the memory win is larger than the
compute win (`HANDOFF-METAL-BACKEND` trap 5: *putting something on the GPU
fixes speed; only fusion fixes memory*).

Two of them are not as pointwise as they look:

- **`expose.upsample`** (5.21 s at 45 MP, the second-largest line in RFC-004's
  table) is a spectral upsampling: RGB → a spectrum, per pixel. It is
  pointwise in shape and enormous in inner-loop length. It is the single
  highest-value kernel in the project.
- **`gamut_compress`** is CAM16, which is iterative. It is pointwise per pixel
  but the per-pixel work is a solve. Budget for it separately.

### 2.2 Spatial (7 nodes) — the prize and the hard part

`crop_rescale · diffusion_filter · lens_blur · halation · dir_couplers ·
scanner_blur · unsharp · print_exposure`

Halation ≈ 26 % and dir_couplers ≈ 19 % of wall time. Both are convolutions
with a physical meaning, and both need **tiling with a halo** on the GPU for
the same reason they need it on the CPU — a 45 MP float32 RGB image is 540 MB
and the intermediates are what blew RSS to 7 GB.

Trap 9 is the one that will bite: **grain draws are i.i.d. and tile freely;
blurs do not.** `grain_blur`, the micro-structure and halation each need a
~4 px halo and will produce visible seams without one. A seam is a *structured*
error, so §3's "anything with structure in it is a bug regardless of its mean"
catches it — but only if you look at the map and not the number.

Halation's radius is large and its content is low-frequency, so it can
legitimately run downsampled. That is a **look-affecting choice**: measure it,
record the factor, do not assume it.

### 2.3 Stochastic (1 node) — `develop.grain`, and it is the whole risk

Read `RFC-002` §3.4 and trap 8 before writing a line of it.

`fast_stats` reproduces grain RMS to within 0.14 % and **still changes the
look**, because it flattens skewness to zero at every density. Skewness is
`1/√μ`, so it is precisely what encodes film's shadow-versus-highlight grain
character (+0.165 in shadows, +0.022 in highlights). **A Metal grain kernel
must reproduce the third moment, not the second.** RMS parity is not evidence.

The reference is `grain_sampler='exact'` — Poisson-thinned, 27× faster than
scipy. Whether Poisson thinning survives translation into a kernel that has to
produce the same *realisation*, or at least the same *distribution at every
density*, is open question 3 in `HANDOFF-METAL-BACKEND` §7 and is the most
likely place this whole effort turns into an RFC instead of a rewrite. Find
that out early — not after the pointwise fusion is done and the schedule is
committed.

### 2.4 The CPU-only logic that needs an actual rewrite

This is the part the user flagged, and it is where the "abandon Python"
framing bites hardest. Each of these currently leans on a CPU library whose
behaviour is not obvious and is not yours:

| what | leans on | why it cannot just be transliterated |
|---|---|---|
| **`auto_exposure`** (7.12 s — the *largest* line in RFC-004's profile) | numpy reductions + a solve | It is a search over a statistic of the whole image. On the GPU it becomes a reduction kernel plus a small host-side solve — the reduction is trivially parallel, the solve should stay on the CPU where it costs nothing. Do not port the loop; restructure it. |
| **`colour-science` conversions** | `colour.RGB_to_RGB` | **Trap 7.** It silently returns float64, and for a same-space call it also applies a near-identity CAT02 round trip. Dropping that round trip moves output by 3.8e-4. Bake the *composed* matrix (including CAT02) as a constant at load time and multiply on device; do not reimplement the library's control flow. `scanning.py`'s two call sites are the pattern. |
| **The measured profiles** | numpy arrays with **NaN in them** | 22 NaNs in Portra 400's `channel_density`, 20 in its `base_density`, marking wavelengths with no data. The reference propagates them to NaN transmittance and zeroes them in `density_to_light`. **Sanitise the constants at load, outside the kernel** (`prepare_spectral_constants` is the pattern), never with an in-kernel branch — trap 3: fast math asserts no-NaN and deletes your check. |
| **Characteristic curves / LUT interpolation** | `scipy.interpolate` | Becomes a texture sample with the right addressing mode. The trap is the *edges*: scipy's extrapolation behaviour at and past the ends of a curve is not what a clamped sampler does, and the ends of a characteristic curve are the shoulder and the toe — the two places a photographer looks. |
| **RAW decode** | LibRaw / rawpy | **You probably do not need this at all.** The frontend already decodes with Core Image and hands the service a half-float linear ProPhoto TIFF (`frontend_architecture.md` §4). The service's own RAW path exists for CLI use. Do not spend GPU work on it. |
| **17³ / 33³ print LUT bake** | scipy | Already has a GPU kernel measured at **1.3e-08 mean abs against the scipy reference** (`scripts/apply_print_lut.py --check`). This is your worked example of what "done" looks like — and the bar §3 sets. |

---

## 3. How you will know you did not change the picture

**Build this before you port anything.** It is the deliverable that makes
every other deliverable checkable, and `HANDOFF-METAL-BACKEND` §5.1 already
specifies it:

### 3.1 The per-node parity harness

One node, one input array, two executors, three numbers: **max abs, mean abs,
and dE2000 where the output is colour.** Runnable per node from the command
line. Copy the shape from `tests/baseline/probe_callable_api.py` and
`scripts/apply_print_lut.py --check`.

It must **refuse to run** when grain or glare is enabled. Glare is unseeded by
design and two identical renders differ by up to 0.042 — larger than most
differences you will be trying to measure. This has produced a phantom bug in
this repo once already (trap 1).

### 3.2 The bar

**Float32 storage epsilon against the numba implementation on the same input**
— i.e. the `1.3e-08 / 2.4e-07` row, not the `1.7–3.8 dE2000` spectral row.

The spectral round-trip error and the RAW-decoder disagreement (≈5 dE2000) are
the *reasons this project is worth doing*. Spending them on implementation
drift converts a physical model into an approximation of one. **A node that
cannot hit the bar is a finding to write down, not a tolerance to widen.**

End to end: a dE2000 map — the map, not the mean — against the numba render at
45 MP with grain and glare off. Anything with structure in it (a band, a
region, a channel, a tile seam) is a bug at any mean.

### 3.3 Keep the reference forever

Not as a fallback for old hardware; this is Apple-Silicon-only. As the thing
you check against. Widen `settings.gpu_backend` to select per node
(`'numba' | 'mlx' | 'metal'`) rather than replacing the CPU path. The day a
colour question arises — and it will — being able to re-run one frame through
the reference is worth more than the code it costs to keep.

This is also why option A in §1 is the recommendation: it is the only one that
leaves the reference runnable in the same process.

---

## 4. Order of work

1. **Re-profile first.** RFC-004's table predates float32 (RFC-006) and the
   scheduling changes (RFC-007/008). Trap 10 is exactly this mistake made
   once: a 7 s line in a profile turned out to be a CPU downscale that GPU
   would not have fixed. Measure at 45 MP with the settings the service ships.
2. **The parity harness** (§3.1). Nothing lands before this exists.
3. **Answer the grain question** (§2.3) — a spike, not an implementation. If
   exact Poisson cannot become a kernel that holds the third moment, the whole
   plan changes shape and you want to know now.
4. **Residency skeleton**: `open` → device buffer → `rgba16` out, with every
   node still calling back to numba through a host round-trip. Slower than
   today, and correct. This is the scaffold that makes step 5 incremental.
5. **Fuse the pointwise runs** (§2.1), starting with `expose.upsample`. Each
   run lands with its parity numbers and its memory profile.
6. **Halation, then dir_couplers** (§2.2), with halos, with a seam check.
7. **`auto_exposure`** as a reduction plus a host solve (§2.4).
8. **Grain**, per step 3's answer.
9. Only then: consider whether the Python shell is still earning its place
   (option B).

---

## 5. What "done" looks like

- A per-node parity table, checked in, one row per node: max abs, mean abs,
  dE2000 where applicable, and the input it was measured on.
- An end-to-end dE2000 **map** at 45 MP, grain and glare off, against numba.
- Re-measured timings at all three tiers, **replacing** API-SPEC §6's table
  rather than sitting beside it.
- Peak RSS at 45 MP, against today's ~7.15 GB.
- A short decision record for every place the rewrite could not match the
  reference exactly: what was chosen, and why.
- `capabilities` reporting the new backend honestly, and — only if it is
  actually true — `concurrent: true` (contract §3.4). The frontend will
  believe you.

---

## 6. Working agreement with the other session

- **Worktree** `../spektrafilm-gpu`, branch `gpu/native-metal`. Never build in
  the main checkout: a concurrent `xcodebuild` and `pytest` sharing a tree is
  its own category of confusing failure.
- **Never edit `modern_UI/**`.** `Service/Methods.swift` is the definitive
  list of what the frontend reads; treat it as read-only documentation.
- Additive wire changes need no permission. Anything else goes in
  `CONTRACT-frontend-backend.md` §5 first.
- Record every wire change you actually make in contract §6. That table is
  what the frontend session reads to know whether it has work to do.
