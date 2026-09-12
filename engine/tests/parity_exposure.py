"""Hold the C++ auto-exposure meter against the Python reference (RFC-015 §6).

Every other harness runs with `auto_exposure = false`, because the two
engines' meters were never compared and a render with the meter on would mix
a metering difference into a pixel comparison. This is the harness for the
meter itself. RFC-015's four modes are implemented twice from the contract's
text (CONTRACT §5, the 2026-09-11 row): C++ in `pipeline.cpp`, Python in the
fork's `utils/autoexposure.py`, neither written from the other. Agreement
between them is evidence about the definition, not about a transliteration.

What it checks, per frame:

  a. **Legacy meters** (`center_weighted`, `average`, `median`): the C++
     `solve` EV equals `measure_autoexposure_ev` on the same frame, and the
     gain the C++ auto-exposure *node* applies equals Python's.
  b. **The four new modes**: C++ `exposure_ev_by_method` (a sibling of
     `solved_params`, never inside it) equals
     `measure_autoexposure_evs_by_method` to 1e-9 EV. With a mode selected,
     `exposure_compensation_ev` is that mode's entry.
  c. **A second frame size.** Each frame is also opened strided to at most
     256 px (`frame[::step, ::step]`), and its meter is compared the same
     way, so every method is held on two samplings of the same scene.
  d. **Negative controls.** The Python side of each comparison is perturbed
     in five ways (a rank one off, interpolated percentiles, the floor, S_HI,
     float32 luminance) and the harness must go red for every one. Otherwise
     "within 1e-9" would mean nothing. The render check's own resolution is
     measured by sweeping a gain error until the picture changes.
  c1-c5. **One EV per frame, at every tier** (RFC-015 P.1), on full-resolution
     RAWs and a schema walk: see that section below.

The meter (RFC-015 P.1). A session meters once: the frame downscaled to
`kMeterLongEdge` (1600 px), after `decode_input` and geometry, the whole
image, not a stride. Every tier's auto-exposure node applies that one EV and
`solve` reports it. For the frames here (at most 1600 px, no geometry) the
meter image is the frame itself, so the Python side is
`measure_autoexposure_ev` on the whole frame.

How the node is observed. The C ABI's `progress` reports the EV the node
applied (`auto_exposure_ev`); independently of that hook, the harness renders
with the meter on and renders the frame pre-multiplied by
`float32(2^EV_python)` with the meter off. The node narrows its gain through
float32 and multiplies, so if its EV is Python's, the two renders are
bit-identical.

Frame sizes. Every frame here is at most 1600 px on its long edge, so the live
tier and the meter share the source on both sides and nothing is resampled.
The real frames are RAW files decoded to linear ProPhoto by the fork's own
loader, downscaled once on the host and cached; both engines receive that
same float32 array.

Grain and glare are off: they are stochastic, and a bit-identical render
comparison would measure the noise (RFC-013's grain trap).

Usage:
    engine/tests/parity_exposure.py [--python-only] [--no-real] [--verbose]

`--python-only` runs without the dylib: the reference numbers, the RFC §6
known answers, the per-frame table, and the negative controls against
the unperturbed reference (which shows the frame set can see each
perturbation).
"""
from __future__ import annotations

import argparse
import math
import sys
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

import numpy as np

ENGINE = Path(__file__).resolve().parents[1]
REPO = ENGINE.parent
sys.path.insert(0, str(REPO / "src"))
sys.path.insert(0, str(ENGINE / "tests"))

MIDGRAY = 0.184
NEW = ("balanced", "center", "protect_highlights", "protect_shadows")
LEGACY = ("center_weighted", "average", "median")
EV_TOLERANCE = 1e-9
# The only encoding either side is given: the frames are scene-linear ProPhoto.
COLOR_SPACE = "ProPhoto RGB"
BASE = {"grain_active": False, "glare_active": False, "auto_exposure": True,
        "input_color_space": COLOR_SPACE, "input_cctf_decoding": False}
REAL_FRAMES = [
    "tests/Test_image/Nikon Z7ii/_DSC2439.NEF",
    "tests/Test_image/A7RV/DSC00185.ARW",
    "tests/Test_image/A7m3/DSC03710.ARW",
]
CACHE = ENGINE / "build" / "parity_exposure_cache"


# --- frames ----------------------------------------------------------------


def grey(y: np.ndarray, tint=(1.0, 1.0, 1.0)) -> np.ndarray:
    """An RGB frame from a luminance field. R = G = B (tint 1) keeps Y = y."""
    y = np.asarray(y, dtype=np.float64)
    return np.stack([y * t for t in tint], axis=-1)


