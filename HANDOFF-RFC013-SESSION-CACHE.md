# Handoff: the session cache and the boot window

| | |
|---|---|
| **For** | the next session — frontend (`modern_UI/**`). The backend half has landed. |
| **From** | BE, 2026-09-10 |
| **Status** | RFC-013 §2 and §3 backend implemented and tested; nothing in `modern_UI/**` has been touched for it |
| **Wire** | **Additive only.** `transport_version` stays 1; a frontend that ignores both additions behaves exactly as it does today |
| **Read first** | `rfc/RFC-013-session-cache-and-start-window.md`, then `modern_UI/Spektrafilm/README.md` §3 |

---

## 1. What landed

Backend only. Four files, one new module:

| file | what it now does |
|---|---|
| `src/spektrafilm/service/session_cache.py` **(new)** | `SessionCache`, an LRU over whole `RenderSession`s with an entry budget, a byte budget and stats. Pure policy; no rendering, no imports beyond the standard library |
| `src/spektrafilm/service/engine.py` | `open` consults the cache before touching the filesystem and inserts after a successful open; `warm_up` pays the first-frame setup; `close` releases everything; `capabilities.backend.session_cache` reports the numbers |
| `src/spektrafilm/service/service.py` | `_m_warm_up` and `close` — the wire skin for both |
| `src/spektrafilm/service/transport.py` | releases cached sessions when the transport stops |
| `tests/test_rfc013_session_cache.py` **(new)** | 20 tests; 15 need no GPU and no image |

Measured on this machine (no Metal in the sandbox — all renders ran on numba,
so the render share of `open` here is *larger* than yours):

| | 1 MP smoke | 45 MP NEF |
|---|---|---|
| first `open`, cold engine | 443 ms | 5.93 s |
| `warm_up` first | 128 ms | 129 ms |
| first `open`, engine warmed | 319 ms | 5.59 s |
| **re-open the same frame** | **0.29 ms** | **0.33 ms** |

---

## 2. The frontend work, in order

### 2.1 Show a boot window that covers real work

The rule that keeps this from becoming a slow app with a logo: **the boot
window must cover work the app has to do anyway**, and it must present the
editor only when there is a rendered picture to show.

```
launch
  ├─ boot window appears immediately (no service wait to draw it)
  ├─ client.call(.capabilities)        ← already happens: Session.warmUp()
  ├─ client.call(.warm_up, …)          ← NEW: ~130 ms, hides first-frame setup
  ├─ if there is a previous/selected frame: run the normal load path
  │    decode → preview texture → linear TIFF → open → solve → reprint (live)
  └─ when applyRender() lands for the first frame: dismiss the boot window
```

Do **not** invent a second load path for the boot window. `Session.load(_:)` →
`openInService(tiff:for:clock:)` already is that path, and duplicating it is how
the two drift.

### 2.2 Gate the first `open` on warm-up

`Session.warmUp()` (Model/Session.swift) is fire-and-forget in a `Task`. The
actor serialises calls in submission order, so today `capabilities` normally
lands before any `open` — but "normally" is not a guarantee: a frame restored
at launch can submit `open` first, and then the first `open` carries the whole
interpreter start on its back, which is exactly the bug that comment was
written about.

Make it explicit. Something like a `private var bootTask: Task<Void, Never>?`
set in `init` that awaits `capabilities` then `warm_up`, and have
`openInService` `await bootTask?.value` before its first `client.call(.open,…)`.
The gate costs nothing when warm-up has already finished.

### 2.3 Add the lap to `LoadClock`

`LoadClock` is the instrument that tells you where the open path went. Add a
`warm_up` lap so the RFC-013 numbers stay attributable, and keep the existing
`core=metal` suffix — it is the first thing to check (HANDOFF-GPU-WIRING §0).

### 2.4 Prefetch neighbours (optional, second step)

`prefetchNeighbours(of:)` already exists. With the session cache, calling
`open` for a neighbour makes that neighbour's *negative* free if the user then
selects it — the engine keeps two sessions by default. Cap the prefetch at one
neighbour beyond the current frame, or the cache will evict the frame the user
is actually on and every prefetch will have been wasted work.

---

## 3. The wire you are calling

### 3.1 `warm_up`

