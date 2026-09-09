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

### 1.1 The nine methods, frozen for this cycle

`capabilities` · `params_schema` · `open` · `get_params` · `set_params` ·
`solve` · `preview_render` · `reprint` · `export` · `export_di` ·
`preview_stock_lut` · `progress` · `cancel`.

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
| 2026-09-09 | FE | BE | §3.2 `exposure_mask` on `reprint` — not blocking, ships after the Layer-2 approximation | open |
| 2026-09-09 | FE | BE | §3.3 ROI render | open |
| 2026-09-09 | FE | BE | §3.4 report `concurrent` in `capabilities` when true | open |

## 6. Wire changes actually made (append; this is the changelog FE reads)

| date | version | change | by |
|---|---|---|---|
| 2026-09-09 | transport 1, schema 1 | baseline at the time this contract was written | — |
| 2026-09-10 | transport 1, schema 1 | **Additive.** `capabilities.backend.render_core` (`"metal"` \| `"mlx"` \| `"cpu"`) says which executor renders; `capabilities.backend.gpu` now reads `"metal"` when the GPU-native core is in use. `capabilities.backend.concurrent` is present and **`false`** (§3.4: not yet verified safe — RFC-011 DR-9). No method, field, tier name or `rgba16` layout changed; the same bytes land at `raw_path`. | BE |
| 2026-09-10 | — | **Behaviour, not wire.** The service now selects `settings.gpu_backend='metal'` when a Metal device is reachable (RFC-011). `set_params.est_cost.seconds_by_tier` is re-measured for that executor: full render live/preview/full = 0.042 / 0.17 / 0.99 s, reprint = 0.012 / 0.046 / 0.24 s (45.75 MP frame, M3 Max, warm); the old `'mlx'` table is kept for a machine without Metal. FE's tier escalation thresholds may want revisiting against these; nothing breaks if they are not. | BE |
| 2026-09-10 | — | **Grain realisation.** With `grain_sampler='stochastic'` (the default) every render already drew fresh grain; with `'exact'` the realisation is reproducible on either executor but differs *between* executors (same distribution, RFC-011 DR-3). A pixel-pinned baseline of a grainy render is executor-specific. | BE |