def synthetic_frames() -> list[tuple[str, np.ndarray]]:
    """RFC §6's frames with known answers, plus the ones that stress the ranks."""
    frames = []
    frames.append(("uniform_midgrey", grey(np.full((90, 120), MIDGRAY))))

    y = np.full((100, 200), MIDGRAY)
    y[10:20, 150:160] = 64 * MIDGRAY          # 0.5 % of the frame at 64x
    frames.append(("patch_0.5pct_64x", grey(y)))

    frames.append(("no_highlights", grey(np.linspace(0.05, 0.3, 90 * 120).reshape(90, 120))))

    y = np.full((100, 200), MIDGRAY)
    y[:, :20] = MIDGRAY * 2 ** 12             # past protect_highlights' clamp
    frames.append(("highlight_clamp", grey(y)))

    y = np.full((100, 200), MIDGRAY)
    y[:, :20] = MIDGRAY * 2 ** -11            # past protect_shadows' clamp
    frames.append(("shadow_clamp", grey(y)))

    # 10 001 distinct values, a ramp over +-5 stops, shuffled. n - 1 = 10 000,
    # so every rank index is an exact integer and every sample is distinct:
    # a rank one off changes every mode that reads it.
    i = np.arange(10001)
    y = MIDGRAY * 2.0 ** (5.0 * (i - 5000) / 5000)
    frames.append(("ramp_distinct_73x137",
                   grey(np.random.default_rng(1).permutation(y).reshape(73, 137))))

    # Coloured log-normal noise, n = 181 * 221 = 40 001: exact ranks again,
    # with a real Y row doing the mixing rather than R = G = B.
    rng = np.random.default_rng(2)
    rgb = np.exp(rng.normal(np.log(0.15), 1.6, (181, 221, 3)))
    rgb *= np.array([1.1, 1.0, 0.8])
    frames.append(("lognormal_181x221_exact_ranks", rgb))

    # At the live tier's limit (not resampled), strided by 7 in check (c),
    # a black border, a lamp and a sky: the RFC's hard cases, synthetically.
    rng = np.random.default_rng(3)
    h, w = 1200, 1600
    yy, xx = np.mgrid[0:h, 0:w]
    base = 0.08 * 2.0 ** (3.0 * (1.0 - yy / h) - 1.0)          # a sky at the top
    field = base[..., None] * np.exp(rng.normal(0.0, 0.5, (h, w, 3)))
    field[:40] = 0.0                                              # a scan border
    field[600:640, 900:940] = 40.0                                # a lamp
    frames.append(("hard_cases_1600x1200", field))

    return [(name, np.ascontiguousarray(np.clip(f, 0.0, None).astype(np.float32)))
            for name, f in frames]


def smoke_frame() -> tuple[str, np.ndarray] | None:
    path = REPO / "tests/Test_image/_smoke_1mp.tif"
    if not path.exists():
        return None
    from spektrafilm.utils.io import load_image_oiio
    array = np.asarray(load_image_oiio(str(path)), dtype=np.float32)[..., :3]
    return ("smoke_1mp", np.ascontiguousarray(array))


def real_frames() -> list[tuple[str, np.ndarray]]:
    """RAW files through the fork's own decoder, at the live tier, cached."""
    from spektrafilm.service.engine import _load_image
    from spektrafilm.utils.preview import resize_for_preview

    out = []
    CACHE.mkdir(parents=True, exist_ok=True)
    for rel in REAL_FRAMES:
        path = REPO / rel
        if not path.exists():
            print(f"skip {rel}: not present")
            continue
        cached = CACHE / (path.stem + "_live.npy")
        if cached.exists():
            array = np.load(cached)
        else:
            image, detected = _load_image(path)
            assert detected["input_color_space"] == COLOR_SPACE
            assert detected["input_cctf_decoding"] is False
            array = resize_for_preview(np.asarray(image, dtype=np.float32)[..., :3], 1600)
            array = np.ascontiguousarray(array.astype(np.float32))
            np.save(cached, array)
        out.append((f"raw_{path.stem}", array))
    return out


def stride_step(frame: np.ndarray) -> int:
    """The stride that brings a frame to at most 256 px (`small_preview`'s formula)."""
    n = max(frame.shape[:2])
    return int(math.ceil(n / 256)) if n > 256 else 1


# --- the Python reference -----------------------------------------------------


