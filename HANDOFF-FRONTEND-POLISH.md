# Handoff: window chrome, and the behaviour gaps behind a sound frontend

| | |
|---|---|
| **Status** | The frontend works end to end — decode, develop, print, adjust, export — and its layout measures within 2 pt of the drawing. What follows is the polish list, ordered by whether it breaks something or merely omits it. |
| **Read first** | `modern_UI/frontend_architecture.md` — the layout, the tokens, the view tree and the data path are recorded there and are not repeated here. Then `modern_UI/Spektrafilm/README.md` §7.1 for the four defects already found and fixed. |
| **Not in scope** | New tests. The suites that exist (34 Swift, 32 Python) pass; this task is behaviour, not coverage. Four were added on 2026-09-09 anyway, for the rules a screenshot cannot show (see §0). Masks are their own task: `HANDOFF-MASKS.md`. |
| **Date** | 2026-09-08 |

---

## 0. What landed on 2026-09-09, and what this list still owes

The frontend in `modern_UI/Spektrafilm` builds, and 38 Swift tests pass (34
before this pass; the new ones pin the tier policy, the sidecar name and the
cache eviction). Verified with `Tools/snapshot.sh`, `compare-layout.py` on the
16:9 capture (within 2 pt on every card) and a `--zoom` capture of the detail
tier through the real render path.

| § | item | status |
|---|---|---|
| 1 | traffic lights over the left panel | **done, differently from the recommendation above** — shifting the header row cleared the *glyphs* but left the buttons painted on the card, which still read as a collision in a live capture. The layout now reserves a 32 pt strip at the top (`Theme.Metric.titleBarHeight`) so the buttons sit on the ground; the header returns to the drawing's 12 pt inset, the cards keep the drawing's widths and gutters and lose 25 pt of height. The strip doubles as the window's drag handle, since `.hiddenTitleBar` removes the usual one. `Tools/compare-layout.py` applies the same offset |
| 2 | opening a folder commits to a render | **done, minimally** — a folder or a multi-file selection lands in a new Browse state and renders nothing; one file still goes straight to Print. The grid is a `LazyVGrid` inside one card, not the full-bleed surface §5.1 describes. Prefetch is now decode-preview only |
| 3.1.1 | the cache is unbounded | **done** — `Import/LinearCache.swift`, 4 GB LRU by modification date, pruned before every write |
| 3.1.2 | a file per slider value | **done** — the TIFF is written after the cancellation guard, so a superseded white-balance value never writes one |
| 3.1.3 | the cache is full resolution | **decided against, deliberately** — see below |
| 3.2 | two files share one sidecar | **done** — `a.NEF.spektra.json`, legacy name migrated on read and left in place |
| 3.3 | `topCollapsed` does not persist | **done** |
| 4 | the auto-solve is not wired | **half done** — `solve(target:"exposure")` runs after `open`, the result is stored in `Sidecar.solvedEV`, and the Exp. Comp. slider's sublabel reads `auto +1.1 EV`. The sliders are *already* offsets, so they were not re-based; what was missing was saying what zero means |
| 5 | progress for long work | **not possible as specified** — see below; elapsed time is shown instead |
| 5 | copy / paste settings | **done** — ⌘C/⌘V, film + print + Layer 2, offsets only |
| 5 | undo | **done** — ⌘Z, coalesced snapshots, deterministic re-render |
| 5 | service restart | **done** — a Restart button in the top bar and ⌥⌘R |
| 5 | crop handles | not done |
| 5 | ROI render | not done — replaced by whole-frame detail tiers, below |
| 5 | masks | not done (`HANDOFF-MASKS.md`) |
| 5 | grain seed | not done — a service change |
| 6 | two controls called white balance | **done** — "Camera WB" with a *Decode* caption, "Print White Balance" with a *Print* caption |
| 6 | Space shows the decode | **decided** — keep it, and label it: the canvas shows `original · decode` while held. The bypass switch remains the Layer 1/Layer 2 comparison, so the two comparisons are distinct and both labelled |
| 6 | arrow keys need canvas focus | **done** — the canvas claims first responder when it enters a window, unless a text field is focused |
| 6 | filmstrip single-select, sidecar litter | recorded, unchanged |

### Resolution follows the zoom (new, and the point of the pass)

