# HANDOFF-DISTRIBUTION.md — what ships, what is still machine-bound, what is missing

Written 2026-09-10, after RFC-014 linked the render engine into the app. It
answers one question first — **does the app carry its own data, or is it still
tied to this machine?** — and then lists what stands between the current build
and something a stranger can download and run.

Everything below was measured on this checkout, not inferred. Where a claim is
a *test*, the command is given.

---

## 1. The answer: the data is bundled, and the app is relocatable

**Verified.** The `.app` was copied to `/tmp/relocation-test` (no repository
anywhere above it), and **both** `<repo>/.venv` and `<repo>/engine/resources`
were renamed away. It opened a frame and rendered it:

```
session: service warm · core=native-metal · engine spektrafilm.native
session: open path (ms): decode 46 · preview-texture 56 · linear-tiff 22
         · service.open 192 · solve 3 · reprint 47 · TOTAL 369
snapshot 1200x700 → /tmp/relocation-test/out.png
```

Reproduce it:

```bash
cp -R modern_UI/Spektrafilm/build/DerivedData/Build/Products/Debug/Spektrafilm.app /tmp/
mv .venv .venv-HIDDEN && mv engine/resources engine/resources-HIDDEN
SPEKTRAFILM_CANVAS_LOG=1 /tmp/Spektrafilm.app/Contents/MacOS/Spektrafilm \
    --snapshot 1200x700 /tmp/out.png --open tests/Test_image/_smoke_1mp.tif --wait 40
mv .venv-HIDDEN .venv && mv engine/resources-HIDDEN engine/resources
```

This is the strong form of the test: it fails if *any* run-time input still
resolves to the repository.

### Every file the engine opens

The C++ engine opens exactly four paths, all relative to the `resources_dir`
handed to `spk_engine_create`:

| what | path | size | contents |
|---|---|---|---|
| baked constants | `spektrafilm_constants.bin` | 6.0 MB | 55 entries: the 1931 CMFS, illuminant SDs, colourspace primaries and matrices, the CAT cone matrices, the Mallett basis, the measured KG3 and lens filter curves, and **the Hanatos irradiance spectra LUT** (192×192×81, float16, 5.97 MB of the 6.0) |
| film + paper profiles | `profiles/<stock>.json` | 5.8 MB | all 28 stocks |
| neutral filter database | `neutral_print_filters.json` | small | the (paper, illuminant, film) filter packs `solve` reads |
| the kernels | `spektrafilm.metallib` | small | compiled by `engine/build.sh` with the safe-math flags |

Nothing else. `grep -rn "resources_dir\|ifstream\|fopen" engine/src` is the
whole list, and `core/profile.cpp::load_profile` validates the stock name as a
path component so a name off the wire cannot walk the filesystem.

### Where `resources_dir` comes from

`EngineClient.defaultResources()`, in order:

1. `SPEKTRAFILM_ENGINE_RESOURCES` if set — for a deliberate A/B;
2. **the app bundle**, `Resources/engine/` — this is the shipping path;
3. a walk up to a checkout's `engine/resources` — a developer convenience for
   a build run out of the tree.

Only (3) is machine-bound, it is last, and the relocation test above proves the
bundle path wins when both exist. `EngineResourceOriginTests` asserts the
resolved path is inside the bundle.

**How the resources get there:** `engine/build.sh bundle` rsyncs
`engine/resources/` into `modern_UI/Spektrafilm/Spektrafilm/Resources/engine/`,
which `Tools/gen-project.py` ships as a folder reference. A pre-build phase
(`Tools/check-engine-resources.sh`) fails the build if they are missing, so the
dangerous case is **stale**, not absent — re-run `engine/build.sh bundle` after
changing anything under `engine/resources`.

### The other things the app reads

| what | where | machine-bound? |
|---|---|---|
| film cover art (11 JPEGs) | `Resources/FilmCovers/` in the bundle | no |
| `StockCatalog.json` | `Resources/` in the bundle | no |
| the user's photographs | `NSOpenPanel`, chosen at run time | no — user data, correctly |
| decoded-TIFF cache, sidecars, thumbnails | `~/Library/Caches/com.hanze.spektrafilm` | no — per-user, correct |

### What is deliberately *not* bundled

`src/spektrafilm/data/luts/print_preview/` (5.9 MB of `.npz` print-preview
LUTs) is **not** in the app, because the only three methods that read it —
`export_di`, `preview_stock_lut`, and the DI package — are not ported and are
refused by name (`ARCHITECTURE.md` §8.8). **When those land, these LUTs become
a bundling requirement**, and `engine/tools/bake_resources.py` is where they
should go.

---

## 2. What is missing before this can be distributed

Ordered by what blocks a download working at all.

### 2.1 Signing and notarisation — blocks everything

Measured on a Release build:

```
$ codesign -dv …/Release/Spektrafilm.app
Signature=adhoc
$ spctl -a -vv …/Release/Spektrafilm.app
…/Spektrafilm.app: rejected
```

`Tools/gen-project.py` sets `CODE_SIGN_IDENTITY = "-"` (ad-hoc),
`DEVELOPMENT_TEAM = ""`, and **`ENABLE_HARDENED_RUNTIME = NO`**. An ad-hoc
signature is fine on the machine that made it and is refused by Gatekeeper
everywhere else. Distribution needs, in order:

1. a Developer ID Application certificate and a team id;
2. `ENABLE_HARDENED_RUNTIME = YES` — **required** for notarisation;
3. `codesign --options runtime --timestamp` over the bundle;
4. `notarytool submit --wait` then `stapler staple`;
5. `spctl -a -vv` returning *accepted*, on a machine that has never seen the
   source.

