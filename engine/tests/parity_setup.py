"""Hold the C++ setup maths against the Python reference, value for value.

RFC-014 §3, the setup half. `dump_setup` writes every quantity the engine
derives before a pixel is touched -- illuminants, enlarger filters, colour
matrices, transfer functions, density curves, the DIR-coupler tables, the
Hanatos tc_lut, the CAM16 C_max table -- and this recomputes each one with
colour-science, scipy and numpy and compares.

The bar is **float64 agreement**, not float32: these are constants, they are
computed once per stock pair, and a constant that is only nearly right is
RFC-012 §4.1's named failure mode. Where the two sides genuinely cannot agree
to the last bit -- a summation order, a library's own iteration -- the check
says so by name and carries the measured bound, so nothing is waved through
silently.

The criterion is the standard mixed one, per element:

    |a - b|  <=  rtol * |a|  +  atol,   atol = ATOL_SCALE * max|a|

and both halves are load-bearing. A pure *relative* bound is unmeetable: an
element that is 4e-7 of the array's peak is the result of cancelling terms of
order 1, so it carries ~7 fewer significant digits than the peak does, and
asking it to agree to 1e-12 relative is asking arithmetic for something it
does not have. A pure *absolute-scaled* bound is too weak the other way: it
would wave through a 100 % error in the toe of a density curve. Together they
say the honest thing -- agree to `rtol` where there are digits to agree on,
and to a few tens of ulps of the array's own scale where there are not.

`ATOL_SCALE` is 1e-14, about 45 ulps of the peak for float64. Every difference
this harness currently reports as passing is at or below 1.4e-15 of peak;
the headroom is there so a reordering in a future refactor does not read as a
regression, and it is far below any error a wrong constant would produce.

Usage:
    engine/tests/parity_setup.py [--build] [--verbose]
"""
from __future__ import annotations

import argparse
import copy
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

np.seterr(invalid="ignore")

ENGINE = Path(__file__).resolve().parents[1]
REPO = ENGINE.parent
sys.path.insert(0, str(REPO / "src"))

# Quantities that cannot be bit-equal, with the reason and the bound each is
# held to. Anything not listed here must match to 1e-12 relative.
TOLERANCES: dict[str, tuple[float, str]] = {
    # np.nansum/einsum use pairwise summation; the C++ loops sum in order.
    "illuminant/": (1e-13, "summation order in the mean-1 normalisation"),
    "illuminant_xy/": (1e-13, "summation order in the CMFS projection"),
    "enlarger/": (1e-13, "summation order upstream in the illuminant"),
    "tc_lut/": (5e-12, "81-term dot product summed in a different order"),
    "spectral_constants/": (1e-13, "summation order upstream in the illuminant"),
    "cmax/": (1e-9, "the bisection's own iteration count and the C_max solve"),
}


# A few tens of ulps of an array's own peak. See the module docstring.
ATOL_SCALE = 1e-14


def tolerance(name: str) -> tuple[float, str]:
    for prefix, (tol, why) in TOLERANCES.items():
        if name.startswith(prefix):
            return tol, why
    return 1e-12, ""


def read_dump(dat: Path, idx: Path) -> dict[str, np.ndarray]:
    data = np.fromfile(dat, dtype=np.float64)
    out: dict[str, np.ndarray] = {}
    for line in idx.read_text().splitlines():
        name, offset, count = line.split("\t")
        offset, count = int(offset), int(count)
        out[name] = data[offset:offset + count]
    return out


