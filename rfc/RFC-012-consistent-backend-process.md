# RFC-012: One process, one bundle — retiring the Python service

| | |
|---|---|
| **Status** | Proposed |
| **Date** | 2026-09-10 |
| **Depends on** | RFC-011 (the GPU-native core, which is what makes this possible), RFC-010 (colour-science testing — the reference path this must not destroy) |
| **Supersedes** | `CONTRACT-frontend-backend.md` §1's "the boundary is the wire" — deliberately, and only at the end of §5's sequence |
| **Scope** | `Service/ServiceClient.swift`, `service/**`, `utils/io.py`, packaging, and eventually `backends/metal/**`'s host language |
| **Hardware of record** | Apple M3 Max, 30-core GPU, 36 GB unified; macOS 25.6; MLX 0.32.2 |
| **Frame of record** | `_DSC2439.NEF` → linear ProPhoto float32, 5504 × 8256 = **45.75 MP** |

---

## 0. The question, and the answer

> Is it time to abandon the Python backend and switch to C++/Rust?

**For speed: no.** Python is not what costs time. **For shipping: yes, and it
is not optional** — the app as it stands cannot leave the machine it was built
on. Those are two different arguments and conflating them produces the wrong
plan, which is why this RFC separates them.

The thing to retire is not *Python the language*. It is **the process
boundary** and **the 2.2 GB environment behind it**. The render itself is
already native: MLX kernels on the GPU, with Python acting as a JSON parser
and a profile loader wrapped around them.

---

## 1. The measurements this argument rests on

All measured 2026-09-10 on the frame of record, on the shipped configuration,
warm, through `RenderService` in-process (so no transport framing is counted
against Python that the app would not also pay).

### 1.1 Where a reprint's 30.6 ms goes

| | ms / reprint | share |
|---|---|---|
| `backends/metal` — **the actual GPU render** | 10.5 | 34 % |
| `_write_rgba16` — **writing the pixels to a file for the client** | 10.0 | **33 %** |
| numpy glue | 1.8 | 6 % |
| colour-science | 0.8 | 2.7 % |
| numba | 0.0 | 0 % |
| Python interpreter, JSON, dispatch, the rest | ~7.5 | 24 % |

**A third of every render is spent writing a file that exists only because the
engine is a separate process.** The GPU does the work in 10.5 ms and then the
architecture spends another 10 ms handing it over. That single row is the
strongest argument in this document, and it is an argument about *IPC*, not
about Python.

### 1.2 Where opening a frame's 1.4 s goes

From `Session.LoadClock` (`SPEKTRAFILM_CANVAS_LOG=1`), warm:

```
decode 96 · preview-texture 230 · linear-tiff 12 · service.open 922
· solve 117 · reprint 36 · TOTAL 1415 · core=metal
```

Cold (no cached TIFF) is 2.34 s; the difference is the RAW decode and the
364 MB write. **This was ~8 s when the question in §0 was asked**, and the
journey there is the evidence for the answer:

| | open, warm | what changed |
|---|---|---|
| the app as found | ~8 s | running the numba core, because the engine was on a branch this checkout did not have |
| merge the GPU core | 7.3 s | `core=metal`; the *render* becomes 37 ms |
| build tier downscales lazily (`699a7c8`) | 5.0 s | `open` was resizing for every tier, including one usually unused |
| warm the service at launch (`61f3bd4`) | 3.85 s | the first request no longer pays 1.9 s of interpreter start |
| port the downscale to Metal (RFC-011 §11) | **1.4 s** | the last big CPU stage in `open` |

**Every one of those was a wiring, scheduling or kernel fix. None of them was
a language change, and a language change would have fixed none of them.** That
is the §0 answer in one table.

What is left, and none of it argues for Rust either:

- `service.open` 922 ms. The engine measures its own share at 278 ms on this
  frame; the rest is the round trip, the 364 MB read (0.11 s uncompressed) and
  per-session setup. Worth profiling, not worth rewriting.
- **~1.9 s of interpreter start and imports**, paid once per session and now
  hidden rather than removed. A native binary makes it ~0. This is the *entire*
  speed case for a language change, and it is one-time.
- The 364 MB linear TIFF, written by the client and read back by the service,
  because large data crosses the boundary as a path (contract §1). It must
  stay **uncompressed** — measured on the read side, LZW costs 1.6 s against
  0.11 s, so compressing it to save cache space would put more than a second
  back into every open. `TIFFHandoffTests` pins that.

### 1.3 What has to be bundled today

