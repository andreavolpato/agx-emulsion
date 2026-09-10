# RFC-013 — Session cache, and paying the boot window first

| | |
|---|---|
| **Status** | Backend half implemented 2026-09-10; **frontend half unwritten** |
| **Date** | 2026-09-10 |
| **Depends on** | RFC-012 §5 step 4 (`service/engine.py` is the engine seam), RFC-011 (three tiers, per-tier caches, `core=metal`) |
| **Scope** | `service/engine.py`, `service/session_cache.py` (new), `service/service.py`, `service/transport.py`, `tests/test_rfc013_session_cache.py`; the frontend half is `modern_UI/**` and is left to an FE session |
| **Handoff** | `HANDOFF-RFC013-SESSION-CACHE.md` |

---

## 0. The result, in the numbers that were asked for

Two different questions with two different answers. Opening a frame the process
has already opened is now a dictionary lookup. Opening one it has not is still
real work — but a fixed, nameable part of that work can be paid before the user
is looking.

| | 1 MP smoke | 45 MP NEF |
|---|---|---|
| first `open`, cold engine | 443 ms | 5.93 s |
| — `warm_up` first | 128 ms | 129 ms |
| first `open`, engine warmed | 319 ms | 5.59 s |
| **re-open the same frame** | **0.29 ms** | **0.33 ms** |

The bottom row is the whole of §2. The third row is the whole of §3: a ~129 ms
investment removes 124 ms from the smoke frame's first open — exactly the
pipeline construction it pre-pays — and 169–502 ms from the 45 MP frame's,
where it also warms the render-side constant caches.

**Read the absolute numbers with the machine in mind.** This sandbox has no
Metal device, so every render in these runs went through the numba reference:
the render share of `open` here is *larger* than in a shipped Metal build, which
is why the 45 MP `open` reads 5.9 s against the ~1.4 s `open path` total
AGENTS.md records. The 1 MP row is the median of three interleaved runs, the
45 MP row two. Load average during measurement was 2.9–4.3 (AGENTS.md trap 17:
this machine is not a benchmark). What the ratios say survives that; what the
absolute milliseconds say does not.

---

## 1. What a re-open used to pay

`RenderEngine.open` was a demolition job at both ends: it built a
`RenderSession`, rendered the live-tier negative, **and released the previous
session**. So walking the filmstrip from frame B back to frame A paid the
entire open path again — profile load, pipeline construction, tier image,
film-side render — for a frame the process had rendered seconds earlier and
still had in memory.

That is a pure loss, and it is the one the user feels: alternating between two
frames is the most common thing anyone does in a filmstrip.

Measured on the smoke frame, where the pipeline-construction share is
unambiguous:

| step | cost |
|---|---|
| `_load_image` + input detection | 33 ms |
| `init_params` + neutral-filter DB + digest | 3 ms |
| **`SimulationPipeline(...)`** | **213 ms cold, 18 ms warm** |
| live-tier negative render | 268 ms (numba; ~40 ms on Metal) |

The pipeline row is the interesting one. Constructing a pipeline for a stock
pair is where the filming tc_lut, the enlarger and scanner LUTs and the fused
kernel constants get built. It is a **one-time cost per process**, and the
engine paid it inside whichever request happened to be first — and again for
every frame that came back after an eviction.

---

## 2. The session cache

`service/session_cache.py` holds an LRU of whole `RenderSession`s, keyed by the
`open` request, bounded by entry count and estimated bytes. `RenderEngine.open`
consults it before touching the filesystem and inserts after a successful open.

**Whole sessions, not negatives.** A session already owns exactly the state
that makes a re-open cheap: the full-resolution image, the per-tier downscales,
the per-tier cached negatives, and the constructed pipelines. A negative-only
cache would still rebuild the pipelines and re-do the tier downscales, i.e.
most of what §1 measures.

### 2.1 The key is the request, not the resolved params

```
(resolved path, st_size, st_mtime_ns, frozen delta, auto_solve, named session_id, render core, ENGINE_VERSION, SCHEMA_VERSION)
```

Keying on the *request* rather than the resolved params is a cost decision with
a correctness argument behind it. The final params depend on
`_detect_nonraw_input`, which reads the file — and computing the key must not
read the file, because that is the work the cache exists to skip. Detection is
a pure function of the file's bytes, so keying on the file's identity plus the
request is equivalent to keying on the final params, without the read.

Three things the key deliberately includes:

