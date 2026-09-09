# Handoff: a fully-Metal render backend, gated on accuracy

| | |
|---|---|
| **The idea** | Move the render off numba and onto Metal end to end, so the whole pipeline is GPU-resident instead of five ops deep. |
| **The premise, settled** | **No language port.** numba is fast enough (13.9 s at 45 MP, 193 ms warm reprint at the live tier) and behaves in a long-lived process — 137–155 ms steady state over twelve renders, flat RSS, no drift. C++ was deferred in RFC-007 §5 D and stays deferred. |
| **The actual problem** | **Accuracy.** Every stage that moves to Metal is a chance to change the picture silently. This document is mostly about how to know that you did not. |
| **Read first** | `AGENTS.md` traps 1–11, `rfc/RFC-010-color-science-testing.md`, then `rfc/RFC-001`, `RFC-004`, `RFC-005` — a phased GPU port has been designed before and its measurements still hold. |
| **Date** | 2026-09-08 |

---

## 1. Where the pipeline actually runs today

`settings.gpu_backend = 'mlx'` routes exactly five operations to Metal:
`gpu_boost`, `gpu_log10`, `gpu_cctf_srgb`, `gpu_xyz_to_rgb` and the separable
Gaussian (`pipeline.py:126` is the only place the flag is read). It measures
**1–8 % faster and never slower** — which is the honest measure of how little
of the render it currently moves. `settings.spectral_backend = 'mlx'` is a
separate switch covering the spectral integral (`backends/mlx_spectral.py`),
and it is already the default.

Everything else is numba. The 23-node topology by kind, from
`runtime/pipeline.py`:

| kind | nodes |
|---|---|
| **pointwise** (14) | input_cast · decode_input · auto_exposure · expose.upsample · expose.exposure · expose.boost · expose.log · develop.curves · scan_spectral · bw_correction · xyz_to_rgb · gamut_compress · cctf · enlarger_spectral · print_curves |
| **spatial** (7) | crop_rescale · diffusion_filter · lens_blur · **halation** · **dir_couplers** · scanner_blur · unsharp · print_exposure |
| **stochastic** (1) | develop.grain |

The profile is **spatial-dominated**: halation ≈ 26 %, dir_couplers ≈ 19 %
(HANDOFF-IPC §5). Neither fuses the way the pointwise stages did. That is
where the remaining time is, and it is also the part with the most ways to be
subtly wrong.

**Do the measurement before the work.** Those shares predate several changes
(RFC-006's float32, RFC-007/008's scheduling). Re-profile at 45 MP with the
settings the service ships before deciding what to port first — trap 10 is
exactly this mistake made once already, where a 7 s line turned out to be a
CPU downscale nobody had isolated.

---

## 2. What "accuracy" has to mean here, in numbers

There is no ground truth to appeal to, so the target has to be stated relative
to errors already measured in this repo:

| error already present | magnitude |
|---|---|
| spectral round-trip (upsample → dye response) | **1.7–3.8 dE2000**, worst in the purple band (RFC-010 §2.2) |
| choice of RAW decoder (C1 vs rawpy, same frame, same film) | **≈ 5 dE2000 mean**, roughly uniform across hue (HANDOFF-DECODE-AB §1) |
| float64 → float32 working precision | shipped as the default in RFC-006; the validation baseline is float64 |
| 33³ print LUT vs the real print chain | mean abs 0.0017, max 0.174 (HANDOFF-PRINT-LUT §1) |
| GPU LUT kernel vs the scipy reference | mean abs **1.3e-08**, max 2.4e-07 — float32 storage epsilon |

So the bar for a ported node is the last row, not the first: **a port should
land at float32 storage epsilon against the numba implementation on the same
input, not merely "within the spectral error".** If a node cannot, that is a
finding to write down, not a tolerance to widen — the spectral and decode
errors are the reasons this project is worth doing, and spending them on
implementation drift converts a physical model into an approximation of one.

End to end, with grain and glare off, the whole-pipeline check is a dE2000
map against the numba render of the same frame. Anything with structure in it
— a band, a region, a channel — is a bug regardless of its mean.

