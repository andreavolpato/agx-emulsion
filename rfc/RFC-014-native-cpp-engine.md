# RFC-014 — A C++ render engine, linked into the app

| | |
|---|---|
| **Status** | **Implemented 2026-09-10**, steps 1-5. The app renders with `.venv` renamed away. Step 6 partly done; §8 records what is left |
| **Decides** | RFC-012's option D, in C++ rather than Swift, and without MLX |
| **Supersedes** | RFC-012 §3's options A/B/C as the shipping answer. RFC-012's *analysis* stands; its conclusion moves |
| **Depends on** | RFC-011 (the Metal kernels), RFC-012 §5 steps 1/3/4 (the gate, the baked constants, the engine seam) |
| **Owner** | The porting loop (§5) is the user's. This document is the map, the boundary and the traps |

---

## 0. The decision

**One binary. C++ engine, Metal compute, linked into the Swift app. No Python,
no MLX, no third-party install.**

The app today cannot render without `<repo>/.venv/bin/python`, and neither can
the "native host" — it is a proxy that `exec`s exactly that interpreter
(ARCHITECTURE §8.5). A first install therefore means: clone a repo, build a
2.2 GB virtualenv, and keep both next to the `.app`. That is not a product.

Two facts, both measured, make the port far smaller than RFC-012 assumed.

### 0.1 MLX is not doing any of the maths

Every `mx.*` call in `backends/metal/`, counted:

```
46  mx.array         wrapping a buffer
 7  mx.float32       5  mx.eval        5  mx.contiguous
 2  mx.zeros         2  mx.transpose   1  mx.max
 2  mx.fast          = mx.fast.metal_kernel, the kernel compiler
```

No matmul, no convolution, no reduction, no FFT. **MLX is a buffer allocator
and a kernel-compilation harness.** The arithmetic is ~600 lines of *our own*
MSL, handed to `mx.fast.metal_kernel` as source strings, which wraps each body
in a function signature. Every one of those responsibilities is a Metal API
call:

| MLX | Metal |
|---|---|
| `mx.fast.metal_kernel(source:)` | `newLibraryWithSource:` + `newComputePipelineStateWithFunction:` |
| `mx.array` | `MTLBuffer` |
| `mx.eval` | `commit` / `waitUntilCompleted` |
| `mx.contiguous`, `zeros`, `transpose`, `max` | our layout; three trivial kernels |

**Consequence: `mlx.metallib` (174.8 MB) and `libmlx.dylib` (21.9 MB) are not
needed.** They are MLX's own operator library, and we call none of it. An
earlier draft of this argument treated ~198 MB of MLX as an irreducible floor
for any host, Python or native. That was wrong, and it was the number that made
option D look expensive.

### 0.2 The part that must not change is the part that transfers verbatim

| | |
|---|---|
| MSL kernel bodies | **~600 lines — move unchanged** |
| Python host/setup in `backends/metal` | ~1,160 lines → C++ (buffer plumbing, dispatch) |
| Setup maths (`colour_baked`, `fused_gamut_cam16`, `fused_tc_b`, `fused_spectral`) | ~940 lines → C++ (small arrays, no images) |
| Profile + colour data | already JSON and a 21.9 KiB baked `.npz` |

The kernels are the easy half. **The ~1,100 lines of setup maths is where the
work is** — building the Hanatos `tc_lut`, the density curves, the enlarger and
scanner LUTs, and the CAM16-UCS `C_max` table. It is small-array numpy over
measured data, not image processing, and it runs once per stock pair.

### 0.3 Why C++ and not Swift

Swift would be the shorter path — the app is already Swift, `MTLDevice` is
first-class there, and there would be no language boundary at all. The decision
is C++ anyway, for one reason that outlives this release:

**Portability.** Metal ties the Swift path to Apple permanently. A C++ engine
keeps a Windows/Linux future open, with the GPU layer swapped for Vulkan behind
an interface. Nothing else about the engine is platform-specific: it is
constants, LUTs, a topology walk, and compute dispatch.

