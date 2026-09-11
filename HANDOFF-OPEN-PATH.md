# Handoff: the open path — what the 6.5 s actually is

| | |
|---|---|
| **For** | the next session. Frontend (`modern_UI/**`), unless you take the engine-side route in §5.2. |
| **From** | 2026-09-11, the session that fixed the Solve/Original row and the decode-first open (§0) and then measured this. |
| **Status** | **Fixed 2026-09-11 — §8.** §5.1 and §5.2 both landed (variant C of §8.1, not §5.2's texture): 45 MP open 6926 → ~1130 ms. Everything above §8 is the diagnosis as it stood, kept because its numbers are why the fix is shaped the way it is. |
| **Read first** | `AGENTS.md` traps 17 and 23, then §3.1.3 of `HANDOFF-FRONTEND-POLISH.md` (the decision that a full-resolution handoff TIFF is what makes detail renders and export possible — this file asks whether that decision is still worth its price), then `ARCHITECTURE.md` §8.8. |
| **Audience** | a session that knows this repo. Nothing here re-explains what the pipeline is, and where a number was not measured it says so; §3.3 and §5 are the parts that need judgement rather than reading. |
| **Numbers** | every figure below was measured on this checkout, on this machine, on 2026-09-11. Commands in §2.3. |

---

## 0. Where the tree is, so you don't get lost

The app builds, and `SpektrafilmTests` is green at **119 tests** (7–8 s).
Two commits from the previous session:

| commit | what |
|---|---|
| `429c9ba` | the app opens onto the decode and develops on request; the Solve/Original row is inset with the well. Adds `SpektrafilmTests/OpenPathTests.swift`. |
| `2f51b69` | the open-path instrument described in §2.1. No behaviour change. |

**A lot of work is uncommitted** and belongs to the user, not to you: the
print-LUT port (`engine/src/core/print_lut.*`, `engine/tests/parity_lut.py`),
the licensing/packaging work (`Tools/package.sh`,
`Tools/bundle-licenses.sh`, `Tools/check-bundle-resources.sh`,
`Resources/Licenses/`, `Windows/AboutWindow.swift`, `LicensingTests.swift`,
`Service/EngineMessage.swift`), `engine/src/pipeline/engine.cpp`,
`shaders/util.metal`, and the docs. Two of those commits above had to carry
part of it because the files are shared (`SpektrafilmApp.swift` and
`project.pbxproj` in the first; `EngineClient.swift` in the second). The user
knows. **Do not `git stash`, `git clean -fdx` or `git checkout -- .`**
(`CONTRACT-frontend-backend.md` §4.1), and `Tools/gen-project.py` must be
re-run after adding or removing any source file.

---

## 1. The finding, in one screen

Opening a 45 MP NEF takes **~6.9 s**, and the ~6.4 s of it the user was
pointing at — "the first profile load and effect application" — is neither a
profile load nor an effect. `Session`'s clock calls that half of the open
`service.open`, and on this frame it is almost entirely
`EngineClient.readLinearRGB`:

```text
session: frame read: tiff 5504×8256 364 MB on disk · decode 2 ms
          · ci-render-to-bitmap 6154 ms (727 MB float RGBA, 118 MB/s)
session: frame upload to the engine (727 MB): 235 ms
session: open path (ms): decode 87 · preview-texture 224 · linear-tiff 29
          · warm-up 0 · service.open 6391 · solve 144 · reprint 47 · TOTAL 6926
          · warm_up 292 ms · core=native-metal · cache 0/0 · 1 hit / 3 miss
```

The phases reconcile, which is how you know nothing is hiding between them:
`service.open` 6391 = frame read 6154 + upload 235, and the whole open 6926 =
87 + 224 + 29 + 6391 + 144 + 47. (The decode and preview laps were briefly
missing from this line between `429c9ba` and this file — `load` hands its clock
to `ensureDeveloped` now, so the develop continues the same line instead of
starting its own at `linear-tiff`.)

Read that against what each phase *sounds* like it is:

| phase | sounds like | actually is |
|---|---|---|
| `decode` · `preview-texture` | Core Image decoding the RAW | 87 + 224 ms — the fast half, and the decode is lazy (2 ms for the `CIImage(contentsOf:)` call itself) |
| `linear-tiff` | writing the handoff TIFF | 29 ms — a **cache hit** |
| `service.open` | the engine opening a frame | **Core Image rasterising the handoff TIFF** — 6154 ms of the phase's 6391, the rest being the upload |
| `frame upload` | the GPU path | 235 ms for 727 MB (3 GB/s) |
| `solve` | the filter pack | 144 ms |
| `reprint` | the film + print pipeline | **47 ms** — the whole render |

So the render is 0.7 % of the open, and reading the handoff file back to
rasterise it is **89 %** of it. The frame the app already holds in memory
renders into the same 727 MB buffer — the same bytes — in **241 ms**, 181 ms of
it warm.

The cost is **per image, not per launch**: a second, different TIFF in the same
process pays it again (5490 ms, then 5518 ms; both then 122–123 ms on a second
render). It is not a warm-up, and it is not paid once.

### 1.1 The answer to the two questions that were asked

**"Is it the cache system?"** The cache is working exactly as designed and that
is the problem: `linear-tiff 29` is a *hit*, so the app is paying 6.2 s to read
back 364 MB it decoded earlier in the same process. Persisting is what makes it
slow, not what would fix it (§3.2).

**"Can the read be optimised — is it still on the CPU, can it run in
parallel?"** Yes, and mostly no, in that order:

- It is **already parallel** and still runs at 118 MB/s. `CIContext.render`
  spread the work over ~12 threads in the sample (§2.2); ~10 MB/s per thread
  points at per-tile overhead and locking inside Core Image's source-node
  path, not at a missing `DispatchQueue.concurrentPerform`.
- It does **not** block the UI: the main thread sat in `mach_msg` for the whole
  6 s, and `openFrame` runs on the `EngineClient` actor. It blocks **the
  engine**, because that actor serialises every other call.
- Optimising it is safe in the sense that matters — it is a pure function of
  (file, destination space) producing a buffer the engine copies, and nothing
  downstream can observe how it was produced. The conditions are in §4.3.
- **Throwing cores at the current path is the wrong tool.** §4.4.

---

## 2. How it was measured

### 2.1 The instrument that landed (`2f51b69`) — keep it

`EngineClient.logFrameRead` (in `Service/EngineClient.swift`) prints two lines
when `SPEKTRAFILM_CANVAS_LOG=1`, the same switch `Renderer` and `Session` read,
so one run prints one story:

```text
session: frame read: tiff <W>×<H> <MB> MB on disk · decode <ms> ms
          · ci-render-to-bitmap <ms> ms (<MB> MB float RGBA, <MB/s> MB/s)
session: frame upload to the engine (<MB> MB): <ms> ms
```

`decode` is `CIImage(contentsOf:)` and is 2 ms because it is lazy — everything
it deferred lands in `ci-render-to-bitmap`. `frame upload` is the `spk_open`
call. Between them they split `service.open` into the two halves that matter.

### 2.2 The profile that names the frames

`sample <pid> 6` started 3 s into an open (`sample` on your own process needs
no root). The main thread is idle in `mach_msg`; the work is on ~12 background
threads, and 3518 of one thread's 3845 samples are one stack:

```text
Session.ensureDeveloped() → Session.develop → Session.openInService
  → EngineClient.call → EngineClient.openFrame → EngineClient.readLinearRGB
    → Array.withUnsafeMutableBytes → -[CIContext render:toBitmap:rowBytes:bounds:format:colorSpace:]
      → CI::image_render_to_bitmap → CI::tile_node_graph → CI::recursive_tile
        → CI::CGNode::tileSurface … (CI_CGNode_SurfaceCacheQueue, 670 samples)
```

`CGNode::tileSurface` is the *source* being rasterised tile by tile, not the
destination conversion. That is the one piece of mechanism the profile gives
you for free; §3.3 is what it does not.

### 2.3 Commands

```bash
# the open, from the app itself (needs a live GUI session and Metal)
SPEKTRAFILM_CANVAS_LOG=1 modern_UI/Spektrafilm/build/DerivedData/Build/Products/Debug/Spektrafilm.app/Contents/MacOS/Spektrafilm \
    --snapshot 1600x900 /tmp/out.png \
    --open "tests/Test_image/Nikon Z7ii/_DSC2439.NEF" --wait 150 2>&1 | grep -E "open path|frame "

# the same, with the profile
… --open … >/tmp/nef.log 2>&1 & sleep 3; sample $! 6 -file /tmp/sample.txt

# build and test
cd modern_UI/Spektrafilm && python3 Tools/gen-project.py
xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm \
    -configuration Debug -derivedDataPath build/DerivedData build
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests \
    -configuration Debug -derivedDataPath build/DerivedData test
```

The standalone Core Image tools used in §3.2 and §3.4 were throwaway:
`/tmp/ciread{,2,3}.swift`, `/tmp/cidiff.swift`, `/tmp/ciround.swift`. They are
not in the repo and a reboot loses them, so what they established is recorded
here with its numbers; the app-side instrument above reproduces the headline
one, and §3.3 says which of the rest is worth re-measuring properly.

**Timing hygiene.** Trap 17 applies. Load average was 2.9–5.4 while these ran
(falling from 13), and five separate launches agreed to within 4 % — 6665,
6567, 6388, 6397, 6407, 6418 ms — so the 20× gap between the file and the
decode is not contamination. Re-check before trusting anything new.

---

## 3. What causes it, and what does not

### 3.1 The path, end to end

1. `ImageDecoder.decodeRAW` builds a `CIRAWFilter` and returns its
   `outputImage` — **lazy**, 2 ms, no pixels yet.
2. `Session.linearTIFF` writes that image to
   `~/Library/Caches/com.hanze.spektrafilm/linear/<key>.tif` as **uncompressed
   half-float linear ProPhoto** (`writeTIFFRepresentation(format: .RGBAh,
   colorSpace: ImageDecoder.linearProPhoto, options: [:])`) — 364 MB at
   45 MP; the "uncompressed" part is deliberate and pinned by
   `TIFFHandoffTests`.
3. `EngineClient.openFrame` (on the `EngineClient` actor) reads that file back
   with `readLinearRGB`: `CIImage(contentsOf:)` → `ImageDecoder.context.render(
   …, format: .RGBAf, colorSpace: linearProPhoto)` into a `[Float]` of
   `w × h × 4` — **727 MB at 45 MP**.
4. `spk_open` copies/upload that buffer to the GPU and builds the session's
   tiers. `spk_image` is `const float*` with 3 or 4 channels; the alpha is
   dropped at the door.

Step 3 is the 6.2 s. Step 2 exists only because step 3 used to be in another
process; the engine reads no frame file at all (`grep -n "ifstream" engine/src`
is three hits, all resource files).

### 3.2 What is exonerated, and by what measurement

| suspect | measurement | verdict |
|---|---|---|
| the engine render | `reprint 47 ms` | 0.7 % of the open |
| the setup caches (trap 18 §2) | `warm_up 292 ms`, and `solve`+`reprint` 191 ms | no |
| the TIFF **write** | `linear-tiff 29 ms` — a cache hit | not in this measurement |
| the disk | `mmap` of the 364 MB file: **0 ms** | no |
| ImageIO's decode | `CGImageSourceCreateImageAtIndex`: **1 ms** | lazy, like CI's |
| the output format (`.RGBAf`) | see the trap in §3.4 | **not established** |
| the destination colour space | a fresh process whose *first* render went to `extendedLinearDisplayP3` took **5466 ms**; every render after it, in any space, 122–123 ms | no |
| that the custom working space is a second, slower path | rendering with the context's working space set to the destination produced **bit-identical** output — `max |Δ| = 0.000000` over 136,323,072 samples | no |
| that the round trip is *colours* wrong | the app's own write + read, end to end: `max |Δ| 0.0017`, `mean |Δ| 0.00002` — half-float quantization | faithful |

Two of those cost this session real time because they were measured in the
wrong order — see §3.4 before you repeat either.

### 3.3 What is left, as hypotheses to pin

The one thing the profile does not tell you is *why* the source rasterisation is
20× slower than rendering the same decode directly. The candidates, in the order
worth testing — each needs a **fresh process per variant** (§3.4):

1. **The 16-bit source.** The file is 16 bits per channel, the buffer is 32, and
   CI may be doing the half→float expansion through a generic path. Compare the
   same image written as `.RGBAf` (727 MB file) and as `.RGBA8`, and compare
   against a TIFF written by a different writer (OpenImageIO, `tifffile`).
2. **The untagged profile.** ImageIO reports the file's `ProfileName` as
   `CG Cal RGB` but there is **no ICC data** in it, and
   `CIImage(contentsOf:).colorSpace` is `nil` — an unnamed source space. Write
   the handoff TIFF in a *named* space (`extendedLinearDisplayP3`, or
   `CGColorSpace(name: "com.adobe.romm")`-style ROMM if you can get one) and
   see whether the tile path changes.
3. **Tile geometry / the CG path itself.** `CGImageSourceCreateImageAtIndex`
   returns a `CGImage` in 1 ms; try `context.createCGImage(_:from:)` once and
   render *that*, or render through `CIContext.render(_:to:)` into a
   `CVPixelBuffer`/`IOSurface` instead of `toBitmap:`.
4. **Thread count.** It is already multi-threaded, so this is low priority, but
   `CIContext` has no knob for it and `sample` is the way to see it change.

If none of them moves it, the answer is "that is what the CG path costs for a
45 MP 16-bit file", and §5.1 becomes the only fix.

### 3.4 TRAP: the first render in a process warms the source, so order lies to you

**This fooled this session twice, in opposite directions.** Core Image caches
the rasterised source after the first render: with one image in one process,
render #1 is 5490 ms and render #2 is 122 ms, *whatever you change in between*.

- Measuring `.RGBAf` → `linearProPhoto` first and `.RGBAh` second produced the
  conclusion "half float is 70× faster". It is not; the second render was warm.
- Measuring with the working space changed produced "45× from a working-space
  choice", which is why `EngineClient` briefly grew a second `CIContext`. A
  fresh process with that same variant **first** took 5466 ms — i.e. the same
  as before — and the two variants were bit-identical. The change was reverted
  before it was committed; do not resurrect it.

Rules: one variant per process, first render only, or warm the source
deliberately and *say* that you did. The same trap applies to any "quarter
size" measurement (the 21 ms quarter-size figure from the same run is a warm
number and means nothing about scaling).