---

## 3. The accuracy traps, specifically

These are not general advice; each one has already cost time in this repo.

1. **fp16 is not a speedup and it is not safe.** The `1e-10` epsilon in
   `log10(fmax(raw, 0) + 1e-10)` underflows below fp16's smallest subnormal
   (≈5.96e-8) and gives `-inf`. Measured storage error on the spectral kernel
   is 2.7e-3 relative, and it is **not faster** (6.9 ms against 6.8 ms) because
   the kernels are compute-bound, not bandwidth-bound. Use float32 on Metal.
   (Trap 6.)
2. **The measured profiles contain NaN** — 22 in Portra 400's
   `channel_density`, 20 in its `base_density` — marking wavelengths with no
   data. The reference path propagates them to NaN transmittance and zeroes
   them in `density_to_light`. A Metal port must reproduce that, and must do
   it by **sanitising constants outside the loop** (as
   `prepare_spectral_constants` does), never with an in-kernel branch. Traps
   2 and 3.
3. **Never trust an in-kernel NaN guard under fast math.** numba's `fastmath`
   asserts no-NaN and deletes the check; Metal's `-ffast-math` does the same.
   Trap 3.
4. **MLX is lazily evaluated.** An unevaluated graph retains every
   intermediate — the exact failure the port exists to avoid. Put explicit
   `mx.eval()` barriers at node boundaries and treat it as a correctness
   requirement, not tuning. And: expressing a stage in stock MLX ops allocates
   an array per operation (`compress_rgb` in stock MLX would be ~3.8 GB of
   intermediates at 16 MP). **Putting something on the GPU fixes speed; only
   fusion fixes memory.** Trap 5.
5. **colour-science silently returns float64** regardless of input dtype, and
   this defeated float32 entirely once — casting at the door did nothing
   because the first colourspace conversion upcast straight back. The two call
   sites in `scanning.py` are the pattern to copy: one became a matmul against
   the identity-trick matrix (exact to 1.3e-15), the other keeps
   `colour.RGB_to_RGB` verbatim but runs it through `parallel_pointwise` with
   an explicit `out_dtype`. Do not swap `RGB_to_RGB` for the bare
   `cctf_encoding`: for a same-space call the former also applies a
   near-identity CAT02 round trip, and dropping it moves output by 3.8e-4.
   Trap 7.
6. **Grain is the hard one, and RMS is not the test.** `fast_stats`
   reproduces grain RMS to within 0.14 % and still changes the look, because
   it flattens skewness to zero at every density — and skewness is `1/√μ`, so
   it encodes film's shadow-versus-highlight grain character (+0.165 in
   shadows, +0.022 in highlights). A Metal grain kernel must reproduce the
   **third moment**, not the second. The reference is
   `grain_sampler='exact'` (Poisson-thinned, 27× faster than scipy);
   `use_fast_stats` is preview-only. Trap 8, RFC-002 §3.4.
7. **Grain draws are i.i.d., blurs are not.** Partitioning the per-pixel draws
   produces a different realisation and no seam, so tile them freely. The
   blurs (`grain_blur`, micro-structure, halation) need ~4 px halos and will
   seam without them. Trap 9.
8. **Glare is unseeded, by design.** Two renders with identical config differ
   by up to 0.042 — larger than most differences a port is trying to measure.
   Every comparison must disable grain and glare, or reuse one pipeline
   instance for both arms. This has produced a phantom bug once already.
   Trap 1, API-SPEC §2.
9. **Colour bugs are silent and a uniformly-biased suite reports full
   confidence.** Three were live simultaneously on 2026-08-26 with 750 tests
   passing; two produced plausible photographs. Trap 11 — and the reason
   RFC-010 exists.

---

## 4. The one thing not to do

