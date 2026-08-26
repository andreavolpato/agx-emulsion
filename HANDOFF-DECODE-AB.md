# Handoff: which RAW decode is the "pleasing" one (the A/B decision)

**Status:** decision pending on a human preference study. Design and the
measurable facts are pinned in this session; what remains is to run the A/B
on a curated dataset and pick the canonical decode.

**Why this is a product choice, not a measurement.** There is no "correct"
colour response. Every decode is a scene estimate with its own colour
tendency; the film model (spectral upsampling + density curves + DIR
couplers + grain) sits on top and adds its own tendency. The only bar the
team has committed to is **"visually pleasing film output"** — not
academic/colorimetric accuracy, which is unattainable at reasonable cost
(the lost spectral information is truly lost; a deep model would only learn
a prior, and any film-referred reference is itself contaminated by the
scanner's tendency).

---

## 1. Where this session landed (measured, not assumed)

The batch in question is `tests/capture_one_test/linear response test/`:
`_DSC2386.NEF` and our own `_DSC2386-2-6.tif` (C1 export, same frame).

| | value |
|---|---|
| same frame, same film (`portra_400` -> `portra_endura`), only decode differs | C1 "Linear Response" TIFF vs rawpy/dcraw + `as_shot` WB |
| **ΔE2000** (aligned downscale, offset dx=16 / dy=32) | mean **5.06**, p95 10.12, max 60.3 |
| PSNR | 24.70 dB |
| mean abs | 0.0335 |
| purple-ish region vs rest | dE 5.23 vs 4.92 — **not purple-specific** |

So the difference between the two decodes is **~5 dE**, roughly uniform across
hue, and it is **larger than the spectral round-trip error** (1.7–3.8 dE,
worst in the purple band — see `rfc/RFC-010-color-science-testing.md` and
AGENTS.md trap 13). Conclusion for this batch: **the colour discrepancy is
decode-driven, not a spectral-reconstruction bug.** The purple band is where
the two effects *could* compound, but it is not where they differ here.

### 1.1 What "C1 Linear Response" actually is

A C1 export bundles three things:
1. **camera profile** — colour (`ProStandard` in this batch);
2. **base characteristic** — tone; `"Linear Response"` flattens this to a
   straight line;
3. **export transform** — the target colour space + its transfer encoding
   (here ProPhoto RGB, i.e. gamma 1.8 on a 16-bit integer).

So "Linear Response" flattens **luminance**, not **chroma**; C1's colour
interpretation is still baked in. The exported TIFF **is** genuinely ProPhoto
(verified by its embedded ICC: `ICCProfile:profile_description = "ProPhoto
RGB"`), but it is **not** scene-linear until you decode the ProPhoto gamma
(OIIO read of a centre patch: raw mean 0.160 -> decoded 0.043, ratio 0.227).

---

## 2. The saturation scare, resolved (and fixed)

**The suspicion "we re-converted a ProPhoto TIFF and over-saturated it" is
not what happens.** On the same C1 TIFF, three render variants (downscaled):

| variant | result |
|---|---|
| A. decode at the door (contract path) | out mean 0.437 / max 0.951, Lab C* mean 15.44 / max 115.69 |
| B. manually decode to linear ProPhoto, then feed | **bit-identical to A, ΔE2000 = 0.0** |
| C. treat gamma values as linear ("no decode") | **de-saturates**: C* mean 11.83 / max 89.55, dE(A,C)=5.39 |

Decode order is irrelevant (A ≡ B), and the "no-decode" mistake *reduces*
saturation, not over-saturates. So for a genuinely ProPhoto file there is no
double-conversion.

**The real over-saturation source** was the service hardcoding
`input_color_space="ProPhoto RGB"` for **every** non-RAW file
(`service/_load_image`). An actually-sRGB input mis-read as ProPhoto inflates
chroma by ~25%:

```
correct (sRGB -> linear ProPhoto):  Lab C* mean 11.26  p95 52.0  max 217
mis-assoc (sRGB values as ProPhoto): Lab C* mean 14.03 p95 61.8 max 257
```

### 2.1 The fix landed this session

`src/spektrafilm/service/service.py` now detects the colour space instead of
assuming ProPhoto:
- priority: **embedded ICC description** (`ICCProfile:profile_description`)
  > **non-generic OIIO colour-space metadata** > **format default**;
- OIIO's `oiio:ColorSpace = srgb_rec709_scene` is treated as its *generic
  role* (it appears on both sRGB web images and genuinely ProPhoto files), so
  it is never trusted as the file's real space;
- defaults: untagged 8-bit `.png/.jpg` -> `sRGB` (encoded), untagged float ->
  `ProPhoto RGB` linear (repo baseline convention), untagged integer TIFF ->
  `ProPhoto RGB` (repo convention);
- the report-only field `input_color_space_source` is returned in `open`'s
  `detected_input` but is filtered out of the `params_delta` merge (so it
  cannot leak into `apply_delta`).

Verified on real files: C1 TIFF -> `ProPhoto RGB` (source `ICC`);
`img/targets/it87_test_chart_2.jpg` -> `Adobe RGB (1998)` (source `ICC`);
`img/targets/cc07.png` -> `sRGB` (source `8bit-web-default`); the float
baselines -> `ProPhoto RGB` linear. See
`tests/test_service.py::test_input_colorspace_detection_uses_icc_and_format_defaults`.

---

## 3. The Apple RAW 8 / 9 point (and why it re-confirms the framing)

After productisation, RAW input is planned to go through **Apple's own RAW 8 /
9 engine** (independent of C1's decoder). That is a **third** decode with its
own camera-profile tendency. The pipeline then adds the spectral film
tendency on top.

Practical consequences:
- there is no single "true" scene; there are **at least three plausible
  decodes** (C1 ProStandard / rawpy-dcraw / Apple RAW), each a different
  colour tendency;
- the contract must **name the canonical decode** and **report which one was
  used** (RFC-010's "the API says what it inferred"). `open`'s
  `detected_input` reports the input space / cctf and a `raw_engine` field
  (`"dcraw"` today via rawpy/LibRaw; `"apple_raw_9"` once the Apple path is
  wired). When Apple RAW becomes the product RAW path, update that value rather
  than leaving `"dcraw"`;
- the A/B below must **include Apple RAW 8/9 as a candidate** once that path
  is wired; if Apple becomes the product RAW path, the A/B is literally
  "which decode's film output is most pleasing" between Apple/C1/rawpy.

---

## 4. The A/B protocol to run (the actual decision)

**Compare film OUTPUT, not input RGB.** Comparing the two input decodes
directly is confounded by C1's tone flattening (Linear Response) vs rawpy's
raw linear — you would be judging tone, not colour. The product image is the
film render, so that is where the bar applies. Optional (and useful): an
additional aligned **input-RGB** comparison, with exposure/tone normalised
first, to isolate the decode's colour tendency by itself.

### 4.1 Data

- large, diverse: neutral gray, skin, sky, foliage, fabric, saturated
  primaries, and **purple/violet specifically** (the weakest reconstructed
  band).
- render each source through **the same film stock** (start with
  `portra_400` -> `portra_endura`; add a cine pair such as
  `vision3_250d` -> `kodak_2383` for a second axis).
- per source, produce each decode candidate as a linear ProPhoto input:
  `(a) C1 Linear Response` (export), `(b) spektrafilm/rawpy`
  (`load_and_process_raw_file(..., output_colorspace="ProPhoto RGB",
  output_cctf_encoding=False)`), `(c) Apple RAW 8/9` when wired.
- feed through the identical pipeline: auto-exposure on (or a fixed matched
  EV), grain+glare **off** (deterministic; otherwise two renders differ by
  the unseeded glare), `working_precision=float32`, `spectral_backend=numba`,
  output `Display P3` + `output_cctf_encoding=True`.
- **align before comparing**: the C1 TIFF and the NEF are not pixel-aligned
  (5520×8288 vs 5504×8256; this frame's offset was dx=16, dy=32). Recover the
  offset per frame or crop, never diff raw.

### 4.2 Presentation & judgement

- **blind paired A/B**, random order, same frame; the judge does not know
  which decode which image came from.
- show a **full frame** for colour + a **1:1 crop** for grain/halation
  (downscaling erases grain/halation — see API-SPEC §4).
- the "only bar" is **which is more pleasing**; use a paired *preference*
  (not an absolute score) and repeat over `N` judges/sessions to beat
  preference noise.
- control for exposure/WB: normalise both to the same neutral before
  presentation, or present both as auto-exposed.

### 4.3 Decision rule

Pick the decode whose film output wins the paired preference. That becomes
the **canonical raw/decode path** for the product. Then:
- write it into the input contract (a one-paragraph "the film look is defined
  relative to decode X; different decodes give different looks");
- gate or remove the non-canonical paths, or keep them as clearly-labelled
  "other decode" options (never silently default to a second one);
- keep the `open` `detected_input` reporting so a user can always see which
  decode was used.

---

## 5. Files / artefacts to reuse

- measurement & evidence: `tests/capture_one_test/linear response test/`,
  `tmp/render_jpeg_samples.py` (render an input to a Display P3 JPEG, CPU
  numba, grain/glare off), `tmp/render_samples/` (this session's 6 renders).
- the fix: `service/service.py` `_detect_nonraw_input` +
  `_resolve_colourspace_name`; regression test in `tests/test_service.py`.
- design framing: AGENTS.md trap 11–13, `rfc/RFC-010-color-science-testing.md`,
  `HANDOFF-CAMERA-MATRIX.md` (the per-camera matrix is **not** the way — the
  decode choice is the lever, and it is now a stated product decision).

---

## 6. Open questions for the next session

1. Should the film look be defined relative to **C1**, **rawpy/dcraw**, or
   **Apple RAW 8/9**? (Only the A/B answers this.)
2. Once Apple RAW becomes the product RAW path, does the C1-linear-TIFF path
   stay as a "bring-your-own" input, or is it dropped?
3. `raw_engine` is now reported in `open`'s `detected_input` (`"dcraw"` today,
   `None` for non-RAW). Confirm it is updated to `"apple_raw_9"` (or whatever
   the product RAW engine is) when that path lands, so the caller always knows
   which decode tendency is in play.