The live tier is 1600 px on the long edge because a reprint has to fit in a
slider drag. Past 100 % zoom it is being interpolated, and an interpolated live
tier cannot show grain or halation — the two things zooming is *for*. So the
canvas now asks for a real render at the zoom level and swaps it in when it
lands, without blocking the gesture.

| zoom | tier | long edge | measured on the 45 MP Nikon Z7 II frame |
|---|---|---|---|
| below 100 % | live | 1600 | reprint 0.44 s |
| 100 % | preview | 3400 | 2.75 s (negative cold), 0.82 s warm |
| 200 % | full | native | 17.3 s cold, 6.2 s warm |

- A frame no larger than the live tier never escalates: it is already native.
- 100 % is one image pixel per device pixel; 200 % needs twice the pixels the
  viewport can show, which is past what the preview tier can feed.
- The request is debounced 700 ms so a zoom gesture or a slider drag does not
  fire it, and it never starts while the scheduler owes the service a render —
  the transport is single-flight, so a 17 s render would sit in front of the
  user's next slider release. If it has to wait, it re-asks.
- Zooming back out is instant: the detail texture stays resident (one frame
  only; a full-resolution texture is 360 MB) and `hideDetail()` puts the live
  tier back on screen.
- `Renderer` now expresses the viewport against the **live** tier's pixel size
  and scales the texture by the ratio in `canvasUniforms`. The first version
  inverted that ratio and drew a 5504 px texture 5.2× too large — which read
  as a black canvas, and is now pinned by
  `RendererTests.testDetailTextureDrawsAtTheLiveRectangle`.

**This is not the ROI render §5.0 specifies.** The service has no crop
parameter, so a detail render is the whole frame at a higher tier: the film
side runs at full resolution and 360 MB crosses the workspace. ROI would be
cheaper (print side only, ~1 s per pan) and needs a service change; it remains
the right optimisation once the tier is used enough to justify it.

### Two decisions this pass made against the list

**§3.1.3, the full-resolution TIFF.** Writing a 1600 px live-tier file and the
full-resolution one only at export looks like a two-orders-of-magnitude cache
win, but the service derives *every* tier — including `export` and the new
detail tier — from the file it opens (`RenderSession._images["full"]` is the
loaded array). A live-tier input silently caps export and detail at 1600 px,
and the single-session service makes swapping sessions per tier expensive. So
the full-resolution file stays, and the 4 GB LRU ceiling is what bounds it
(about eleven frames). If ROI rendering lands, revisit this together with it.

**§5, progress polling.** `progress` cannot be polled over this transport:
`reprint` does not return until the render is finished, and the stdio channel
is single-flight, so a `progress` call would queue behind the render it is
asking about. Real progress needs the service to accept a caller-supplied
progress id and answer requests while a render runs — a service change, not a
client one. Until then the top bar shows elapsed time for the work in flight,
which is the part that is actually known.

### A service bug this pass found

`service.py::_m_solve` passed `session.image("live")` straight to
`measure_autoexposure_ev`, which hands it to `colour.RGB_to_XYZ` expecting
three channels. The client's half-float linear ProPhoto TIFFs are **RGBA**, so
`solve(target="exposure")` raised `ValueError: matmul ... size 4 is different
from 3` on every image the frontend opens — which is why §4 had been left
unwired. Fixed by measuring `image[..., :3]`. The filter-pack half of `solve`
still writes its neutrals onto the session; the client only asks for
`target="exposure"` and lets `open` apply the database neutrals, so the
asymmetry does not bite. Note also that writing the solved EV into
`camera.exposure_compensation_ev` would *double-apply* it: `auto_exposure` is
on and already applies the solve, and the slider is an offset on top. The
handoff's suggested fix would be a bug; the value is for display only.

---

## 1. The traffic lights sit on the left panel — decide this first

`.windowStyle(.hiddenTitleBar)` leaves the three window buttons floating over
whatever is beneath them, and what is beneath them is the top-left corner of
the left panel card, exactly where the drawing puts the import and export
icons.

Measured on `modern_UI/design/snapshots/live-window.png`: the buttons occupy
roughly **x 10–57 pt, y 5–20 pt**. The left card starts at x 9, y 7; its
header row is 44 pt tall with the import icon at x 12–38 and the export icon
at x 50–76. The green button lands on the export icon.

