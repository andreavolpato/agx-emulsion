# RFC-010 — how to test colour science, when every failure is silent

| | |
|---|---|
| **Status** | Proposed. Motivated by three real bugs found on 2026-08-26, all of which passed the entire existing suite. |
| **Date** | 2026-08-26 |
| **Relates to** | RFC-001 §6 (equivalence bars), RFC-002 §6 (stochastic bars), RFC-006 (float32), `API-SPEC-callable-render-service.md` §10 |

## 0. The problem this RFC exists for

On 2026-08-26 the suite had **750 passing tests**. Three colour bugs were live
at the same time:

1. `fused_tc_b` passed a callable where `colour.cctf_decoding` wanted a method
   name, so `input_cctf_decoding=True` was broken for every image above the
   fused threshold — i.e. every real frame.
2. The render service hardcoded `input_cctf_decoding=False`, silently applying
   no transfer function to gamma-encoded input.
3. `preprocess.auto_exposure` multiplied its gain into **gamma-encoded** data
   because the decode happened later, inside `upsample`. The effective
   exposure gain was `g ** 1.8`.

None crashed. None produced an obviously broken image. (2) and (3) produce
*plausible* photographs — that is exactly what makes them dangerous. Bug (1)
only raised at all because colour-science happened to reject the wrong type;
had it accepted a callable, it would have silently mis-decoded forever.

**Why 750 tests missed all three: every test and every baseline in this repo
feeds linear input.** An entire input class — encoded integer files, which is
what Capture One, Lightroom and Photoshop actually produce — was never
exercised. The tests were not weak. They were *uniformly biased*, and a
uniformly biased suite reports full confidence at exactly the moment it knows
nothing.

Colour science is the domain where "it runs and the picture looks fine" is the
default failure presentation. This RFC is about what to test instead.

## 1. The principle

> **Test properties that must hold, not pictures that must match.**

A property needs no reference image, no colour chart, and no human. It is
cheap, deterministic, and it fails loudly. Most of what we actually care about
in a physically-based renderer is expressible as a property.

Reference images are the *weakest* tool here: they need a blessed artifact,
they rot, and when one fails a human has to decide whether the new picture is
better or worse — which is precisely the human-in-the-loop cost we are trying
to avoid spending on every commit.

## 2. Test classes, strongest first

### 2.1 Invariance tests — the highest-value class, zero ground truth

Something changes about the *representation* while the *meaning* is unchanged;
the render must not move. Each one of these would have caught a real bug.

| invariance | statement | catches |
|---|---|---|
| **Encoding** | the same image as linear float and as gamma-encoded integer must render identically | bugs 1, 2, 3 — *all three of today's* |
| **Exposure** | with auto-exposure on, a linear-light scale of the input must render identically | bug 3 |
| **Backend** | numba vs mlx, CPU vs GPU, fused vs reference | RFC-001/007 ports |
| **Precision** | float32 vs float64 within RFC-001 §6.1 bars | RFC-006 |
| **Chunking** | `parallel_pointwise` output must not depend on chunk count | thread-boundary bugs |
| **Tap** | `reprint` from a cached negative == full render | the service's cache boundary |
| **Colour space** | render in sRGB out vs Display P3 out, converted back, must agree | output-side transform bugs |

Two are already implemented (`test_service.py::test_auto_exposure_gain_is_applied_in_linear_light`,
`::test_reprint_matches_a_full_render_with_the_same_params`). **The encoding
invariance test is the single highest-value test in this repo** and should be
run across every input class in §2.5.

### 2.2 Round-trip bounds on a measured property

Measure a quantity that has no "correct" value but must not drift, and pin it
with headroom. `tests/test_spectral_roundtrip_hue.py` is the template:
`RGB -> spectrum -> XYZ -> RGB` per hue, with recorded bounds.

It also documents a real limit rather than hiding it: the reconstruction
round-trips at **1.7–3.8 dE at every hue**, worst in the purple/violet band
(mean 3.07, rotating ~6° **toward blue**), because reconstructing a spectrum
from three numbers is underdetermined and the smooth-spectrum prior
under-represents the bimodal spectra non-spectral colours need. That is
structural, not a defect. The test asserts the *direction* of the failure too,
so a change of character trips it even if the magnitude is unchanged.

