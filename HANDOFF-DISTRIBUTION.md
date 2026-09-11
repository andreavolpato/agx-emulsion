# HANDOFF-DISTRIBUTION.md — what ships, what is still machine-bound, what is missing

Written 2026-09-10 after RFC-014 linked the render engine into the app, and
**revised the same day** once the packaging, licensing and configuration work
in §2 was done and the last three unported methods were ported. §3's
checklist is the current state; where a section describes what *was* wrong,
it now says what replaced it.

It answers one question first — **does the app carry its own data, or is it
still tied to this machine?** — and then lists what stands between the current
build and something a stranger can download and run.

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
| baked constants | `spektrafilm_constants.bin` | 9.45 MB | 71 entries: the 1931 CMFS, illuminant SDs, colourspace primaries and matrices, the CAT cone matrices, the Mallett basis, the measured KG3 and lens filter curves, **the Hanatos irradiance spectra LUT** (192×192×81, float16, 5.97 MB) and **the 8 print-preview LUTs** (33³×3 float32 plus axes, 3.45 MB) |
| film + paper profiles | `profiles/<stock>.json` | 5.8 MB | all 28 stocks |
| neutral filter database | `neutral_print_filters.json` | small | the (paper, illuminant, film) filter packs `solve` reads |
| print-LUT metadata | `print_luts.json` | small | per stock: `paired_film`, `declared_pairing`, `lut_size` |
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

### The print-preview LUTs — bundled, as this section predicted

This section used to say the 8 `.npz` print-preview LUTs were deliberately
absent, because the only three methods that read them were unported, and that
**"when those land, these LUTs become a bundling requirement"**. Those methods
landed. So did the requirement.

`bake_resources.bake_print_luts` now writes them into the constants blob as
`print_lut/<stock>` (33³×3 float32) and `print_lut_axes/<stock>` (3×33), with
`print_luts.json` as the metadata index — 3.45 MB, which is why the blob is
9.45 MB rather than 6.0. `engine/tests/parity_lut.py` reads them back out of
the *shipping dylib* and holds them bit-exact against the `.npz`.

Two things fell out of it that were not obvious:

- **The bake checks its own assumption.** The trilinear kernel maps a density
  to a grid coordinate with one subtract and one multiply, which is only the
  same interpolation the scipy reference does when the axis is uniformly
  spaced. It is, on all eight shipped assets — but that is a property of the
  bake, not a guarantee, so `bake_print_luts` verifies it at bake time, where
  a future re-bake would trip it, rather than in a kernel that cannot report
  anything.
- **They are CC BY-SA 4.0 derivatives**, not neutral data. The licence is
  explicit that a LUT is "a direct encoding of the information in the original
  profiles". Bundling them is what made §2.3's licence work mandatory rather
  than tidy.

---

## 2. Signing, licensing and packaging

Everything below has been done except the one step that needs a certificate
this repository must not contain. §2.1 is now the only real blocker, and it is
a purchase rather than a piece of work.

### 2.1 Signing and notarisation — the one remaining blocker

**Done:** the pipeline. `modern_UI/Spektrafilm/Tools/package.sh` is
archive → export → verify → DMG → notarise → staple → `spctl`, and it runs.
Measured on this machine:

```
$ Tools/package.sh
** ARCHIVE SUCCEEDED **   ** EXPORT SUCCEEDED **
  CodeDirectory v=20500 … flags=0x10002(adhoc,runtime)
  …/Spektrafilm.app: valid on disk
  …/Spektrafilm.app: satisfies its Designated Requirement
  …/Spektrafilm-0.3-arm64.dmg (10M)
=== notarisation
  skipped: no Developer ID. Gatekeeper will refuse this on any other Mac.
=== gatekeeper
  …/Spektrafilm-0.3-arm64.dmg: rejected
  source=no usable signature
```

`flags=…,runtime` is the change that mattered:
**`ENABLE_HARDENED_RUNTIME` is `YES`** now, in both configurations, so a Debug
build exercises the same hardening the release ships with. `spctl` still says
*rejected*, correctly, and the script says why rather than exiting 0 on an
unshippable artefact.

**Not done, and cannot be here:** the Developer ID Application certificate.
Once you have one:

```bash
export SPEKTRAFILM_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)"
export SPEKTRAFILM_TEAM_ID=TEAMID
xcrun notarytool store-credentials SPEKTRAFILM_NOTARY \
    --apple-id you@example.com --team-id TEAMID --password <app-specific>
export SPEKTRAFILM_NOTARY_PROFILE=SPEKTRAFILM_NOTARY
modern_UI/Spektrafilm/Tools/package.sh
```

