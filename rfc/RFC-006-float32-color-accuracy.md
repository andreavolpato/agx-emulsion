# RFC-006 — float32 color accuracy: is the working-precision move actually safe?

| | |
|---|---|
| **Status** | **Applied.** §5's recommendation shipped: `working_precision='float32'` is the default, the §4 gaps are closed in §7, and the kernels were made dtype-preserving so the flag actually does something. |
| **Referenced by** | RFC-004 §2.2 (deferred), RFC-005 §4 P3 + §6 (gated on this), RFC-007 §6 Q3 (deferred) |
| **This RFC was missing** | Every one of the above cites it; the file never existed until now. |
| **Date** | 2026-08-25 |

## 0. The question this RFC exists to answer

RFC-004 §2.1 moved the GPU path to float32 (Metal's native precision) while
keeping the CPU path at float64 as "the validation baseline." RFC-004 §2.2
then found that per-node float32 **already broke** the proposed hard ΔE bars
on one config — "measured ΔE max 2.42, MS-SSIM 0.9955 — the culprit is grain
+ the 17³ LUT + CAM16, not the pointwise matmuls" — and explicitly declined
to adopt a global accuracy number, deferring the real question to this RFC.
RFC-005 P3 (`working_precision="float32"` as the frontend default) and
RFC-007 §6 Q3 (whether a fused float32 kernel is safe for CAM16) both cite
this RFC as the gate. Nobody had written it. This is that RFC.

**The question, precisely:** is `settings.working_precision = "float32"`
(currently `"float64"` by default, `params_schema.py:258`) colorimetrically
safe as the pipeline's default working precision — not just for the
pointwise nodes RFC-004/005 already ported, but end-to-end, including the
three stages RFC-004 §2.2 flagged as the risk: the 17³ enlarger/scanner LUT,
CAM16-UCS gamut compression, and grain.

## 1. Methodology

Same protocol as RFC-005 §5 / RFC-007 §7 (per-phase CPU-float64 reference vs
candidate, `tests/baseline/compare.py`'s deterministic mode: ΔE2000 mean/p99/max,
PSNR, MS-SSIM, against RFC-001 §6.1's hard bars — mean ≤ 0.5, p99 ≤ 1.0, max
≤ 2.0, PSNR ≥ 50 dB, MS-SSIM ≥ 0.999). Grain is stochastic, so it gets its
own comparison in `compare.py`'s stochastic mode (moment + radial-PSD match,
RFC-002 §6.2's bars) with `grain_sampler="exact"` so both renders draw the
*same* realisation and only precision differs — otherwise two independent
grain draws would swamp the precision signal, the same trap
`API-SPEC-callable-render-service.md` §2 documents for the reprint
equivalence check.

All four runs below: 16 MP reference image
(`tests/baseline/_DSC2439_16mp_linear_prophoto.tif`), `kodak_portra_400` /
`kodak_portra_endura`, `spectral_backend="mlx"`, sRGB output. Outputs and
metrics JSON are in `tests/baseline/out/rfc006/`.

## 2. Results

| comparison | config | ΔE mean | ΔE p99 | ΔE max | PSNR | MS-SSIM | vs RFC-001 bars |
|---|---|---|---|---|---|---|---|
| CPU f64 vs CPU f32 | no LUTs, grain off, glare off | 0.000008 | 0.000050 | 0.000184 | 146.7 dB | 1.000000 | **pass, ~2700x margin on the tightest bar (max)** |
| CPU f64 vs CPU f32 **with the 17³ LUT** | `use_enlarger_lut=use_scanner_lut=True`, grain off, glare off | 0.000007 | 0.000029 | 0.000072 | 149.6 dB | 1.000000 | **pass, ~27000x margin** |
| CPU f64 vs GPU f32 | `gpu_backend="mlx"`, no LUTs, grain off, glare off | 0.001144 | 0.002845 | 0.003299 | 105.1 dB | 1.000000 | **pass, ~600x margin on max** |
| CPU f64-grain vs CPU f32-grain (stochastic) | `grain_sampler="exact"` (shared realisation), glare off | rms_rel 0.000042, skew_rel 0.001824, kurtosis_rel 0.000643, psd_correlation 0.999999 | | | | | **pass, well inside RFC-002 §6.2 bars (0.02 / 0.05 / 0.05 / 0.98 floor)** |

CAM16-UCS gamut compression is exercised in every row (`output_gamut_compress.active`
defaults `True`, `gamut_compression.py:69`) — it is not a separate config, it's
always in the graph, so the LUT row above already includes RFC-004 §2.2's
"CAM16" culprit alongside the "17³ LUT" one.

**All four pass by margins of 2-3 orders of magnitude, including the two
stages RFC-004 §2.2 named as the risk.** This directly contradicts RFC-004's
earlier finding of ΔE max 2.42 on "the GUI config."

## 3. Why this RFC's numbers don't match RFC-004 §2.2's

Not re-litigating RFC-004 — reconciling it, because both measurements are
real. RFC-004 §2.2 was measured *before* RFC-005 §7.2 item 5 landed:

> **`Node.precision` is now honoured.** ... a node tagged `backend=('mlx',)`
> returned float32, which propagated into every downstream CPU stage.
> Removing a GPU tag therefore changed *numerics* ... The tap dtypes the GPU
> port was producing by accident are now declared, independent of which
> backend runs the node. (RFC-005 §7.2)

RFC-004 §2.2's bad number was measured against **uncontrolled per-node dtype
propagation** — float32 leaking into stages that were never meant to run at
that precision, an accident of which nodes happened to carry a GPU tag at the
time, not a deliberate `working_precision` policy. RFC-005 fixed exactly
that. This RFC's numbers are the first measurement taken *after* that fix,
with `working_precision` set as an explicit, declared policy rather than an
emergent side effect — and the difference between "2.42 ΔE max, culprit
unclear" and "0.0032 ΔE max, three orders of magnitude inside every bar" is
consistent with that being the actual cause. Also probably relevant: RFC-004
also mentions "the GUI config" without pinning it down — different from
`init_params`'s defaults used here (`kodak_portra_400`/`kodak_portra_endura`,
no non-default GUI overrides). Not fully reconcilable without the exact GUI
state RFC-004 used, which isn't recorded — flagged as an open question in §6.