def python_evs(frame: np.ndarray) -> dict:
    """Every method's EV on `frame`, straight from `utils/autoexposure.py`."""
    from spektrafilm.utils import autoexposure as ae

    out = {m: float(ae.measure_autoexposure_ev(frame, COLOR_SPACE, False, method=m))
           for m in LEGACY}
    out.update(ae.measure_autoexposure_evs_by_method(frame, COLOR_SPACE, False))
    return out


@dataclass
class Reference:
    name: str
    frame: np.ndarray
    step: int
    full: dict          # on the whole frame: the session meter, what every tier applies
    strided: dict       # on frame[::step, ::step]: check (c)'s second frame


def reference(name: str, frame: np.ndarray) -> Reference:
    step = stride_step(frame)
    return Reference(name, frame, step, python_evs(frame), python_evs(frame[::step, ::step]))


# --- negative controls: the Python side, perturbed -----------------------------


@contextmanager
def perturbed(kind: str):
    """Patch the production module in place, so a control perturbs the real
    function rather than a copy of it."""
    from spektrafilm.utils import autoexposure as ae

    saved = {k: getattr(ae, k) for k in ("_rank_percentile", "_luminance_y",
                                         "LOG_Y_FLOOR", "S_HI")}
    try:
        if kind == "P99 one rank high":
            def rank(a, q10, _orig=saved["_rank_percentile"]):
                if q10 != 990:
                    return _orig(a, q10)
                s = np.sort(a)
                return float(s[min(s.size - 1, (q10 * (s.size - 1)) // 1000 + 1)])
            ae._rank_percentile = rank
        elif kind == "P99.5 one rank low":
            def rank(a, q10, _orig=saved["_rank_percentile"]):
                if q10 != 995:
                    return _orig(a, q10)
                s = np.sort(a)
                return float(s[max(0, (q10 * (s.size - 1)) // 1000 - 1)])
            ae._rank_percentile = rank
        elif kind == "np.percentile interpolation":
            ae._rank_percentile = lambda a, q10: float(np.percentile(a, q10 / 10))
        elif kind == "floor at 2^-11":
            ae.LOG_Y_FLOOR = MIDGRAY * 2.0 ** -11
        elif kind == "S_HI + 1e-6":
            ae.S_HI = saved["S_HI"] + 1e-6
        elif kind == "luminance in float32":
            def lum(image, cs, cctf, _orig=saved["_luminance_y"]):
                return _orig(np.asarray(image, dtype=np.float32), cs, cctf).astype(np.float32)
            ae._luminance_y = lum
        else:
            raise ValueError(kind)
        yield
    finally:
        for k, v in saved.items():
            setattr(ae, k, v)


CONTROLS = ["P99 one rank high", "P99.5 one rank low", "np.percentile interpolation",
            "floor at 2^-11", "S_HI + 1e-6", "luminance in float32"]


def over(a: dict, b: dict, methods) -> list[tuple[str, float]]:
    return [(m, abs(a[m] - b[m])) for m in methods if not abs(a[m] - b[m]) <= EV_TOLERANCE]


def run_controls(refs: list[Reference], observed: dict[str, dict]) -> int:
    """Each perturbation must turn at least one comparison red.

    `observed` is what the other side reported per frame: the C++ engine's
    numbers, or with --python-only the unperturbed reference (so this then
    shows that the frame set can see each perturbation at all).
    """
    failures = 0
    print("\n(d) negative controls: the Python side perturbed, compared again")
    for kind in CONTROLS:
        with perturbed(kind):
            hits = []
            for ref in refs:
                if ref.name not in observed:
                    continue
                bad = over(python_evs(ref.frame), observed[ref.name], NEW)
                hits += [(ref.name, m, d) for m, d in bad]
        frames_hit = sorted({h[0] for h in hits})
        if not hits:
            print(f"FAIL control {kind!r}: nothing went red -- the check cannot see it")
            failures += 1
        else:
            worst = max(hits, key=lambda h: h[2])
            print(f"ok   control {kind!r}: {len(hits)} red across {len(frames_hit)} frames "
                  f"(worst {worst[2]:.2e} EV, {worst[0]}/{worst[1]})")
    return failures


# --- the checks ------------------------------------------------------------


def print_reference_table(refs: list[Reference]) -> None:
    print("Python reference EVs: the session meter (whole frame), and (c) the same frame strided to <= 256 px")
    header = f"{'frame':32s} {'size':>10s} {'step':>4s} " + " ".join(f"{m[:12]:>13s}" for m in NEW)
    print(header)
    for ref in refs:
        h, w = ref.frame.shape[:2]
        print(f"{ref.name:32s} {f'{w}x{h}':>10s} {ref.step:4d} "
              + " ".join(f"{ref.full[m]:+13.6f}" for m in NEW))
        print(f"{'':32s} {'':>10s} {'strd':>4s} "
              + " ".join(f"{ref.strided[m]:+13.6f}" for m in NEW))


# The frames are float32, because that is what `spk_open` takes, so a known
# answer holds to float32 input rounding, not to float64: float32(0.184) is
# 0.18400000036, which is already -2.8e-9 EV. Relative rounding <= 2^-24 is
# <= 8.6e-8 EV. The clamps are exact whatever the input, so those stay `==`.
KNOWN_ANSWER_TOLERANCE = 1e-7


def check_known_answers(refs: dict[str, Reference]) -> int:
    """RFC §6's synthetic answers, on the reference itself."""
    failures = 0
    checks = []
    tol = KNOWN_ANSWER_TOLERANCE
    r = refs["uniform_midgrey"].full
    checks += [(f"uniform_midgrey {m} == 0 ({r[m]:+.1e})", abs(r[m]) < tol) for m in NEW]
    r = refs["patch_0.5pct_64x"].full
    checks.append((f"patch: balanced {r['balanced']:+.2e} within 0.05 of 0, "
                   f"linear mean {r['average']:+.4f}", abs(r["balanced"]) < 0.05
                   and abs(r["average"] + math.log2(1.315)) < 1e-6))
    r = refs["no_highlights"].full
    checks.append(("no_highlights: protect_highlights == balanced",
                   r["protect_highlights"] == r["balanced"]))
    r = refs["highlight_clamp"].full
    checks.append(("highlight_clamp: protect_highlights == balanced - 3",
                   r["protect_highlights"] == r["balanced"] - 3))
    r = refs["shadow_clamp"].full
    checks.append(("shadow_clamp: protect_shadows == balanced + 2",
                   r["protect_shadows"] == r["balanced"] + 2))
    r = refs["ramp_distinct_73x137"].full
    checks.append((f"ramp: balanced {r['balanced']:+.1e} (0), protect_highlights "
                   f"{r['protect_highlights']:+.9f} (-2.45), protect_shadows "
                   f"{r['protect_shadows']:+.9f} (+1)",
                   abs(r["balanced"]) < tol and abs(r["protect_highlights"] + 2.45) < tol
                   and abs(r["protect_shadows"] - 1.0) < tol))
    for ref in refs.values():
        if ref.step == 1:
            checks.append((f"{ref.name}: <= 256 px, so the strided frame is the frame",
                           all(ref.strided[m] == ref.full[m] for m in NEW + LEGACY)))
    for label, ok in checks:
        print(f"{'ok  ' if ok else 'FAIL'} {label}")
        failures += not ok
    return failures


def check_engine(refs: list[Reference], verbose: bool) -> tuple[int, dict[str, dict]]:
    """(a), (b), (c) against the shipping dylib. Returns failures and what the
    engine reported for the new modes, per frame, for the negative controls."""
    from spk_ctypes import Engine, EngineError

    failures = 0
    observed: dict[str, dict] = {}
    worst = {"legacy_solve": 0.0, "legacy_strided": 0.0, "new_solve": 0.0, "new_strided": 0.0}
    with Engine() as engine:
        names = [f["name"] for f in engine.params_schema()["fields"]]
        if "auto_exposure_method" not in names:
            print("FAIL the engine does not declare auto_exposure_method; "
                  "only the default (center_weighted) can be compared")
            failures += 1
        for ref in refs:
            h, w = ref.frame.shape[:2]
            print(f"\n{ref.name}  {w}x{h}, (c) stride {ref.step}")
            try:
                full = engine.open(ref.frame, BASE)
                small = engine.open(np.ascontiguousarray(ref.frame[::ref.step, ::ref.step]), BASE)
            except EngineError as exc:
                print(f"FAIL open: {exc}")
                failures += 1
                continue
            with full, small:
                by_method_seen = []
                for method in LEGACY + NEW:
                    try:
                        full.set_params({"auto_exposure_method": method})
                        small.set_params({"auto_exposure_method": method})
                    except EngineError as exc:
                        if method != "center_weighted":
                            print(f"FAIL {method}: set_params refused: {exc}")
                            failures += 1
                            continue
                    try:
                        sf, ss = full.solve("exposure"), small.solve("exposure")
                    except EngineError as exc:
                        print(f"FAIL {method}: solve: {exc}")
                        failures += 1
                        continue
                    ev_full = sf["solved_params"]["exposure_compensation_ev"]
                    ev_strided = ss["solved_params"]["exposure_compensation_ev"]
                    problems = []
                    # Swift decodes solved_params as [String: Double].
                    if not all(isinstance(v, (int, float)) and not isinstance(v, bool)
                               for v in sf["solved_params"].values()):
                        problems.append("solved_params holds a non-number")
                    d_full = abs(ev_full - ref.full[method])
                    d_strided = abs(ev_strided - ref.strided[method])
                    kind = "legacy" if method in LEGACY else "new"
                    worst[f"{kind}_solve"] = max(worst[f"{kind}_solve"], d_full)
                    worst[f"{kind}_strided"] = max(worst[f"{kind}_strided"], d_strided)
                    if not d_full <= EV_TOLERANCE:
                        problems.append(f"solve {ev_full:+.12f}, Python {ref.full[method]:+.12f}")
                    if not d_strided <= EV_TOLERANCE:
                        problems.append(f"strided {ev_strided:+.12f}, Python {ref.strided[method]:+.12f}")
                    if np.float32(2.0 ** ev_full) != np.float32(2.0 ** ref.full[method]):
                        problems.append("the applied gain differs after the float32 narrowing")
                    bm = sf.get("exposure_ev_by_method")
                    if bm is None:
                        problems.append("no exposure_ev_by_method beside solved_params")
                    else:
                        by_method_seen.append(bm)
                        if method in NEW and bm.get(method) != ev_full:
                            problems.append(f"exposure_compensation_ev {ev_full!r} is not "
                                            f"exposure_ev_by_method[{method!r}] {bm.get(method)!r}")
                    if "exposure_ev_by_method" in sf["solved_params"]:
                        problems.append("exposure_ev_by_method is inside solved_params")
                    if ref.step == 1 and ev_strided != ev_full:
                        problems.append("<= 256 px but the strided frame meters differently")
                    failures += report(f"{method:18s}", problems, verbose,
                                       f"solve {ev_full:+.9f}  strided {ev_strided:+.9f}  "
                                       f"|C++ - Py| {d_full:.1e} / {d_strided:.1e}")
                if by_method_seen:
                    first = by_method_seen[0]
                    if any(bm != first for bm in by_method_seen[1:]):
                        failures += report("exposure_ev_by_method", ["changes with the session's "
                                           "method; it must not"], verbose, "")
                    bad = over(first, ref.full, NEW) if set(first) >= set(NEW) else [("keys", 1.0)]
                    observed[ref.name] = first
                    failures += report("exposure_ev_by_method", [f"{m} off by {d:.2e}" for m, d in bad],
                                       verbose, "all four within 1e-9 of Python")
                failures += check_node_render(engine, full, ref, verbose)
    print(f"\nworst |C++ - Python|: legacy solve {worst['legacy_solve']:.2e}, legacy strided "
          f"{worst['legacy_strided']:.2e}, new solve {worst['new_solve']:.2e}, "
          f"new strided {worst['new_strided']:.2e} EV (bar {EV_TOLERANCE:.0e})")
    return failures, observed


def check_node_render(engine, session, ref: Reference, verbose: bool) -> int:
    """The node's gain, end to end: meter on == pre-multiplied by Python's gain, meter off.

    The node applies the session's one meter of the frame, which on these
    frames (<= 1600 px, no geometry) is the whole frame: `ref.full`."""
    from spk_ctypes import EngineError

    failures = 0
    for method in LEGACY + NEW:
        try:
            session.set_params({"auto_exposure_method": method})
        except EngineError:
            if method != "center_weighted":
                continue
        metered, _ = session.render("live")
        gain = np.float32(2.0 ** ref.full[method])
        with engine.open(ref.frame * gain, {**BASE, "auto_exposure": False}) as manual:
            by_hand, _ = manual.render("live")
        worst = int(np.abs(metered.astype(np.int32) - by_hand.astype(np.int32)).max())
        failures += report(f"{method:18s} render", [] if worst == 0 else
                           [f"meter on vs Python's gain by hand: {worst} counts"], verbose,
                           "meter on == Python's float32 gain by hand, bit for bit")
    return failures


def render_resolution(engine, ref: Reference) -> int:
    """How small a gain error the render comparison can see, on this frame."""
    with engine.open(ref.frame * np.float32(2.0 ** ref.full["balanced"]),
                     {**BASE, "auto_exposure": False}) as s:
        exact, _ = s.render("live")
    seen = None
    for delta in (1e-9, 1e-8, 1e-7, 1e-6, 1e-5, 1e-4):
        gain = np.float32(2.0 ** (ref.full["balanced"] + delta))
        with engine.open(ref.frame * gain, {**BASE, "auto_exposure": False}) as s:
            moved, _ = s.render("live")
        changed = int((moved != exact).sum())
        print(f"     gain error {delta:.0e} EV: {changed} of {moved[..., :3].size} values change")
        if changed and seen is None:
            seen = delta
    if seen is None:
        print(f"FAIL the render check could not see a 1e-4 EV gain error on {ref.name}")
        return 1
    print(f"ok   the render check resolves {seen:.0e} EV on {ref.name}")
    return 0


def report(label: str, problems: list[str], verbose: bool, detail: str) -> int:
    if problems:
        print(f"FAIL {label}: {'; '.join(problems)}")
        return 1
    if verbose:
        print(f"ok   {label}: {detail}")
    return 0


# --- RFC-015 P.1: one EV per frame, at every tier ----------------------------------
#
# Each tier used to meter its own image, so the export was exposed differently
# from the canvas: on 13 RAWs up to 0.095 EV at the node and +0.069 EV of print
# luminance. The session now meters once (a METER_LONG_EDGE image, after
# decode_input and geometry) and every tier applies that EV. These run on
# full-resolution RAWs; before the engine change, (c1)-(c3) and (c5) are red,
# which is their control.

SEVEN = LEGACY + NEW
TIER_RAWS = REAL_FRAMES + ["tests/Test_image/Nikon Z7ii/_DSC2704.NEF"]
# What Params.swift sends for a new frame, minus the two stochastic stages.
APP = {"film_stock": "kodak_portra_400", "print_stock": "kodak_supra_endura",
       "film_format_mm": 36.0, "grain_active": False, "grain_sublayers_active": False,
       "halation_active": True, "glare_active": False, "auto_exposure": True,
       "input_color_space": COLOR_SPACE, "input_cctf_decoding": False}
# Export vs canvas once the meter is shared: measured residual <= 0.0024 EV on
# five RAWs with the meter equalised by hand; today up to 0.069.
DOWNSCALE_BAR_EV = 0.005
# (c3) cases over the bar for a reason that is not the meter. Each must still
# be over it: one that comes back within the bar fails, so the list cannot go
# stale. Measured: _DSC2704 center_weighted +0.0057 EV luminance / +0.0079
# worst channel, average +0.0046 / +0.0062, and the same with the meter off
# and both tiers exposed by hand at the same gain.
C3_KNOWN = {("_DSC2704", "center_weighted"), ("_DSC2704", "average")}
C3_KNOWN_REASON = ("not the meter: identical with meter off; tracked by the pixel-unit "
                   "sharpening/glare item")
# C++ vs Python once the EV comes from a downscaled image: bounded by the two
# downscalers, <= 1.3e-7 EV on 11 of 13 RAWs and 4.8e-4 on the worst.
CROSS_ENGINE_BAR_EV = 1e-3


def python_meter(frame: np.ndarray, delta: dict) -> dict:
    """The Python reference's session meter for these params: all seven EVs."""
    from spektrafilm.runtime.params_builder import digest_params, init_params
    from spektrafilm.service import schema
    from spektrafilm.service.session import RenderSession

    params = init_params(film_profile=delta.get("film_stock", "kodak_portra_400"),
                         print_profile=delta.get("print_stock", "kodak_portra_endura"))
    carry = {k: v for k, v in delta.items() if k not in ("film_stock", "print_stock")}
    schema.validate_delta(carry)
    schema.apply_delta(params, carry)
    params.settings.working_precision = "float32"
    try:
        from spektrafilm.backends.metal import device as mdev
        params.settings.gpu_backend = "metal" if mdev.available() else ""
    except Exception:
        params.settings.gpu_backend = ""
    return RenderSession("parity", None, frame, digest_params(params), {}).meter_evs()


def load_full_res(engine, rel: str) -> np.ndarray | None:
    """A RAW at native resolution, decoded by the fork's loader. Centre-cropped
    only if the engine refuses its size (the 60 MP cap, until it is raised)."""
    from spektrafilm.service.engine import _load_image
    from spk_ctypes import EngineError

    path = REPO / rel
    if not path.exists():
        print(f"skip {rel}: not present")
        return None
    img = np.ascontiguousarray(np.asarray(_load_image(path)[0], dtype=np.float32)[..., :3])
    try:
        engine.open(img, APP).close()
    except EngineError as exc:
        h, w = img.shape[:2]
        keep = int(60e6 // h)
        img = np.ascontiguousarray(img[:, (w - keep) // 2:(w - keep) // 2 + keep])
        print(f"note {path.name}: engine refused {w}x{h} ({exc}); centre-cropped to {keep}x{h}")
    return img


def export_vs_canvas(live_rgba: np.ndarray, full_rgba: np.ndarray) -> tuple[float, float]:
    """Full render downscaled to the live size vs the live render, in linear
    Display P3: (mean-luminance ΔEV, worst per-channel ΔEV). The engine's own
    downscale is not on the ABI; skimage agrees with it to <= 1.3e-7 EV on
    metering."""
    from spektrafilm.model import colour_baked as cb
    from spektrafilm.utils.preview import resize_for_preview

    def linear(rgba):
        v = rgba[..., :3].astype(np.float64) / 65535.0
        return np.asarray(cb.RGB_to_RGB(v, "Display P3", "Display P3", apply_cctf_decoding=True))

    live = linear(live_rgba)
    down = resize_for_preview(linear(full_rgba), max(live.shape[:2]))
    assert down.shape == live.shape, (down.shape, live.shape)
    y = lambda a: np.asarray(cb.RGB_to_XYZ(a, "Display P3"))[..., 1]
    d_lum = math.log2(y(down).mean() / y(live).mean())
    d_ch = max((math.log2(down[..., c].mean() / live[..., c].mean()) for c in range(3)), key=abs)
    return d_lum, d_ch


def check_tiers(verbose: bool) -> int:
    """(c1)-(c4) on full-resolution RAWs."""
    from spk_ctypes import Engine

    failures = 0
    worst_downscale, worst_cross = (0.0, ""), (0.0, "")
    with Engine() as engine:
        for rel in TIER_RAWS:
            img = load_full_res(engine, rel)
            if img is None:
                continue
            name = Path(rel).stem
            print(f"\n{name}  {img.shape[1]}x{img.shape[0]}")
            py = python_meter(img, APP)
            with engine.open(img, APP) as s:
                for method in SEVEN:
                    s.set_params({"auto_exposure_method": method})
                    ev = s.solve("exposure")["solved_params"]["exposure_compensation_ev"]
                    applied, outs = {}, {}
                    for tier in ("live", "preview", "full"):
                        outs[tier], _ = s.render(tier)
                        applied[tier] = s.progress().get("auto_exposure_ev")
                    problems = []
                    # (c1) the same EV at every tier, and it is solve's: ==, not ≈.
                    if any(v is None for v in applied.values()):
                        problems.append("the engine does not report auto_exposure_ev per render")
                    elif not all(v == ev for v in applied.values()):
                        problems.append("applied EV differs by tier: " + ", ".join(
                            f"{t} {v:+.6f}" for t, v in applied.items()) + f"; solve {ev:+.6f}")
                    # (c2) the export, bit for bit, is the frame exposed at solve's EV.
                    with engine.open(img * np.float32(2.0 ** ev), {**APP, "auto_exposure": False}) as m:
                        by_hand, _ = m.render("full")
                    counts = int(np.abs(outs["full"].astype(np.int32) - by_hand.astype(np.int32)).max())
                    if counts:
                        problems.append(f"export is not the frame at solve's EV: {counts} counts off")
                    # (c3) the export looks like the canvas.
                    d_lum, d_ch = export_vs_canvas(outs["live"], outs["full"])
                    if max(abs(d_lum), abs(d_ch)) > abs(worst_downscale[0]):
                        worst_downscale = (max(abs(d_lum), abs(d_ch)), f"{name}/{method}")
                    over_bar = abs(d_lum) > DOWNSCALE_BAR_EV or abs(d_ch) > DOWNSCALE_BAR_EV
                    c3 = (f"export vs canvas {d_lum:+.4f} EV luminance, "
                          f"{d_ch:+.4f} worst channel (bar {DOWNSCALE_BAR_EV})")
                    if (name, method) in C3_KNOWN:
                        if over_bar:
                            print(f"known {method:18s}: {c3} -- {C3_KNOWN_REASON}")
                        else:
                            problems.append(f"{c3}: unexpectedly within bar: remove from C3_KNOWN")
                    elif over_bar:
                        problems.append(c3)
                    # (c4) C++ and Python meter the same frame alike.
                    d_py = abs(ev - py[method])
                    if d_py > worst_cross[0]:
                        worst_cross = (d_py, f"{name}/{method}")
                    if d_py > CROSS_ENGINE_BAR_EV:
                        problems.append(f"C++ {ev:+.6f} vs Python {py[method]:+.6f} EV")
                    failures += report(f"{method:18s}", problems, verbose,
                                       f"EV {ev:+.6f} at every tier; export vs canvas "
                                       f"{d_lum:+.4f} / {d_ch:+.4f} EV; |C++ - Py| {d_py:.1e}")
            del img
    print(f"\nworst export vs canvas {worst_downscale[0]:.4f} EV ({worst_downscale[1]}); "
          f"worst |C++ - Python| meter {worst_cross[0]:.1e} EV ({worst_cross[1]})")
    return failures


def meter_walk_frame() -> np.ndarray:
    """Small enough to walk the schema quickly, uneven enough that a crop,
    a flip-free rotation or a colour space moves the meter."""
    rng = np.random.default_rng(8)
    h, w = 400, 600
    yy, xx = np.mgrid[0:h, 0:w] / np.array([h, w])[:, None, None]
    base = 0.05 * 2.0 ** (4.0 * xx * (1.0 - 0.5 * yy))
    rgb = base[..., None] * np.array([1.2, 1.0, 0.7]) * np.exp(rng.normal(0.0, 0.3, (h, w, 3)))
    return np.ascontiguousarray(rgb.astype(np.float32))


def check_meter_walk(verbose: bool) -> int:
    """(c5) For every wire field: after `set_params`, the engine's EVs equal a
    fresh Python meter of the same params. A cache key that misses an upstream
    field leaves a stale EV and fails here, for that field."""
    from parity_session import value_for
    from spk_ctypes import Engine, EngineError

    frame = meter_walk_frame()
    base = {"grain_active": False, "glare_active": False,
            "input_color_space": COLOR_SPACE, "input_cctf_decoding": False}
    failures = 0
    with Engine() as engine:
        fields = engine.params_schema()["fields"]
        print(f"\n(c5) meter cache walk: {len(fields)} fields, {frame.shape[1]}x{frame.shape[0]} frame")
        for field in fields:
            name, value = field["name"], value_for(field)
            delta = {**base, name: value}
            method = delta.get("auto_exposure_method", "center_weighted")
            try:
                with engine.open(frame, base) as s:
                    s.solve("exposure")                      # warm the cache
                    s.set_params({name: value})
                    out = s.solve("exposure")
            except EngineError as exc:
                failures += report(f"{name:26s}", [f"engine: {exc}"], verbose, "")
                continue
            got = {**out.get("exposure_ev_by_method", {}),
                   method: out["solved_params"]["exposure_compensation_ev"]}
            want = python_meter(frame, delta)
            # No downscale at this size, so the inputs are identical, except
            # where an engine changes the pixels before the meter: geometry
            # (each resamples on its own) and the input decode (float32 on
            # the device in C++, float64 in Python).
            gpu_touched = name.startswith("geometry_") or name == "input_cctf_decoding"
            bar = CROSS_ENGINE_BAR_EV if gpu_touched else EV_TOLERANCE
            bad = [f"{m} C++ {got[m]:+.6f} vs Python {want[m]:+.6f}"
                   for m in got if not abs(got[m] - want[m]) <= bar]
            failures += report(f"{name:26s}", bad, verbose, f"= {value!r}: EVs match")
    return failures


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python-only", action="store_true",
                    help="no dylib: reference numbers, known answers, negative controls")
    ap.add_argument("--no-real", action="store_true", help="skip the RAW-derived frames")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    from spektrafilm.utils import autoexposure as ae
    print(f"Python reference: {ae.__file__}")
    frames = synthetic_frames()
    smoke = smoke_frame()
    if smoke:
        frames.insert(0, smoke)
    if not args.no_real:
        frames += real_frames()
    refs = [reference(name, frame) for name, frame in frames]
    by_name = {r.name: r for r in refs}

    failures = 0
    print_reference_table(refs)
    print("\nRFC §6 known answers (Python reference)")
    failures += check_known_answers(by_name)

    if args.python_only:
        observed = {r.name: {m: r.full[m] for m in NEW} for r in refs}
    else:
        print("\n(a)-(c) against the engine")
        got, observed = check_engine(refs, args.verbose)
        failures += got
        from spk_ctypes import Engine
        print("\nrender check resolution")
        with Engine() as engine:
            failures += render_resolution(engine, by_name.get("smoke_1mp", refs[0]))
        failures += check_meter_walk(args.verbose)
        if not args.no_real:
            print("\n(c1)-(c4) one EV at every tier, full-resolution RAWs")
            failures += check_tiers(args.verbose)
    failures += run_controls(refs, observed)

    print(f"\n{failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