- **`ENGINE_VERSION` and `SCHEMA_VERSION`.** A change to how a session is built
  or spoken about must not hand back a session from the previous semantics.
- **The render core.** A session's cached negatives were produced by a specific
  executor. A process that lost its Metal device would otherwise serve primes
  from an engine that no longer exists.
- **A named `session_id`.** A caller that names a session is asking for a
  distinct identity; it never gets handed back a session under someone else's
  name.

The delta is canonicalised with a type-preserving freezer. `True == 1` in
Python, so without the tag a bool field set to `True` and an int field set to
`1` hash to the same key and hand back the wrong session.

### 2.2 Policy

- **The active session is never evicted.** `max_entries` counts the active
  session, so the floor is 1 and the engine cannot pull the frames out from
  under a caller. A single session that alone exceeds the byte budget is kept
  anyway; the budget yields to the invariant.
- **Default 2 entries, 4 GiB.** Two fully warmed 45 MP sessions measured ~4 GB
  each on the Metal core (RFC-011 §5). 4 GiB keeps the second entry only when
  it is a smaller frame or a partially warmed one, which is the honest ceiling
  for a machine that may have 16 GB of unified memory.
- **`SPEKTRAFILM_SESSION_CACHE_ENTRIES=1` restores the old behaviour** — one
  frame held, the previous released on a switch — without losing the ability to
  re-hit the frame you are on. `SPEKTRAFILM_SESSION_CACHE_BYTES` sets the
  budget.
- **Release happens outside the lock.** `RenderSession.release` waits for
  in-flight renders; a caller must not be blocked behind that while the cache
  lock is held, so `put` returns evicted entries and the engine releases them.

### 2.3 Two bugs the first run of this code produced

Both are the kind that pass a review and fail silently, so they are recorded
rather than quietly fixed:

1. **The cache key was shadowed.** `open` already used `key` as the loop
   variable in `for key, value in detected.items()`, and the new key was
   assigned above it. The cache stored the literal string `'raw_engine'` as the
   key for every frame — a permanent cache miss that looks exactly like a cold
   cache, i.e. like nothing being wrong beyond the speed. The variable is now
   `cache_key`, and `test_reopening_the_same_frame_reuses_the_session` fails if
   it collides again.
2. **A replaced key leaked its session.** Re-inserting an existing key (only
   reachable through a caller-supplied `session_id`) dropped the previous entry
   without releasing it, so the frames stayed resident with nothing pointing at
   them. `SessionCache.put` now returns the replaced session through the same
   path as an eviction.

---

## 3. Start-window separation

The frontend wants to show a boot window, do the unavoidable first-frame work
behind it, and present an editor that is already holding a rendered picture.
That is a frontend design (see the handoff); the backend owes it two things.

### 3.1 What the boot window can pay

| cost | when it is paid today | `warm_up` covers it |
|---|---|---|
| interpreter + imports (~13 s in this sandbox) | `capabilities`, already the FE's `Session.warmUp` | already covered |
| transport schema | first `capabilities`/`open` | yes |
| render-core probe | first `capabilities` | yes |
| film/print profile tables | first `open` | yes |
| neutral-filter database | first `open` | yes |
| pipeline construction (LUTs, fused constants) | first `open`, again per stock pair | **yes** |
| image decode, detection, tier downscale | only `open` can do it | no |
| live-tier film-side render | only `open` can do it | no |

### 3.2 `warm_up`