That reason is accepted, and §4 is honest about what "swap Metal for Vulkan"
actually costs, because it is not free and it is not zero-risk.

---

## 1. What the binary contains

```
Spektrafilm.app/
  Contents/MacOS/Spektrafilm        Swift + the C++ engine, statically linked
  Contents/Resources/
      default.metallib              compiled kernels (ours)
      profiles/*.json               film and paper measurements
      colour_constants.bin          the baked 21.9 KiB
      FilmCovers/, StockCatalog.json
```

Expected size **~15 MB**, against 7.6 MB today and ~400–500 MB for a frozen
Python bundle. Nothing to install. Signable and notarisable like any app.

Python does not disappear from the repo — it remains the **reference and the
test oracle** (§3), as a development dependency that never ships.

---

## 2. The Swift ↔ C++ boundary

This is the question the decision turns on in practice, and the answer is that
it is a solved problem *if the boundary is narrow and stable*. Three mechanisms
exist; the recommendation is the first.

### 2.1 Use a C ABI, not Swift's C++ interop

Xcode 26.6 / Swift 6.3 supports direct C++ interop
(`-cxx-interoperability-mode=default`), and it works. Prefer a hand-written
`extern "C"` surface anyway:

- **It is ABI-stable.** C++ name mangling, `std::` layouts and Swift's interop
  rules all move between toolchains. A C ABI does not.
- **It is testable from three languages.** The same `.h` can be driven from
  Swift, from C++ tests, and from Python via `ctypes` — which is what keeps the
  numba parity oracle (§3) pointed at the shipping code rather than a copy.
- **It forces the boundary to stay narrow.** Direct interop makes it easy to
  leak `std::vector<Node>` across the line and end up with the transport
  problem again in a new form.

The engine's API is already narrow — `service/engine.py` is the shape to copy,
because RFC-012 §5 step 4 built it precisely as the seam this attaches to:

```c
// SpektrafilmEngine.h  — the whole surface
typedef struct spk_engine spk_engine;
typedef struct spk_session spk_session;

spk_engine*  spk_engine_create(const char* resources_dir, id_mtl_device device);
void         spk_engine_destroy(spk_engine*);

spk_status   spk_warm_up(spk_engine*, const char* film, const char* print);
spk_session* spk_open(spk_engine*, const spk_image* input, const char* params_json);
spk_status   spk_set_params(spk_session*, const char* params_delta_json);
spk_status   spk_reprint(spk_session*, spk_tier, spk_result* out);
spk_status   spk_solve(spk_session*, const char* target, char** solved_json);
void         spk_session_release(spk_session*);

const char*  spk_last_error(spk_engine*);   // never throws across the boundary
```

Params stay JSON. They are small, the schema already exists
(`service/schema.py`), and a struct-per-parameter surface would break every
time a slider is added — the thing contract §1 exists to prevent.

**Errors never cross as exceptions.** Every entry point is `noexcept` with a
status code and `spk_last_error`; a C++ exception unwinding into Swift is
undefined behaviour.

### 2.2 Share one `MTLDevice`, and stop copying pixels

The prize is not only the removed dependency. Today a render crosses the
boundary as a **364 MB file** in each direction, and `_write_rgba16` is 50–64 %
of a render at 45 MP (RFC-012 §1.1 as re-measured). In-process, it is a
pointer.

Swift already owns an `MTLDevice` (`Renderer.device`). Pass it in at
`spk_engine_create` and the engine renders **into a texture the canvas already
has**:

```
Swift: renderer.device ──► spk_engine_create(...)
Swift: spk_reprint(session, tier, &result)
       result.texture  ──► MTLTexture the Renderer draws, zero copy
```

Use **metal-cpp** on the C++ side (Apple's single-header C++ bindings for
Metal). It is not in the SDK — it is a separate source download that gets
vendored into the repo. That is a *source* dependency, not an install one, so
it does not violate §0. Objective-C++ (`.mm`) is the alternative and is more
familiar, but it is Apple-only by construction, which defeats §0.3.