This is a design decision, not a bug fix, and it belongs to the author. The
options, with what each one costs:

| option | cost |
|---|---|
| **Shift the header row right**, so the icons begin clear of the buttons (x ≥ 78) and the `⋮` stays at the right edge | keeps the drawing's structure and every card's geometry; the icons move ~66 pt right of where the drawing puts them. **Recommended** — it is the only option that costs no vertical space and no card geometry. |
| Inset the left card's content by ~28 pt at the top | costs a row of vertical space in the panel that most needs it, and breaks the alignment of the two panels' headers |
| Move import and export into the top bar | frees the corner entirely and matches how Capture One and Lightroom place window controls, but empties a corner the drawing deliberately fills, and the top bar is the canvas's, not the library's |
| Hide the buttons and provide close/minimise/zoom by menu and keyboard only | most faithful to the drawing, least native. A personal tool can afford it; state it as a deliberate choice if you take it |

Whatever is chosen, check it at all three window shapes with
`Tools/capture-live.sh` — the traffic lights are drawn by the window server
and do not appear in `Tools/snapshot.sh` output at all, which is why the
collision survived every capture until the app was run for real.

**Taken instead (2026-09-09): a 32 pt strip reserved at the top**, so the
buttons sit on the ground. The recommended header-row shift cleared the glyphs
but a live capture still showed the buttons painted on the card, which reads
as the same collision. See §0.

---

## 2. Opening a folder commits to a render nobody asked for

Today, `open(urls:)` selects the first frame by filename order and
immediately: decodes it through Core Image, writes a **363 MB** half-float
TIFF to the cache, calls `open` on the service (**~7 s** of film-side render at
45 MP), reprints it, and starts decoding the two neighbouring frames in the
background. None of that was asked for, and none of it can be stopped.

Three things are wrong with it:

1. **It spends seven seconds and a third of a gigabyte on a guess.** Which
   frame is "first" is alphabetical, which is to say arbitrary.
2. **It renders before the user has chosen anything.** Film, paper and format
   are still at their defaults at that moment. If the intent was a cine pair,
   the first render is wasted — and a film change is a shoot-layer change, so
   the whole film side runs again.
3. **There is no way to just look at a folder.** Browsing forty negatives to
   pick one is a normal thing to want, and this app cannot do it without
   printing each one you land on.

### This is a missing state, not a missing dialog

`modern_UI/SPEC-spektrafilm-desktop-frontend.md` §5.1 specifies **two** states
with a continuous canvas animation between them:

> **Browse.** Full-bleed grid. Breadcrumb and sort at top, nothing else. The
> grid is a *worklist*, not a preview surface — it shows what is in this
> session and how far along each frame is.
>
> **Print.** Docked three-sided layout.

Only Print was built. The Browse state is the confirmation step, and it comes
with the thumbnail-state model already implemented in the filmstrip
(unprocessed / processed / stale). Adding a modal "are you sure" would be the
wrong shape entirely.

### Recommended behaviour

| opened | lands in | renders |
|---|---|---|
| **one file** (Finder "Open With", a Capture One "Edit With" handoff, one dropped image) | **Print**, immediately | yes — this is the whole point of a handoff, and a confirmation here would be noise |
| **a folder, or several files** | **Browse** | **nothing.** ImageIO thumbnails only: no decode, no TIFF written, no service call |

Entering Print is then an explicit act — click a thumbnail, or `⏎` on the
selection. Nothing is auto-selected on arrival.

Two smaller changes belong with it:

- **Prefetch only the decode preview**, only while idle in Browse, and never
  the full-resolution TIFF. Today `prefetchNeighbours` writes two more 363 MB
  files before you have touched anything (see §3.1).
- **Re-entering Print for a frame already rendered** should show its cached
  print instantly — the texture store already keeps the last eight, so this is
  free.

The single-file case is the one to be careful about: going straight to the
print is *correct* there, and the fix must not make the handoff from Capture
One slower than it is now.

---

## 3. Defects — confirmed, with evidence

### 3.1 The decode cache is unbounded, and full resolution