All five settings live in `gen-project.py`, which is generated — change them
there, not in Xcode, or the next `gen-project.py` run reverts them.

### 2.2 The entitlements describe an app that no longer exists

```xml
<!-- App Sandbox is OFF on purpose: the app spawns a Python subprocess
     (the render service) and reads arbitrary folders. -->
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
```

Every clause of that comment is now false: there is no subprocess and no
Python. `allow-jit` was for numba and `disable-library-validation` for loading
MLX's dylibs; **neither should be needed by a self-contained Metal app**, and
both weaken the hardened runtime that notarisation is about. Remove them, build,
and confirm the app still launches — that is the test.

Sandboxing (`com.apple.security.app-sandbox = true` plus
`files.user-selected.read-write`) is now *possible* for the first time, because
the only thing that read arbitrary paths was the service. It is not required
for Developer ID distribution, only for the Mac App Store. **If you ever turn
it on, `NSOpenPanel` access stops surviving a relaunch** and
`Library.chooseFilesOrFolder` will need security-scoped bookmarks — nothing in
the app persists a chosen folder today.

### 2.3 Licence obligations — the part with legal weight

The app is GPL-3.0-or-later and **the bundle currently contains no licence file
at all**:

```bash
$ find …/Spektrafilm.app -iname "*licen*" -o -iname "*COPYING*"     # empty
```

Three obligations, and the second is the one that is easy to miss:

- **GPL-3.0-or-later** (the application and the engine). Distributing binaries
  requires the licence text and a written offer of, or link to, the
  corresponding source.
- **CC BY-SA 4.0 — the 28 film and paper profiles.** They are Andrea Volpato's,
  and their own `metadata.license` says: *"Redistribution and derivatives must
  credit the author, link the project, preserve this license."* Until now they
  lived only in a source checkout; **putting them inside the `.app` is
  redistribution.** `SPEKTRAFILM_LICENSE.txt` and
  `src/spektrafilm/data/license/` are the texts, and neither is bundled.
- **Apache-2.0 — vendored metal-cpp** (`engine/third_party/metal-cpp/`),
  compiled into the binary. Its `LICENSE.txt` must be reproduced.

Minimum: ship a `Contents/Resources/Licenses/` directory with all three, and
surface it from the app (an About panel or a menu item). Adding it to the
`Resources/` folder reference is a one-line change to `engine/build.sh` or a
copy phase.

Note also that the profiles are CC BY-SA — a *share-alike* licence — which is
worth a deliberate reading before shipping derivatives of them (a baked LUT
derived from a profile is arguably one).

### 2.4 Release configuration is unverified beyond "it builds"

Release builds clean (17 MB, `Mach-O thin (arm64)`), but **every number in
`ARCHITECTURE.md` §8.7 and every parity run was measured in Debug**, which
compiles the engine at `-O0`. Before shipping:

- run `SpektrafilmTests` against Release;
- run the five parity harnesses against a Release-built `libspektrafilm_engine.dylib`
  (`engine/build.sh` already builds with `-O2`, so this is really a check that
  Xcode's `-O` and `build.sh`'s `-O2` agree — fast math is off in both, but the
  runtime probe is what proves it);
- re-measure the tier timings; they should only improve.

### 2.5 Packaging

There is no archive step, no `.dmg`, no `exportOptions.plist`, and no CI. The
smallest honest path is `xcodebuild archive` → `-exportArchive` →
`create-dmg`/`hdiutil` → notarise the DMG.

`ARCHS = arm64` only. That is fine for an Apple-silicon-only release and should
be *stated* in the release notes and `LSMinimumSystemVersion` (currently 15.0)
rather than discovered.

### 2.6 Smaller things

- **Version strings** are `CFBundleShortVersionString = 0.2` / `CFBundleVersion = 2`
  in a checked-in `Info.plist`. They are not derived from anything, so they will
  silently stay at 0.2. `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in
  `gen-project.py` would at least put them in one place.
- **Bundle size is 17 MB Release / 20 MB Debug**, of which 11 MB is resources:
  5.8 MB of profiles for all 28 stocks (the UI lists ~11) and 6.0 MB of
  constants (5.97 MB of it the Hanatos spectra). Both are trimmable if size
  ever matters; neither is code.
- **No update mechanism** (Sparkle or otherwise), and no crash reporting.
- **`spk_last_error` messages surface to the user as-is.** They are written for
  a developer ("run engine/build.sh bundle"), which is right for now and wrong
  for a shipped build.

---

## 3. Checklist

```
[x] app renders with no repository, no venv, no engine/resources   (§1, tested)
[x] all engine inputs bundled and resolved from the bundle          (§1)
[x] Release configuration builds                                    (§2.4)
[ ] Developer ID signature + hardened runtime + notarisation        (§2.1)
[ ] entitlements pruned to what a Metal-only app needs              (§2.2)
[ ] GPL-3.0, CC BY-SA 4.0 and Apache-2.0 texts in the bundle        (§2.3)
[ ] parity + Swift tests run against Release                        (§2.4)
[ ] archive / DMG / notarised artefact                              (§2.5)
[ ] version numbers derived rather than hand-edited                 (§2.6)
[ ] export, export_di, preview_stock_lut ported                     (ARCH §8.8)
[ ] print_preview LUTs bundled, once the above need them            (§1)
```

The first three are done. Nothing in the remaining list is blocked by the
engine — they are packaging, legal and configuration, which is a different kind
of work from the last session's and can be done in any order.