**Ownership rule, stated once:** Swift owns the device and the drawable; the
engine owns everything it allocates and frees it in `spk_session_release`. No
buffer is freed by the side that did not allocate it.

### 2.3 Build integration

One Xcode project, two targets: a static library for the engine, and the app.
`.cpp` files get `CLANG_CXX_LANGUAGE_STANDARD = c++20`; the app gets the
`.h` via a bridging header. `Tools/gen-project.py` already generates
`project.pbxproj` from the filesystem and must learn the new target — that is
the only build-system change.

The `.metal` sources compile with the app, into `default.metallib`, exactly as
`Canvas/Shaders.metal` does now. **The kernels stop being runtime-compiled
strings and become build-time artefacts**, which removes a per-launch cost and
makes a broken kernel a build failure instead of a first-render failure.

---

## 3. Correctness: numba stays the oracle

RFC-011 held every ported node to **float32 storage epsilon** against the numba
reference. That bar and that method carry over unchanged; only the language on
the other side changes.

```
Python (dev only)                     C++ engine (shipped)
  numba reference  ──── dE / max|Δ| ────  spk_* via ctypes
       ▲
  scripts/gpu_native/parity.py
```

Because the C ABI is callable from `ctypes`, the existing harness drives the
**shipping binary** rather than a reimplementation of it. Use the 1 MP frame
(`tests/Test_image/_smoke_1mp.tif`): a run is seconds, and a check affordable
on every change is worth more than one run at the end.

Grain and glare must be off for any pixel comparison — they are the only
stochastic stages, and a correct port looks broken without this (AGENTS trap 1;
it fooled this session once already).

---

## 4. Portability, honestly

The C++ decision is justified by a Windows future. What that actually costs:

**Portable with no work:** the setup maths, the topology walk, the parameter
schema, the profile loading, the session cache. This is the ~1,100 lines that
dominate the effort, and it is plain C++ over small arrays.

**Not portable:** the ~600 lines of MSL, and the dispatch layer around them.
The *maths* transfers — a Gaussian blur is a Gaussian blur — but MSL is not
GLSL, and Metal's binding model is not Vulkan's descriptor sets.

**The recommendation, if Windows is genuinely wanted:** do not hand-maintain
two kernel languages. Author each kernel once and cross-compile — write in
HLSL or GLSL, compile to SPIR-V for Vulkan, and use SPIRV-Cross to emit MSL for
Metal. That is a real toolchain with real friction, and it should be a decision
taken **before** the kernels are ported, not after. Porting MSL→C++-driven-MSL
now and then rewriting to SPIR-V later is the one sequencing mistake available
here.

**Also not portable, and worth knowing now:** the frontend's RAW decode is Core
Image. A Windows build needs LibRaw or equivalent, and the two will not agree
on a decode — which is a *look* difference, not a bug (AGENTS trap 12).

If Windows is a "maybe someday", C++ still costs little over Swift. If it is a
commitment, the SPIR-V decision belongs in §5 step 1.

---

## 5. The porting loop

**This loop is the user's to run.** It is written to be repeatable per node, so
that progress is countable and a regression is attributable to one node.

Order is by dependency, not by size: `preprocess` first because everything
reads its output, `scanning` last because it is what the eye judges.

For each node in `pipeline._topology`:

1. **Pin the reference.** Run the node under numba on the 1 MP frame, save the
   input and output taps. This is the contract for the port.
2. **Move the MSL body verbatim** into a `.metal` file. Do not retype it; a
   transcription error in a density curve is a plausible-looking photograph.
3. **Write the C++ host side**: bind constants once at pipeline construction,
   allocate outputs, dispatch, one `MTLComputeCommandEncoder` per node.
4. **Compare against the pinned tap** at float32 storage epsilon. Grain and
   glare off.
