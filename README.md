# Filmify

A macOS film and print simulator. Open a RAW or TIFF negative, choose a film
stock and a paper, and watch a physically-modelled render settle in under a
second — grain, halation, couplers, enlarger dichroics and all.

**Filmify is the application.** The simulation it runs is **spektrafilm** — the
engine, the 28 measured film profiles and the print-preview LUTs baked from
them are Andrea Volpato's, licensed CC BY-SA 4.0. This repository is the
desktop product built on top of that engine. See [Licensing](#licensing).

```
┌─ Filmify.app ─────────────────────────────────────────────────────────┐
│  SwiftUI + Metal, macOS                                               │
│                                                                       │
│  Session ── Renderer ── EngineClient                                  │
│                              │  spk_engine.h, a hand-written C ABI     │
│                              ▼                                        │
│  ┌─ engine/ ── C++20, compiled into this target ───────────────────┐  │
│  │  core/      setup maths: colour, profiles, curves, CAM16        │  │
│  │  gpu/       a five-verb interface + its Metal backend           │  │
│  │  shaders/   the kernels, MSL, in spektrafilm.metallib           │  │
│  │  pipeline/   the 21-node graph, the session, the C ABI          │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│  Resources/engine/  baked constants, 28 profiles, the metallib        │
└───────────────────────────────────────────────────────────────────────┘
```

**One binary. No Python, no subprocess, no virtualenv at run time.** The engine
is statically compiled into the app and takes pixels in, handing back an
`MTLTexture` the canvas draws — zero copy, no file handoff. A 45 MP frame opens
in about a second.

---

## Build

Requires macOS 15+, Xcode 26.6 and an Apple-silicon Mac. `ARCHS = arm64` only.

```bash
engine/build.sh bundle     # compile the engine + kernels, rsync baked resources into the app
cd modern_UI/Spektrafilm
xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm \
           -derivedDataPath build/DerivedData build     # → Filmify.app
```

`engine/build.sh bundle` is **not optional and not automatic**: the app target
has a pre-build phase (`Tools/check-bundle-resources.sh`) that fails the build
when the resources are absent. The dangerous case is *stale*, not absent — re-run
`engine/build.sh bundle` after anything under `engine/resources/` changes.

Launch it, or use the snapshot harness:

```bash
build/DerivedData/Build/Products/Debug/Filmify.app/Contents/MacOS/Filmify \
    --snapshot 1200x700 /tmp/out.png --open frame.tif --wait 40
```

### Test

```bash
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests \
           -derivedDataPath build/DerivedData test      # 139 tests, ~7 s
engine/tests/check_math_guard.sh                        # the fast-math guard can fire
engine/build/gpu_smoke engine/resources/spektrafilm.metallib
```

Two schemes: `SpektrafilmFrontend` runs everything except the class that renders
a real negative (~2 s, no pixels); `SpektrafilmTests` is the full suite.
`SpektrafilmTests` is the target's name and has nothing to do with the product
name — see [Naming](#naming).

Four tests skip on a fresh clone: they need camera fixtures under
`tests/Test_image/`, which are multi-GB and deliberately not carried. Drop
`_smoke_1mp.tif` there (a 1 MP linear ProPhoto TIFF) and they run. Nothing else
needs it — `OpenPathTests` and `DecodeSeparationTests` skip rather than fail.

---

## What is in here, and what is deliberately not

| | |
|---|---|
| `modern_UI/Spektrafilm/` | the app: Swift sources, tests, `Tools/`, the Xcode project |
| `modern_UI/design/`, `reference_layout/`, `film_covers/` | the drawing the UI was measured against, and the stock cover art |
| `engine/` | the C++ engine, its MSL kernels, its C ABI, its parity harnesses |
| `engine/resources/` | **tracked** — the baked constants, 28 profiles, print-LUT index, metallib |
| `engine/third_party/metal-cpp/` | vendored Apple metal-cpp (Apache-2.0) |
| `rfc/`, `HANDOFF-*.md`, `ARCHITECTURE.md`, `AGENTS.md` | the design record and the traps |

Not here, on purpose: the **Python reference implementation**. Upstream
`spektrafilm` ships a numba/colour-science engine under `src/`; this repository
carries only the C++ port. The Python engine never shipped and never will — but
it is the oracle several harnesses compare against, so see below if you need it.

### Naming

The product is **Filmify**; the engine, profiles and LUTs are **spektrafilm**.
That split is deliberate and the licence asks for it: `SPEKTRAFILM_LICENSE.txt`
says not to use "spektrafilm" in product branding without asking, while
explicitly welcoming the factual reference. The About panel says which is which.

Internally the Xcode **target**, the **scheme** and the Swift **module** are
still called `Spektrafilm`. Renaming those buys nothing a user can see and
breaks every `BlueprintName` in the schemes, so they stay. Only the *product*
name, the bundle id (`com.hanze.filmify`) and the user-visible strings are
Filmify.

### Rebaking the engine resources

`engine/resources/` is 15 MB of generated data that is **checked in**, because
regenerating it needs the whole Python reference package plus nine native
dependencies (scipy, matplotlib, exiv2, OpenImageIO, rawpy, lensfunpy,
scikit-image, opt-einsum, numpy). The engine itself needs none of them, and a
desktop checkout should not have to install a colour-science stack to build an
app. So the output travels and the generator is the tool of record:

```bash
# from a checkout that HAS the Python tree, e.g. the upstream fork:
PYTHONPATH=src .venv/bin/python engine/tools/bake_resources.py --out engine/resources
```

Re-bake only when a profile, LUT or colour constant changes, then commit the
result. `Tools/gen-catalog.py` reads the catalog straight out of
`engine/resources/`, so the app's stock list cannot disagree with what the
engine will actually load.

### Parity harnesses

`engine/tests/parity_*.py` drive the **shipping dylib** through `ctypes` and
compare it against the Python reference. They are the reason the C++ port can
be trusted, and they need that reference:

```bash
PYTHONPATH=<reference-checkout>/src .venv/bin/python engine/tests/parity_setup.py
```

Point `PYTHONPATH` at a checkout of the upstream fork, build the dylib first
(`engine/build.sh dylib`), and use the 1 MP frame — parity is a correctness
question, not a performance one.

---

## Licensing

| what | licence | file |
|---|---|---|
| Filmify, the app | GPL-3.0-or-later | `LICENSE` |
| the C++ render engine | GPL-3.0-or-later | `LICENSE` |
| film and paper profiles, and the print-preview LUTs derived from them | CC BY-SA 4.0 | `SPEKTRAFILM_LICENSE.txt` |
| vendored metal-cpp | Apache-2.0 | `engine/third_party/metal-cpp/LICENSE.txt` |

All four texts ship inside the `.app` (`Tools/bundle-licenses.sh`, checked by
`LicensingTests` and the pre-build phase) and are reachable from
**Filmify → About Filmify**. That panel is an obligation rather than polish:
CC BY-SA names "an app's About screen" by example as a place attribution must
survive, and the GPL wants a route to the corresponding source.

The profiles ship **unmodified**. The 8 print-preview LUTs are **derivatives**
— the licence says a LUT is "a direct encoding of the information in the
original profiles" — so they carry the same CC BY-SA 4.0. What was changed and
how is recorded in `Resources/Licenses/Profiles-and-LUTs-CHANGELOG.txt`.

---

## Status

Working and used daily. Real gaps, stated: there is no CI, no auto-update and
no crash reporting; the build is arm64-only; and shipping a notarised DMG still
needs a Developer ID certificate. `HANDOFF-DISTRIBUTION.md` is the full
checklist and `HANDOFF-OPEN-PATH.md` the current performance work.
