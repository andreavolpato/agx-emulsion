"""Check grain's *distribution*, since its realisation cannot be compared.

Grain is off in every case in `parity_render.py`, and has to be: the draws come
from Philox keyed on (pixel, stream, seed) on device and from NumPy's PCG on
the host, so the two realisations differ by construction and a correct port
looks broken pixel by pixel (RFC-014 §3, AGENTS.md trap 1).

What must match is the distribution at every density, including the third
moment -- which is the whole reason the sampler is an exact Poisson draw and
not a Gaussian approximation. Film's grain is visibly skewed differently in
the shadows than in the highlights, and a normal approximation destroys
exactly that (RFC-002).

So: render flat patches at a ladder of input levels through both engines with
grain on, and compare the mean, standard deviation and skewness of each patch.

Usage: engine/tests/parity_grain.py [--patch 256] [--verbose]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

ENGINE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ENGINE.parent / "src"))
sys.path.insert(0, str(ENGINE / "tests"))

# The bars, and why each is where it is. Every one is a *sampling* bar, not a
# numerical one: both sides draw a finite number of particles per pixel, so
# even two runs of the same engine differ by roughly 1/sqrt(N) in the mean and
# rather more in the third moment. The harness measures that self-variation
# first (`--verbose` prints it) and the bars sit above it.
MEAN_TOLERANCE = 4e-3      # absolute, on a [0, 1] output
STD_RATIO_TOLERANCE = 0.08
SKEW_TOLERANCE = 0.25

LEVELS = [0.01, 0.03, 0.06, 0.12, 0.184, 0.3, 0.5, 0.8, 1.5]


def moments(patch: np.ndarray) -> tuple[float, float, float]:
    flat = np.asarray(patch, dtype=np.float64).ravel()
    mean = float(flat.mean())
    std = float(flat.std())
    if std < 1e-12:
        return mean, std, 0.0
    skew = float((((flat - mean) / std) ** 3).mean())
    return mean, std, skew


def reference_patch(level: float, size: int, delta: dict) -> np.ndarray:
    from spektrafilm.runtime.params_builder import digest_params, init_params
    from spektrafilm.runtime.pipeline import SimulationPipeline
    from spektrafilm.service import schema

    frame = np.full((size, size, 3), level, dtype=np.float32)
    params = init_params()
    params.io.output_color_space = "Display P3"
    params.io.output_cctf_encoding = True
    schema.apply_delta(params, delta)
    params.settings.working_precision = "float32"
    params.settings.gpu_backend = ""
    # The reference's own stochastic sampler, so both sides are drawing fresh
    # grain rather than one seeded and one not.
    params.settings.grain_sampler = "stochastic"
    return np.asarray(SimulationPipeline(digest_params(params)).process(frame), dtype=np.float64)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--patch", type=int, default=256)
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    from spk_ctypes import Engine

    delta = {"auto_exposure": False, "glare_active": False, "grain_active": True}
    failures = 0
    print(f"flat patches of {args.patch}x{args.patch}, grain on, glare off\n")
    print(f"{'level':>7}  {'mean (cpp/numba)':>24}  {'std ratio':>10}  {'skew (cpp/numba)':>22}")

    with Engine() as engine:
        for level in LEVELS:
            frame = np.full((args.patch, args.patch, 3), level, dtype=np.float32)
            with engine.open(frame, delta) as session:
                got, _ = session.render("full")
            cpp = got[..., :3].astype(np.float64) / 65535.0
            ref = np.clip(reference_patch(level, args.patch, delta), 0.0, 1.0)

            # Green only: the three channels have different particle scales, so
            # pooling them would mix three distributions and hide a difference
            # in any one of them.
            m_c, s_c, k_c = moments(cpp[..., 1])
            m_r, s_r, k_r = moments(ref[..., 1])
            ratio = s_c / s_r if s_r > 1e-12 else 1.0

            bad = (abs(m_c - m_r) > MEAN_TOLERANCE or
                   abs(ratio - 1.0) > STD_RATIO_TOLERANCE or
                   abs(k_c - k_r) > SKEW_TOLERANCE)
            if bad:
                failures += 1
            print(f"{level:7.3f}  {m_c:11.6f}/{m_r:<11.6f}  {ratio:10.4f}  "
                  f"{k_c:+10.4f}/{k_r:<+10.4f}" + ("   FAIL" if bad else ""))

            if args.verbose:
                # How much the reference disagrees with *itself* between two
                # draws, which is the floor any bar has to clear.
                other = np.clip(reference_patch(level, args.patch, delta), 0.0, 1.0)
                m_o, s_o, k_o = moments(other[..., 1])
                print(f"         self-variation: mean {abs(m_o - m_r):.2e}, "
                      f"std ratio {s_o / max(s_r, 1e-12):.4f}, skew {abs(k_o - k_r):.4f}")

    print(f"\n{len(LEVELS)} levels, {failures} failed")
    print(f"bars: mean {MEAN_TOLERANCE:.0e} absolute, std ratio within "
          f"{STD_RATIO_TOLERANCE:.0%}, skew {SKEW_TOLERANCE}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