```jsonc
// request — every field optional
{"film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura"}

// response
{
  "film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura",
  "already_warm": false,
  "render_core": "metal",
  "total_ms": 128.4,
  "steps": [
    {"name": "schema",      "ok": true, "ms": 0.0,   "cached": true},
    {"name": "render_core", "ok": true, "ms": 20.8,  "core": "metal"},
    {"name": "profiles",    "ok": true, "ms": 3.2,   "filters_cached": false},
    {"name": "pipeline",    "ok": true, "ms": 105.7, "nodes": 21}
  ],
  "session_cache": {"entries": 0, "bytes": 0, "max_entries": 2, "max_bytes": 4294967296}
}
```

Call it with the stocks the frame will actually open with — the sidecar's film
and print stock — or the engine warms a pair the first `open` will not use.
`steps[].ok == false` is not fatal: the boot window should log it and carry on,
because the work is simply paid again inside `open`.

### 3.2 `capabilities.backend.session_cache`

```jsonc
{"entries": 2, "bytes": 203251328, "max_entries": 2, "max_bytes": 4294967296,
 "hits": 2, "misses": 3, "evictions": 1, "enabled": true}
```

Worth putting in the status-bar bug report along with `core=metal`: it is the
difference between "opening frames is slow" and "the cache is evicting on
every switch".

### 3.3 What did **not** change

No new fields on `open`, `reprint`, `preview_render`, `solve`, or any response
shape. `Capabilities.Backend` in `Service/Methods.swift` has optional fields,
so the new `session_cache` key decodes without a change — but if you want it on
screen, add it explicitly.

---

## 4. Traps

1. **A cache hit does not re-apply `params_delta`.** The delta is baked into
   the key, so a hit means the request is identical to the one that opened the
   session. Re-applying it would invalidate the very caches the hit exists to
   keep (`apply_delta` clears pipelines and negatives for shoot-layer fields).
   The consequence for the frontend: the engine's params and the sidecar's
   params must stay in sync, which they already do through `scheduler` and
   `fullDelta`.
2. **A hit returns the session's *current* params**, not the params as of the
   first open. `set_params` moves a live session. If your boot flow reads
   `OpenResponse.params`, do not assume it is `defaults + delta`.
3. **The key is `st_size` + `st_mtime_ns`, not a content hash.** A linear TIFF
   rewritten in place with both preserved would be a stale hit. The frontend's
   linear cache replaces files rather than editing them, so this is safe today
   — but if you ever start editing a TIFF in place, tell the backend.
4. **Two sessions resident, not two renders.** The cache does not enable
   concurrency; `configure_transport` is still refused unless the core is
   Metal. Do not read `entries: 2` as permission to issue a second render.
5. **`SPEKTRAFILM_SESSION_CACHE_ENTRIES=1` is the off switch**, and it is the
   first thing to try when a rendering change is suspected of being a caching
   bug. It restores the old single-session behaviour exactly.
6. **The boot window is not a substitute for the first render.** If the editor
   appears before `applyRender` for the first frame, the user still watches a
   blank canvas — which is the thing this RFC exists to remove.

---

## 5. Acceptance

Backend (already green here):

```bash
.venv/bin/python -m pytest -q -W ignore tests/test_rfc013_session_cache.py
python3 Tools/gen-project.py --check        # from modern_UI/Spektrafilm
```

Frontend, once you have it:

```bash
cd modern_UI/Spektrafilm
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmFrontend \
    -configuration Debug -derivedDataPath build/DerivedData test
```

and the real one, which is what actually proves the launch path:

```bash
SPEKTRAFILM_CANVAS_LOG=1 …/Spektrafilm --snapshot 1600x900 /tmp/o.png \
    --open "tests/Test_image/Nikon Z7ii/_DSC2439.NEF" --wait 180 2>&1 >/dev/null \
  | grep "open path"
```

The line to expect, with a `warm_up` lap added and `core=metal` at the end:

```
session: open path (ms): warm_up … · decode … · preview-texture … · linear-tiff …
         · service.open … · solve … · reprint … · TOTAL … · core=metal
```

Then double-click the same frame twice in the filmstrip: the second `open`
should be a cache hit, and the second `service.open` lap should read ~0 ms
rather than the ~900 ms AGENTS.md records.

---

## 6. Deliberately not done

- **No prefetching in the engine.** Deciding which frame is next is a UI
  question; the engine only promises that a prefetched `open` is reused.
- **No render-result cache.** The cache holds sessions, not pictures; a
  `reprint` is still a render (12–250 ms on Metal depending on tier).
- **No `_write_rgba16` removal.** That is RFC-012 option D and needs the
  contract amended first.
- **No `ARCHITECTURE.md` / `API-SPEC-*` / `CONTRACT-*` edits.** Those are
  shared with the other session; this handoff and the RFC are the record.