5. **Only then** move to the next node. A node that is "nearly right" is a node
   that will be debugged twice.

Step 0, before any node: **stand up the shell** — `spk_engine_create`, the
resource loading, the baked constants, and one trivial node end to end through
Swift. A boundary that works for one node works for twenty-one.

### 5.1 Known traps, each already measured

1. **Fast math changes the picture.** MLX compiles with
   `MathMode::Safe`; Metal's `MTLCompileOptions.fastMathEnabled` has
   historically defaulted to **true**. RFC-012 §5 step 1 measured `exp` and fma
   contraction drifting by up to **1.1e-5** under fast math — past the float32
   bar, silently. Set it explicitly and assert it in a test.
2. **`preprocess.crop_rescale` has no Metal body today.** It is 1 of the 21
   default nodes and still runs on the reference path — a port, not a
   translation.
3. **`preprocess.geometry` is bound but pruned** at default params. It has a
   Metal body that a default render never exercises; test it with a non-identity
   crop or it will be wrong the first time someone crops.
4. **Grain must reproduce.** `grain_sampler='exact'` derives every chunk's
   stream from a fixed `SeedSequence`, and chunking the i.i.d. draws creates no
   seam — but the *blurs* do, and need ~4 px halos if tiled (AGENTS traps 1, 9).
5. **NaN in the measured profiles is load-bearing.** Portra 400 has 22 NaN in
   `channel_density`; the reference lets them propagate and zeroes them in
   `density_to_light`. Sanitise outside the loop, never with an in-kernel
   branch (AGENTS traps 2, 3).
6. **The engine must say what it is.** `render_core` today probes what the
   process can *reach*, not what a session *uses*, and that hid a real bug this
   week (a stock change silently demoting a session to numba while
   `capabilities` still said `metal`). The C++ engine reports what it actually
   loaded — the metallib it opened, the device it got — not what is available.

---

## 6. Sequence

| step | what | gate |
|---|---|---|
| 1 | Decide SPIR-V vs MSL-only (§4). Blocks kernel work | a written answer |
| 2 | The shell: C ABI, static lib, shared `MTLDevice`, one node end to end | a picture on the canvas from C++ |
| 3 | Setup maths: baked constants, profiles, LUTs, `C_max` | `tc_lut` and curves match numba |
| 4 | Nodes, in the §5 loop | every node at float32 epsilon |
| 5 | Delete the transport: no JSON-RPC, no rgba16 file, no `.venv` | the app renders with Python uninstalled |
| 6 | Retire `native/`, the session cache's process assumptions, and RFC-012 options A–C | — |

Step 5 is the one that answers the question this document exists for, and it
has a one-line test: **rename `.venv`, launch the app, open a frame.**

**Run 2026-09-10, and it passes.** With `<repo>/.venv` renamed away:

```
session: service warm · core=native-metal · engine spektrafilm.native
session: warm_up: 296 ms · core=native-metal
session: open path (ms): decode 35 · preview-texture 6 · linear-tiff 39 ·
         service.open 440 · solve 3 · reprint 46 · TOTAL 572
snapshot 1600x900 → /tmp/rfc014-final.png
```

572 ms from a file to a developed photograph on the canvas, with no Python
process, no `.venv`, and no file between the render and the texture.

---

## 7. What this costs, stated plainly

This is the largest single piece of work in the project. It is ~1,700 lines of
Python to move, of which ~600 transfer verbatim, plus a build-system change and
a new test path — against a backend that today works, is fast (45 MP in ~1 s),
and is measured to float32 epsilon.

The argument for doing it is not performance. It is that **the app cannot be
given to anyone**, and every alternative examined — freezing Python, a proxy
host, a smaller venv — leaves that true or trades it for a 400 MB bundle and a
process boundary that costs half of every render.

The argument for doing it *now* is that the two hardest questions are already
answered: the kernels are ours and transfer unchanged, and the colour science is
already baked to 21.9 KiB of constants.