`gen-project.py` reads those two variables, so the identity lands in the
generated pbxproj rather than being passed to `xcodebuild` and lost on the
next generator run — which is the trap this section originally warned about.
The last step is still the one that counts: **`spctl -a -vv` on a machine that
has never seen this source.**

### 2.2 The entitlements — done

They said this:

```xml
<!-- App Sandbox is OFF on purpose: the app spawns a Python subprocess
     (the render service) and reads arbitrary folders. -->
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
```

Every clause of that comment was false — no subprocess, no Python, no numba to
JIT, no MLX dylibs to load — and both entitlements weakened the hardened
runtime notarisation is about. **They are gone.** The Release bundle's
entitlement set is now empty:

```
$ codesign -d --entitlements - …/Release/Spektrafilm.app
[Dict]
```

and the app still renders — verified by the relocation test in §1, on the
Release build, with `.venv` and `engine/resources` renamed away.
`Tools/package.sh` greps for both clauses and fails the release if either
comes back.

Sandboxing is still *possible* and still not done. It is not required for
Developer ID distribution, only for the Mac App Store. **If you ever turn it
on, `NSOpenPanel` access stops surviving a relaunch** and
`Library.chooseFilesOrFolder` will need security-scoped bookmarks — nothing in
the app persists a chosen folder today.

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

### 2.3 Licence obligations — done, with one question left for you

The bundle used to contain no licence file at all. It now carries four, in
`Contents/Resources/Resources/Licenses/`, written by
`Tools/bundle-licenses.sh` from their canonical copies rather than retyped:

| file | covers |
|---|---|
| `Spektrafilm-GPL-3.0.txt` | the application and the C++ engine |
| `Profiles-and-LUTs-CC-BY-SA-4.0.txt` | the 28 profiles and the 8 baked print LUTs |
| `Profiles-and-LUTs-CHANGELOG.txt` | what this build changed about them |
| `metal-cpp-Apache-2.0.txt` | the vendored metal-cpp compiled into the binary |

Three things back this up rather than leaving it to a checklist:

- **`Tools/check-bundle-resources.sh`** is the app target's pre-build phase
  and fails the build when any of them is missing.
- **`LicensingTests`** asserts each file is present, readable *through the
  same accessor the About panel uses*, and is the licence it claims to be — a
  build that shipped the GPL four times would pass a mere existence check.
- **`AboutWindow`** shows the credit and serves the full texts. That is not
  decoration: the CC BY-SA preamble names "an app's About screen" by example
  as a place the attribution must survive, and the GPL wants a route to the
  corresponding source. Both are on the panel, reached from
  **Spektrafilm → About Spektrafilm**.