`scripts/experimental_fast_gpu_look.py` (RFC-009) is a from-scratch all-MLX
path: **202 ms and 1.09 GB at 16 MP against the real pipeline's ~7 s**, a
genuine ~35× — and its output is flat and lower-contrast than the real render
(`tests/baseline/out/experimental_fast_gpu_look/comparison.png`). It gets its
speed by skipping the spectral integral, the measured characteristic curves
and the Poisson grain model. It is a different look, not a faster
implementation of this one.

**This task is a port, not a reimplementation.** Same math, same measured
data, same node boundaries; only the executor changes. If a Metal version of a
node needs different math to be fast, that is a finding for a separate RFC —
and if it ever ships, it ships as an explicit, labelled `render_mode`, never
as a silent fallback (RFC-009 §0, §3).

---

## 5. Suggested shape of the work

### 5.1 Build the parity harness first

Before porting anything, build the thing that will tell you whether a port is
correct: a per-node A/B that runs one node under numba and under Metal on the
same input array and reports max abs, mean abs, and — where the node's output
is colour — dE2000. It should be runnable per node from the command line and
should refuse to compare when grain or glare is enabled.

The shape already exists to copy: `tests/baseline/probe_callable_api.py` does
this for the reprint-vs-full-render equivalence, and
`scripts/apply_print_lut.py --check` does it for the LUT kernel against scipy.

### 5.2 Port in profile order, one node per change

Halation (26 %) and dir_couplers (19 %) are the prize and should come first —
but they are spatial, which means tiling with halos and the memory question,
so expect them to be the two hardest as well. Halation's radius is large but
it is low-frequency and can legitimately run downsampled; that is a
look-affecting choice, so measure it rather than assume it.

Each node lands with: the kernel, its parity numbers against numba, and its
memory profile. A node whose parity is worse than float32 epsilon does not
land until the reason is understood.

### 5.3 Keep numba as the reference forever

Not as a fallback for old hardware — this is Apple-Silicon-only — but as the
thing the Metal path is checked against. `settings.gpu_backend` already exists
as the switch; widen it (`'mlx'` → per-node or `'metal'`) rather than
replacing the CPU path. The day a colour question arises, the ability to
re-run the same frame through the reference implementation is worth more than
the code it costs to keep.

### 5.4 Memory is a separate goal from speed

Peak RSS is ~7.15 GB at 45 MP after RFC-006 (159 B/px, down from ~300).
The lever for memory is **tiling with halo** for the spatial operators, which
works in Python and would be required in Metal anyway — it is not a reason to
port. Do not conflate the two goals in one change; they have different
acceptance criteria.

---

## 6. What "done" looks like

- A `backend` switch that selects numba or Metal per node, defaulting to
  whatever the parity work has cleared.
- A parity report, checked in, with one row per ported node: max abs, mean
  abs, dE2000 where applicable, and the input it was measured on.
- An end-to-end dE2000 map against the numba reference at 45 MP with grain and
  glare disabled, and the same at the live tier.
- Re-measured timings at all three tiers, replacing API-SPEC §6's table rather
  than sitting beside it.
- A short decision record for every place the port could not match the
  reference exactly, saying what was chosen and why.

---

## 7. Open questions, in priority order

1. **Is the spatial work actually GPU-bound?** Re-profile before porting.
   Trap 10 is the precedent: the biggest line in a profile turned out to be a
   CPU downscale that GPU would not have fixed.
2. **Does halation's low-frequency character survive running downsampled**, and
   at what factor? This is a look question with a measurable answer.
3. **Can the exact Poisson grain sampler be expressed as a Metal kernel that
   preserves skewness at every density**, or does it need a different
   decomposition? If the latter, that is an RFC, not a port.
4. **Does `unpooled_device_memory()` (`mx.set_cache_limit(0)`, process-global
   and not reentrant) still make sense** when most of the pipeline is on the
   GPU rather than a few ops?
5. **What happens to single-flight?** The transport is serialised because
   numba's `workqueue` layer aborts the process on concurrent entry
   (HANDOFF-IPC §3, RFC-007 §8.5). A fully-Metal pipeline may not need that
   constraint — but the constraint is currently what keeps the lazy Metal
   kernel globals from racing on first call, so it does not lift for free.
