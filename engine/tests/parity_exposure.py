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
     `solve` EV equals `measure_autoexposure_ev` on the same live tier, and
     the gain the C++ auto-exposure *node* applies equals the one the Python
     pipeline would apply.
  b. **The four new modes**: C++ `exposure_ev_by_method` (a sibling of
     `solved_params`, never inside it) equals
     `measure_autoexposure_evs_by_method` to 1e-9 EV. With a mode selected,
     `exposure_compensation_ev` is that mode's entry.
  c. **Solve vs node, per mode.** `solve` meters the whole live tier; the
     node meters a stride sample (`step = ceil(long_edge / 256)`). The
     difference is reported as a number per frame, and it must be exactly 0
     on frames of 256 px or less, where the two samples are the same.
  d. **Negative controls.** The Python side of each comparison is perturbed
     in five ways (a rank one off, interpolated percentiles, the floor, S_HI,
     float32 luminance) and the harness must go red for every one. Otherwise
     "within 1e-9" would mean nothing. The render check's own resolution is
     measured by sweeping a gain error until the picture changes.

How the node is observed. The C ABI has no tap after the auto-exposure node,
so the harness observes it twice:

  * **exactly**: the node meters `frame[::step, ::step]` (a pure gather,
    `spk_stride_sample`). A second session opened on that pre-strided frame
    is at most 256 px, so its stride is 1 and its `solve` reports the node's
    measurement exactly;
  * **end to end**: render with the meter on, and render the frame
    pre-multiplied by `float32(2^EV_python)` with the meter off. The node
    narrows its gain through float32 and multiplies, so if its EV is
    Python's, the two renders are bit-identical.

Frame sizes. Every frame is at most 1600 px on its long edge, so the live tier
shares the source on both sides (`tier_image`, `resize_for_preview`) and
nothing is resampled. The real frames are RAW files decoded to linear ProPhoto
by the fork's own loader, downscaled once on the host and cached. Both engines
receive that same float32 array. Frames over 256 px go through the node's
stride on both sides.