---

## 4. Can the read be optimised? (the questions as asked)

### 4.1 It is already on the CPU *and* already parallel

`CIContext.render(toBitmap:)` is synchronous and CPU-bound **at the
destination** — it writes a `[Float]` in this process — and Core Image
parallelises the graph over ~12 threads internally. The sample in §2.2 shows
that, and 118 MB/s across a dozen threads is ~10 MB/s per thread: the
bottleneck behaves like per-tile overhead and queueing
(`CI_CGNode_SurfaceCacheQueue` alone held 670 samples), not like a
single-threaded kernel.

So "run it in parallel" is already true and is not the lever. If you want that
lever specifically, measure it: split the destination into N horizontal bands,
render each with its own `CIContext` on its own queue with
`render(_:toBitmap:rowBytes:bounds:colorSpace:)` scoped to that band, and
compare against the single call. **Do not assume it wins** — banding multiplies
the per-tile setup that §3.3 says is the likely cost.

### 4.2 It blocks the engine, not the UI

The main thread is idle for the whole 6 s (`mach_msg` in the profile), so the
window stays responsive; what stalls is everything else that needs
`EngineClient`, because that actor is serial. This is why the symptom presents
as "the app hangs after I open a frame" rather than as a beachball, and why
`Session`'s own clock is the only place it shows.

