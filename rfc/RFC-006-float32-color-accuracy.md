# RFC-006 — float32 color accuracy: is the working-precision move actually safe?

| | |
|---|---|
| **Status** | Measured, recommendation given. Not yet applied to `params_schema.py`'s default — see §5. |
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