`Session.linearTIFF` writes a half-float linear ProPhoto TIFF per
`(file, white balance)` and nothing ever deletes one. They are written at the
source's full resolution: **363 MB for one 45 MP frame**. After a handful of
test runs on a single image the cache stood at **1.7 GB**
(`~/Library/Caches/com.hanze.spektrafilm/linear/`). A folder of fifty frames,
browsed once, is on the order of 18 GB; every white-balance value a user
lands on while dragging the temperature slider writes another copy of the
frame.

Three separate things to fix, in order:

1. **Bound the directory.** LRU by access time against a size ceiling —
   `modern_UI/SPEC-spektrafilm-desktop-frontend.md` §1.1 proposed 20 GB, which
   is far too generous now that the entries are this large; something like
   4 GB, checked before each write, is closer to right for a cache whose
   entries are regenerable in a few seconds.
2. **Do not write a new file per slider value.** The white-balance path should
   settle before it writes: debounce the *write*, not just the reopen, or key
   the cache on a quantised temperature so neighbouring values share an entry.
3. **Reconsider full resolution.** The full-resolution TIFF exists so `export`
   and any future ROI render have real pixels, but nothing in the current app
   asks for them until export. Writing the live tier (1600 px, ~5 MB) at
   select time and the full-resolution file only when export needs it would
   cut the steady-state cache by two orders of magnitude.

### 3.2 Two files with the same stem share one sidecar

`Sidecar.url(for:)` is `deletingPathExtension().appendingPathExtension("spektra.json")`,
so `a.NEF` and `a.tif` in the same folder both resolve to `a.spektra.json` and
silently overwrite each other's settings. Keep the full name:
`a.NEF.spektra.json`. Note that this changes the sidecar path for any file
already edited, so either migrate on read or accept the reset and say so.

(The frontend spec asked for `<original>.spektra`; the built name is
`<original>.spektra.json`. Harmless, but the two documents should agree.)

### 3.3 `topCollapsed` is the only panel state that does not persist

`leftCollapsed`, `rightCollapsed` and `filmstripCollapsed` are stored under
`ui2.`; the top bar's flag is a plain `false`. Either persist it under the
same prefix or drop the collapse tab for the top bar — the asymmetry is
visible the moment someone folds it and relaunches.

---

## 4. The auto-solve is not wired, and it changes what the sliders mean

**This is the largest product gap, and it is not a small fix.** The service's
`solve` method is never called: `grep -rn "Method.solve" modern_UI` returns
nothing outside the type definitions.

`PRD-callable-render-api.md` §0 and frontend spec §5.2 both build on one idea —
*sliders exist to override the auto-solve* — and its consequences run through
the whole interface:

- **Print sliders should read as offsets from the solve, and zero should be
  the solved value.** Today Brightness, Yellow and Magenta are absolute
  offsets from the engine's defaults, and their zero tick means "the engine
  default", not "what this frame solved to". On a frame that solves two stops
  from the default, every number in the Enlarger section is misleading.
- **Exp. Comp. is the same story on the shoot side.** The engine's
  `auto_exposure` runs inside the render and `exposure_compensation_ev` is
  added to it, so the control is already an offset — but the UI never shows
  what it is an offset *from*, and `solve` is what would tell it.
- **Paste-settings semantics depend on it.** Frontend spec §5.5 defines paste
  as "offsets only, each frame solves its own exposure", which cannot be built
  until the solve exists.

Two things to know before wiring it, both recorded in the previous session's
notes and both still true:

1. **`solve` is asymmetric.** Its filter-pack half calls
   `apply_database_neutral_print_filters(params)` and those three neutrals
   stick on the session; its exposure half only *returns* an EV and never
   writes `camera.exposure_compensation_ev`. A caller that solves and renders
   gets the solved filter pack but not the solved exposure. Either round-trip
   the EV through `set_params` client-side, or fix the asymmetry in
   `service/service.py::_m_solve` — the latter is cleaner and is a three-line
   change.
2. **Where to call it.** Once per frame, after `open` and before the first
   `reprint`, then store the result in the sidecar (`Sidecar.solvedEV` already
   exists and is currently never written). The sliders then display
   `value − solved` and send `value`.

---

## 5. Behaviour that is missing rather than wrong

None of these are defects; they are things the interface implies and does not
yet do. Ordered by how often the gap is felt.

