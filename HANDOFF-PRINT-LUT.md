# Handoff: `preview_stock_lut` implementation (for a fresh session)

**Status (revised 2026-09-10): shipped.** `preview_stock_lut` and the DI
package are implemented in the native C++ engine, the eight LUTs are baked
into the app bundle, and `engine/tests/parity_lut.py` holds all of it against
this file's own Python reference. See `ARCHITECTURE.md` §8.8 for the C++/Swift
split and §8.7 for the re-measured speed.

Two corrections to what follows, both about numbers this file states
correctly and which are easy to carry into the wrong comparison:

- **§3.1's 190× is against scipy on the CPU.** Against a *reprint on the
  GPU* — which is what a user would otherwise have got — the flip is about
  4×: 2.0 ms vs 9 ms at the live tier, 47 vs 167 at full, on a 45 MP frame.
  Still worth having; not two orders of magnitude.
- **§3's open items 2 and 3.** Item 2 (wire it into a service) is done, in the
  engine rather than a service, because there is no service any more
  (RFC-014). Item 3 — the film-mismatch question — is **still open and was
  not decided**: the engine takes option (b)+(c)'s honest middle, answering
  the mismatched pair and *warning* that the table is coupled to the paired
  film's dye spectra with unmeasured error. Nobody has baked the film×print
  cross product or measured the approximation, which is exactly what §3.3
  says to do rather than guess.

The original status line, for the record: *prototyped, measured, and shipped
as data assets. Not yet wired into an actual running service — this session
built and validated the mechanism, not the service endpoint.*

**Context you need first:** `PRD-callable-render-api.md` §7.3 (the
`preview_stock_lut` contract box) and `API-SPEC-callable-render-service.md`
§2 (the full "print+scan chain bakes to a LUT" writeup, including the
accuracy numbers and the same-pipeline-instance-vs-independent-render trap).
Both were written this session against real measurements, not projected.

---

## 1. What already exists and is validated — don't re-derive this

- **8 shipped LUTs**, one per print stock in the profile library:
  `src/spektrafilm/data/luts/print_preview/<print_stock>.{npz,json}`. Baked
  by `scripts/bake_all_print_luts.py`, all 8 in 0.71s total. Each `.npz`
  holds a `lut` array `(33,33,33,3)` float32 and an `axes` array `(3,33)`
  float32 (per-channel density grid coordinates); each `.json` sidecar
  records `paired_film`, `declared_pairing` (bool — see §2), and bake
  settings.
