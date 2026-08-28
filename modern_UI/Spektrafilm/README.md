# Spektrafilm Desktop — step one

| | |
|---|---|
| **What this is** | The frontend shell. Layout, controls, canvas, decode path. |
| **What it is not** | Connected to the engine. `ServiceClient` is written and the API is typed; nothing is spawned. |
| **Governed by** | `../UI-GUIDELINE-swiftui.md` (how), `../SPEC-spektrafilm-desktop-frontend.md` (what), `../../API-SPEC-callable-render-service.md` (the backend contract) |
| **Date** | 2026-08-28 |

---

## 0. Two bugs found by measurement, both fixed

The canvas rendered flat magenta. It was **not** a colour bug, and guessing at
it would have gone to the wrong place entirely. `Tools/probe.sh` runs the app's
own `ImageDecoder` headlessly, renders to a readable texture with exactly the
app's settings, and prints per-channel statistics — which localised both:

**1 — the magenta. `CIContext.render` needs `.shaderWrite`.**
Core Image renders through a compute kernel. Into a texture created with only
`[.shaderRead, .renderTarget]` it writes **nothing at all**, silently: no
exception, no command-buffer error. The texture then holds whatever was in
that allocation, and with `.private` storage that is uninitialised GPU memory.

| usage flags | R / G / B mean |
|---|---|
| `[.shaderRead, .renderTarget]` | 0.0000 / 0.0000 / 0.0000 — alpha zero too |
| `+ .shaderWrite` | 0.4771 / 0.4668 / 0.4533 |

Pixel format was innocent; `rgba16Unorm` and `rgba16Float` fail identically
without the flag. The probe keeps the broken configuration as a regression
check that must report `ALL ZERO`.

**2 — a double decode on RAW, ~45% too dark.**
`decodeRAW` called `matchedToWorkingSpace(from: output.colorSpace)`.
`CIRAWFilter` *reports* its output as Display P3, but with `boostAmount = 0`
the values are already scene-linear — so the remap decoded a curve that had
never been applied. Whole-image mean on the 45 MP reference frame: **0.477
without the remap, 0.261 with it.** Same family as API-SPEC §4's
double-encode, running the other direction. The remap is gone.

Re-run any time:

```
Tools/probe.sh <file> [more files…]        # needs no Metal toolchain
```

---

## 0.1 Build state, stated plainly

`xcodebuild -list` resolves the project and its scheme. All 26 Swift files
**typecheck clean** under Swift 6 with complete strict concurrency — no errors
and no warnings:

```
xcrun swiftc -typecheck -sdk $(xcrun --show-sdk-path --sdk macosx) \
  -target arm64-apple-macos15.0 -swift-version 6 $(find Spektrafilm -name '*.swift')
```

A full `xcodebuild` **fails on this machine**, before Swift compilation, on a
missing Xcode component:

```
error: cannot execute tool 'metal' due to missing Metal Toolchain;
       use: xcodebuild -downloadComponent MetalToolchain
```

That is an install, not a code defect — Xcode 26 moved the Metal compiler to a
downloadable component. Run it and build again. **`Shaders.metal` has
therefore never been compiled**; treat it as unverified until it has been.
Nothing else is waiting on it.

---

## 1. What was verified, and how

### The backend, before any UI was written

The service was driven directly over stdio on a real 45.75 MP `_DSC2484.NEF`.
Every number below is from that run, not from the spec:

| call | measured | API-SPEC §10.3 says |
|---|---|---|
| `capabilities` | 1.97 s (cold import) | 1.76 s import |
| `open` (RAW decode + live negative) | 7.05 s | 6.98 s |
| `solve` | 106 ms | 100 ms |
| `reprint`, live tier, warm | **197 ms** | 193–199 ms |
| `preview_stock_lut` | 8.9 ms apply, GPU | 4–10 ms |

`capabilities` reports `gpu_available: true`, `spectral: mlx`,
`working_precision: float32`, tiers `live 1600 / preview 3400 / full null`.
The RAW path came back `raw_engine: "dcraw"`,
`input_color_space_source: "rawpy-decode"`, linear ProPhoto.