### 4.3 Yes, optimising it is OK — with three conditions

The read is a pure function from (file, destination space) to a buffer that
`spk_open` copies immediately. Nothing downstream — the engine, the tiers, the
canvas, export — can observe how the buffer was produced, and the round trip is
value-faithful to half-float epsilon (§3.2). So:

1. **Keep the contract exact**: float32, linear ProPhoto, top row first.
   `testTheFrameIsReadTopRowFirst` exists because a vertical flip produced a
   correctly developed, upside-down photograph with 27 of 27 parity cases green
   (trap 23). The colour space is `ImageDecoder.linearProPhoto` and the engine
   is calibrated against it.
2. **Expect the *input* to shift by ~half-float epsilon**, not zero, if you
   change the decode path — and remember the parity harnesses hand the engine a
   numpy array and never come through this function, so they cannot see it.
   Verify with the engine's own input buffer (a temporary checksum log is
   enough), not with a snapshot: `--snapshot` renders through `cacheDisplay`,
   the canvas is a `CAMetalLayer` it cannot see, and glare is unseeded (trap 1),
   so two snapshots are not bit-comparable anyway.
3. **Say what you changed about the surface.** `EngineClient`'s header calls the
   method surface deliberately unchanged, and `OpenRequest.imagePath` is part of
   that. The *wire* (the params JSON, contract §2) is not touched either way.

