# RFC-015 — Auto exposure that meters by intent, and a white balance that reaches the engine

| | |
|---|---|
| **Status** | Proposed 2026-09-11. Nothing implemented. §1.1 is a code-traced bug that has **not yet been reproduced live**. |
| **Date** | 2026-09-11 |
| **Depends on** | RFC-014 (the C++ engine is the renderer; `Pipeline::measure_exposure_ev` is the meter), `CONTRACT-frontend-backend.md` §1.1 (additive wire changes need no version bump) |
| **Scope — engine** | `engine/src/pipeline/pipeline.cpp` (`measure_exposure_ev`, `node_auto_exposure`), `engine/src/pipeline/engine.cpp` (`spk_solve`), `engine/src/core/params.{hpp,cpp}` (one new wire field) |
| **Scope — frontend plumbing** | `Model/Session.swift` (re-decode → re-develop), `Model/Params.swift` + `Model/Sidecar.swift` (the mode field), `Import/ImageDecoder.swift` (white balance for flat files) |
| **Out of scope — frontend design** | **The UI for everything in this RFC is designed by the user (Hanze) and is not specified here.** §4 lists the design inputs: what the UI has to be able to express. It does not say how. Do not build controls, layouts or copy from this document. |
| **Handoff** | §8. That is where the next session starts. |

---

## 0. Two problems, one boundary

Both started as a user observation about the picture, and both turn out to be
about what crosses the frontend/backend boundary and when:

1. **"Camera WB does nothing to the result."** The engine does not absorb it.
   The frontend re-decodes the RAW with the new white balance and then never
   gives the engine the new frame (§1.1). This is a bug, not a design flaw, so
   the setting stays. §1.2 says why the post-print white balance cannot
   replace it.
2. **"Centre-weighted auto exposure gets a lot of frames wrong."** Right
   symptom, mostly the wrong suspect. The bigger error is that every mode
   takes an *arithmetic* mean of *linear* light, which a few bright pixels
   dominate (§2.2). The fix is to meter in log space and let the user choose
   the *intent* (balanced, centre, protect highlights, protect shadows) rather
   than a meter pattern (§2.3).

One RFC because the two share their shape: an engine-side computation, a
number that has to reach the frontend (`solve`), a setting that has to reach
the engine (`params_delta`, the decoded frame), and a UI the user will design
on top of both.

---

## 1. White balance

### 1.1 The bug: a re-decode does not re-develop

Traced through the code; **reproduce before fixing** (§7 step 1).

1. Changing Camera WB writes `Session.decode` (`Session.swift:57`), which calls
   `scheduleReopen()` (`:1129`).
2. `scheduleReopen` cancels the develop task, invalidates the cached print, and
   runs `load(url)`. That re-decodes the RAW through `CIRAWFilter` with the new
   `neutralTemperature`/`neutralTint` (`ImageDecoder.swift:163–168`). So the
   *display* decode, the picture shown before a develop and on the left of the
   split, does change.
3. `load` ends in `ensureDeveloped()`, whose second line is
   `if let sid = serviceSessionID { return sid }` (`:918`).
4. **`scheduleReopen` never clears `serviceSessionID`.** Only selecting a
   different frame does (`:727`, `:805`). So `ensureDeveloped` returns the old
   session at once. The engine keeps the linear frame from the *first*
   develop, and every later reprint, slider move and export renders the old
   white balance.

It came in with `429c9ba` ("open onto the decode"), which added the early
return. **The fix:** in `scheduleReopen`, drop the engine session the same way
a frame switch does (`scheduler.invalidate()` and `serviceSessionID = nil`),
so the `load` → `ensureDeveloped` tail develops the new decode. `wantsDevelop`
is already preserved there, so a frame that was never developed is still only
re-decoded.

Nothing in the engine neutralises a global cast on its own. The print
normalisation (`printing.cpp`, `exposure_factor`) divides by a *geometric mean
over channels*, which moves brightness and leaves colour alone. The neutral
filter pack comes from `neutral_print_filters.json` per stock pair, not from
the image. So once the frame reaches the engine, a white-balance change must
show in the print.

**Second reason it can look dead.** Camera WB applies to RAW only; the panel
says "Decode white balance applies to RAW input only." The only test image in
the repo, `img/test/portrait_leaves_32bit_linear_prophoto_rgb.tif`, is a flat
file, so there it can never do anything. See §1.3.

