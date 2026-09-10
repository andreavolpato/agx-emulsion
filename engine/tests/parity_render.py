"""Hold the C++ engine's picture against the numba reference, pixel for pixel.

RFC-014 §3: numba stays the oracle and the bar stays float32 storage epsilon;
only the language on the other side changes. This drives the **shipping
dylib** through `ctypes` (see `spk_ctypes.py`) and `SimulationPipeline`
through numba, on the same frame with the same parameters, and reports the
difference.

Grain and glare are off in every comparison. They are the only stochastic
stages, their realisation is drawn from a different generator by construction
(Philox on device against NumPy's PCG on the host), and RFC-014 §3 is explicit
that a correct port looks broken without this. Their *distributions* are
checked separately by `grain_moments.py`.

Two divergences are expected and are not failures. Both are marked
`expect_divergence=True`, so the harness fails if the two ever *agree* there --
which for the first would mean the port had inherited a bug.

`camera.lens_blur_um`: the Python engine prunes that node before
`pixel_size_um` exists, so the parameter has never done anything
(`max |out(0) - out(50 um)| == 0.0` exactly). The C++ engine computes the sigma
per run and the blur happens.

`dir_couplers_amount` above ~1.736: at that point the coupler inverse's own
exposure axis (`log_exposure - silver @ matrix`) stops being monotonic, and
`np.interp` requires an increasing `xp`. Past it the reference's output is a
product of numpy's internal binary search rather than of the model, so neither
engine is right and agreeing would be a coincidence. The wire allows the
parameter up to 4.0, which is worth knowing: the schema's range is wider than
the maths supports.

Usage:
    engine/tests/parity_render.py [--case NAME] [--size N] [--verbose]
"""
from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

ENGINE = Path(__file__).resolve().parents[1]
REPO = ENGINE.parent
sys.path.insert(0, str(REPO / "src"))
sys.path.insert(0, str(ENGINE / "tests"))

# The bar, and where each half of it comes from.
#
# RFC-011 held every ported *node* to float32 storage epsilon against numba,
# measured on one tap at a time. End to end through 21 nodes -- a bicubic LUT
# sample, an 81-term spectral integral, a CAM16 forward and inverse -- the
# accumulated float32 error is larger than one tap's, and it is the GPU's, not
# the port's. Measured on this frame, against the same numba reference:
#
#     Python Metal core (RFC-011, already validated)   1.9e-5
#     this C++ engine                                  2.3e-5
#
# So the absolute bar is set at 3e-5, just above what the validated core
# reaches, rather than at an epsilon no GPU path meets. That alone would hide a
# systematic shift, so it is paired with a count-level bar: essentially every
# value must land within one 16-bit count, which is the smallest difference the
# output format can express. A wrong constant fails the second bar long before
# the first (the print-balance bug this harness found was 2 counts over 93 % of
# the frame at 2e-4 absolute).
FLOAT_TOLERANCE = 3e-5
COUNT_TOLERANCE = 1.0
COUNT_OUTLIER_FRACTION = 1e-5

# Deterministic by construction: no grain, no glare, no auto-exposure (which
# would measure a different sample on each side).
BASE = {
    "grain_active": False,
    "glare_active": False,
    "auto_exposure": False,
}


@dataclass
class Case:
    name: str
    delta: dict = field(default_factory=dict)
    expect_divergence: bool = False
    note: str = ""