### 2.3 Physics-derived known answers — free ground truth, no chart needed

This is the answer to "we cannot afford a ColorChecker." A physically-based
model can be interrogated with stimuli whose correct answer is known
analytically:

- an **equal-energy** stimulus must produce a neutral result;
- the film's **own reference illuminant** must print neutral by construction;
- **doubling input radiance** must move exposure exactly one stop along the
  H&D curve, and be log-linear in the straight-line section;
- a **monochromatic** stimulus at λ must excite the three layers in the ratio
  the published sensitivity curves give;
- **spectral-locus** stimuli must stay inside the locus after reconstruction.

None of these require equipment. They test the physics against itself, which
is exactly what "physically accurate" buys us — the user's own point: if the
model is right, agreement with real film is an *outcome*, not an input.

### 2.4 Monotonicity and direction

Sign errors and parameter entanglement are common and silent. Assert
direction, not value: more `print_exposure` must move the print monotonically
one way; more halation must increase highlight spread; more grain must
increase local variance without shifting the mean. Cheap, and immune to the
"is this picture better?" problem.

### 2.5 Cross-input-class conformance — today's actual gap

The same scene, delivered as **RAW / float TIFF / integer TIFF / JPEG / PSD**,
must land within a stated tolerance. Today's suite covers exactly one of five.
This is a fixture problem, not a framework problem: one scene, five encodings,
one parametrised test.

### 2.6 Domain sentinels

Cheap canaries on every render: no NaN, no Inf, no negatives where physically
impossible, chromaticities inside the locus, output within `[0, 1]` when both
gamut compressions are active. These are assertions, not tests, and belong
close to the kernels.

## 3. Where human-in-the-loop still belongs

Not on every commit. Two places:

1. **A gated contact sheet on colour-touching changes.** The artifact exists
   (`probe_callable_api.py`). Make it a required, *stored* artifact so the
   diff between approved and candidate is visible, rather than a thing someone
   regenerates and squints at.
2. **Acceptance of a new bound.** When a §2.2 bound trips, a human decides
   whether the reconstruction got better or worse. That is a real judgement
   and should not be automated — but it should happen once per real change,
   not once per commit.

## 4. The fixed-dataset trap

Everything measured today used one scene: `_DSC2439` / `_DSC2410`, a flat-lit
overcast beach. It has no neutral reference, no skin in bright light, no deep
coloured shadows, and its one saturated object is a blue-purple coat — which is
precisely the hue the reconstruction is worst at, and we only noticed by
accident.

**A single frame silently defines what "correct" means.** The fix is not more
photographs; it is a deliberate *stimulus set*:

- synthetic: hue circle, neutral ramp, exposure ramp, spectral-locus edge,
  memory colours (skin, sky, foliage);
- real: 3–4 frames chosen for coverage — high chroma, skin under mixed light,
  neutral-dominant, high dynamic range — *not* four more frames of the same
  beach.

The synthetic half costs nothing and catches most of it.

## 5. Deferred, with the reasoning recorded

- **ColorChecker chart.** The standard instrument for "which decode is more
  colorimetrically accurate" (today: rawpy's dcraw matrix vs Capture One's
  profiled ICC — unresolved). Deferred: real purchase cost, and §2.3's
  physics-derived answers cover much of the same ground for free. Worth doing
  when the decode question needs settling for a product decision rather than
  curiosity. The harness is ~an hour once a chart shot exists.
- **Shooting the same scene on real film and comparing.** The gold standard,
  and genuinely too expensive per-change. Two notes: it is a *one-time capital*
  expense (one controlled roll gives a reference every future change can be
  checked against), not a per-commit cost — and an attempt at it today failed
  as evidence because EV, white balance and the manual de-mask were all
  uncontrolled. **An uncontrolled reference is worse than no reference**: it
  invites confident conclusions that the data cannot support.

## 6. What to do first

1. Encoding invariance across all five input classes (§2.1, §2.5) — highest
   value, catches the whole class of bugs found today.
2. Physics-derived known answers (§2.3) — free, and the honest substitute for
   a chart.
3. The synthetic stimulus set (§4) — cheap, and fixes the single-scene bias.

Everything else can follow.