## 4. What this RFC does NOT cover

- **Only one film/paper stock pair** (`kodak_portra_400`/`kodak_portra_endura`).
  Different stocks have different characteristic-curve shapes and could hit
  float32's mantissa differently, particularly stocks with steep toe/shoulder
  regions. Before flipping the global default, spot-check 2-3 more pairs —
  cheap to do (`tests/baseline/probe_callable_api.py`'s `build_params` helper
  already parameterises film/paper stock, this RFC's harness could reuse it
  directly).
- **Only one frame**, a flat-lit studio portrait. RFC-005 §5 / RFC-007 §7's
  own protocol has the same limitation and the same fix: "the gate is the
  reviewer's eyes on the side-by-side," not the numbers alone. The numbers
  here are necessary, not sufficient.
- **Not the fused GPU kernels RFC-004 P3/P5 and RFC-007 §6 Q3 describe as
  "later."** `gamut_compress` and the full Hanatos `upsample` reconstruction
  still run their CPU-precision internals regardless of `working_precision`
  (per-call `dtype=float` casts throughout `gamut_compression.py` and
  `spectral_upsampling.py` — e.g. `gamut_compression.py:297,322,375` — silently
  promote back to float64 internally, the same "AGENTS.md trap" the pipeline
  docstring already names). This RFC answers "is the *declared*
  `working_precision` policy safe," not "would a hypothetical fused-float32
  CAM16/Hanatos kernel be safe" — that's still RFC-004 P3/P5's open question,
  now unblocked to actually attempt since this RFC found no float32 accuracy
  wall at the current architecture.
- **Preview-mode's own float32 forcing** (`preview_mode=True` already zeroes
  several params regardless of `working_precision`, `params_builder.py:81-92`)
  is a different, already-shipped code path and isn't re-litigated here.

## 5. Recommendation

**Set `working_precision="float32"` as the default in `params_schema.py:258`**,
unblocking RFC-005 P3 and closing RFC-007 §6 Q3's deferral — but only after
the stock-pair spot-check in §4 is done, since this RFC tested exactly one
pair. Keep `float64` fully supported and selectable (it remains the
validation baseline RFC-004 §2.1 established, and every RFC-005/007
acceptance protocol depends on a float64 reference existing to compare
against). **Not applied in this RFC** — changing a schema default is a
production behavior change and should be a deliberate follow-up commit with
the multi-stock check attached as evidence, not a drive-by edit bundled into
the RFC that first measured the question.

## 6. Open questions

