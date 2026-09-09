# Handoff: the app is on the GPU core — what is left in the open path

| | |
|---|---|
| **State** | The frontend now renders through the GPU-native core. Opening a 45.75 MP frame went from **~8 s to 3.85 s**, and the render inside it is **37 ms**. Everything still costing time is *around* the render, not in it. |
| **Read first** | This file, then `CONTRACT-frontend-backend.md` §1 and §4 (the boundary and who owns what), then `rfc/RFC-011-gpu-native-render-core.md` for the engine. `AGENTS.md` trap 10 is the one this whole document is an instance of. |
| **Branch** | `ui/frontend-fixes`, which now contains `gpu/native-metal` (merged at `3bc4380`). |
| **Date** | 2026-09-10 |

---

## 0. What was actually wrong, because it is the interesting part

The user reported that opening one picture took ~8 s and said it looked
"consistent with the CPU wire". That was exactly right, and it was right for
two reasons that stacked:

**1. The app was running the CPU core.** The GPU-native engine lived on
`gpu/native-metal`, in a separate worktree. The app spawns
`python -m spektrafilm.service` from the repo root it finds by walking up from
its bundle — which is the *main* checkout, which had no
`src/spektrafilm/backends/metal` at all. Every render went through numba. The
fix was a merge.

**2. Nothing could have told you that.** `Capabilities` in `Service/Methods.swift`
decoded `version`, `engine`, `max_mp`, `tiers` and the two version numbers —
and not `backend`. So the client had no way to ask which executor it got, and
the only symptom of running the wrong one was that things felt slow. The app
now reads `backend.render_core` at `open`, shows it, and puts a warning on the
canvas when it is `cpu` or `mlx`.

> **The lesson worth keeping:** an app that depends on a separate engine
> process must be able to say *which* engine it is talking to. Not in a log —
> in the interface. This cost a whole session of work landing against a
> backend nobody was using.

And then, with the GPU core actually wired in, the picture inverted: the
render became 37 ms and **the open path became 99 % of the time**. That is the
part still worth working on, and §2 is the list.

---

## 1. How to measure it (do this first, every time)

`SPEKTRAFILM_CANVAS_LOG=1` now prints one line per open with every stage:

```
$ SPEKTRAFILM_CANVAS_LOG=1 build/DerivedData/Build/Products/Debug/Spektrafilm.app/Contents/MacOS/Spektrafilm \
    --snapshot 1600x900 /tmp/out.png --open "tests/Test_image/Nikon Z7ii/_DSC2439.NEF" --wait 120 2>&1 >/dev/null \
    | grep "open path"

session: open path (ms): decode 95 · preview-texture 239 · linear-tiff 42
         · service.open 3315 · solve 111 · reprint 37 · TOTAL 3841 · core=metal
```

`core=metal` is the first thing to check. If it says anything else, stop —
nothing else you measure will mean what you think it means.

Delete `~/Library/Caches/com.hanze.spektrafilm/linear` for a cold run; the
warm run reuses the decoded TIFF.

**Why this instrument had to exist.** The service reports `elapsed_ms` for
renders and the status bar shows it, so the *only* number anyone could see was
the fastest thing in the pipeline. A slow open therefore read as a slow render,
which is the wrong half of the app. Do not delete `Session.LoadClock`.

---

## 2. What is left, in order of size

### 2.1 `resize_for_preview` — ~2.4 s, the largest single cost — GPU port

`src/spektrafilm/utils/preview.py` is three lines of
`skimage.transform.resize(..., anti_aliasing=True)`. On the 45 MP frame that
is a separable Gaussian prefilter plus a bilinear resample over
8256 × 5504 × 4, on the CPU: **2.4 s**, measured as `scipy.ndimage.correlate1d`
3.37 s + `zoom_shift` 1.17 s across the two calls it used to make.

It survived the whole GPU-native rewrite because the rewrite ported *render
nodes* and this is not one — it is the thing that produces a node's input.
This is `AGENTS.md` trap 10 almost verbatim, and the codebase already contains
one fix of the same shape: `ResizingService.small_preview` has a comment
saying "measured 7.1 s vs ~0 ms at 45 MP" for the auto-exposure sample.

**This is a port, not a reimplementation.** The output feeds the film
simulation, so a different downscale is a different picture. Two things were
measured before writing this, so you do not have to:

