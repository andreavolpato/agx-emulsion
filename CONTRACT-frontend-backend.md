# Contract: the frontend/backend boundary, while two sessions work at once

| | |
|---|---|
| **Why this exists** | Two agents are editing this repo simultaneously: one rewriting the render engine to be GPU-native, one fixing the SwiftUI frontend. They must not read each other's code to make progress, and they must not both edit one file. This document is the only thing they share. |
| **Parties** | **FE** — `modern_UI/Spektrafilm/**` (Swift). **BE** — `src/spektrafilm/**`, `tests/**`, `rfc/**` (Python → Metal). |
| **Status** | Binding for both sides from 2026-09-09 until superseded. A change to *this file* is the only change that requires both sides to agree. |
| **Date** | 2026-09-09 |

---

## 1. The boundary is the wire, and nothing else

FE talks to BE through exactly one channel: newline-delimited JSON-RPC over
the stdio of `python -m spektrafilm.service` (`Service/ServiceClient.swift` ↔
`src/spektrafilm/service/transport.py`). There is no shared library, no shared
memory, no import in either direction.

Everything crossing that channel is either

- **small** — parameters, metadata, timings — and travels as JSON; or
- **large** — pixels, masks, LUTs — and travels as a **file path into the
  workspace**, written by the producer and deleted by the consumer.

The second rule is what makes the GPU rewrite invisible to FE. BE may replace
numpy with a Metal buffer, a `MTLSharedEvent`, or a compiled kernel graph; as
long as the bytes it lands at `raw_path` are the same little-endian
`rgba16` (row 0 = top) that `TextureStore.uploadRGBA16` maps today, FE does
not change and does not need to be told.

### 1.1 The methods, frozen for this cycle

`capabilities` · `params_schema` · `open` · `get_params` · `set_params` ·
`solve` · `preview_render` · `reprint` · `export` · `export_di` ·
`preview_stock_lut` · `progress` · `cancel` · `configure_transport` ·
`warm_up`.

> The heading used to read "the nine methods" while listing thirteen. Nobody
> was counting; the frozen set is the list, not the number, so the number is
> gone. `warm_up` (RFC-013 §3) is the most recent addition and was added under
> the "additive is always allowed" rule below.

BE **may not** rename, remove, or change the meaning of any of these, or of
any field FE currently reads (`Service/Methods.swift` is the definitive list
of what FE reads — BE should treat that file as read-only documentation and
never edit it).

BE **may** add methods and add optional fields. Additive is always allowed and
never needs agreement.

### 1.2 The three invariants that are actually load-bearing

These have each cost a day in this repo already, so they are stated as
requirements on BE rather than as description:

