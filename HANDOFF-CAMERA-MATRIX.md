# Handoff: per-camera colour matrix for the RAW decode (for a fresh session)

**Status:** designed and de-risked, not implemented. The blocking unknowns were
resolved on 2026-08-26 by experiment — read §2 before writing any code, because
the obvious approach does not work and the reason is not obvious.

**Context you need first:** `AGENTS.md` traps 11–13,
`rfc/RFC-010-color-science-testing.md` (this is the exact class of change where
a silent colour error is the default outcome), and
`src/spektrafilm/utils/raw_file_processor.py`.

---

## 1. What this is and why it matters

`load_and_process_raw_file` decodes RAW through
`rawpy.postprocess(output_color=ColorSpace.ACES, ...)`, which applies **dcraw's
generic per-model camera matrix** from LibRaw's built-in table. That matrix is
a coarse colorimetric estimate.

Measured on 2026-08-26: the same frame decoded by rawpy vs by Capture One
(ProStandard, a profiled ICC with a LUT) differed by **median chroma 18.0 vs
27.7 — a 54% difference**, plus a white-balance difference. That gap is
**larger than the spectral reconstruction error** (1.7–3.8 dE, RFC-010 §2.2),
so it is currently the dominant colour error in the whole pipeline. It is also
the cheapest to attack: a measured 3×3 for a known body is free data.

Goal: **when the camera is in a local database, use its measured matrix;
otherwise fall back to today's path, bit-identically.**

Source of matrices: DxOMark publishes an ISO 17321 colour matrix per body under
CIE-D50 and CIE-A. For the Nikon Z7 II (the reference body for this repo's
baselines) it is:

```
        R_out    G_out    B_out
R_raw    1.81    -0.72    -0.09
G_raw   -0.14     1.44    -0.31
B_raw    0.03    -0.46     1.43
```

## 2. The three things I checked so you do not have to

### 2.1 `rawpy.rgb_xyz_matrix` is **XYZ→camera**, not camera→XYZ

dcraw's `cam_xyz` convention. Verified numerically: `M @ XYZ(D65)` gives
`[0.5497, 1.0620, 0.9109]`, whose reciprocal normalised to green is
`[1.9319, 1.0, 1.1659]` — matching `raw.daylight_whitebalance / G` =
`[1.9316, 1.0, 1.1661]` to four decimals. So camera→XYZ is `inv(rgb_xyz_matrix)`.

Also: `raw.color_matrix` is **all zeros** for this body. Do not use it.

### 2.2 You cannot override LibRaw's matrix through rawpy

`raw.rgb_xyz_matrix` *looks* writable (`m[0][0] *= 1.5` raises nothing) but it
returns a **copy**: reading the attribute back shows the original values, and
`postprocess()` output is bit-identical (max abs diff 0.000000). There is no
`postprocess` parameter for a colour matrix either — the signature has no
matrix/colour argument beyond `output_color`.

**So the matrix must be corrected after the fact, not injected.**

### 2.3 Re-deriving rawpy's output by hand does not trivially work

Two attempts, both failed, both recorded so you do not repeat them:

- decode `output_color=ColorSpace.raw`, apply `inv(rgb_xyz_matrix)` then
  XYZ→ACES yourself → **max abs diff 0.217** against rawpy's own ACES output;
- decode `output_color=ColorSpace.XYZ` and apply XYZ→ACES yourself → **max abs
  diff 0.073**.

LibRaw does more per target space than a single matrix (highlight handling and
per-space white adaptation are the likely causes; not chased down). Conclusion:
**do not try to reimplement the decode.** Correct its output instead.

## 3. Recommended implementation

Compose a single correction matrix that maps rawpy's output to what the
measured matrix would have produced. Both are linear maps out of the same
camera space, so the camera space cancels:

```
M_correction = M_XYZ_from_sRGB @ M_dxo(cam→sRGB) @ rgb_xyz_matrix(XYZ→cam)
```

applied to rawpy's `ColorSpace.XYZ` output, then XYZ→ProPhoto exactly as today.
One 3×3 matmul on the decoded image, no re-plumbing of the decode.

**Read the DxO table row-wise as output channels**, i.e.
`out_i = Σ_j M[i][j] · wb_raw_j`. DxO labels rows `R_raw` and columns `R_sRGB`,
which reads as the transpose — but the **row sums are 1.00, 0.99, 1.00**, the
white-preserving property a correctly-oriented matrix must have, while the
column sums are 1.70, 0.26, 1.03. Row-wise is right. *Re-run that row-sum check
for every matrix you add to the database; it is the cheapest possible guard
against a transposed entry, and a transposed matrix produces a plausible-looking
wrong image, not an error.*