CASES = [
    Case("defaults"),
    Case("exposure_up", {"exposure_compensation_ev": 1.5}),
    Case("exposure_down", {"exposure_compensation_ev": -2.0}),
    Case("gamma", {"density_curve_gamma": 1.4}),
    Case("no_couplers", {"dir_couplers_active": False}),
    Case("coupler_amount", {"dir_couplers_amount": 1.5}),
    Case("coupler_amount_nonmonotonic", {"dir_couplers_amount": 2.0},
         expect_divergence=True,
         note="above amount ~1.736 (kodak_portra_400, bisected) the coupler inverse's own "
              "exposure axis stops being monotonic, so np.interp is outside its documented "
              "domain and the reference's output there is an artefact of its internal search; "
              "the wire allows up to 4.0"),
    Case("no_halation", {"halation_active": False}),
    Case("halation_amount", {"halation_amount": 2.5}),
    Case("boost", {"halation_boost_ev": 3.0}),
    Case("print_exposure", {"print_exposure": 1.6}),
    Case("filter_shift", {"m_filter_shift": 0.4, "y_filter_shift": -0.3}),
    Case("preflash", {"preflash_exposure": 0.35}),
    Case("scan_film", {"scan_film": True}),
    Case("srgb_out", {"output_color_space": "sRGB"}),
    Case("linear_out", {"output_cctf_encoding": False}),
    Case("prophoto_out", {"output_color_space": "ProPhoto RGB"}),
    Case("scanner_blur", {"scanner_lens_blur": 4.0}),
    Case("format_medium", {"film_format_mm": 60.0}),
    Case("crop", {"geometry_crop_x": 0.1, "geometry_crop_y": 0.05,
                  "geometry_crop_w": 0.6, "geometry_crop_h": 0.7}),
    Case("crop_rotated", {"geometry_crop_x": 0.1, "geometry_crop_y": 0.05,
                          "geometry_crop_w": 0.6, "geometry_crop_h": 0.7,
                          "geometry_rotation_deg": 7.5}),
    Case("quarter_turn", {"geometry_quarter_turns": 1}),
    Case("flips", {"geometry_flip_h": True, "geometry_flip_v": True}),
    Case("stock_gold", {"film_stock": "kodak_gold_200"}),
    Case("stock_positive", {"film_stock": "fujifilm_velvia_100"}),
    Case("paper_premier", {"print_stock": "kodak_endura_premier"}),
    Case("lens_blur", {"lens_blur_um": 50.0}, expect_divergence=True,
         note="the Python engine prunes this node before pixel_size_um exists, "
              "so the parameter does nothing there; the C++ engine applies it"),
]