- **Application is validated correct**, not assumed: `scripts/apply_print_lut.py`
  loads a shipped LUT, renders a real negative from a RAW, applies the LUT
  via trilinear interpolation (`scipy.ndimage.map_coordinates`), and writes
  a genuine TIFF. Checked against the *same pipeline instance*'s real
  `Tap.RGB_OUT` (not an independently-rendered file — that comparison
  produces a spurious ~0.05 mean diff purely from two different unseeded
  grain draws, a trap this session hit once already and is now documented
  in both API-SPEC §2 and this file so it isn't rediscovered): **mean abs
  diff 0.0017, max 0.174**, visually indistinguishable.
- **Timing, real numbers, not estimates** (apply superseded — see 3.1):
  bake 0.26s (single stock,
  reference implementation) down to ~0.01s per stock once numba/JIT/spectral
  caches are warm (measured baking all 8 sequentially); apply 4.5s on a
  45 MP negative using unoptimized `scipy.ndimage.map_coordinates`. A full
  LUT-based render (negative + apply, no full print+scan pass) was 15.03s
  against ~19.5s for the equivalent full render on the same 45 MP frame.
- **The API contract is written**, not just implied — `PRD-callable-render-api.md`
  §7.3's `preview_stock_lut` row and call-out box are the spec to implement
  against.

## 2. Explicitly deprioritized this session — do not "fix" it as a bug

**`scanning.glare` is not in the LUT, and that's the intended design, not a
gap to close.** Glare is spatial+stochastic (a random veiling-flare field,
blurred) — structurally impossible to represent in a pointwise 3D LUT.
Measured impact of leaving it out: mean abs diff rises from 0.00085
(glare-matched comparison) to only 0.00177 (LUT-without-glare vs.
production-with-glare) — small, and per this session's product call:
**nobody needs glare-accurate output while flipping between stock previews
during grading.** `preview_stock_lut` is explicitly a fast-look-preview
path, not the deliverable — the actual `export` call still runs the full
pipeline (glare included) every time. Do not spend implementation effort
adding glare (or scanner_blur/unsharp/diffusion_filter, same category —
all off by default anyway) to the LUT bake. If a future session wants
glare-accurate previewing for some other reason, that's a new, separate
ask — it is explicitly out of scope here per this session's product
judgment call, recorded so it doesn't get "fixed" as an oversight.

## 3. What actually needs building next

1. ~~**GPU-accelerated LUT application.**~~ **Done (2026-08-25).**
   `mlx_ops.gpu_apply_lut3d` is a Metal trilinear kernel;
   `scripts/apply_print_lut.py` grew `--backend auto|gpu|cpu` (auto = GPU when
   Metal is available, scipy otherwise) and `--check`, which runs both arms and
   reports agreement. Measured on `_DSC2439.NEF` at 45 MP:
   **4525.8 ms -> 23.8 ms, a 190x speedup**, against the scipy reference at
   **mean abs 1.3e-08 / max abs 2.4e-07** — float32 storage epsilon, i.e. the
   same eight corners with the same weights. Comfortably beat the "well under
   100 ms" target. First dispatch is ~313 ms including Metal shader
   compilation; that is one-time per process, not per preview.
   Covered by `tests/test_gpu_lut3d.py` (scipy equivalence on random and on a
   shipped asset, edge clamping, exact grid-node hits).

   Two notes for whoever touches it next: the kernel assumes the per-channel
   axes are **uniformly spaced**, which is how `bake_all_print_luts.py` writes
   them (verified to 2.4e-7 on the shipped assets) — a non-uniform axis would
   need a search, not a scale. And the CPU baseline in this row was
   re-measured after the RFC-006 float32 work; the negative render feeding it
   is now float32, so do not compare a new number against the pre-RFC-006
   15.03 s end-to-end figure below. The same run now totals **9.33 s**
   (9.01 s negative + 0.02 s apply).
2. **Wire `preview_stock_lut` into the actual render service** once that
   service exists (this PRD/API-SPEC describe a service that doesn't have a
   running implementation yet, per PRD §0). The method needs: load the
   session's cached negative (`Tap.CMY_FILM`, already how `reprint` works),
   look up or bake the requested stock's LUT, apply, write to the session
   workspace, return the path. All the pieces exist as standalone scripts;
   none are wired into a request handler yet.
3. **The film-mismatch question, still genuinely open.** Five of the eight
   shipped LUTs are paired with a *default* negative, not one declared by
   the profile data (`kodak_2393`, `kodak_ektacolor_edge`,
   `kodak_endura_premier`, `kodak_supra_endura`, `kodak_ultra_endura` — see
   `bake_all_print_luts.py`'s module docstring for the reasoning). More
   importantly: **what happens if a user has a negative from a film stock
   that doesn't match ANY shipped LUT's paired film at all** (e.g. they're
   using `kodak_ektar_100`, which targets `kodak_portra_endura`, and want to
   preview `kodak_2393`)? The LUT is coupled to the film's dye spectra via
   `_film_cmy_to_print_log_raw`, so this is a real approximation, not a
   free combination. Options, not decided here: (a) bake the full film×print
   cross product (many more LUTs, all cheap individually given the ~0.01-0.25s
   bake time, but combinatorially it's ~20 films × 8 prints = up to 160 —
   still under a minute total if bake time holds at scale, worth just
   measuring rather than assuming it's a problem); (b) accept the
   approximation and measure its actual error on a representative mismatched
   pair before deciding if it's acceptable; (c) restrict `preview_stock_lut`
   to only accept `film_stock` values that have a shipped or bakeable LUT
   for that exact pair, erroring otherwise. (a) is probably the right
   default answer given the sub-minute total bake cost this session
   measured, but nobody has actually baked the full cross product or
   measured its total time/storage — do that first, don't guess.
4. **`.cube`-format export**, if external-tool interop (Resolve, Photoshop)
   is wanted per the original ask that motivated this feature — the shipped
   `.npz` format is spektrafilm-internal only. Converting a `(33,33,33,3)`
   array to a standard `.cube` LUT file is a small, well-understood format
   task, not attempted this session.

## 4. Repo hygiene note

`scripts/bake_all_print_luts.py`, `scripts/apply_print_lut.py`, and
`scripts/prototype_print_lut.py` are three related but distinct scripts —
the first two are the production path (bake once, apply many times), the
third is the original single-stock research prototype that proved the
concept before the other two existed. Consider whether the prototype should
be removed once the production scripts are trusted, or kept as the
minimal-repro reference — not decided here, flagging so it isn't silently
duplicated further.