1. **`rgba16` layout.** `width × height × 4 × uint16`, row-major, row 0 is the
   top of the image, values already Display-P3 *encoded*. FE applies no
   transfer curve and never will (`frontend_architecture.md` §4, "Colour,
   stated once"). A GPU-native BE that lands linear values, or BGRA, or
   bottom-up, produces a washed-out or upside-down canvas and no test on
   either side will say so.
2. **Single-flight transport.** One request in flight at a time. FE's
   `RenderScheduler` and its detail-tier escalation both assume it: they
   deliberately refuse to start a 6–17 s full-resolution render while an edit
   is owed one. If the GPU rewrite makes concurrency safe (HANDOFF-METAL-BACKEND
   §7 Q5), that is a **capability flag**, not a silent change — see §3.
3. **Tier names.** `live` (1600 px long edge) · `preview` (3400) · `full`
   (native). FE's cache keys, its zoom thresholds and its texture budget are
   all expressed in those three words. New tiers may be added; these three may
   not move.

---

## 2. Version negotiation, and how a breaking change is actually made

`capabilities` already reports `transport_version` and `schema_version` (both
1). Use them:

- **`transport_version`** bumps when the framing or the file-handoff
  convention changes. FE refuses to start against a transport version it does
  not know, with a visible error rather than a blank canvas.
- **`schema_version`** bumps when a `params_delta` field is renamed, removed,
  or changes units. Additive fields do **not** bump it.

**The procedure for a breaking change is: don't, this cycle.** If BE
genuinely cannot do the GPU rewrite without one, the change lands as

1. a new optional field or method that does the new thing,
2. the old one kept working and marked deprecated in `service.py`'s docstring,
3. a line in §6 of this file saying what and why,
4. and only then, in a later cycle, the removal.

BE never gets to break FE and leave a note. FE never gets to demand a wire
change without writing it into §5 first.

---

## 3. New surfaces FE needs from BE (in priority order)

These are FE's asks. None of them blocks BE's GPU work, and none of them is
urgent enough to justify reordering it. They are recorded here so BE can shape
kernels with them in mind rather than retrofitting later.

| # | surface | why FE wants it | shape |
|---|---|---|---|
| 1 | **`geometry` in `params_delta`** | Crop and rotate are currently a *display* transform only. Export therefore ships the uncropped, unrotated frame — the crop is a lie past the canvas. | `{crop: [x,y,w,h] normalised, rotation_deg: float, flip_h: bool, flip_v: bool}`. Applied at the **start** of the pipeline (before `crop_rescale`), so a 40 % crop costs 40 % of the render. |
| 2 | **`exposure_mask` on `reprint`** | The physically correct application point for a dodge/burn mask is the enlarger, before the paper curve. FE ships the after-print approximation first and does not need this to launch. | `{path, width, height}` — single-channel float32, stops, 0 = neutral. Same file-handoff convention as `rgba16`. |
| 3 | **ROI render** | At 400 % zoom on a 45 MP frame FE renders the whole image to show 2 % of it. | `roi: [x,y,w,h]` normalised on `reprint`, with a halo the service picks (the spatial operators need one; FE must not have to know how big). |
| 4 | **`concurrent: true` in `capabilities`** | If the GPU path lifts single-flight, FE can start a full-resolution render *behind* a live slider drag instead of after it. This is the single biggest perceived-speed win available to FE. | a bool in `capabilities.backend`. FE keeps the serial path when absent. |

Ask 4 is free for BE to report and expensive for BE to get wrong: report it
only when concurrent entry is actually safe, not when it merely didn't crash.

---

## 4. File ownership — the mechanical rule

No file is edited by both sessions. If you need a change in the other side's
column, write it in §5 and say so in your handoff; do not reach across.

| owner | paths |
|---|---|
| **FE** | `modern_UI/**` (all of it, including `Spektrafilm.xcodeproj`, `Tools/*`, snapshots) |
| **BE** | `src/spektrafilm/**`, `src/spektrafilm_lut_creator/**`, `tests/**`, `scripts/**`, `rfc/**`, `pyproject.toml`, `uv.lock` |
| **shared, append-only** | this file (§5 and §6 only), `README.md` |
| **neither, without saying so** | `AGENTS.md`, `ARCHITECTURE.md`, `API-SPEC-callable-render-service.md` — these describe the system as a whole and a unilateral edit to them makes the other side's context wrong |

`src/spektrafilm_gui/**` is the dead PyQt frontend. Neither side touches it;
BE may delete it if it obstructs the rewrite, and should say so.

### 4.1 Git: separate worktrees, one base

```
/Users/…/spektrafilm            branch  ui/frontend-fixes     ← FE (this checkout)
/Users/…/spektrafilm-gpu        branch  gpu/native-metal      ← BE (git worktree)
```

Both branch from the commit that adds this file, so both contain it and
neither has to rebase to see it. Rules:

- **Commit early and often, on your own branch only.** Never commit on
  `main`, never on the other side's branch, never `git checkout` a branch that
  has a worktree (git will refuse; that refusal is the safety net).
- **Never rebase or force-push a branch the other side may have read.** If
  history must be rewritten, do it before the other side is told the branch
  exists.
- **Never `git stash`, `git clean -fdx`, or `git checkout -- .` at the repo
  root.** Both worktrees share one object store and one stash; a stash pushed
  from one is visible and stealable from the other.
- The integration merge is `ui/frontend-fixes` → `main`, then
  `gpu/native-metal` → `main`, in that order, because FE's changes are small
  and BE's are large. Whoever merges second resolves.

`git worktree list` at any time says who is where. If it shows a worktree you
did not create, another session is live in it — do not build in it (a
concurrent `xcodebuild` or `pytest` in the same DerivedData is its own
category of confusing failure).

---

## 5. Requests across the boundary (append here; do not edit others' entries)

| date | from | to | request | status |
|---|---|---|---|---|
| 2026-09-09 | FE | BE | §3.1 `geometry` in `params_delta` — crop/rotate must survive export | open |
| 2026-09-09 | FE | BE | §3.2 `exposure_mask` on `reprint` — not blocking, ships after the Layer-2 approximation | **withdrawn 2026-09-10** — the user overrode HANDOFF-MASKS §1 and asked for Lightroom's masking (per-mask adjustment sets) rather than the darkroom dodge-and-burn model. That makes masks Layer 2 by construction, so this engine surface has no customer. |
| 2026-09-09 | FE | BE | §3.3 ROI render | open, **low** — at 0.237 s for a full-tier reprint the latency it protects against has mostly evaporated |
| 2026-09-10 | FE | BE | §3.1 raised to **first priority**: proportional to the render, and the render is now 1 s rather than 14. `Model/Geometry.swift`'s `sourcePoint(forOutput:imageSize:)` is the definition — top-left origin, rotation rigid in *pixels* | accepted by BE |
| 2026-09-09 | FE | BE | §3.4 report `concurrent` in `capabilities` when true | open |
| 2026-09-10 | FE | BE | A **Positive** group in the print picker whose entry is "No print Profile": render the film stage and stop, so a slide shows as a positive and a negative shows as the negative. Proposed as `print_stock: "none"` plus a capability flag. | **already exists — no engine change needed.** The wire field is **`scan_film`** (bool, print layer, `service/schema.py`), and it does exactly this: `pipeline.py` drops the three `printing.*` nodes and runs the scan chain from `Tap.CMY_FILM`, while `scanning.scan_spectral` switches its spectral integral to the *film's* dye densities and base under the film's own viewing illuminant. Verified over the service on the 1 MP smoke frame: `reprint {"scan_film": true}` returns `reprint=true` with the negative reused (63 ms), tonally inverted against the print (corr −0.48) and orange-masked (mean RGB 0.65 / 0.34 / 0.26) — the "original false negative result". Supported on the Metal core (`nodes.py`), covered by `test_rfc003_split.py::test_scan_film_topology_is_decoupled`. **Do not gate the row on a capability flag**; `scan_film` has been in `params_schema` since before this contract. BE recommends against `print_stock: "none"`: `print_stock` names a paper, and a sentinel there would make "which paper" and "is there a paper" the same field — the second is a pipeline-topology choice and is already its own boolean. |
| 2026-09-10 | BE | FE | **Not a request — a hazard note about a line in FE's column.** `Service/ServiceClient.swift:71` sets `env["PYTHONPATH"] = repo/src`. Because `spektrafilm` is installed *editable*, that line looks redundant (the venv already pins a source) but is not: `PYTHONPATH` overrides the editable `.pth`, and it is what guarantees the app runs the engine sitting next to the binary it launched rather than whichever checkout the venv happens to point at. Dropping it as a simplification would reintroduce `HANDOFF-GPU-WIRING` §0 — an app rendering on an engine nobody chose. BE hit the same trap in a throwaway worktree and got a wrong measurement from it (RFC-012 §5 step 3). No action wanted; just please keep the line. | noted by BE |
| 2026-09-10 | BE | FE | **To use `concurrent`:** match replies to requests by JSON-RPC `id` (the client currently reads the next line as the reply to the last request), then call the additive method `configure_transport {"concurrent": true, "max_workers": 3}` once per process. Until that call the service stays strictly in-order, so nothing changes for the shipping client. See §6 (2026-09-10, concurrency) for the semantics. | open |
| 2026-09-11 | FE | BE | **RFC-015 §3, additive.** (1) New `params_delta` field **`auto_exposure_method`**: `str`, path `camera.auto_exposure_method`, shoot layer, not live, default `center_weighted`, declared **immediately after `auto_exposure`** in both the engine's `kFields` and the Python `service/schema.py` (`parity_schema.py` checks order). Accepted values: `balanced`, `center`, `protect_highlights`, `protect_shadows`, and the legacy `center_weighted`, `average`, `median`, which stay byte-identical to today. Anything else is a user error at `set_params`/`open`. (2) `solve(target:"exposure"\|"both")` adds `exposure_ev_by_method: {balanced, center, protect_highlights, protect_shadows}`, all four from the one sample, **at the top level of the response, a sibling of `solved_params` — never inside it**. `solved_params` is decoded as `[String: Double]` (`Methods.swift` `SolveResponse`), so a nested object there throws, which would silently break the `try?` exposure solve on develop and break Solve on every press. It is absent for `filter_pack`. `exposure_compensation_ev` stays in `solved_params` as the EV of the session's *current* method. **The four new modes are implemented twice from this definition — C++ in the engine, Python in the fork's `utils/autoexposure.py` — and a parity harness compares them.** On the sample's luminance `Y` (same sample and Y row as today): floor `Y ← max(Y, 0.184·2^-12)`; `P(q)` = the element at 0-based index `k` of the floored `Y` sorted ascending (rank, no interpolation; not `np.percentile`'s default), where **`k = (q10 · (n−1)) / 1000` in exact integer division** with `q10 = 10q ∈ {10, 50, 990, 995}`. Integer arithmetic is belt-and-braces: checked for every n ≤ 5·10^7, a floating-point `q/100·(n−1)` never lands on a different rank for these four q. It is still the rule, so that neither side has to re-prove that. **`Y` stays in double on both sides.** Trim membership is discontinuous, and float32 luminance moved `balanced` by 1.4e-4 EV on a real RAW, so the sample must not move onto the GPU in float; trim set `T = {P(1) ≤ Y ≤ P(99)}`, inclusive; `EV_b = −log2(exp(mean_T ln Y)/0.184)`; `EV_c` the same with today's centre-weighted Gaussian weights (σ 0.2 of the long edge, same grid) as a weighted mean of `ln Y` over `T`; `EV_h = clamp(log2(0.184·2^2.5 / P(99.5)), EV_b − 3, EV_b)`; `EV_s = clamp(log2(0.184·2^−3.5 / P(5)), EV_b, EV_b + 2)`; percentiles for `EV_h`/`EV_s` are over all floored samples (untrimmed, unweighted). Sums in double; parity tolerance 1e-9 EV. The AE node applies the chosen mode's EV exactly as today (one scalar gain, float32-narrowed, not print-compensated). | open |

## 6. Wire changes actually made (append; this is the changelog FE reads)

| date | version | change | by |
|---|---|---|---|
| 2026-09-09 | transport 1, schema 1 | baseline at the time this contract was written | — |
| 2026-09-10 | transport 1, schema 1 | **Additive.** `capabilities.backend.render_core` (`"metal"` \| `"mlx"` \| `"cpu"`) says which executor renders; `capabilities.backend.gpu` now reads `"metal"` when the GPU-native core is in use. `capabilities.backend.concurrent` is present and **`false`** (§3.4: not yet verified safe — RFC-011 DR-9). No method, field, tier name or `rgba16` layout changed; the same bytes land at `raw_path`. | BE |
| 2026-09-10 | — | **Behaviour, not wire.** The service now selects `settings.gpu_backend='metal'` when a Metal device is reachable (RFC-011). `set_params.est_cost.seconds_by_tier` is re-measured for that executor: full render live/preview/full = 0.042 / 0.17 / 0.99 s, reprint = 0.012 / 0.046 / 0.24 s (45.75 MP frame, M3 Max, warm); the old `'mlx'` table is kept for a machine without Metal. FE's tier escalation thresholds may want revisiting against these; nothing breaks if they are not. | BE |
| 2026-09-10 | — | **Grain realisation.** With `grain_sampler='stochastic'` (the default) every render already drew fresh grain; with `'exact'` the realisation is reproducible on either executor but differs *between* executors (same distribution, RFC-011 DR-3). A pixel-pinned baseline of a grainy render is executor-specific. | BE |
| 2026-09-10 | transport 1, schema 1 | **Additive: §3.1 `geometry` landed** as eight scalar `params_delta` fields (the wire carries scalars, so the object in §3.1 is flattened): `geometry_crop_x/y/w/h` (normalised, top-left origin), `geometry_rotation_deg` (−45…45, positive clockwise, rigid in pixels), `geometry_quarter_turns` (int 0…3), `geometry_flip_h/v`. Shoot layer (a new negative). Applied as `preprocess.geometry` right after `decode_input`, before auto-exposure and `crop_rescale`, so the meter sees the composed frame and every later node costs the crop's share. Mapping and sampling are a transliteration of `Model/Geometry.swift` / `geometryResample` (output pixel centres at (i+0.5)/N, bilinear, clamp to edge; output size = round(crop·source), swapped for odd quarter turns); `tests/fixtures/geometry_pairs.json` pins 15 (output uv → source uv) pairs on the 8256×5504 frame for FE to check against. The film pixel pitch is taken from the *uncropped* frame, so grain and halation do not coarsen under a crop. Identity at the defaults → node pruned, render bit-identical. | BE |
| 2026-09-10 | transport 1, schema 1 | **Additive: concurrency (RFC-011 §10).** `capabilities.backend.concurrent` is now **`true`** when the Metal core is the executor: N pipelines rendering on N threads were verified bit-identical to sequential, through grain/glare and through pipeline construction under load. New `capabilities.transport` block: `{concurrent_requests, max_workers, responses_in_order}`. New method **`configure_transport`** (`{concurrent?: bool, max_workers?: 1..8}` → the transport block); default off = today's in-order behaviour. When on: each request runs on a worker thread, replies come back in **completion order** (match by `id`), renders on *different tiers* of the session run at once, renders on the *same tier* queue, `progress`/`cancel`/`capabilities`/`params_schema` are answered immediately on the reader thread (so **cancel now works mid-render**), and a `set_params` that lands while a tier is rendering is applied to that tier when its render finishes (the in-flight reply reflects the params as of its start; the session's `params` in the reply are current). `open` waits for the previous session's renders before releasing it. A background (preview/full) render **yields to a live-tier render** at kernel granularity: measured on the 45 MP frame, a live reprint takes 44 ms while a full export runs (27 ms alone; 285 ms with node-level yield only; 423 ms with none). Throughput of two concurrent 45 MP renders is only 1.14× sequential — one GPU — so batch export should stay sequential on the service and overlap the *client's* decode with the service's render. | BE |
| 2026-09-10 | transport 1 | FE now matches replies by JSON-RPC id instead of taking the next line as its reply. No behaviour change while the transport answers in order; it is the client-side prerequisite for `configure_transport`. FE stays serial until concurrency is tested here. | FE |
| 2026-09-10 | — | **Neither wire nor behaviour.** RFC-012 §5 step 3: the colour-science constants are baked (`data/baked/colour_constants.npz`, 21.9 KiB) and a reprint no longer loads colour-science or pandas. No method, field, tier name, version or `rgba16` layout changed, and rendered output is unchanged — every baked value is re-derived from colour-science and asserted equal in `tests/test_rfc012_baked_colour.py`. Recorded here only because it removes a runtime dependency the native host would otherwise have to reproduce. See `HANDOFF-NATIVE-HOST.md` for what FE does when the host lands: **nothing**, plus one additive `capabilities.backend.host` field. | BE |
| 2026-09-10 | — | **Neither wire nor behaviour — structure only, recorded because FE should know where the engine now lives.** RFC-012 §5 step 4: the service is split into `service/engine.py` (`RenderEngine` — typed args, in-memory results, no workspace, no JSON, writes no file) and `service/service.py` (the nine wire methods, request validation, and the file handoff). No method, field, tier name, version or `rgba16` layout changed; the same bytes land at `raw_path` and FE needs no change. The split is the seam RFC-012's option D detaches at, so that removing the process later deletes the transport and nothing else. | BE |
| 2026-09-10 | — | **Behaviour, not wire.** The tier downscale runs on the Metal core (RFC-011 §11): skimage's parameters exactly, 1.2e-7 max abs against it, 55 ms instead of 1.6–2.4 s per tier on the 45 MP frame. `open` 2.6 s → 278 ms warm on an uncompressed 4-channel half TIFF like the client's; a compressed TIFF (LZW/ZIP) costs 1.1–1.6 s to read on this frame, uncompressed 0.1 s — keep writing it uncompressed (HANDOFF-GPU-WIRING §2.2). Tier images are RGB (alpha dropped at the downscale; nothing read it). The frontend session's lazy tier build (699a7c8) is kept as merged. | BE |
| 2026-09-10 | — | **Additive, no version bump (allowed by §1.1).** RFC-013: a tenth-and-more method `warm_up` — build the profile pair and its pipeline before the first `open`, so the boot window covers work the app has to do anyway. Every request field optional; a client that never calls it behaves exactly as before. `capabilities.backend` also gains `session_cache` (the engine's LRU over whole sessions) and `host` (`"python"` \| `"native"`, which binary answered). FE calls `warm_up` at launch and gates the first `open` on it. **Not written by either the FE or BE session** — landed in the working tree from a third author; verified by FE before use: a cache hit is byte-identical to a cold open with grain and glare off, and re-open costs 0.59 ms against a full open. | — |
| 2026-09-12 | transport 1, schema 1 | **Additive (RFC-015 §3; the 2026-09-11 §5 row).** `params_delta` gains **`auto_exposure_method`** (str, shoot layer, not live, default `center_weighted`), declared right after `auto_exposure`. Seven names are accepted: the intents `balanced`, `center`, `protect_highlights`, `protect_shadows`, and the legacy `center_weighted`, `average`, `median`. Any other name is rejected at `set_params`/`open` with a user error naming the param. `solve(target:"exposure"\|"both")` gains a **top-level** `exposure_ev_by_method {balanced, center, protect_highlights, protect_shadows}`, a sibling of `solved_params` (absent for `filter_pack`). `solved_params` is unchanged: `exposure_compensation_ev` is still one flat number, the EV of the session's current method. **A client that sends no method gets byte-identical output:** the legacy EVs and render hashes are equal before and after on the smoke frame and a 24 MP RAW, 6/6. `parity_exposure.py` checks the intents against an independently written Python reference: worst 2.9e-12 EV, and six perturbations of the reference all go red. `parity_schema` shows the tables identical; `parity_session` walks the new field live (re-rendered, shoot layer). Known: the intents are more sensitive than the legacy meters to *which* sample is metered. `solve` (whole live tier) and the node (256 px stride) differ by up to 2.3e-2 EV on a 1600 px frame and up to 0.13 EV (`protect_shadows`) on a 24 MP frame, against ~3e-3 for the legacy meters. | FE orchestrator (engine by the executor session, reference by the fork session) |
| 2026-09-12 | transport 1, schema 1 | **Additive field + behaviour (RFC-015 P.1).** `progress` gains **`auto_exposure_ev`**: the EV the auto-exposure node applied to that render's negative, `null` with the meter off. Behaviour: the session now meters **once per frame** (the frame downscaled to 1600 px, its own constant `kMeterLongEdge`, after `decode_input` and geometry, the whole image) and **every tier applies that one EV**, for all seven methods; `solve`'s `exposure_compensation_ev` and `exposure_ev_by_method` report that same cached meter. Before, each tier metered its own image, so an export's print luminance differed from the canvas by up to +0.069 EV on real RAWs. The cache is keyed on the fields upstream of the node (`input_color_space`, `input_cctf_decoding`, `geometry_*`), so a film, Exp. Comp. or method change does not re-meter (21 ms on a 45 MP frame when it does). One-time shift of existing edits: canvas median ≈3e-3 EV (max 0.014), exports up to 0.083 EV, both toward one number. FE needs no change. | BE |