**The backend is real and matches its own spec.** The blurry parts are in the
contract, not the implementation — see §3.

### The decode path in the app

`Canvas/ImageDecoder.swift` decodes RAW natively through `CIRAWFilter` with
the four settings frontend SPEC §2.5 requires (`boostAmount = 0`,
`boostShadowAmount = 0`, gamut mapping off, draft mode off), plus lens
correction off. Flat files go through ImageIO, and the transfer function is
read from the *storage type* — the same rule `service.py::_load_image`
follows — rather than assumed.

One thing had to be built rather than looked up. Core Graphics ships
`kCGColorSpaceROMMRGB` (ProPhoto at its native gamma 1.8) and linear variants
of sRGB, P3, Gray and ITU-R, **but no linear ROMM**. Since linear ProPhoto is
the engine's stated input contract, substituting the gamma-1.8 space would be
a silent whole-image tone error and substituting linear P3 would silently
narrow the gamut. It is constructed from ROMM's published primaries at
gamma 1.0 instead.

---

## 2. The colour rule this build is organised around

The image is encoded to Display P3 **exactly once**, at texture upload, and
the `CAMetalLayer`'s colour space is set to Display P3 so ColorSync performs
the display transform. The shader applies no curve in either direction and
the texture format is `.rgba16Unorm`, deliberately not an `_srgb` one.

This is UI-GUIDELINE §4 rules 1–3 and API-SPEC §4's recorded double-encoding
bug. The inspector's `pipeline` section states it in the UI, not only in a
comment, because it is the checkpoint UI-GUIDELINE §10 step 3 says not to walk
past: **a washed-out canvas means a second encode crept in.** Fix it there.

---

## 3. What 联调 has to resolve — the gaps, ranked

Recorded here and in `Service/Methods.swift`, so they live next to the type
that would carry the field.

1. **`get_live_negative` and `get_print_lut` do not exist** (frontend SPEC
   §1.3). They are what would let the negative leave the Python process for
   60 fps GPU compositing. Without them the interactive path is `reprint` at
   ~193 ms on release — which SPEC §1.3 itself names as the fallback. The
   shell is built to the fallback, so the live path is an addition later, not
   a restructure. **SPEC §8 step 1 is the prerequisite:** is
   `density offset → LUT` equivalent to `reprint` with grain and glare off?
   Unanswered. Everything about the interaction model depends on it.

2. **Render output paths are reused and overwritten.** `_render` writes
   `{kind}_{session}_{tier}.tif` and clobbers it every call. It cannot key a
   cache, and two renders of the same kind race on one file. The client must
   read before issuing the next call.

3. **`solve` does not apply the EV it computes.** Verified in the probe: the
   filter-pack half calls `apply_database_neutral_print_filters(params)` and
   those three neutrals stick; the exposure half only returns an EV and never
   writes `camera.exposure_compensation_ev`. A caller that solves and renders
   gets the solved filter pack but not the solved exposure. Round-trip it
   through `set_params`, or fix the asymmetry backend-side.

4. **No `grain_seed`** (SPEC §1.4). `grain_sampler` is unseeded, so the same
   image closed and reopened exports differently. Until it lands, the app must
   not claim reopening reproduces a previous export.

5. **No `exposure_mask`** (SPEC §1.5), so `Enlarger`-target masks cannot
   exist. `After print` masks are Layer 2 and need no service change — which
   is why they ship first, and why the mask geometry being identical either
   way means nothing is wasted.

6. **`cancel` cannot arrive mid-render on stdio.** Supersede client-side by
   discarding results; send shoot-layer changes only on release.

---

## 3.5 Adding, removing or replacing an editing surface

Every surface in a dock is one module, in one file, that references no other
module. `Modules/EditorModule.swift` holds the contract and the registry.

```swift
@MainActor
enum GrainCurveModule {
    static let module = EditorModule(
        id: "grain-curve", title: "Grain", systemImage: "circle.grid.cross",
        column: .left, layer: .physical,
        summary: { $0.flag("grain_active") ? "on" : "off" },
        content: { AnyView(Body(session: $0)) })

    private struct Body: View { ... }
}
```