```jsonc
// request — both fields optional, defaulting to the schema's stock defaults
{"film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura"}

// response
{
  "film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura",
  "already_warm": false,          // this process has warmed this pair before
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

Rules it keeps:

- **It opens no image.** Decode needs a path the engine does not have yet. The
  frontend calls `open` immediately afterwards, and §2 is what makes a later
  return to that frame free.
- **It writes no file and starts no render.**
- **It never fails the app.** A step that raises is reported as
  `{"ok": false, "error": "..."}` and the work is simply paid again later.
- **It is safe with a session open.** Pipeline construction is serialised by
  `RenderSession`'s `BUILD_LOCK`; warm-up takes the same lock.
- **It is idempotent.** A second call for the same pair reports
  `already_warm: true` and near-zero step timings.

### 3.3 What the boot window must not do

Hide the wrong thing. A splash screen that simply delays the editor by the
import time turns a fast app into a slow one with a logo. The boot sequence
should call `capabilities` → `warm_up` → `open(first frame)` and present the
editor when `open` returns, so the window is covering work the app has to do
anyway. If `open` fails, the boot window is where the user should find out.

---

## 4. Risks

### 4.1 The key is a claim about the file, and it is the weak link

`st_size` + `st_mtime_ns` distinguishes a rewritten file in every case except an
in-place edit that preserves both, which is not something an image developer
does. A content hash would close that hole and cost a full pass over a 364 MB
TIFF on **every** open — the exact cost this cache exists to remove. The trade
is taken deliberately:

- the frontend's linear cache writes to a path derived from
  `(frame key, white balance)` and replaces it rather than editing in place;
- `SPEKTRAFILM_SESSION_CACHE_ENTRIES=1` disables reuse across frames entirely;
- a stale hit is not silent in the way RFC-010's colour bugs were: the response
  carries the params the caller asked for and the session the caller named, and
  only the *decode* of the file could be stale.

This is written down because the alternative — quietly trusting mtime — is what
a reader would otherwise assume had been verified.

### 4.2 Memory

Caching whole sessions multiplies the largest thing the process holds. The
budget exists for that reason, the estimate announces its own coarseness
(`PIPELINE_BYTES_ESTIMATE` covers constants not reachable as a single array),
and `capabilities.backend.session_cache` reports the running total so a bug
report can include it.

### 4.3 Concurrency

The cache adds no concurrency. The transport is still single-flight by default,
and `configure_transport {"concurrent": true}` is still refused unless the
render core is Metal (RFC-011 §10). What changed is that the previous session is
no longer force-released on every switch, so two sessions can be *resident* at
once — resident, not rendering. The tier locks are per session and unchanged.

### 4.4 A cached session's params can have moved

`set_params` mutates a live session. The cache therefore stores `meta` and
`detected_input` but **not** `params`: a hit returns `session.read_params()`,
describing the session as it is now rather than as it was opened.

---

## 5. Wire changes

Both are additive, so contract §2's version negotiation is untouched and a
frontend that ignores them behaves exactly as it does today.

- `capabilities.backend.session_cache` — new object.
- `warm_up` — new method. `transport_version` stays 1. If the frontend never
  calls it, the engine is simply slower on the first frame, as before.

No response shape changed, no field was renamed, and `open`'s response for a
given frame is unchanged.

---

## 6. What this does not do

- **It does not make decode faster.** Core Image decode and the linear TIFF
  write are the frontend's, and they are unaffected.
- **It does not prefetch.** Decoding the *next* frame in the background is the
  frontend's other half and is not implemented here; the backend's contribution
  to it is that the session cache already holds a prefetched frame's expensive
  state if `open` was called for it.
- **It does not remove the file handoff.** `_write_rgba16` and the 364 MB round
  trip are RFC-012 option D.
- **It does not make a film-stock change free.** A shoot-layer change
  invalidates the negatives inside the session by design
  (`RenderSession.apply_delta`), and the cache does not keep a second generation
  of them.
- **It does not fix the C_max `open` path.** `utils/gamut_compression.py` still
  reaches colour-science at three sites on `open` (RFC-012 §5 step 3's remaining
  item).

---

## 7. Verification

`tests/test_rfc013_session_cache.py` — 20 tests, 15 of which need no GPU and
no image:

| what | test |
|---|---|
| a re-open is a hit, same session object, negative still there | `test_reopening_the_same_frame_reuses_the_session` |
| returning to a previous frame is a hit | `test_returning_to_a_previous_frame_is_a_hit` |
| a changed delta is a different entry | `test_a_changed_delta_opens_a_new_session` |
| eviction releases the session it drops | `test_a_third_frame_evicts_and_releases_the_oldest` |
| the active session is never evicted | `test_lru_evicts_the_oldest_and_never_the_active_session`, `test_an_active_session_over_budget_is_kept` |
| the key follows bytes, not the path | `test_the_key_follows_the_bytes_not_the_path` |
| a bool cannot collide with an int | `test_a_bool_and_an_int_do_not_collide` |
| `entries=1` restores the old behaviour | `test_one_entry_restores_the_single_session_behaviour` |
| warm-up reports every step and opens nothing | `test_warm_up_reports_every_step_without_an_image`, `test_warm_up_opens_no_session` |
| `capabilities` carries the block | `test_capabilities_reports_the_cache_block` |
| `warm_up` and the block travel the wire | `test_warm_up_and_the_cache_block_travel_the_wire` |

The three integration tests that render are skipped where the smoke frame is
absent; they run on whatever executor the machine has.