### 4.4 What parallelising the read would not buy

Even at infinite speed the read still costs 727 MB of float RGB staging through
the CPU and a 235 ms upload (§5.2). Parallelising is a way to make a bad path
less bad; not writing the file is the way to not have the path.

---

## 5. The fix

### 5.1 The one to do first: stop handing the frame over through a file

`spk_open` already takes pixels. Render the decode's `CIImage` straight into the
buffer `readLinearRGB` builds today — same `.RGBAf`, same destination
`linearProPhoto`; the working space is irrelevant, which §3.2 measures — and
delete the write and the read from the path.

Why it is safe: the same decode rendered that way gives **the same numbers** as
the file round trip (measured, `max |Δ| 0.0017`), and it already happens in this
process — `decodeRAW`'s `CIRAWFilter` output is the same pixels step 2 writes
out.

What it should cost, from the parts already measured:

| | today | direct |
|---|---|---|
| decode (lazy, on the RAW) | 87 ms | 87 ms |
| preview texture for the canvas | 224 ms | 224 ms |
| render the frame to float RGBA for the engine | folded into the TIFF write | **241 ms** cold, 181 ms warm |
| TIFF write (on a cache miss) | a full CI render + 364 MB to disk | — |
| TIFF read + rasterise | **6154 ms** | — |
| upload to the engine | 235 ms | 235 ms |
| `solve` + `reprint` | 191 ms | 191 ms |
| **open** | **6.9 s** | **~1.0 s** (estimate; 978 ms from the rows above) |