def reference() -> dict[str, np.ndarray]:
    """Every quantity `dump_setup.cpp` writes, computed the Python way."""
    from spektrafilm.config import SPECTRAL_SHAPE
    from spektrafilm.model import colour_baked as cb
    from spektrafilm.model.color_filters import (
        color_enlarger, compute_band_pass_filter, custom_dichroic_filters,
    )
    from spektrafilm.model.illuminants import standard_illuminant
    from spektrafilm.utils.spectral_upsampling import _illuminant_to_xy

    ref: dict[str, np.ndarray] = {}

    illuminant_names = ["D50", "D55", "D65", "D75", "E", "A", "T", "K75P",
                        "TH-KG3", "TH-KG3-L", "BB3400", "BB5500"]
    for name in illuminant_names:
        sd = np.asarray(standard_illuminant(name), dtype=np.float64)
        ref[f"illuminant/{name}"] = sd
        ref[f"illuminant_xy/{name}"] = np.asarray(_illuminant_to_xy(name), dtype=np.float64)

    ref["dichroic/custom"] = np.asarray(custom_dichroic_filters.filters, dtype=np.float64)

    light = standard_illuminant("TH-KG3")
    for k, pack in enumerate([(0.0, 65.0, 55.0), (0.0, 65.9, 54.2), (10.0, 0.0, 120.0)]):
        ref[f"enlarger/filtered_{k}"] = np.asarray(
            color_enlarger(light, filter_cc_values=pack), dtype=np.float64)

    ref["bandpass/off"] = compute_band_pass_filter([0.0, 410.0, 8.0], [0.0, 675.0, 15.0])
    ref["bandpass/on"] = compute_band_pass_filter([1.0, 410.0, 8.0], [0.8, 675.0, 15.0])

    spaces = ["sRGB", "ProPhoto RGB", "Display P3", "Adobe RGB (1998)",
              "ACEScg", "ACES2065-1", "ITU-R BT.709", "ITU-R BT.2020"]
    for cs in spaces:
        c = cb.colourspace(cs)
        ref[f"m_rgb_to_xyz/{cs}"] = np.asarray(c.matrix_RGB_to_XYZ, dtype=np.float64).ravel()
        ref[f"m_xyz_to_rgb/{cs}"] = np.asarray(c.matrix_XYZ_to_RGB, dtype=np.float64).ravel()
        # RGB_to_RGB on the identity is how the reference recovers the matrix
        # the output CCTF node applies (backends/metal/kernels.make_cctf).
        ref[f"m_rgb_to_rgb_same/{cs}"] = np.asarray(cb.RGB_to_RGB(
            np.eye(3), cs, cs, apply_cctf_decoding=False, apply_cctf_encoding=False),
            dtype=np.float64).T.ravel()
        for ill in ["D50", "D55", "D65"]:
            xy = _illuminant_to_xy(ill)
            ref[f"m_rgb_to_xyz_cat16/{cs}/{ill}"] = np.asarray(cb.RGB_to_XYZ(
                np.eye(3), cs, apply_cctf_decoding=False, illuminant=xy,
                chromatic_adaptation_transform="CAT16"), dtype=np.float64).T.ravel()
            ref[f"m_xyz_to_rgb_cat02/{cs}/{ill}"] = np.asarray(cb.XYZ_to_RGB(
                np.eye(3), cs, apply_cctf_encoding=False, illuminant=xy),
                dtype=np.float64).T.ravel()

    xs = list(-0.2 + 1.4 * np.arange(401) / 400.0)
    for b in (0.0031308, 0.040449936, 0.018, 1.0 / 512.0, 16.0 / 512.0, 0.081):
        for eps in (-1e-9, 0.0, 1e-9):
            xs.append(b + eps)
    xs_arr = np.asarray(xs, dtype=np.float64)
    ref["cctf/x"] = xs_arr
    for cs in ["sRGB", "ProPhoto RGB", "Display P3", "Adobe RGB (1998)",
               "ACEScg", "ITU-R BT.709", "ITU-R BT.2020"]:
        ref[f"cctf_decode/{cs}"] = np.asarray(cb.cctf_decoding(xs_arr, cs), dtype=np.float64)
        ref[f"cctf_encode/{cs}"] = np.asarray(cb.cctf_encoding(xs_arr, cs), dtype=np.float64)

    # --- per-stock setup: curves, couplers, the tc_lut ----------------------
    from spektrafilm.model.couplers import (
        compute_density_curves_before_dir_couplers, compute_dir_couplers_matrix,
    )
    from spektrafilm.runtime.params_builder import digest_params, init_params
    from spektrafilm.utils.gamut_compression import (
        InputGamutCompressSpec, compress_xy_radial, spectral_locus_xy,
    )
    from spektrafilm.utils.fused_spectral import prepare_spectral_constants
    from spektrafilm.utils.fused_tc_b import tc_b_matrix
    from spektrafilm.utils.morph_curves import PrintCurvesMorphParams, apply_print_curves_morph
    from spektrafilm.utils.spectral_upsampling import compute_hanatos2025_tc_lut
    from spektrafilm.profiles.io import Hanatos2025SensitivityAdaptation
    from spektrafilm.config import STANDARD_OBSERVER_CMFS

    def sensitivity_for(params, camera):
        sens = np.nan_to_num(10 ** np.asarray(params.film.data.log_sensitivity))
        if camera.filter_uv[0] > 0 or camera.filter_ir[0] > 0:
            illuminant = standard_illuminant(params.film.info.reference_illuminant)
            bp = compute_band_pass_filter(camera.filter_uv, camera.filter_ir)
            bp = np.tile(bp[:, None], (1, 3))
            norm = (np.sum(sens * bp * illuminant[:, None], axis=0)
                    / np.sum(sens * illuminant[:, None], axis=0))
            sens = sens * (bp / norm)
        return sens

    def adaptation(params, *, window, surface):
        a = params.film.hanatos2025_adaptation()
        a.apply_window = window
        a.apply_surface = surface
        a.spectral_gaussian_blur = params.settings.spectral_gaussian_blur
        return a

    for film_stock, print_stock in [("kodak_portra_400", "kodak_portra_endura"),
                                    ("fujifilm_velvia_100", "kodak_portra_endura"),
                                    ("kodak_gold_200", "kodak_endura_premier")]:
        params = digest_params(init_params(film_profile=film_stock, print_profile=print_stock))
        p = f"stock/{film_stock}/"
        curves = np.asarray(params.film.data.density_curves)
        normalized = curves - np.nanmin(curves, axis=0)
        ref[p + "normalized_curves"] = normalized.ravel()
        ref[p + "density_max"] = np.nanmax(normalized, axis=0)

        le = np.asarray(params.film.data.log_exposure)
        gamma = np.repeat(np.atleast_1d(params.film_render.density_curve_gamma), 3)
        x_axis = le[:, None] / gamma[None, :]
        ref[p + "curve_x"] = x_axis.ravel()
        dx = np.diff(x_axis, axis=0)
        with np.errstate(divide="ignore"):
            ref[p + "curve_inv"] = np.where(dx != 0, 1.0 / dx, 0.0).ravel()

        matrix = compute_dir_couplers_matrix(params.film_render.dir_couplers) * params.film_render.dir_couplers.amount
        ref[p + "dir_matrix"] = matrix.ravel()
        ref[p + "curves_before_couplers"] = compute_density_curves_before_dir_couplers(
            normalized, le, matrix, positive=params.film.info.type == "positive").ravel()

        ple = np.asarray(params.print.data.log_exposure)
        ref[p + "print_curves"] = apply_print_curves_morph(
            ple, params.print.data.density_curves_model,
            params.print_render.density_curves_morph,
            profile_type=params.print.info.type).ravel()
        morph = PrintCurvesMorphParams(active=True, gamma_factor=1.15, gamma_factor_fast=0.9,
                                       gamma_factor_slow=1.1, gamma_factor_red=1.05,
                                       gamma_factor_green=1.0, gamma_factor_blue=0.95)
        ref[p + "print_curves_morphed"] = apply_print_curves_morph(
            ple, params.print.data.density_curves_model, morph,
            profile_type=params.print.info.type).ravel()

        sens = sensitivity_for(params, params.camera)
        ref[p + "sensitivity"] = sens.ravel()
        filtered = copy.deepcopy(params.camera)
        filtered.filter_uv = (1.0, 410.0, 8.0)
        filtered.filter_ir = (0.8, 675.0, 15.0)
        ref[p + "sensitivity_filtered"] = sensitivity_for(params, filtered).ravel()

        ref[f"tc_lut/{film_stock}"] = compute_hanatos2025_tc_lut(
            sens, adaptation(params, window=True, surface=False),
            gamut_compress=params.io.input_gamut_compress).ravel()
        ref[f"tc_lut/{film_stock}/plain"] = compute_hanatos2025_tc_lut(
            sens, adaptation(params, window=False, surface=False),
            gamut_compress=InputGamutCompressSpec(active=False)).ravel()
        ref[f"tc_lut/{film_stock}/surface"] = compute_hanatos2025_tc_lut(
            sens, adaptation(params, window=True, surface=True),
            gamut_compress=InputGamutCompressSpec(active=False)).ravel()

        # `tc_b_matrix` already returns the transpose of what `RGB_to_XYZ`
        # gives on the identity, i.e. plain row-major RGB->XYZ -- the same
        # orientation `Colour::matrix_RGB_to_XYZ` returns. No second .T.
        ref[p + "tc_b_matrix"] = tc_b_matrix(
            params.io.input_color_space,
            _illuminant_to_xy(params.film.info.reference_illuminant)).ravel()

        illum = standard_illuminant(params.print.info.viewing_illuminant)
        cmfs = np.asarray(STANDARD_OBSERVER_CMFS[:])
        norm = np.sum(illum * cmfs[:, 1], axis=0)
        chd, base, ixs = prepare_spectral_constants(
            params.print.data.channel_density, params.print.data.base_density, illum, cmfs, norm)
        ref[f"spectral_constants/{print_stock}/chd"] = chd.ravel()
        ref[f"spectral_constants/{print_stock}/base"] = base.ravel()
        ref[f"spectral_constants/{print_stock}/ixs"] = ixs.ravel()

    locus = spectral_locus_xy()
    ref["locus/xy"] = np.asarray(locus, dtype=np.float64).ravel()
    white = _illuminant_to_xy("D55")
    grid = np.stack(np.meshgrid(np.arange(64) / 63.0 * 0.8, np.arange(64) / 63.0 * 0.9,
                                indexing="ij"), axis=-1)
    ref["compress_xy/values"] = compress_xy_radial(
        grid.reshape(-1, 2), np.asarray(white, dtype=float),
        threshold=0.0, limit=1.0, power=6.0, locus=locus).ravel()

    # --- CAM16-UCS setup and the C_max table --------------------------------
    from spektrafilm.utils import gamut_compression as gc
    from spektrafilm.utils.fused_gamut_cam16 import _setup_for

    for cs in ["sRGB", "Display P3"]:
        st = _setup_for(cs)
        p = f"cam16/{cs}/"
        ref[p + "scalars"] = np.array([st["n"], st["F_L"], st["N_bb"], st["N_cb"],
                                       st["z"], st["A_w"], st["c"], st["N_c"]])
        ref[p + "D_rgb"] = np.asarray(st["D_rgb"], dtype=np.float64)
        ref[p + "m_to_xyz"] = np.asarray(st["m_to_xyz"], dtype=np.float64).ravel()
        ref[p + "m_to_rgb"] = np.asarray(st["m_to_rgb"], dtype=np.float64).ravel()
        ref[p + "white_Jp"] = np.array([st["white_Jp"]])
        ref[p + "l_grid"] = np.asarray(st["l_grid"], dtype=np.float64)
        ref[p + "h_grid"] = np.asarray(st["h_grid"], dtype=np.float64)
        ref[f"cmax/{cs}"] = np.asarray(st["c_max_table"], dtype=np.float64).ravel()

        t = np.arange(400) / 399.0
        rgb = np.stack([-0.2 + 1.6 * t, 0.9 - 0.8 * t, 0.05 + 1.1 * t * t], axis=-1)
        xyz = rgb @ np.asarray(st["m_to_xyz"]).T
        xyz_w = gc._output_cs_whitepoint_xyz(cs)
        jab = np.asarray(colour_module().XYZ_to_CAM16UCS(
            xyz, XYZ_w=xyz_w, L_A=gc._CAM16UCS_L_A, Y_b=gc._CAM16UCS_Y_B))
        ref[p + "forward"] = jab.ravel()
        back = np.asarray(colour_module().CAM16UCS_to_XYZ(
            jab, XYZ_w=xyz_w, L_A=gc._CAM16UCS_L_A, Y_b=gc._CAM16UCS_Y_B))
        ref[p + "inverse"] = back.ravel()

    knee = []
    for i in range(301):
        x = 3.0 * i / 300.0
        knee.append(float(gc.reinhard_knee(np.array(x), threshold=0.0, limit=1.0, power=6.0)))
        knee.append(float(gc.reinhard_knee(np.array(x), threshold=0.7, limit=1.0, power=2.2)))
    ref["knee/values"] = np.asarray(knee)

    return ref


