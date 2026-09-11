"""Hold the ported LUT paths against the Python reference.

The sixth parity harness, and the one for `preview_stock_lut` and
`export_di` -- the two methods ARCHITECTURE §8.8 listed as refused by name
until this session. Like the other five it drives the **shipping dylib**
through `ctypes`; the oracle is `service/engine.py`'s own code, reached
directly rather than reimplemented here.

Three things are checked, and they fail for different reasons:

1. **The table.** `spk_print_lut_table` against the shipped `.npz`, bit for
   bit. It goes through numpy -> the blob -> a float64 widening -> a float32
   narrowing, and a table that arrived transposed or off by an entry would
   still produce a plausible photograph, which is RFC-012 §4.1's named
   failure mode. Bit-exact is the right bar because nothing in that chain is
   arithmetic.

2. **The apply.** `spk_preview_stock_lut` against
   `engine._apply_lut_cpu(reference negative, ...)` -- the scipy trilinear
   path the Metal kernel was validated against at 2.4e-7 when both read the
   *same* negative. Here they do not: the C++ negative comes off the GPU and
   the reference's off numba, so this inherits `parity_render`'s error rather
   than the kernel's, and carries `parity_render`'s bar for the same reason.

3. **The DI normalisation.** `spk_export_di` against
   `clip((negative - lo) / (hi - lo), 0, 1)` with the LUT's own axes -- the
   expression in `RenderEngine.di_package`, which is what makes the `.cube`'s
   domain 0..1.

Grain and glare are off throughout, for `parity_render`'s reason: they are
stochastic and drawn from different generators on the two sides. Glare is
additionally not in the LUT at all and is not meant to be
(HANDOFF-PRINT-LUT §2).

Usage:
    engine/tests/parity_lut.py [--stock NAME] [--verbose]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

ENGINE = Path(__file__).resolve().parents[1]
REPO = ENGINE.parent
sys.path.insert(0, str(REPO / "src"))
sys.path.insert(0, str(ENGINE / "tests"))

# `parity_render`'s bars, and for its reason: the two engines are compared
# through their own negatives, so what is measured here is the accumulated
# float32 error of the film side plus one trilinear sample, not the kernel's.
FLOAT_TOLERANCE = 3e-5
COUNT_TOLERANCE = 1.0
COUNT_OUTLIER_FRACTION = 1e-5

BASE = {"grain_active": False, "glare_active": False, "auto_exposure": False}

# One paired case (the LUT's own film), one mismatched (which must warn), and
# one non-default paper, so the stock lookup is exercised as well as the
# kernel.
CASES = [
    ("kodak_portra_endura", "kodak_portra_400"),
    ("kodak_2383", "kodak_vision3_250d"),
    ("fujifilm_crystal_archive_typeii", "kodak_portra_400"),   # mismatched on purpose
]


def load_frame() -> np.ndarray:
    from spektrafilm.utils.io import load_image_oiio
    array = np.asarray(load_image_oiio(str(REPO / "tests/Test_image/_smoke_1mp.tif")),
                       dtype=np.float32)
    return np.ascontiguousarray(array[..., :3])


def reference_negative(frame: np.ndarray, film: str, paper: str) -> np.ndarray:
    """`Tap.RGB_IN` -> `Tap.CMY_FILM` through numba, at the full tier.

    The same entry and exit `RenderSession.negative` uses, built here rather
    than through a session because the harness has no workspace and wants the
    array, not a file.
    """
    from spektrafilm.runtime.params_builder import digest_params, init_params
    from spektrafilm.runtime.pipeline import SimulationPipeline, Tap
    from spektrafilm.service import schema

    params = init_params(film_profile=film, print_profile=paper)
    params.io.output_color_space = "Display P3"      # `spk_open`'s convention
    params.io.output_cctf_encoding = True
    schema.apply_delta(params, dict(BASE))
    params.settings.working_precision = "float32"
    params.settings.gpu_backend = ""                  # numba: the oracle
    pipeline = SimulationPipeline(digest_params(params))
    return np.asarray(pipeline.process(frame, inject=Tap.RGB_IN, collect=Tap.CMY_FILM),
                      dtype=np.float64)


def to_counts(array: np.ndarray) -> np.ndarray:
    clipped = np.clip(np.asarray(array, dtype=np.float32), 0.0, 1.0)
    return (clipped * 65535.0 + 0.5).astype(np.uint16)


def compare(label: str, got_rgba: np.ndarray, want: np.ndarray, verbose: bool) -> bool:
    """`parity_render.compare`, minus the divergence cases it has and this
    does not."""
    if got_rgba.shape[:2] != want.shape[:2]:
        print(f"FAIL {label}: shape {got_rgba.shape[:2]} from C++, {want.shape[:2]} from Python")
        return False
    counts_a = got_rgba[..., :3].astype(np.int32)
    counts_b = to_counts(want).astype(np.int32)
    count_delta = np.abs(counts_a - counts_b)
    worst_counts = int(count_delta.max())
    over = int((count_delta > COUNT_TOLERANCE).sum())
    fraction = over / count_delta.size

    float_a = counts_a.astype(np.float64) / 65535.0
    float_b = np.clip(np.asarray(want, dtype=np.float64), 0.0, 1.0)
    float_delta = np.abs(float_a - float_b)
    worst_float = float(float_delta.max())

    ok = worst_float <= FLOAT_TOLERANCE and fraction <= COUNT_OUTLIER_FRACTION
    detail = (f"max {worst_float:.2e} absolute, {worst_counts} count"
              f"{'' if worst_counts == 1 else 's'}")
    if over:
        detail += f", {over} of {count_delta.size} ({100 * fraction:.5f} %) over 1 count"
    print(f"{'ok  ' if ok else 'FAIL'} {label}: {detail}")
    if not ok:
        idx = np.unravel_index(int(np.argmax(float_delta)), float_delta.shape)
        print(f"       worst at {idx}: C++ {float_a[idx]:.9f}, Python {float_b[idx]:.9f}")
    if verbose:
        for q in (50, 90, 99, 99.9):
            print(f"       p{q}: {np.percentile(float_delta, q):.2e} absolute")
    return ok


def check_tables(engine, luts: Path, verbose: bool) -> int:
    """Every shipped table, out of the blob and back, against the `.npz`."""
    failures = 0
    catalog = engine.print_lut_catalog()
    shipped = sorted(p.stem for p in luts.glob("*.npz"))
    if sorted(catalog) != shipped:
        print(f"FAIL catalog: engine has {sorted(catalog)}, the assets are {shipped}")
        failures += 1
    for stock in shipped:
        with np.load(luts / f"{stock}.npz", allow_pickle=False) as z:
            want = np.asarray(z["lut"], dtype=np.float32)
        got = engine.print_lut_table(stock)
        if got.shape != want.shape:
            print(f"FAIL table {stock}: shape {got.shape}, expected {want.shape}")
            failures += 1
            continue
        # Bit-exact: nothing between the `.npz` and this pointer is arithmetic,
        # so anything but zero here is a shape or an ordering bug.
        if not np.array_equal(got, want):
            worst = float(np.abs(got.astype(np.float64) - want.astype(np.float64)).max())
            print(f"FAIL table {stock}: not bit-exact, max |delta| {worst:.3e}")
            failures += 1
            continue
        if verbose:
            print(f"ok   table {stock}: {want.shape} bit-exact")
    if not failures:
        print(f"ok   tables: {len(shipped)} stocks, bit-exact out of the blob")
    return failures


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stock", action="append", help="run only these print stocks")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    from spk_ctypes import Engine

    from spektrafilm.service.engine import _apply_lut_cpu

    luts = REPO / "src/spektrafilm/data/luts/print_preview"
    frame = load_frame()
    print(f"frame: {frame.shape[1]}x{frame.shape[0]} "
          f"({frame.shape[0] * frame.shape[1] / 1e6:.2f} MP)\n")

    cases = [c for c in CASES if not args.stock or c[0] in args.stock]
    failures = 0
    with Engine() as engine:
        print(f"engine: {engine.build_info}")
        failures += check_tables(engine, luts, args.verbose)

        for paper, film in cases:
            with np.load(luts / f"{paper}.npz", allow_pickle=False) as z:
                lut, axes = np.asarray(z["lut"]), np.asarray(z["axes"])
            negative = reference_negative(frame, film, paper)

            delta = {**BASE, "film_stock": film, "print_stock": paper}
            try:
                with engine.open(frame, delta) as session:
                    preview, meta = session.preview_stock_lut(paper, "full")
                    di, di_meta = session.export_di(paper)
            except Exception as exc:
                print(f"FAIL {paper}: the engine refused -- {exc}")
                failures += 1
                continue

            want_preview = _apply_lut_cpu(negative.astype(np.float32), lut, axes)
            if not compare(f"preview {paper}", preview, want_preview, args.verbose):
                failures += 1

            lo, hi = axes[:, 0], axes[:, -1]
            want_di = np.clip((negative - lo) / (hi - lo), 0.0, 1.0)
            if not compare(f"di      {paper}", di, want_di, args.verbose):
                failures += 1

            # The mismatch warning is a contract, not a nicety: the table is
            # coupled to the negative's dye spectra, so a session on another
            # film is an approximation nobody has measured (PRD §7.3). It has
            # to be present when the films differ and absent when they do not.
            paired = meta["paired_film"]
            warned = "warning" in meta
            if warned != (paired != film):
                print(f"FAIL {paper}: paired_film {paired!r}, session film {film!r}, "
                      f"warning {'present' if warned else 'absent'}")
                failures += 1
            elif warned:
                print(f"ok   {paper}: warns that the LUT is paired with {paired!r}")
            if di_meta["paired_film"] != paired:
                print(f"FAIL {paper}: export_di reports paired_film {di_meta['paired_film']!r}, "
                      f"preview_stock_lut reports {paired!r}")
                failures += 1
            print(f"     apply {meta['apply_ms']:.2f} ms on {meta['apply_backend']}\n")

    print(f"{len(cases)} stocks, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