It also removes, as a consequence: the 364 MB write on every cache miss, the
`LinearCache` and its LRU churn — **15 entries, 4.21 GB, 11 of them
45 MP-sized**, i.e. a cache that has been at its 4 GB ceiling and evicting — and
the lazy-CI dance around a file that exists only to be read back by the process
that wrote it.

Files: `Service/EngineClient.swift` (`openFrame` / `readLinearRGB`),
`Model/Session.swift` (`linearTIFF` and the `develop` path that calls it), and
the `OpenRequest` payload in `Service/Methods.swift` (`image_path` on the wire —
the wire *schema* is untouched either way, contract §2).
`Import/LinearCache.swift` and `TIFFHandoffTests` then need a decision: keep the
cache for a future out-of-process caller, or delete both with the path they
describe.

**Decide this against §3.1.3 of `HANDOFF-FRONTEND-POLISH.md` first.** That
section chose the full-resolution file deliberately, because the service
derived *every* tier from the file it opened, and a live-tier input would have
silently capped detail renders and export at 1600 px. With the engine in
process, the equivalent is handing it full-resolution *pixels* — the tiers are
built on the engine side either way — but say so explicitly rather than
discovering it.

### 5.2 The deeper one: let the engine take a texture

`spk_image` is `const float*`. If it accepted an `id<MTLTexture>` (or an
`IOSurface`), the app could render the decode into a texture the engine
samples directly: no 727 MB CPU buffer, no 235 ms upload, no readback either
way. This is the natural end of RFC-014's "the engine is in this process", and
it is the only version that removes the staging buffer rather than making it
cheaper. It is an `engine/**` change, so it needs the parity harnesses
(`parity_render.py` and `parity_session.py` in particular) and a word with
whoever owns the engine side that session.

### 5.3 How to know it worked

The instrument already prints the line. Target: `frame read` under 400 ms,
`service.open` under 500 ms, and `TOTAL` under 1.5 s on the 45 MP frame, with
`reprint` unchanged at ~47 ms. Then the two OpenPathTests cases and the full
suite, then a snapshot — and look at it (trap 23), because a green suite did
not catch a vertical flip.

---

## 6. The tiering question, which was asked in the same breath

The user's reading was "at 45 MP the render is fast enough, so the resolution
tiers may not be worth having — make it a setting". Measured on this frame:

| tier | when it is used | render | resident |
|---|---|---|---|
| live, 1600 px | at fit, and for every slider release | **46–47 ms** (`reprint 47`) | ~10 MB |
| preview, 3400 px | ≥ 100 % zoom | **184 ms** (`detail preview 2266x3400 landed in 184 ms`) | ~46 MB |
| full, 8256 px | ≥ 200 % zoom | **1004 ms** cold (`detail full 5504x8256 landed in 1004 ms`); 237 ms warm is the repo's number, not re-measured here | ~360 MB |