---

## 8. What was built, what it measures, and what is left

Written after the fact, so the map above can be read against the territory.

### 8.1 Where the code is

```
engine/include/spektrafilm/spk_engine.h    the whole C ABI (§2.1)
engine/src/core/                           the setup maths -- no GPU, no pixels
engine/src/shaders/                        the kernels, MSL, transferred verbatim
engine/src/gpu/                            the GPU interface + its Metal backend
engine/src/pipeline/                       the 21-node graph, the session, the ABI
engine/tools/bake_resources.py             every run-time constant, baked
engine/tests/                              five harnesses, described below
engine/build.sh                            lib / dylib / metallib / bundle / tests
```

The Swift side is `modern_UI/Spektrafilm/Spektrafilm/Service/EngineClient.swift`.
`ServiceClient.swift` is deleted, and with it the subprocess, the JSON-RPC
framing, the workspace directory and the `PYTHONPATH` invariant.

### 8.2 The decision §6 step 1 was waiting for

**MSL-only**, with the kernels behind a narrow `Gpu` interface (five verbs;
nothing above it names Metal) so a Vulkan backend can be added beside them.
Authoring in HLSL → SPIR-V → SPIRV-Cross would put two build tools and a
cross-compiler between ~600 lines of already-measured MSL and float32 parity,
and Windows is not scheduled. §4's sequencing warning is answered rather than
ignored: the kernels were *not* retyped, and the abstraction is where the
rewrite would attach.

### 8.3 What parity actually measures

| harness | what it holds | result |
|---|---|---|
| `parity_setup.py` | 227 setup quantities against colour-science, scipy, numpy | 0 failed, 86 bit-exact |
| `parity_schema.py` | the wire schema and digested params, 6 stock pairs | identical |
| `parity_render.py` | the picture, 27 configurations, 1 MP frame, vs numba | 0 failed, max 2.3e-5 |
| `parity_grain.py` | grain's mean/std/skew at 9 densities | 0 failed |
| `gpu_smoke` + `check_math_guard.sh` | the boundary, and that the trap-1 guard can fire | 0 failed |

The render bar is **measured, not asserted**. RFC-011 held each *node* to
float32 storage epsilon; end to end through 21 nodes the accumulated error is
larger, and it is the GPU's rather than the port's -- on the same frame against
the same reference, the already-validated Python Metal core reaches 1.9e-5 and
this engine reaches 2.3e-5. So the bar is 3e-5 absolute, paired with a
count-level bar (essentially every value within one 16-bit count) so a
systematic shift cannot hide under the absolute one. The print-balance bug
below was 2e-4 over 93 % of the frame and failed both.

### 8.4 The traps, revisited

Every trap in §5.1 was real. What each cost:

1. **Fast math.** Confirmed by measurement, not by reading: `MTLCompileOptions`
   defaults to `MathModeFast` on Xcode 26.6 (`mathMode` reads 2), and the
   offline compiler defaults to fast math too. `build.sh` sets
   `-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise`, and because a
   build flag is exactly the kind of guard that stops being read,
   `spk_math_probe` computes `a*b - a*b` -- exactly 0 under fast math, the fma
   error term under safe -- and `spk_engine_create` refuses to start if it comes
   back zero. `check_math_guard.sh` builds a fast-math library and asserts the
   refusal, so the guard is known to be able to fire.
2. **`preprocess.crop_rescale` has no Metal body.** Ported. At the shipped
   defaults its only job is the film's pixel pitch, and that is now a *per-run*
   value -- see 8.5.
3. **`preprocess.geometry` is pruned at default params.** Covered by three
   parity cases (`crop`, `crop_rotated`, `quarter_turn`, `flips`), all at
   1 count.
4. **Grain must reproduce.** It does, distributionally: `parity_grain.py`.
   Nothing tiles, so the blur seam the trap warns about cannot arise.