Then one line in `ModuleRegistry.all`. That is the whole integration.

| you want to | you do |
|---|---|
| add a surface | new file + one line in the registry |
| remove one | delete the line; nothing else refers to it |
| reorder | move the line |
| replace one | point the line at a different type |
| move it to the other dock | change `column:` |

**The rule that keeps this true:** a module may read and write `Session` and
use anything in `Controls/`. A module must never reference another module. If
two need to agree on something, that something belongs in `Session`.

The dock — not the module — draws the layer boundary, wherever the declared
`layer` changes. So a module cannot forget to draw it or draw a second one,
and the frontend SPEC §3.1 rule that the two layers stay visually distinct
survives someone adding a module carelessly.

---

## 3.6 Layout

```
┌────────────────────────────────────────────┐
│ toolbar                       full width   │
├────────────────────────────────────────────┤
│  ╭────────╮                  ╭─────────╮   │
│  │  dock  │     canvas       │  dock   │   │  docks float, inset
│  ╰────────╯   (full bleed)   ╰─────────╯   │  canvas runs edge to edge
├────────────────────────────────────────────┤
│ filmstrip + status            full width   │
└────────────────────────────────────────────┘
```

Bars span the window; docks never touch them, so nothing overflows anything.
The canvas is genuinely full-bleed underneath — collapsing a dock reveals more
image rather than resizing it, so a pan or zoom does not shift when a panel is
toggled (frontend SPEC §5.0).

Docks are `.regularMaterial` in a rounded rect with a hairline border. Colour
is mostly *not* in `Theme` any more: the docks use the semantic hierarchy
(`.primary` / `.secondary` / `.tertiary`) and the system accent, so they track
the user's vibrancy, contrast and accessibility settings instead of freezing a
palette that ignores them. What stays ours is the canvas surround — which must
be a specific neutral value because an image sits on it — and the two
filter-pack track gradients, still the only hue in the interface.

### Canvas behaviour

Capture One's model. The image is fitted and centred; **it can never be
dragged off-screen.** Below fit scale, pan is ignored entirely; above it, pan
is clamped so an image edge cannot come inside the viewport edge. The clamp
lives in exactly one place, `Renderer.samplingTransform`.

| gesture | does |
|---|---|
| two-finger scroll | pan |
| pinch, or ⌘/⌥ + scroll | zoom about the cursor |
| double-click | toggle fit ↔ 100% |
| `Z` / `⌘0` / `⌘±` | 100% / fit / step |

Scroll is *not* bound to zoom: on a trackpad that turns every attempt to pan
into a resize.

---

## 4. What is in the shell

| area | state |
|---|---|
| `SplitContainer`, draggable dividers, `Tab` collapse, `@AppStorage` persistence | built |
| Collapsible panel sections with collapsed-state summaries | built |
| `ScrubSlider` — numeric field, zero tick, ⌥ fine, ⇧ snap, double-click reset, commit on release | built |
| Metal canvas, P3 layer, zoom/pan as a sampling transform | built, shader uncompiled |
| RAW + flat decode, decoder and colour space reported in the inspector | built |
| Filmstrip, ImageIO thumbnails off the main actor, three-state badge | built |
| Stock picker with cine pairs at the same level as still, undeclared pairings marked | built |
| Layer 1 / Layer 2 rule, Layer 2 group with bypass switch, Layer 2 in the shader | built |
| Read-only curve scopes | placeholder geometry; profile JSON not read yet |
| `ServiceClient`, all 13 methods typed | written, not spawned |
| Masks, export, sidecar | not started |

Build order from here is UI-GUIDELINE §10 step 4: install the Metal
toolchain, confirm step 3's colour checkpoint on a known test image, then wire
`open` → `solve` → `reprint`.

---

## 5. Running it

```
open modern_UI/Spektrafilm/Spektrafilm.xcodeproj
```

⌘O opens a folder, or drop one on the window. The folder is the session;
there are no project files. `tmp/Test_image/Nikon Z7ii/` is a good first
target — nine NEFs, including the 45 MP frame the backend probe used.