**The tiers are not the 6.5 s** — they are 46/184/1004 ms *after* an open that
costs ~6900 ms, and the render the open performs is the 46–47 ms one. Removing
them would not have moved the number the user noticed.

But the underlying instinct is legitimate and worth offering *after* §5.1: an
opt-in "always render native" preference, where the live tier renders at the
frame's own resolution and no escalation is needed. The honest price, for the
UI copy: every slider release goes ~46 ms → ~1 s cold (237 ms warm), and the
resident texture goes 10 MB → 360 MB. It is cheap to implement — a
`UserDefaults` bool consulted by `Session.wantedTier` and by the tier the
scheduler reprints at — and it should default **off**, because a 1 s slider is
not something to switch on by accident. Do not do it before §5.1, or the user
will pay ~6.9 s per frame before they pay the 1 s per edit.

---

## 7. Loose ends

- **The 6 s number predates the bug it was attributed to** and may have been
  hiding since before the engine existed. `HANDOFF-RFC013-SESSION-CACHE.md` §1
  records "first `open`, cold engine — 45 MP NEF: 5.93 s" for the *numba*
  backend, and "5.59 s" warmed. When RFC-014 replaced numba, the render went to
  46 ms and the app's `service.open` phase stayed at ~6.4 s, under a name kept
  for continuity that still reads like the engine doing work. Any number in
  this repo whose cause was removed but whose value did not change is worth
  re-deriving; this one took two sessions to notice.
- **`Session.linearTIFF`'s docstring and `LinearCache`'s header both still
  explain the cache as "the service takes a file"**, which has not been true
  since RFC-014. If §5.1 lands, they go; if it does not, they should at least
  stop describing a service that is not there.
- **Export** goes through `Exporter.swift` and the engine's `spk_reprint` at the
  full tier, not through the handoff TIFF (`Session.currentServiceSession()`
  develops first). Nothing in the export path depends on the file today —
  check that claim again before deleting `LinearCache`.
- **The 4.87 GB peak memory footprint** (`/usr/bin/time -l`, peak RSS 2.9 GB)
  is not the subject of this file, but §5.2 is where it would be addressed.
- **Nothing here was verified on a second machine or a second frame.** The
  Nikon `_DSC0897.NEF` (51 MB, whose sidecar was written the same day) is the
  obvious second sample; so is a 24 MP A7m3 frame, which should show whether
  the 118 MB/s is a pixel-rate or a per-tile constant.

---

## 8. What landed (2026-09-11, the session after)

### 8.1 The premise, re-measured first

§5.1's estimate rested on a 241 ms direct render, and §3.4 is a warning
about exactly that kind of number. Re-measured one variant per **fresh
process**, first render, the app's order (1600 px preview first), 45 MP
`_DSC2439.NEF`, two interleaved rounds, load 5.4:

| variant | frame to float RGBA | pixels vs B |
|---|---|---|
| A — today: read the handoff TIFF | 7079 / 6351 ms | max \|Δ\| 5.9e-4, mean 1.8e-5 |
| B — decode → `toBitmap` into `[Float]` | 226 / 239 ms | — |
| **C — decode → `toBitmap` into a shared `MTLBuffer`** | 236 / 239 ms | **bit-identical** |
| D — `render(to:)` a linear rgba32Float texture over the buffer | 187 / 190 ms | max \|Δ\| 2.5e-4 |

C was chosen: the same pixels as B, and the engine can borrow the memory.
D is 40 ms faster, not identical, and needs the vertical flip trap 23 is
about. A vs B also says the file was the *less* faithful path.

### 8.2 The change

- **Engine (additive):** `spk_open_device` + `spk_device_image` borrow a
  caller's `id<MTLBuffer>` for the length of the call; `Gpu::borrow` wraps it
  without a copy (retained, never pooled). `spk_open` and `spk_open_device`
  share one body (`open_frame`) and differ only in how the frame reaches the
  device; a device frame always goes through `spk_take_rgb`, which is the copy
  that ends the borrow. `spk_ctypes.py` is untouched.