5. **NaN in the measured profiles is load-bearing.** Neutralised once, outside
   the loop, in `prepare_spectral_constants`; no in-kernel branch.
6. **The engine must say what it is.** `capabilities.backend.render_core` is
   `"native-metal"`, and it reports what was *loaded* -- the device it got and
   the math mode the probe measured -- not what the process could reach.

### 8.5 Two bugs found in the *reference*, not in the port

Both are reproduced deliberately or diverged from deliberately, and the
render-parity harness asserts the divergence so the port cannot quietly
inherit either.

- **`camera.lens_blur_um` does nothing on the Python engine.**
  `_build_topology` derives its sigma from `pixel_size_um`, which is `None`
  until the first render, so `is_identity` is always true and the node is
  pruned unconditionally. Measured: `max |out(0) - out(50 um)| == 0.0` exactly.
  The C++ engine computes every blur sigma per run, so the parameter works.
  The harness fails if the two ever agree there.
- **The print balance evaluates its grey in sRGB.**
  `FilmingStage._simple_rgb_to_density_spectral` calls `_rgb_to_film_raw(rgb)`
  with no `color_space`, so it takes that method's default -- `"sRGB"`, not
  `io.input_color_space`. Reproduced and named
  (`kMidgrayProbeColourSpace`); using the input space instead moved the midgray
  spectral density by 7.6e-5 and every rendered print by 2 counts over 93 % of
  the frame.

And one about the model rather than either engine: above
`dir_couplers_amount` ≈ 1.736 (bisected, kodak_portra_400) the coupler
inverse's own exposure axis stops being monotonic, and `np.interp` requires an
increasing `xp`. Past that the reference's output is a product of numpy's
internal search. **The wire allows the parameter up to 4.0**, so the schema's
range is wider than the maths supports.

### 8.6 Size and speed

| | |
|---|---|
| app bundle | **20 MB**, of which 11 MB is baked resources |
| against | 7.6 MB + a 2.2 GB venv + a repo checkout |
| open a 1 MP frame, cold | 572 ms total (`warm_up` 296 ms, `open` 440 ms, reprint 46 ms) |
| warm render at 1.9 MP | 62 ms full, 53 ms reprint |
| the deleted file | 364 MB per `open`, each way, plus 10 ms of every 30.6 ms reprint |

The 20 MB is above §1's ~15 MB estimate, and the difference is all data: 6.0 MB
of baked colour constants (the Hanatos irradiance spectra are 5.97 MB of that,
kept float16 exactly as the reference stores them) and 5.8 MB of film profiles
for all 28 stocks. Both are trimmable and neither is code.

### 8.7 What is left

Three methods on the wire are **not** ported, and the engine refuses them by
name rather than returning something plausible:

- `export` — writes a file; the render exists, the writer does not.
- `export_di` — the DI package: three files plus the shipped print-preview
  LUTs.
- `preview_stock_lut` — needs the `.cube` machinery.

None is on the path from opening a frame to seeing it; each is a subsystem
rather than a node. `Exporter.swift` still calls them and will surface the
refusal.

Also open:

- **Per-node timings are off by default.** Dispatches batch into one command
  buffer, so a timer around a node body measured *encode* time -- 0.003 ms for
  a full-frame matmul. `node_times` is empty unless
  `SPEKTRAFILM_NODE_TIMINGS=1`, which flushes per node and gives up the
  batching. An empty field is honest; a plausible wrong number is not.
- **The session LRU is gone, deliberately.** A session is a pointer the caller
  holds, so the caller's retention *is* the cache and
  `spk_session_release` is when it ends. `capabilities.session_cache` reports
  the sessions currently open. RFC-013's numbers were about a cache the wire
  needed; this boundary does not.
- **`native/`** (the stdio proxy host) and RFC-012's options A-C are now dead
  and should be removed -- §6 step 6.
- **The Python engine stays**, as the reference and the test oracle (§3). It is
  a development dependency that never ships, and every harness above depends
  on it.