| gap | what exists now | what it needs |
|---|---|---|
| **No progress for long work** | `export` and the DI package run 14 s+ behind a spinner. The service's `progress` method is never called. | Poll `progress` on a timer while a render is in flight and show the node name and percentage in the top bar. The service already reports both. |
| **No copy / paste settings** | `⌘C`/`⌘V` do nothing; frontend spec §5.4 and §5.5 specify them | Copy the sidecar's params (and, once §3 lands, the offsets), paste onto the selection. The clipboard payload is tens of bytes. |
| **No undo** | every edit is immediate and permanent within a session | Params are tiny and grain is baked into the cached negative, so undo is a deterministic re-`reprint` from a stack of `FilmParams`/`Adjustments` snapshots. The service does not need to know. |
| **No service restart** | if the Python process dies, `onTermination` writes the reason into the status line and the app is inert | Offer a restart. `ServiceClient.start()` is already idempotent and the session can be reopened from the sidecar. |
| **Crop is a one-shot drag** | drawing a rectangle sets it; the only way to change it is to draw again, and the only way to clear it is the context menu | Handles, an aspect-ratio menu, and the standard rule-of-thirds overlay. The crop already survives into export and the sidecar. |
| **`preview_stock_lut` unused** | switching paper costs a full reprint | At ~200 ms the reprint is fast enough and exactly right, where the LUT is an approximation that omits glare. Worth leaving alone unless flipping through papers becomes a real activity — record the decision either way. |
| **No ROI render** | past the 1600 px live tier the canvas interpolates | Frontend spec §5.0. This is the one that matters for judging grain and halation, which are invisible below full resolution. It needs the working-resolution negative, so it pairs naturally with the cache work in §3.1. |
| **Masks** | not built; the sidecar has no field for them | Its own document: `HANDOFF-MASKS.md`, which also designs the interface, since the drawing has none. |
| **Grain is unseeded** | reopening a frame redraws the grain, so an export is not reproducible | Needs `grain_seed` in the shoot layer (frontend spec §1.4) — a service change, not a client one. Until it lands, do not claim reopening reproduces a previous export. |

---

## 6. Smaller things, worth a pass together

- **Two controls called white balance.** The Camera section's "White Bal. /
  Color Temp. / Color Tint" is a *decode* setting that re-decodes the RAW; the
  right panel's "White Balance / Temperature / Tint" is a Layer 2 adjustment on
  the print. Both are legitimate and they are in the right places, but the
  names collide. Consider "Camera White Balance" and "Print Temperature", or a
  one-line caption under each.
- **Vignetting sits in Camera but is Layer 2.** It is there because that is
  where a photographer looks for it, and its comment says so. If the layer
  boundary ever reads as ambiguous in use, moving it to the right panel is the
  honest fix.
- **Space shows the decode, not the print.** Holding Space swaps in the Core
  Image preview — a useful comparison, but not the one the spec meant
  ("show original"), and not the one the bypass switch already gives (Layer 1
  without Layer 2). Decide which comparison Space should make and label it.
- **Arrow keys need canvas focus.** `←`/`→` step frames only when the canvas is
  first responder; `⌘[` and `⌘]` always work. Either promote the arrows to
  commands or give the window a focus story.
- **The filmstrip is single-select.** No multi-select, no keyboard navigation
  within it, no drag-reorder. All intentional for now; note it before someone
  reports it.
- **Sidecars are written next to the source files.** This is what the spec
  asked for, and it does mean opening a folder eventually litters it with
  `.spektra.json` files. Fine for a personal tool; worth a sentence in any
  future README aimed at anyone else.

---

## 7. How to check your work

Two harnesses, and they see different things:

```
Spektrafilm/Tools/snapshot.sh                       layout, three window sizes, offscreen
Spektrafilm/Tools/compare-layout.py <capture>       cards against the drawing, ±2.5 pt
Spektrafilm/Tools/capture-live.sh [image.NEF]       the real window, window server
SPEKTRAFILM_CANVAS_LOG=1                            one line per draw and per dropped render
```

`snapshot.sh` cannot see the Metal canvas or the traffic lights — it renders
through `cacheDisplay`, which ignores a `CAMetalLayer` entirely, and it draws
no window chrome. Everything in §1 is invisible to it. Use `capture-live.sh`
before believing anything about what is actually on screen; it is slower and
needs Screen Recording permission, which is why it is the acceptance check and
not the inner loop.