def colour_module():
    import colour
    return colour


def compare(got: dict[str, np.ndarray], ref: dict[str, np.ndarray], verbose: bool) -> int:
    missing = sorted(set(got) - set(ref))
    unchecked = sorted(set(ref) - set(got))
    failures = 0
    exact = 0
    for name in sorted(got):
        if name not in ref:
            continue
        a = np.asarray(ref[name], dtype=np.float64).ravel()
        b = got[name]
        if a.shape != b.shape:
            print(f"FAIL {name}: shape {b.shape} from C++, {a.shape} from the reference")
            failures += 1
            continue
        if np.array_equal(a, b, equal_nan=True):
            exact += 1
            if verbose:
                print(f"  ok  {name}  ({b.size} values, bit-exact)")
            continue
        rtol, why = tolerance(name)
        delta = np.abs(a - b)
        peak = float(np.nanmax(np.abs(a)))
        atol = ATOL_SCALE * max(peak, 1e-300)
        budget = rtol * np.abs(a) + atol
        over = delta > budget
        worst = int(np.nanargmax(delta / np.maximum(budget, 1e-300)))
        if not over.any():
            if verbose:
                print(f"  ok  {name}  ({b.size} values, worst {delta[worst]:.2e} of "
                      f"{budget[worst]:.2e} allowed" + (f", {why}" if why else "") + ")")
            continue
        print(f"FAIL {name}: {int(over.sum())} of {b.size} values over budget; "
              f"worst index {worst}: |{a[worst]!r} - {b[worst]!r}| = {delta[worst]:.3e} "
              f"> {budget[worst]:.3e} (rtol {rtol:.0e}, atol {atol:.2e})")
        failures += 1

    print(f"\n{len(got)} quantities compared, {exact} bit-exact, {failures} failed")
    if missing:
        print(f"NOT CHECKED (no reference): {', '.join(missing)}")
        failures += len(missing)
    if unchecked:
        print(f"reference has no C++ counterpart: {', '.join(unchecked)}")
    return failures


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", action="store_true", help="rebuild dump_setup first")
    ap.add_argument("--verbose", "-v", action="store_true")
    ap.add_argument("--binary", type=Path, default=ENGINE / "build" / "dump_setup")
    args = ap.parse_args()

    if args.build or not args.binary.exists():
        subprocess.run([str(ENGINE / "build.sh"), "tests"], check=True)

    with tempfile.TemporaryDirectory() as tmp:
        dat, idx = Path(tmp) / "setup.dat", Path(tmp) / "setup.idx"
        subprocess.run([str(args.binary), str(ENGINE / "resources"), str(dat), str(idx)], check=True)
        got = read_dump(dat, idx)
    return 1 if compare(got, reference(), args.verbose) else 0


if __name__ == "__main__":
    sys.exit(main())