| candidate | time | max abs vs current |
|---|---|---|
| current (skimage) | 2.41 s | — |
| the same, forced float32 | 2.35 s | **0.0** — skimage is already float32 here, so this buys nothing |
| integer box-decimate, then skimage on the remainder | 0.71 s | **0.22** on a 0…1 range |

The box shortcut is 3.4× faster and **not acceptable**: 0.22 is four orders of
magnitude past the float32-epsilon bar RFC-011 held every ported node to, and
the error is structured (it is at edges). Do not take it without an RFC and a
labelled mode.

The right shape is the GPU one: `backends/metal/blur.gaussian` already exists
and is the same separable filter. Reproduce skimage's parameters exactly —
`sigma = max(0, (1/scale − 1) / 2)` per axis, `truncate=4.0`, `mode='reflect'`,
then `order=1` warp — and check it with `scripts/gpu_native/parity.py`, which
is built for exactly this. Expect the edge handling (`reflect`) to be the part
that bites.

### 2.2 The 364 MB TIFF handoff — ~0.5 s cold, and it is architectural

The client decodes the RAW with Core Image, writes a half-float linear ProPhoto
TIFF into `~/Library/Caches/com.hanze.spektrafilm/linear`, and passes the path;
the service reads it back. On this frame that is 364 MB written and 364 MB read
for every new frame (`linear-tiff` 498 ms cold, `service.open`'s `_load_image`
0.12 s).

The file handoff is in the contract (§1: large data travels as a path) and it
should stay a file — but it does not have to be *this* file. Options, cheapest
first:

1. **Write float16 without the alpha channel.** The array is
   8256 × 5504 × **4** and the fourth channel is unused. 25 % off both sides,
   for a one-line change on each — but it is a wire-adjacent change, so it goes
   in contract §5 first.
2. **Skip the round trip when the tier is all that is wanted.** `open`
   immediately downscales to the live tier and (now) never touches the full
   image again unless the user zooms. Handing over the full frame to
   immediately throw 96 % of it away is the actual waste; §2.1 and this are the
   same problem seen from two ends.
3. Shared memory / IOSurface. Real work, and it breaks the "no shared memory"
   line in contract §1 — do not start here.

### 2.3 The rest, for completeness

`preview-texture` 239 ms, `solve` 111 ms, `decode` 95 ms warm, `reprint` 37 ms.
None of these is worth touching until §2.1 lands; after it, `service.open`
should be a few hundred milliseconds and this list becomes the profile.

---

## 3. Things that will bite you

1. **Check `core=metal` before believing any measurement.** See §0.
2. **`open` is now the only place a tier's downscale happens lazily.**
   `RenderSession.image(tier)` builds it on first use under the tier's lock.
   If you make the preview tier eager again "to warm it up", you put 2.4 s back
   into `open` for a tier most sessions never use.
3. **The two pre-existing test failures are not yours.**
   `tests/test_regression_baselines.py` needs `.npz` baselines that are not in
   the working tree (the user deleted `tests/baseline/`; do not restore it), and
   `tests/gui/` tests the dead PyQt frontend. Everything else passes: 797.
4. **`src/` belongs to the backend session** under `CONTRACT-frontend-backend.md`
   §4. The lazy-tier change in `699a7c8` is the frontend session crossing that
   line deliberately, because the user asked for the open path fixed and this
   was half of it. It is behaviour-preserving with no wire effect. Anything in
   §2.1 changes *pixels* and should go through whoever owns the parity harness.
5. **Concurrency is available and off.** The engine reports
   `backend.concurrent: true` and offers `configure_transport`; the client
   matches replies by JSON-RPC id (`f167b21`) so it is safe to turn on, but it
   has not been tested against the real canvas and it is a visible behaviour
   change. It is worth real money — a live reprint measured 44 ms *while* a
   45 MP export runs — but it should be its own change, verified with
   `Tools/capture-live.sh`, not folded into a performance pass.
6. **`Tools/capture-live.sh` needs a live GUI session.** If
   `CGWindowListCopyWindowInfo` reports almost no on-screen windows, the display
   is asleep or the session is locked and the failure is environmental, not a
   regression. It is still the only capture that can see the canvas at all.

---

## 4. What "done" looks like for the next pass

- `service.open` under 500 ms on the 45 MP frame, with the live-tier downscale
  on the GPU and a parity row against the skimage reference at float32 epsilon.
- The `open path` log line published in the app's own status bar, not just the
  log — the same argument as §0's: the app should be able to say why it is
  slow.
- A decision, either way, on the alpha channel and the TIFF handoff (§2.2),
  written into contract §5 before it is built.