```
.venv                                   2.2 GB
  PySide6            1.2 GB   the dead PyQt frontend — not needed at all
  mlx                206 MB   needed: this is the render
  llvmlite + numba   149 MB   the reference path only (RFC-011 §3.3)
  colour-science      98 MB   0.8 ms per render (§2.2)
  scipy               90 MB   not in the reprint path at all
  pandas              50 MB   a colour-science dependency
  matplotlib          29 MB   scripts and QA only
  skimage             29 MB   one function, being ported to the GPU
  numpy               26 MB   glue
  exiv2               20 MB   `utils/io.py` — goes with the file boundary (§2.4)
  PyOpenColorIO       20 MB   not imported anywhere in src/spektrafilm
```

And `Service/ServiceClient.swift` locates all of it like this:

```swift
// The app lives at <repo>/modern_UI/Spektrafilm/...; walk up until
// `src/spektrafilm` is found.
var url = Bundle.main.bundleURL
for _ in 0..<8 { url.deleteLastPathComponent(); … }
…
let python = repo.appending(path: ".venv/bin/python")
```

**The app requires a checkout of this repository and a built virtualenv
sitting next to it.** There is no code-signing story, no notarization story,
no sandbox story, and no story at all for handing it to another person. This
is not a performance problem. It is an existence problem, and it is the reason
this RFC exists.

---

## 2. What actually depends on Python

The useful surprise from §1.3 is how little.

### 2.1 The render does not

`backends/metal/*.py` imports, in total: `mlx.core`, `numpy`, `threading`,
`time`, `contextlib`, `dataclasses`, and three internal modules. That is the
whole dependency surface of the thing that produces the picture. MLX is a C++
library with Python bindings, so the kernels are already native; the Python
around them builds argument lists.

### 2.2 colour-science is a *bake-time* dependency pretending to be a runtime one