The share-alike reading this section asked for was made and is recorded in
`Profiles-and-LUTs-CHANGELOG.txt`: the profiles ship **unmodified**, the 8
LUTs are **derivatives** (the licence says so explicitly — "LUTs and similar
artifacts are interpreted as direct encodings of the information in the
original profiles"), and they are therefore distributed under the same
CC BY-SA 4.0 as the share-alike condition requires. The changelog also records
*how* they were baked, which pairing each used, and that glare is excluded.

**The one thing left is yours to decide, not mine.** The same licence says:

> Don't use "spektrafilm" or my name in product branding without asking. The
> license covers the files; the name is not part of that grant. Factual
> reference is welcome and even encouraged, for example "graded with
> spektrafilm", or "this app uses spektrafilm LUTs".

This application is *named* Spektrafilm, with `com.hanze.spektrafilm` as its
bundle id. That is product branding using the name, and it is outside what
the file licence grants — the licence asks you to ask. It is a two-line email
(`andrea.volpato@outlook.com`) and it is worth sending before a public
release, or renaming the product and keeping the factual reference. Nothing in
the code depends on the answer; this is here so it is a decision rather than
an oversight.

### 2.4 Release configuration — verified

All three of this section's items are done, and one of them turned out to be
a check on the harness rather than on Release:

- **`SpektrafilmTests` against Release: 117 tests, 0 failures**, 4.2 s (the
  same 117 pass in Debug in 6.7 s).
- **All six parity harnesses pass**, plus `gpu_smoke` and
  `check_math_guard.sh` (which builds a deliberately fast-math library to
  prove the guard can fire, then confirms the shipped one is safe). These
  already ran against `-O2`: `engine/build.sh` has always compiled the dylib
  that way, so what this really checked is that Xcode's `-O` and
  `build.sh`'s `-O2` agree, and the runtime probe is what proves the math
  mode rather than either build flag.
- **The tier timings were re-measured** and are in `ARCHITECTURE.md` §8.7,
  now with a fourth column for the LUT flip the port added. The reprint
  column reproduced (0.009 / 0.034 / 0.167 s at 45 MP), which is what makes
  the new numbers comparable to the old ones.

Also verified, and the stronger form of §1's test: the **Release** build,
copied to `/tmp` with no repository above it and with both `.venv` and
`engine/resources` renamed away, opened a frame and rendered it in 285 ms —
and the LUT parity harness, pointed at the resources *inside that bundle*
(`SPEKTRAFILM_ENGINE_RESOURCES=…/Spektrafilm.app/Contents/Resources/Resources/engine`)
with `engine/resources` still hidden, passed bit-exact. That is the check
worth having: `engine/build.sh bundle` is an rsync, and an rsync that did not
run leaves a **stale** bundle rather than an empty one.

### 2.5 Packaging — done

`modern_UI/Spektrafilm/Tools/package.sh`, one script, the whole path:

```
resources and licences → project → archive → export → verify the signature
→ DMG → notarise → staple → spctl
```

It generates its own `exportOptions.plist`, reads the version out of
`gen-project.py` so the DMG's name cannot disagree with the bundle's, copies
the licence texts to the top of the disk image as well as inside the app, and
**fails rather than succeeding quietly** when Gatekeeper says no. `--dry-run`
prints the plan without building. Without a Developer ID it still archives,
exports and builds the DMG, then says the result will be refused everywhere
else and why — a script that refuses to run at all teaches nothing, and one
that exits 0 on an unshippable artefact is worse.

There is still **no CI**, and that is the remaining gap here.

`ARCHS = arm64` only. That is fine for an Apple-silicon-only release and is
now *stated* rather than discovered: the DMG is named
`Spektrafilm-<version>-arm64.dmg`, and `LSMinimumSystemVersion` is 15.0. Put
both in the release notes.

### 2.6 Smaller things

- **Version strings — done.** `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
  in `gen-project.py` are the single place; `Info.plist` references them as
  `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`. Now 0.3 / 3, and
  `LicensingTests.testTheVersionCameFromTheBuildSettings` fails if the plist
  ever ships an unexpanded placeholder or drifts back to the hand-typed 0.2.
  `NSHumanReadableCopyright` was added at the same time, since the About panel
  is not the only place macOS shows a copyright line.
- **Bundle size is 17 MB Release**, of which 15 MB is resources: 9.45 MB of
  constants (5.97 MB Hanatos spectra + 3.45 MB print LUTs), 5.8 MB of profiles
  for all 28 stocks (the UI lists ~11), 196 kB of cover art, 80 kB of licence
  texts. The DMG is 10 MB. All trimmable if size ever matters; none of it code.
- **`spk_last_error` — done.** `Service/EngineMessage.swift` rewrites the
  classes that actually reach a user: an incomplete install no longer says
  "run engine/build.sh bundle" to someone with no checkout, the fast-math
  refusal says *this build* is wrong rather than the app, and a cancelled
  render does not read as a failure. Two rules keep it honest — anything
  unrecognised is **passed through** rather than replaced with a confident
  guess, and the engine's own words are kept in parentheses (and in the
  canvas log) so a bug report still carries them. `EngineMessageTests` pins
  both.
- **No update mechanism** (Sparkle or otherwise), and no crash reporting.
  Still true, and still the largest thing this list does not cover.

---

## 3. Checklist

```
[x] app renders with no repository, no venv, no engine/resources   (§1, §2.4)
[x] all engine inputs bundled and resolved from the bundle          (§1)
[x] Release configuration builds                                    (§2.4)
[x] hardened runtime on, in both configurations                     (§2.1)
[x] entitlements pruned to what a Metal-only app needs              (§2.2)
[x] GPL-3.0, CC BY-SA 4.0 and Apache-2.0 texts in the bundle        (§2.3)
[x] the licence obligations surfaced in the app (About panel)       (§2.3)
[x] parity + Swift tests run against Release                        (§2.4)
[x] archive / export / DMG, as one script                           (§2.5)
[x] version numbers derived rather than hand-edited                 (§2.6)
[x] engine errors rewritten for someone who did not build this      (§2.6)
[x] export, export_di, preview_stock_lut ported                     (ARCH §8.8)
[x] print_preview LUTs bundled                                      (§1)

[ ] Developer ID Application certificate + notarised artefact       (§2.1)
[ ] ask about the product name, or rename it                        (§2.3)
[ ] spctl accepted on a machine that has never seen this source     (§2.1)
[ ] CI                                                              (§2.5)
[ ] update mechanism and crash reporting                            (§2.6)
```

**The three open items that block a public release are not code.** A
certificate is a purchase; the name is a two-line email; the clean-machine
`spctl` check needs the first one and a second Mac. Everything a build can do
has been done and is tested, which is the difference between "not ready" and
"waiting on you".

CI and an update mechanism are real gaps but do not block a first release —
someone can download a notarised DMG and use it without either.