### Database shape

`src/spektrafilm/data/camera_matrices/*.json`, one entry per body:

```json
{
  "make": "NIKON CORPORATION",
  "model": "NIKON Z 7_2",
  "display_name": "Nikon Z7II",
  "illuminant": "D50",
  "target": "sRGB",
  "matrix": [[1.81, -0.72, -0.09], [-0.14, 1.44, -0.31], [0.03, -0.46, 1.43]],
  "white_balance_raw": [1.75, 1.0, 1.37],
  "metamerism_index_iso17321": 83,
  "source": "DxOMark measurements page",
  "notes": "row-sums verified 1.00/0.99/1.00"
}
```

Lookup key is EXIF make+model, normalised (upper-case, collapse whitespace).
`_read_exif_metadata` already returns `ExifData.make` / `.model` and is already
used for lens correction, so the plumbing exists. Beware the naming: EXIF says
`NIKON CORPORATION` / `NIKON Z 7_2` while Capture One's sidecar says
`Nikon Z7II` — match on EXIF, keep `display_name` for humans only.

### Fallback

No entry → return today's result **unchanged**. This must be bit-identical, and
it is the first test to write (§5).

## 4. Open questions, in priority order

1. **Illuminant dependence.** The DxO matrix is fit under D50; they publish a
   CIE-A variant too (there is a tab for it on the measurements page). A matrix
   fit under one illuminant is an approximation under another. Options: ship
   both and select by the scene white balance, blend between them by CCT, or
   ship D50 only and document the limit. **Decide deliberately — do not ship
   D50 silently and call it "measured".**
2. **Is it actually better?** This is a *hypothesis*, not an established fact.
   Nobody has shown DxO's matrix beats dcraw's for this body. RFC-010 §5's
   ColorChecker is the instrument that settles it. Until then this change is
   "different", not "correct", and the commit message must say so.
3. **Where does white balance live?** LibRaw applies camera WB in camera space
   before its matrix; DxO's matrix also expects neutral-balanced input (hence
   row sums of 1). They should compose correctly, but the WB values differ
   (LibRaw as-shot `[1.6777, 1, 1.3223]` vs DxO D50 `[1.75, 1, 1.37]`) and this
   has not been verified end to end.
4. **Scope of the database.** One body is enough to ship the mechanism. Do not
   bulk-enter matrices you have not row-sum-checked.

## 5. Tests to write first (RFC-010 shapes — none need a colour chart)

1. **Fallback invariance.** A body not in the database renders bit-identically
   to `main`. This is the one that protects every existing user.
2. **Neutral preservation.** A neutral patch stays neutral through the
   correction matrix — the row-sum property, asserted on the *image*, not just
   the JSON.
3. **Schema validation.** Every database entry has row sums within tolerance of
   1.0, a 3×3 of finite floats, and a declared illuminant and target. Runs over
   the whole directory, so a bad entry cannot land.
4. **Lookup normalisation.** `"NIKON CORPORATION"`/`"nikon corporation "` and
   the model variants resolve to the same entry; an unknown body returns None
   rather than raising.
5. **Round-trip sanity.** `M_correction` applied to a synthetic image, then its
   inverse, returns the original within float tolerance.

## 6. What this does *not* change, so nobody panics

- **The baselines are safe.** `tests/baseline/_DSC2439_*.tif` are already
  *decoded* TIFFs, not RAW, so they do not go through this path at all. Every
  RFC-001/005/006/007 number stands.
- **The service is unaffected** except that RAW input may decode differently
  for listed bodies. `open`'s `detected_input` should grow a field naming which
  matrix was used — per RFC-010, the API must report what it inferred, and
  "which camera matrix" is exactly that class of fact.
- **This is orthogonal to the input-contract work.** Encoded TIFFs from Capture
  One never touch the RAW decode.

## 7. Why this is worth doing before the fancier idea

The deeper fix is camera-aware *spectral reconstruction* — using the sensor's
own spectral sensitivities to pick the metamer, instead of assuming the camera
is colorimetric (its ISO 17321 metamerism index of 83 says it is not). That
needs measured sensitivity curves, which DxO does not publish and which do not
exist publicly for the Z7 II; you would have to estimate them from a chart
under multiple illuminants.

The matrix swap is the same idea's cheap first step: it attacks the larger of
the two measured error terms with data that already exists, and it builds the
per-camera database that the spectral version would need anyway.