1. What was "the GUI config" RFC-004 §2.2 measured against? If recoverable
   (a saved GUI state file, or someone's memory of the session), re-run it
   against current `main` — if it now also passes, that closes §3's
   reconciliation with direct evidence instead of an inferred explanation.
2. Multi-stock spot-check (§4) — do it before flipping the default.
3. Once §5 ships, RFC-004 P3 (fused CAM16 kernel) and P5 (fused Hanatos
   kernel) become worth attempting on their own merits — re-scope those
   phases' risk assessment now that "is float32 safe at all" has an answer.


---

## 7. Follow-up session (2026-08-25): making the flag real, and shipping it

§2's measurements answered "is float32 colorimetrically safe". They did not
answer "does float32 buy anything", and the answer at the time was **almost
nothing**: measured at 45 MP, `working_precision='float32'` gave 12.68 GB
against float64's 13.22 GB (-4%) and 18.6 s against 19.1 s. AGENTS.md trap 7
already named the cause — the cast happened at the door and every kernel
promoted straight back inside.

### 7.1 What was actually promoting

Per-node dtype + `tracemalloc` peak trace on the 1 MP smoke frame, float32
requested, eleven of twenty-one nodes returned float64:

| promoting node | peak B/px | cause |
|---|---|---|
| `scanning.cctf` | 147 | `colour.RGB_to_RGB` returns float64, unchunked |
| `filming.develop.dir_couplers` | 180 | float64 coupler matrix in the `contract`; float64 amplitudes in `fast_exponential_filter` |
| `filming.expose.halation` | 156 | float64 scatter/halation constant vectors; same exponential filter |
| `filming.develop.grain` | 85 | float64 accumulator (`np.zeros` with no dtype) |
| `printing.expose.enlarger_spectral`, `scanning.scan_spectral` | 72 each | the MLX kernel computes in float32 and the dispatcher then widened the result to float64 — a full-resolution copy carrying no information |
| `scanning.xyz_to_rgb`, `scanning.gamut_compress`, `filming.expose.upsample` | ~48 each | colour-science, and `dtype=np.float64` on the fused kernels' entry casts |
| `preprocess.auto_exposure` | 24 | NEP 50: a `np.float64` scalar is strongly typed, so `float32_image * ev` promotes |

Plus one pure waste independent of precision: `interpolate_exposure_to_density`
allocated a full-resolution float64 `np.zeros` and immediately overwrote it
with the `fast_interp` result — 24 B/px, 1.1 GB at 45 MP, written and thrown
away on every render at either precision.

### 7.2 The invariant

`utils/precision.py`, applied inside the kernels rather than at the door:

> **Full-resolution buffers follow the dtype of their input. Per-pixel
> arithmetic still happens in float64.**

The second half is what makes this cheap in accuracy. In a numba kernel a
float32 load multiplied by a float64 constant promotes to float64 *in
registers*, so the CAM16 forward/inverse, the Hanatos projection and the
81-term spectral accumulation all still evaluate exactly as before — only the
stored result narrows. This is the answer to §4's "not the fused float32
kernels" caveat and to RFC-004 P3/P5's open question: the kernels never needed
to become float32, only their buffers did.

Two colour-science sites could not simply preserve dtype, and got different
treatments:

- `_scan_xyz_to_rgb` → a matmul against `colour.XYZ_to_RGB(np.eye(3), ...)`,
  the identity trick RFC-004 already ships on the GPU node. Verified exact to
  **1.3e-15** against the per-pixel call.
- `_scan_cctf` → `colour.RGB_to_RGB` kept **verbatim**, but run through
  `parallel_pointwise(..., out_dtype=...)` (new parameter), so the float64 it
  insists on returning is one chunk of the frame at a time and the surviving
  buffer is narrow. It is kept verbatim on purpose: for a same-space call
  `RGB_to_RGB` also applies a near-identity CAT02 round-trip matrix before the
  curve, and substituting the colourspace's bare `cctf_encoding` moves output
  by up to **3.8e-4** — the "verify which curve variant is wanted" warning in
  AGENTS.md trap 7, now quantified.

### 7.3 The trap this exposed

Making the kernels dtype-preserving **broke the float64 path**: dE2000 max
**37.9** against the pre-change float64 baseline.

`run_topology` spelled float64 as `precision=None` — "leave every dtype
alone". That was only ever equivalent to float64 because every kernel promoted
internally. Several taps are declared `precision='float32'` even in the float64
pipeline (RFC-005 §7.2, pinning the dtypes the RFC-004 GPU tags used to produce
as a side effect); those were being widened back *by accident*, inside whichever
kernel happened to multiply them against a float64 constant. Once that accident
stopped, float32 reached `grain`, where a rounded input flips Poisson draws and
produces a **different grain realisation** — which reads as a catastrophic
colour regression and is really one node's worth of noise. Grain-off, the same
comparison was dE max 9.9e-7.

Fix: the dispatcher now widens each node's inputs to the working precision as
well as narrowing its outputs, and `pipeline.process` passes `"float64"`
explicitly instead of `None`. **Side effect worth recording: the float64 path
is now genuinely float64.** It previously carried accidental float32 rounding
in `exposure` / `boost` / `halation`, so the baseline moved by dE2000 max
**0.000188**, PSNR 151 dB, MS-SSIM 1.000000 — and the grain field is unchanged
in distribution (rms_rel 1e-6, PSD correlation 1.000000).

### 7.4 Results

45 MP `_DSC2439`, `kodak_portra_400` / `kodak_portra_endura`, grain on with
`grain_sampler='exact'` (deterministic, per §1's protocol), glare off,
`spectral_backend='mlx'`, sRGB out. Single reference run per arm:

| | float64 | float32 | vs float64 |
|---|---|---|---|
| wall time | 18.34 s | **14.25 s** | **-22%** |
| peak RSS | 12.55 GB | **7.15 GB** | **-43%** |
| bytes/pixel | 279 | **159** | -43% |

Against the *pre-change* code, where float32 was 18.6 s / 12.68 GB, this is
**-24% time and -44% peak RSS** — and float64 itself gained too (13.22 → 12.55
GB, and the 1.1 GB dead allocation is gone at both precisions).

Accuracy, float64 vs float32 on the same build:

| comparison | dE mean | dE p99 | dE max | PSNR | MS-SSIM | vs RFC-001 6.1 |
|---|---|---|---|---|---|---|
| no LUTs, grain off | 0.000017 | 0.000069 | 0.000242 | 142.7 dB | 1.000000 | **pass, ~8000x margin on max** |
| with the 17³ LUTs | 0.000009 | 0.000038 | 0.000101 | 146.4 dB | 1.000000 | **pass, ~20000x margin** |
| grain on, stochastic mode | rms_rel 0.000041, skew_rel 0.003517, kurtosis_rel 0.000115, psd_correlation 0.999993 | | | | | **pass, well inside RFC-002 6.2** |

### 7.5 §6 open questions, resolved

1. **"The GUI config" RFC-004 §2.2 measured against** — still unrecovered, and
   now largely moot: §3's inferred explanation is corroborated by §7.3, which
   found the *same class* of bug (an undeclared dtype leaking across nodes and
   changing a stochastic draw) from the opposite direction. Left open.
2. **Multi-stock spot-check — done, closed.** Five film/print pairs at 16 MP,
   grain and glare off, float64 vs float32:

   | film / print | dE mean | dE p99 | dE max | PSNR | MS-SSIM |
   |---|---|---|---|---|---|
   | `kodak_portra_400` / `kodak_portra_endura` | 0.000018 | 0.000070 | 0.000214 | 142.6 | 1.000000 |
   | `kodak_ektar_100` / `kodak_portra_endura` | 0.000018 | 0.000071 | 0.000242 | 142.5 | 1.000000 |
   | `fujifilm_pro_400h` / `fujifilm_crystal_archive_typeii` | 0.000015 | 0.000073 | 0.000240 | 142.6 | 1.000000 |
   | `kodak_gold_200` / `kodak_supra_endura` | 0.000015 | 0.000069 | 0.000218 | 142.7 | 1.000000 |
   | `kodak_vision3_500t` / `kodak_2383` | 0.000012 | 0.000067 | 0.000208 | 143.6 | 1.000000 |

   All five pass every bar by ~4 orders of magnitude. §5's blocker is cleared;
   the default is flipped.
3. **RFC-004 P3/P5 (fused CAM16 / Hanatos float32 kernels)** — re-scoped and
   arguably no longer needed as stated. §7.2 got the memory those phases were
   after (the buffers) without touching the arithmetic, which is where their
   risk lived. What remains for them is *speed* on device, not precision.

### 7.6 Still open

- **Nothing here was measured with glare on.** Glare is the one unseeded stage
  (AGENTS.md trap 1) and every number above disables it, as the protocol
  requires. Its buffers were not audited for promotion.
- **`preprocess.crop_rescale` and the GUI preview path** were not profiled;
  `preview_mode` has its own precision forcing (§4) and is unchanged.
- **`_reference_path` in `spectral_dispatch` still returns float64
  unconditionally.** Deliberate — it is the A/B reference the fused kernels are
  measured against — but it means `spectral_backend='reference'` does not get
  the memory win.