### 1.2 Decision: keep Camera WB. The post-print white balance cannot replace it

The app has three places a colour balance can happen, and they are not
interchangeable:

| where | control today | what it is physically |
|---|---|---|
| **before the film** | Camera WB (`DecodeSettings`, applied in `CIRAWFilter`) | the light that reaches the film: an 80A on the lens, or daylight vs tungsten stock |
| **at the enlarger** | `m_filter_shift` / `y_filter_shift` (engine, print layer, live-mutable) | the darkroom printer's colour correction |
| **after the print** | Print White Balance (`Adjustments.temperature/tint`, Layer 2) | a correction on the scan, i.e. taste |

Film is non-linear per dye layer. A cast that reaches the film puts each
channel at a *different point* on that stock's characteristic curve, so it
comes out as a different cast in the shadows, midtones and highlights
(crossover). Tungsten light on daylight stock leaves the blue layer
underexposed, in its toe. A post-print correction is roughly one gain per
channel on the finished image: it can neutralise the midtones and leaves the
ends tinted in different directions. So neutralising the scene light belongs
before the film; the other two are for correction and taste. Deleting Camera
WB would remove the only physically correct place for it.

### 1.3 Proposal: white balance for linear flat files, in the client

A scene-linear TIFF (the repo's own test image is one) has no RAW white
balance to set, but it can still be chromatically adapted before the film. Do
it **in the client**, next to the RAW path, not as an engine node:

- It keeps `ImageDecoder`'s rule that white balance is a client decision
  applied to *both* decodes. For a flat file `display` and `linear` are the
  same image, so one transform keeps the before/after split comparing the
  film rather than the neutral point. An engine-side node would leave the
  "original" unbalanced.
- **No wire change.** The engine receives an already-balanced linear ProPhoto
  frame, exactly as it does for a RAW.

Mechanics: a 3×3 chromatic adaptation (Bradford) in linear ProPhoto, applied
as a `CIColorMatrix` on `decoded.linear` before `engineFrame` and on the
display image. The source white comes from temperature (CCT on the Planckian
locus) plus tint (Duv). Identity, the "as shot" of a flat file, is the colour
space's own white (D50 for ProPhoto). Pick-neutral for flat files samples
`ImageDecoder.sampleLinear` and adapts that pixel's chromaticity to the white.

**Scale warning for the UI (§4):** Apple's RAW `neutralTint` is in Apple's own
units, and CCT+Duv is not the same scale. The two must not be presented as the
same slider values. Whether the UI hides that or states it is a design call.

**Sidecar:** `DecodeSettings` already holds `temperature` and `tint`. For flat
files they are read on the Planckian+Duv scale, and a flat file whose
`whiteBalance == .asShot` is identity. No schema change is needed unless the
UI wants the scale recorded explicitly.

---

## 2. Auto exposure

### 2.1 What the engine does today

`Pipeline::measure_exposure_ev` (`pipeline.cpp:554`) is the whole meter. Two
corrections to how it has been described:

- **The luminance is not adapted.** `rgb_to_xyz_ae_` is the Y row of the input
  space's RGB→XYZ with `illuminant = nullptr` (`pipeline.cpp:189–192`),
  matching `autoexposure._luminance_y`. CAT02 to the film's reference
  illuminant belongs to the `tc_b` matrix, a different thing.
- **Three methods exist and none is reachable.** The C++ engine implements
  `center_weighted` (the default, `params.hpp:121`), `average` and `median`.
  Python had seven (`utils/autoexposure.py`: plus `partial`, `matrix`,
  `multi_zone`, `highlight_weighted`). But `auto_exposure_method` is **not in
  the wire table** (`params.cpp` `kFields` lists only `auto_exposure`), so the
  app always gets `center_weighted`.

Unchanged by this RFC: the 256 px stride sample for the node versus the full
live tier for `solve` (`pipeline.hpp:100–108`, ~3e-3 EV apart); the division
by 0.184; the gain narrowed through float32.

**A finding the frontend design depends on (verify, §6).** By code reading,
**Exp. Comp. is print-compensated by default.** `print_exposure_compensation`
and `normalize_print_exposure` both default to `true` (`params.hpp:132–133`).
That makes `printing.cpp` take the print gain from a mid-grey exposed *at*
`2^exposure_compensation_ev`, so the print re-normalises the compensated
mid-grey. That is a lab auto-printer: the slider moves where the scene sits on
the film curve (grain, latitude, saturation), and much less how bright the
print is. If rendering at −2 / 0 / +2 EV confirms it, the UI should not
present Exp. Comp. as a brightness control. Brightness belongs to
`print_exposure`.

**A second finding (no action in this RFC).** The meter runs after
`preprocess.geometry` (`pipeline.cpp:1325–1326`), so it would meter the crop.
But the frontend never sends geometry (it crops client-side at export), so
today the meter always sees the **uncropped** frame, and `solve` meters the
uncropped tier too. Cropping to a subject does not re-meter. Whether it should
is an open question (§5, Q4).

### 2.2 Why so many frames come out wrong

All three shipped modes take an arithmetic mean of linear luminance. In linear
light one stop brighter is twice the value, so a small bright region
dominates the mean: a strip of sky, a window or a lamp pulls it up, and the
frame is underexposed. Centre weighting only moves where the error comes
from.

The standard fix is the **log-average**: average ln Y, then exponentiate. That
is what photographic mid-grey means, a middle in *stops*. It is hardly moved
by small bright areas. It is overly moved by near-black pixels (black borders,
the frame edge of a scan), hence the trimming below.

### 2.3 The four modes

Wire names, and what each promises about the **output**:

| `auto_exposure_method` | name for the UI (user's call) | promise |
|---|---|---|
| `balanced` | overall correctness | the frame's middle, in stops, lands on mid-grey |
| `center` | centre-weighted | the same, for a subject in the middle |
| `protect_highlights` | preserve highlights | as balanced, but pulled down until the brightest part stops clipping |
| `protect_shadows` | preserve shadows | as balanced, but raised until the dark part stops blocking |

On the sample `Y_i` (the same stride sample and Y row as today):

```
floor      Y_i ← max(Y_i, 0.184 · 2^-12)
trim       T = { i : P1(Y) ≤ Y_i ≤ P99(Y) }                 (by rank)

balanced   L = exp( mean_{i∈T} ln Y_i )
           EV_b = −log2(L / 0.184)

center     L_w = exp( Σ_{i∈T} w_i ln Y_i / Σ_{i∈T} w_i ),  w_i = today's Gaussian (σ = 0.2 of the long edge)
           EV_c = −log2(L_w / 0.184)

protect_highlights
           H = P99.5(Y)                                      (all samples, unweighted, untrimmed)
           EV_h = clamp( log2(0.184 · 2^s_hi / H),  EV_b − 3,  EV_b )

protect_shadows
           S = P5(Y)
           EV_s = clamp( log2(0.184 · 2^−s_lo / S), EV_b,  EV_b + 2 )

initial    s_hi = 2.5 stops above mid-grey,  s_lo = 3.5 stops below (calibrated in §7 step 3)
```

**The protect modes are bounds on balanced, not meters of their own.** That is
the design point. A standalone highlight meter pushes a frame that has no
highlights far over, and a standalone shadow meter does the opposite to a
bright frame. As bounds, each acts only when that frame actually has
something at risk, and otherwise equals `balanced`. The clamps (−3 / +2 EV)
stop a single specular highlight or a black border from running away with the
exposure.

**Protection is never centre-weighted.** A blown sky in a corner is still
blown.

**Where the offset goes.** The AE node applies `EV_mode` exactly as it applies
`EV` today: one scalar gain, float32-narrowed. It is *not* print-compensated,
unlike Exp. Comp. (§2.1). That is deliberate. "Protect highlights" promises a
darker output with the highlights kept, and that holds in both paths:
reversal and `scan_film`, where the film clips, and negative → print, where
the paper clips first. The lab behaviour ("expose more, print to normal")
stays available through Exp. Comp. No change to `printing.cpp`.

**Cost:** two partial sorts (`nth_element`) and a log sum over ~40 k samples.
Not measurable next to the stride gather already on the device.

### 2.4 Later: shoulder and toe from the stock

`s_hi` and `s_lo` are fixed stops in v1. The engine has each stock's density
curves (`film.data.density_curves` against `log_exposure`), so both can
become properties of the stock: the log exposure where density comes within δ
of `D_max` (shoulder) or of base + fog (toe). That is the physically honest
version, but it needs the calibration set from §7 step 3 to choose δ. It is
not part of this RFC's first implementation.

---

## 3. Wire changes (all additive, per CONTRACT §1.1)

| change | shape | notes |
|---|---|---|
| **new `params_delta` field** | `auto_exposure_method`: string, shoot layer, not live | Accepted values: `balanced`, `center`, `protect_highlights`, `protect_shadows`, plus the legacy `center_weighted`, `average`, `median`, which keep today's linear-mean behaviour byte for byte. Unknown value → user error, as today. |
| **engine default unchanged** | `center_weighted` | The parity harnesses compare against the Python reference, whose default this is. The app switches by *sending* a mode (§7 step 6), not by the engine changing under it. |
| **`solve(target:"exposure")` response** | adds `exposure_ev_by_method: {balanced, center, protect_highlights, protect_shadows}` | All four from one sample in one call, so a UI can show what each mode would do without four round trips. `exposure_compensation_ev` stays: the EV of the session's *current* method, for back-compat. |
| **no wire change** | flat-file white balance (§1.3), re-decode fix (§1.1) | client-only |

The implementing session appends the request to CONTRACT §5 before the engine
work and the landed change to §6 after it. That is the contract's own rule;
this RFC does not edit the contract.

**Frontend plumbing (not design):** `FilmParams` gains `autoExposureMethod:
String?`, sent as `auto_exposure_method` only when non-nil. A sidecar without
the field decodes to nil and sends nothing, so **every existing edit keeps its
current exposure**, and a new mode applies only to frames where it is chosen.
Changing the mode is a shoot-layer edit (rebuild + film render) followed by a
`solve(target:"exposure")` so `solvedEV` and its "auto +x EV" label stay true.

---

## 4. Frontend design inputs (the user designs the UI)

This section lists **what the UI has to be able to express**. It gives no
layout, controls or copy; those are the user's.

1. **The four exposure intents** and which is active; optionally each one's EV
   from `exposure_ev_by_method`.
2. **What Exp. Comp. means** once §2.1's finding is verified: film placement,
   not print brightness. It is also an offset from the solved EV, so its zero
   is `solvedEV` (today's "auto +x EV" sublabel).
3. **Three white balances**, named so they cannot be confused (§1.2): before
   the film (Camera WB), at the enlarger (M/Y filter shift), after the print
   (Print White Balance). Today two of them are both called "white balance".
4. **White balance on flat files** (§1.3), including the scale difference
   between Apple's RAW tint and CCT/Duv, and "as shot" meaning identity for a
   flat file.
5. **Latency the UI must allow for:** a white-balance change re-decodes and
   re-develops (about 1.1 s on a 45 MP RAW after `df46492`); a mode
   change is a film re-render plus a solve. Neither is a live reprint.

---

## 5. Open questions (the user's decisions)

- **Q1 — the default mode for new frames.** Recommend `balanced`, but only
  after §7 step 3 shows it beats `center_weighted` on the evaluation set.
- **Q2 — `s_hi` / `s_lo`**, from the evaluation set. Then whether §2.4 (from
  the stock) is worth doing.
- **Q3 — flat-file white balance** (§1.3): build it, and whether its UI shows
  the scale difference.
- **Q4 — should the meter see the crop?** A camera meters what is in the
  viewfinder, which argues yes. It needs the crop rect reaching the meter:
  either the frontend sends `geometry_*` (which also moves the crop into the
  engine at render) or a meter-only ROI on `solve` and the node. Not in this
  RFC.

---

## 6. Verification

- **§1.1, before fixing:** on a RAW, develop, change Camera WB (e.g. As Shot →
  Tungsten), wait for the reprint, and confirm the **print** does not change
  (compare the output, not the display decode). Then fix it and confirm the
  print changes and export matches the canvas. Under this repo's rule
  (guards-that-cannot-fire): a test for the fix must fail on the old code.
- **§2.1 print-compensation finding:** render one frame at Exp. Comp. −2 / 0 /
  +2 with defaults, and measure mean output luminance and a mid-grey patch.
  Report the numbers. Repeat with `print_exposure_compensation = false`.
- **Legacy methods are byte-identical:** `center_weighted`, `average` and
  `median` give the same EV and the same render as before the change. The
  existing parity harnesses run with `auto_exposure = false`, so they **do
  not cover this**; add a direct EV comparison against
  `utils/autoexposure.py` for all three.
- **New modes, unit-level:** synthetic frames with a known answer. A uniform
  frame at Y = 0.184 gives 0 EV in all four. A mid-grey frame with a 0.5 % patch
  at 64× leaves `balanced` within 0.05 EV of 0 (the linear mean is off by
  ~0.4 EV). A frame with no highlights gives `protect_highlights == balanced`.
  Frames past the clamp limits hit exactly −3 and +2.
- **`solve`:** `exposure_ev_by_method` matches the node's EV for each mode (to
  within the stride-vs-full-tier difference, stated as a number).
- **Old sidecars:** a sidecar without the field sends no
  `auto_exposure_method` and renders bit-identically to before (grain and
  glare off; see the RFC-013 grain trap).

---

## 7. Sequence

1. **§1.1 fix (frontend, small).** Reproduce, fix, verify. Independent of
   everything else; ship first.
2. **Engine: the four modes, the wire field, `exposure_ev_by_method`**, with
   §6's tests. CONTRACT §5 entry first, §6 entry on landing.
3. **Evaluation.** Needs a folder of ~20–30 real frames from the user,
   including the hard cases: backlit, snow or beach, night with lamps, open
   sky, dark interior, a scan with black borders. Table per frame: EV per
   mode, plus `center_weighted` as today's baseline, and a contact sheet
   rendered at each. This decides Q1 and Q2.
4. **Frontend plumbing** (§3): the field, the sidecar, re-solve on mode
   change. Behind the user's UI design, not ahead of it.
5. **Flat-file white balance** (§1.3), if Q3 says yes.
6. **Default switch** for *new* frames, if Q1 says yes: the frontend starts
   sending the chosen mode. The engine default stays.

---

## 8. Handoff to the next session

Read in this order: this RFC §0, §1.1 and §7; then `CONTRACT-frontend-backend.md`
§1–§2 and §5–§6; then `AGENTS.md` (engine build and the parity loop).

**Where things are**

| what | file |
|---|---|
| the meter | `engine/src/pipeline/pipeline.cpp:554` `measure_exposure_ev`, `:624` `node_auto_exposure` |
| `solve` | `engine/src/pipeline/engine.cpp` (~`:1094`, target `exposure`) |
| wire table | `engine/src/core/params.cpp` `kFields`; field accessors further down the same file |
| Python reference | `src/spektrafilm/utils/autoexposure.py` |
| print compensation | `engine/src/core/printing.cpp` (~`:150–180`) |
| the re-decode bug | `modern_UI/Spektrafilm/Spektrafilm/Model/Session.swift` `scheduleReopen` (~`:1129`), `ensureDeveloped` (~`:911`) |
| RAW white balance | `modern_UI/Spektrafilm/Spektrafilm/Import/ImageDecoder.swift` `rawFilter` |
| the UI today | `Panels/Sections/CameraSection.swift`, `Controls/KelvinSlider.swift`, `Panels/Sections/RightSections.swift` (`WhiteBalanceSection`) |

**Commands**

```
engine/build.sh all                     # after engine changes; `metallib` after a .metal, `bundle` to sync into the app
PYTHONPATH=src:engine/tests .venv/bin/python engine/tests/parity_schema.py    # the wire table
PYTHONPATH=src:engine/tests .venv/bin/python engine/tests/parity_session.py   # every field, live
cd modern_UI/Spektrafilm && xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm -derivedDataPath build/DerivedData build
cd modern_UI/Spektrafilm && xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests -derivedDataPath build/DerivedData test
```

**Traps that apply here**

- **The UI is not yours to design.** Implement the engine and the plumbing,
  then stop at §4 and hand back. If a control is needed to test something,
  use a debug menu item or a test, not a finished-looking control.
- **Check which engine the app is running** (`AGENTS.md`; the app renders with
  the engine in its own checkout, and `engine/build.sh bundle` is an rsync
  that can leave a stale bundle).
- **Grain and glare are stochastic by design.** Any pixel-equality check must
  turn them off first, or it measures noise and reports a defect (RFC-013).
- **A check that cannot fail is not a check.** Every new test must be seen red
  on the old code before it counts as green.
- **`testSchema2SidecarsKeepTheirCrop` is flaky** (JSONEncoder key order is
  random per process). It predates this RFC; don't read a red run of it as
  yours.
- **Legacy method names must stay byte-identical.** Python-reference parity
  depends on it, and the parity harnesses won't notice because they run with
  `auto_exposure = false`.