98 MB (plus pandas' 50 MB) for **0.8 ms per render**. What it actually does at
render time is a small number of fixed matrix products and transfer curves —
RFC-007 A already established that colour-science belongs at setup time, and
RFC-011 folded the CAT02 round trip into a baked matrix rather than calling
`RGB_to_RGB` per pixel (trap 7).

The remaining calls are per-*session*, not per-pixel, and every one of them is
a pure function of the profile and the colourspace names. **They can be
precomputed into shipped constants.** That is a data change, not a port, and
it is checkable exactly: the baked constant either equals what colour-science
returns or it does not.

### 2.3 numba is the reference, and the reference must not be shipped or deleted

149 MB of llvmlite and numba contribute **0.0 ms** to a render on the Metal
core. RFC-011 §3.3 is emphatic that the numba path stays forever as the thing
the GPU path is checked against — *"the day a colour question arises, the
ability to re-run the same frame through the reference implementation is worth
more than the code it costs to keep."*

Both things are true at once and the resolution is obvious once stated:
**the reference is a development dependency, not a runtime one.** It stays in
the repo, in the parity harness, in CI. It does not go in the app.

### 2.4 OpenImageIO exists to serve the process boundary

`utils/io.py` reads the TIFF that the client wrote because the client and the
engine are different processes. Remove the boundary and this dependency, the
364 MB write, the 364 MB read, and `_write_rgba16`'s 10 ms per render all go
at once.

---

## 3. Options

| | what it is | interpreter start | IPC cost/render | bundle | reference kept | effort |
|---|---|---|---|---|---|---|
| **A** *(today)* | Python service, subprocess, file handoff | 1.9 s | 10 ms | **impossible** | yes | — |
| **B** | trimmed, frozen Python runtime **inside** the bundle | ~1.9 s | 10 ms | ~600 MB | yes | small |
| **C** | native binary (Swift/C++ over MLX-C) as a subprocess, same wire | ~0 | 10 ms | ~250 MB | yes, in dev | medium |
| **D** | native **library**, linked into the app, no process at all | 0 | **0** | ~250 MB | yes, in dev | large |

The bundle column for C and D is dominated by MLX itself, measured rather than
guessed: `libmlx.dylib` 20.9 MB + `mlx.metallib` **166.7 MB** = ~188 MB, plus
the baked profile data and the app. The metallib is large because it carries
kernels for all of MLX's operations; whether it can be trimmed to the ones this
pipeline dispatches is an open question and **not** assumed by this RFC.

### 3.1 B is a trap, and it is the tempting one

Dropping PySide6, matplotlib, jedi, babel and PyOpenColorIO takes 2.2 GB to
roughly 600 MB, and tools like PyInstaller will produce something that
launches. It looks like a week of work and an answer.

It is not an answer. It ships a Python interpreter and 600 MB of scientific
libraries inside a photo editor to run kernels that are already native, keeps
the 10 ms-per-render file handoff, keeps the 1.9 s start, and adds a permanent
packaging tax to every dependency change — with code signing and notarization
of a bundled interpreter as an ongoing cost rather than a one-off. **Take B
only as a stopgap if something has to be demonstrable to a person on another
machine before D lands**, and say so in the commit that does it.

### 3.2 D is the destination, C is how you get there safely

C and D differ only in whether the native core is behind a pipe or behind a
function call. That means C is not a detour: **it is D with the boundary still
in place**, which is exactly what makes it checkable — the same wire, the same
`rgba16` bytes, the same contract tests, and the existing Python service still
runnable next to it for comparison. Once C is at parity, D is deleting the
transport.

The prize in D is §1.1's second row: the file write is a third of a render, and
in D it does not exist. A live reprint would go from ~30 ms to ~13 ms, and
`open`'s 364 MB round trip to zero, because the client's decoded buffer is
already in the same address space (and on Apple silicon, already in the same
memory the GPU reads).

---

## 4. What is genuinely at risk

Stated plainly, because the failure modes here are the expensive kind.

1. **Colour correctness, silently.** RFC-010 exists because three colour bugs
   were live simultaneously with 750 tests passing and two produced plausible
   photographs. Every constant that moves from "computed by colour-science at
   startup" to "baked into the binary" is a chance to bake the wrong one.
   *Mitigation:* the baking script emits the constants **and** a test that
   re-derives them from colour-science and asserts equality. The bake is
   checked in; the check runs in CI, where the 98 MB dependency still lives.
2. **Losing the reference by accident.** If the Python path stops being run,
   it stops working, and the day it is needed it will not build.
   *Mitigation:* the parity harness (`scripts/gpu_native/parity.py`) runs in
   CI on every change, not on demand. A reference nobody exercises is not a
   reference.
3. **Driving MLX from a native host.** This is the single assumption the whole
   of C and D rests on, so it was checked rather than assumed. The installed
   MLX 0.32.2 ships everything a C++ host needs, next to the Python bindings:

   ```
   mlx/include/mlx/mlx.h        the C++ header
   mlx/lib/libmlx.dylib         the library the Python bindings themselves call
   mlx/lib/mlx.metallib         the compiled Metal kernels
   mlx/lib/cmake/               CMake package config
   ```

   So the kernels are not behind Python; Python is one caller of them. What is
   *not* yet verified is that `mx.fast.metal_kernel` — how RFC-005 writes bare
   Metal, and how most of `backends/metal` is built — is reachable and
   byte-identical from that API. *Mitigation:* §5 step 1 is a spike that does
   nothing except run one existing kernel from a non-Python host and compare
   the bytes. If it fails, this RFC is wrong and B becomes the answer by
   default.
4. **Rewriting instead of relinking.** `HANDOFF-GPU-NATIVE.md` §4's line still
   holds: same math, same measured data, same node boundaries, only the
   executor changes. The nodes are already MLX; C and D must move the *host*,
   not re-derive the pipeline. Any node whose math changes is a separate RFC.

---

## 5. Sequence

Each step is independently valuable and independently abandonable.

1. ~~**Spike MLX from a non-Python host**~~ (§4.3) — **done 2026-09-10, it
   passes.** `scripts/gpu_native/native_host_spike/` records what the shipping
   `backends/metal` kernels hand to `mx.fast.metal_kernel` — name, MSL source
   and header as strings, every input buffer, grid and threadgroup — and
   replays them through `mlx::core::fast::metal_kernel` from a C++ binary that
   links `libmlx.dylib` and has no Python in its image (`otool -L`). Four
   kernels, chosen for the paths that would diverge:

   | kernel | what it exercises | result |
   |---|---|---|
   | `spk_log10_guarded` | `log10`, the `max(·,0)+1e-10` guard, denormals, negatives | byte-identical |
   | `spk_boost` | `exp` on a highlight ramp, early-out branch | byte-identical |
   | `spk_curves` | binary search over a repeated knot and a non-monotonic toe, `interp_channel` | byte-identical |
   | `spk_matmul3` | fma contraction in the 3×3 | byte-identical |

   **The gate is a real one:** re-running the same source under
   `MathMode::Fast` moves `spk_boost` and `spk_matmul3` off byte-identical by
   up to 1.1e-5 absolute, so the comparison detects compile-level differences
   rather than passing vacuously. Two consequences:

   - **C is available.** The one assumption both C and D rest on holds.
   - **The native host must keep `CompileOptions{MathMode::Safe}`** — MLX's
     default. Built with relaxed or fast math it drifts past RFC-011's float32
     storage epsilon silently, which is exactly §4.1's failure mode.

   Coverage is total for this pipeline: `template_args`, `init_value`,
   `atomic_outputs` and `ensure_row_contiguous` appear nowhere in
   `backends/metal/`, so every dispatch in the engine is source + header + the
   row-contiguous default + a 1-D grid.
2. ~~**Finish the GPU resize**~~ — **done** (RFC-011 §11, merged `d8c4881`).
   `open` 2.6 s → 278 ms in the engine, 1.4 s end to end in the app. Held to
   float32 storage epsilon against skimage (max abs 1.2e-7); the edge mode was
   the trap, as expected — skimage's `mode='reflect'` is the numpy-pad name and
   maps to ndimage *mirror*, not scipy reflect.
3. **Bake the colour-science constants** (§2.2), with the re-derivation test.
   Removes 148 MB and the last per-render third-party call. Valuable even if
   this RFC goes no further.
4. ~~**Split the service in two**~~ — **done 2026-09-10.** `service/engine.py`
   holds `RenderEngine`: typed arguments in, in-memory results out. It has no
   workspace, parses no JSON, and writes no file. `service/service.py` keeps
   the nine wire methods and is now only three things — validate the request
   shape, call **one** engine method, materialise the result to a path.

   The rule, stated so it can be checked: **the engine returns pixels, the
   service turns pixels into paths.** `tests/test_rfc012_engine_seam.py`
   asserts it — including an AST guard that fails if `engine.py` grows a
   `save_image_oiio` / `tofile` / `write_text` — and renders a frame through
   `RenderEngine` alone, with no service and no temp directory, which is the
   option-D rehearsal.

   What this buys D: `_write_rgba16` and the JSON layer are now in one file
   and nothing depends on them, so removing the process is a deletion. What it
   cost: nothing at runtime — the same 757 tests pass, and the wire is
   unchanged (no new method, no renamed field, no version bump).

   One thing the split found on its own: `RenderSession.workspace` was stored
   and never read. The session never had file business; only the service did.

   A caution from doing it. The first cut dropped `transport_version` and
   `schema_version` from `capabilities`, which contract §2 makes a
   *launch* failure on FE, not a warning — a split that "only moves code"
   still moves the wire if the wire is assembled from both halves. The
   capability key set is now pinned by a test.
5. **C — the native host behind the same wire.** Contract unchanged, so the
   frontend does not move and every existing test applies. Both services
   runnable side by side; ship whichever passes parity.
6. **D — link it in and delete the transport.** Needs a contract amendment
   (§1's "the boundary is the wire" is retired here, not before) and it should
   be its own RFC, because removing single-flight and the file handoff changes
   the frontend's scheduler as much as it changes the backend.

---

## 6. The splash screen

Asked for separately, and worth answering separately, because it is a
different kind of thing.

A startup screen — Photoshop's, Capture One's — that appears immediately and
holds while the engine warms is **worth having on its own merits**, and it
should be built regardless of which option above is chosen:

- It gives the app a face during the ~1.9 s of service warm-up that currently
  happens behind a window showing an empty canvas.
- It is the honest place to report *which engine started* — `core=metal`, the
  thing §1 of `HANDOFF-GPU-WIRING.md` shows nobody could see — and to fail
  loudly if the engine did not start at all, which today produces a working
  window that silently cannot render.
- It is where a first-run "no engine found" message belongs, and that message
  is going to be needed under option B or C too.

But it must be understood for what it is. **A splash screen hides the 1.9 s
once; it does nothing about the 10 ms per render, the 364 MB round trip, or
the fact that the app cannot be given to anyone.** Building it and calling the
problem solved would be the worst outcome of this document. Build it because a
professional application should have one — and land §5 anyway.

---

## 7. Recommendation

Step 2 is already done. Do **1 and 3** now: they are needed under every option,
and step 3 alone removes 148 MB and the last per-render third-party call.

Note what the table in §1.2 means for urgency: the speed problem is
substantially *solved*, by fixes that had nothing to do with the language. So
this RFC should now be read purely as what it is — a **distribution** RFC. The
app is fast. It still cannot be given to anyone.

Then **C**, then **D** as its own RFC.

Do **not** do B unless something must be demonstrated on another machine
first — and if it is done, do it as an explicitly labelled stopgap with a date
on it, because a working bundle is exactly the kind of thing that removes the
pressure to build the right one.