- **Frontend:** a RAW is decoded **twice** (`ImageDecoder` header).
  `DecodedImage.linear` (Apple's tone rendering off) is the only thing
  `ImageDecoder.engineFrame` renders for the engine; `DecodedImage.display`
  (Apple's default) is what the canvas shows before a develop, under Space and
  left of the split. Same geometry in both — **lens correction off in both**:
  Apple's default corrects the Z7 II's lens, which keeps the extent and moves
  the picture, so a literal default would be misregistered against the print.
  White balance follows the user's in both.
- **Deleted:** `LinearCache`, `Session.linearTIFF`, `writeLinearTIFF`,
  `readLinearRGB`, `OpenRequest`, `TIFFHandoffTests`. `Session` removes the old
  `Caches/…/linear` directory at launch (it held 4.2 GB here). `call(.open, …)`
  is refused by name; `EngineClient.open(_:paramsDelta:)` takes an `EngineFrame`.
- **The comparison, which was wrong at zoom before any of this:** the
  "before" was the 1600 px decode stretched against a native-resolution print
  at 200 %, so the left half was soft and the right half grainy. The renderer
  now compares against `before` — the original at the detail print's
  resolution, rendered only while a comparison is up (`Session.
  ensureOriginalDetail`). The "After" label also sat under the tier badge once
  the picture reached the canvas edge; the badges are one list
  (`Session.canvasBadges`) the overlay steps around. `renderOffscreen` now
  honours "show original" like `draw` does, and `--original` captures it.

### 8.3 Measured after (Debug build, load 2.6–2.7)

```text
open path (ms): decode 183 · preview-texture 238 · warm-up 30 · frame 282
               · engine.open 203 · solve 137 · reprint 47 · TOTAL 1128
```

Three launches: 1125–1140 ms (a first launch with a cold disk read the NEF in
924 ms and totalled 1964). `reprint` is unchanged at 46–49 ms.

**What §5.2 actually bought** — interleaved A/B in one build, the borrow
against a host `spk_open` of the same buffer: `spk_open` 202–204 ms vs
257–281 ms, peak RSS 1.66–1.70 GB vs 3.02–3.15 GB (the host arm carried one
extra `[Float]` copy, so the fair saving is ~55–75 ms and ≥ 0.6 GB). *Not*
the 235 ms §5.2 implied: most of that phase was never the copy.

### 8.4 Two traps this session paid for

- **`-[MTLBuffer contents]` autoreleases the buffer.** It returns an inner
  pointer, and Swift (like ARC) retains and autoreleases the receiver to keep
  it valid. `engineFrame` therefore parked the 727 MB frame in whatever pool
  the calling thread drained next, after every owner had dropped it —
  `testTheEngineKeepsNothingOfTheCallersBuffer` saw it alive after `open`. The
  render is wrapped in `autoreleasepool`. A first guess (the engine's
  autoreleased command buffers) was tested by removing it and was *not* the
  holder; that change was reverted rather than kept on suspicion.
- **The frame is now ~50 ms slower than §8.1's B** (≈280 ms, which matches
  B with no preview in front of it): the preview warms the *display*
  decode's demosaic, not the linear one's. That is the price of the two
  decodes being separate objects, and it was paid deliberately.

### 8.5 Where the open's time is now, and the next lever

`engine.open` is 30 ms of upload and `spk_take_rgb`, and **~170 ms of
`Pipeline::build`** — after `warm_up` has already built the same stock pair,
with `1 hit / 3 miss` on the setup cache in every open's log line. That is
the next thing to read (`core/setup_cache.hpp`: which key differs between
`warm_up` and `open`), and Debug's `-O0` engine (trap 18 §2) is part of it.
After that: `decode` + `preview-texture` (~420 ms) is time to first picture
and is Core Image's; `solve` is 137 ms.

### 8.6 Tests

124 Swift tests (was 119): `DecodeSeparationTests` (the routing with solids
that cannot be confused; both RAW filters' geometry and white balance on the
Z7 II; the original vs the print end to end — grid correlation 0.996, 0.06
against the flipped print as the control), three `spk_open_device` tests in
`EngineClientTests` (byte-identical live print to `spk_open` with grain and
glare off; a short buffer refused; the caller's buffer not kept), and the
`before` rule in `CompareAndFlagsTests`. All six parity harnesses,
`gpu_smoke` and the math guard: green, exit 0.