def load_frame(size: int | None) -> np.ndarray:
    """The 1 MP smoke frame, or a deterministic synthetic one at `size`.

    RFC-014 §3 prescribes the 1 MP frame: a run is seconds, and a check
    affordable on every change is worth more than one run at the end.
    """
    if size is None:
        from spektrafilm.utils.io import load_image_oiio
        path = REPO / "tests/Test_image/_smoke_1mp.tif"
        array = np.asarray(load_image_oiio(str(path)), dtype=np.float32)
        return np.ascontiguousarray(array[..., :3])
    rng = np.random.default_rng(7)
    h = size
    w = int(size * 4 / 3)
    # A smooth base plus noise plus a few blown highlights, so the frame
    # exercises the toe, the shoulder and the highlight boost rather than
    # sitting in the linear middle.
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    base = 0.05 + 0.5 * (xx / w) * (1.0 - 0.4 * yy / h)
    array = np.stack([base, base * 0.8 + 0.05, base * 0.6 + 0.1], axis=-1)
    array += 0.03 * rng.standard_normal(array.shape).astype(np.float32)
    array[h // 4:h // 4 + h // 16, w // 3:w // 3 + w // 12] = 6.0
    return np.ascontiguousarray(np.clip(array, 0.0, None).astype(np.float32))


def reference_render(frame: np.ndarray, delta: dict) -> np.ndarray:
    """The same frame through numba, with the same resolved parameters."""
    from spektrafilm.runtime.params_builder import digest_params, init_params
    from spektrafilm.runtime.pipeline import SimulationPipeline
    from spektrafilm.service import schema

    resolved = {**BASE, **delta}
    params = init_params(film_profile=resolved.get("film_stock", "kodak_portra_400"),
                         print_profile=resolved.get("print_stock", "kodak_portra_endura"))
    # `spk_open`'s own convention, applied before the delta so an explicit
    # output space still wins.
    params.io.output_color_space = "Display P3"
    params.io.output_cctf_encoding = True
    carry = {k: v for k, v in resolved.items() if k not in ("film_stock", "print_stock")}
    schema.validate_delta(carry)
    schema.apply_delta(params, carry)
    params.settings.working_precision = "float32"
    params.settings.gpu_backend = ""      # numba: the oracle, not the GPU core
    params = digest_params(params)
    pipeline = SimulationPipeline(params)
    return np.asarray(pipeline.process(frame), dtype=np.float64)


def to_counts(array: np.ndarray) -> np.ndarray:
    """`service._write_rgba16`'s quantisation, so both sides are compared in
    the values that actually reach the canvas."""
    clipped = np.clip(np.asarray(array, dtype=np.float32), 0.0, 1.0)
    return (clipped * 65535.0 + 0.5).astype(np.uint16)


def compare(case: Case, got: np.ndarray, want: np.ndarray, verbose: bool) -> bool:
    if got.shape[:2] != want.shape[:2]:
        print(f"FAIL {case.name}: shape {got.shape[:2]} from C++, {want.shape[:2]} from numba")
        return False
    counts_a = got[..., :3].astype(np.int32)
    counts_b = to_counts(want).astype(np.int32)
    count_delta = np.abs(counts_a - counts_b)
    worst_counts = int(count_delta.max())
    over = int((count_delta > COUNT_TOLERANCE).sum())
    fraction = over / count_delta.size

    # The float comparison is against the engine's own output before
    # quantisation, so a value sitting on a rounding boundary is not counted
    # twice.
    float_a = counts_a.astype(np.float64) / 65535.0
    float_b = np.clip(np.asarray(want, dtype=np.float64), 0.0, 1.0)
    float_delta = np.abs(float_a - float_b)
    worst_float = float(float_delta.max())

    if case.expect_divergence:
        # The point of this case is that the two *must not* agree.
        if worst_counts <= COUNT_TOLERANCE:
            print(f"FAIL {case.name}: the two engines agree (max {worst_counts} counts), but this "
                  f"case exists because they must not -- {case.note}")
            return False
        print(f"ok   {case.name}: diverges by {worst_counts} counts as expected ({case.note})")
        return True

    ok = worst_float <= FLOAT_TOLERANCE and fraction <= COUNT_OUTLIER_FRACTION
    label = "ok  " if ok else "FAIL"
    detail = (f"max {worst_float:.2e} absolute, {worst_counts} count"
              f"{'' if worst_counts == 1 else 's'}")
    if over:
        detail += f", {over} of {count_delta.size} values ({100 * fraction:.5f} %) over 1 count"
    print(f"{label} {case.name}: {detail}")
    if not ok:
        idx = np.unravel_index(int(np.argmax(float_delta)), float_delta.shape)
        print(f"       worst at {idx}: C++ {float_a[idx]:.9f}, numba {float_b[idx]:.9f}")
        print(f"       bars: {FLOAT_TOLERANCE:.0e} absolute, "
              f"{COUNT_OUTLIER_FRACTION:.0e} of values over {COUNT_TOLERANCE:g} count")
    if verbose:
        for q in (50, 90, 99, 99.9):
            print(f"       p{q}: {np.percentile(float_delta, q):.2e} absolute")
    return ok


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", action="append", help="run only these cases")
    ap.add_argument("--size", type=int, default=None,
                    help="use a synthetic frame this many pixels tall instead of the 1 MP frame")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    from spk_ctypes import Engine

    frame = load_frame(args.size)
    print(f"frame: {frame.shape[1]}x{frame.shape[0]}  "
          f"({frame.shape[0] * frame.shape[1] / 1e6:.2f} MP), "
          f"range {frame.min():.4f}..{frame.max():.4f}\n")

    cases = [c for c in CASES if not args.case or c.name in args.case]
    failures = 0
    with Engine() as engine:
        print(f"engine: {engine.build_info}")
        caps = engine.capabilities()
        print(f"core:   {caps['backend']['render_core']} on {caps['backend']['gpu']}, "
              f"math {caps['backend']['math_mode']}\n")
        for case in cases:
            delta = {**BASE, **case.delta}
            try:
                with engine.open(frame, delta) as session:
                    rgba, _ = session.render("full")
            except Exception as exc:
                print(f"FAIL {case.name}: the engine refused -- {exc}")
                failures += 1
                continue
            want = reference_render(frame, case.delta)
            if not compare(case, rgba, want, args.verbose):
                failures += 1

    print(f"\n{len(cases)} cases, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
