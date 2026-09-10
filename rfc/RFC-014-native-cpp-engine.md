# RFC-014 — A C++ render engine, linked into the app

| | |
|---|---|
| **Status** | Proposed. Decision taken 2026-09-10; not started |
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