Grain and glare are off: they are stochastic, and a bit-identical render
comparison would measure the noise (RFC-013's grain trap).

Usage:
    engine/tests/parity_exposure.py [--python-only] [--no-real] [--verbose]

`--python-only` runs without the dylib: the reference numbers, the RFC §6
known answers, the stride-vs-full table, and the negative controls against
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

    # At the live tier's limit (not resampled) with a stride of 7 in the node,
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


def node_step(frame: np.ndarray) -> int:
    """`Pipeline::measure_exposure_ev`'s stride and `small_preview`'s: the same formula."""
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
    full: dict          # on the live tier: what `solve` reproduces
    node: dict          # on the stride sample: what the node applies


def reference(name: str, frame: np.ndarray) -> Reference:
    step = node_step(frame)
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
    print("(c) solve (whole live tier) vs node (stride sample), Python reference, EV")
    header = f"{'frame':32s} {'size':>10s} {'step':>4s} " + " ".join(f"{m[:12]:>13s}" for m in NEW)
    print(header)
    for ref in refs:
        h, w = ref.frame.shape[:2]
        print(f"{ref.name:32s} {f'{w}x{h}':>10s} {ref.step:4d} "
              + " ".join(f"{ref.full[m]:+13.6f}" for m in NEW))
        print(f"{'':32s} {'':>10s} {'node':>4s} "
              + " ".join(f"{ref.node[m]:+13.6f}" for m in NEW))
        print(f"{'':32s} {'':>10s} {'diff':>4s} "
              + " ".join(f"{ref.node[m] - ref.full[m]:+13.2e}" for m in NEW))


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
            checks.append((f"{ref.name}: <= 256 px, so node == solve exactly",
                           all(ref.node[m] == ref.full[m] for m in NEW + LEGACY)))
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
    worst = {"legacy_solve": 0.0, "legacy_node": 0.0, "new_solve": 0.0, "new_node": 0.0}
    with Engine() as engine:
        names = [f["name"] for f in engine.params_schema()["fields"]]
        if "auto_exposure_method" not in names:
            print("FAIL the engine does not declare auto_exposure_method; "
                  "only the default (center_weighted) can be compared")
            failures += 1
        for ref in refs:
            h, w = ref.frame.shape[:2]
            print(f"\n{ref.name}  {w}x{h}, node stride {ref.step}")
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
                    ev_node = ss["solved_params"]["exposure_compensation_ev"]
                    problems = []
                    # Swift decodes solved_params as [String: Double].
                    if not all(isinstance(v, (int, float)) and not isinstance(v, bool)
                               for v in sf["solved_params"].values()):
                        problems.append("solved_params holds a non-number")
                    d_full = abs(ev_full - ref.full[method])
                    d_node = abs(ev_node - ref.node[method])
                    kind = "legacy" if method in LEGACY else "new"
                    worst[f"{kind}_solve"] = max(worst[f"{kind}_solve"], d_full)
                    worst[f"{kind}_node"] = max(worst[f"{kind}_node"], d_node)
                    if not d_full <= EV_TOLERANCE:
                        problems.append(f"solve {ev_full:+.12f}, Python {ref.full[method]:+.12f}")
                    if not d_node <= EV_TOLERANCE:
                        problems.append(f"node {ev_node:+.12f}, Python {ref.node[method]:+.12f}")
                    if np.float32(2.0 ** ev_node) != np.float32(2.0 ** ref.node[method]):
                        problems.append("node gain differs after the float32 narrowing")
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
                    if ref.step == 1 and ev_node != ev_full:
                        problems.append("<= 256 px but node and solve differ")
                    failures += report(f"{method:18s}", problems, verbose,
                                       f"solve {ev_full:+.9f}  node {ev_node:+.9f}  "
                                       f"(stride-vs-full {ev_node - ev_full:+.2e})  "
                                       f"|C++ - Py| {d_full:.1e} / {d_node:.1e}")
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
    print(f"\nworst |C++ - Python|: legacy solve {worst['legacy_solve']:.2e}, legacy node "
          f"{worst['legacy_node']:.2e}, new solve {worst['new_solve']:.2e}, "
          f"new node {worst['new_node']:.2e} EV (bar {EV_TOLERANCE:.0e})")
    return failures, observed


def check_node_render(engine, session, ref: Reference, verbose: bool) -> int:
    """The node's gain, end to end: meter on == pre-multiplied by Python's gain, meter off."""
    from spk_ctypes import EngineError

    failures = 0
    for method in LEGACY + NEW:
        try:
            session.set_params({"auto_exposure_method": method})
        except EngineError:
            if method != "center_weighted":
                continue
        metered, _ = session.render("live")
        gain = np.float32(2.0 ** ref.node[method])
        with engine.open(ref.frame * gain, {**BASE, "auto_exposure": False}) as manual:
            by_hand, _ = manual.render("live")
        worst = int(np.abs(metered.astype(np.int32) - by_hand.astype(np.int32)).max())
        failures += report(f"{method:18s} render", [] if worst == 0 else
                           [f"meter on vs Python's gain by hand: {worst} counts"], verbose,
                           "meter on == Python's float32 gain by hand, bit for bit")
    return failures


def render_resolution(engine, ref: Reference) -> int:
    """How small a gain error the render comparison can see, on this frame."""
    with engine.open(ref.frame * np.float32(2.0 ** ref.node["balanced"]),
                     {**BASE, "auto_exposure": False}) as s:
        exact, _ = s.render("live")
    seen = None
    for delta in (1e-9, 1e-8, 1e-7, 1e-6, 1e-5, 1e-4):
        gain = np.float32(2.0 ** (ref.node["balanced"] + delta))
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
    failures += run_controls(refs, observed)

    print(f"\n{failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
