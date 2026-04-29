"""Prototype scan-film MTF plotter for neutral sinusoidal targets.

The script generates an achromatic sine grating around the repo's neutral
midgray level, runs the scan-film pipeline (no print stage), disables scanner
lens blur and unsharp mask, and fits the output modulation in linear RGB.

Run directly, for example:

    python proto/plot_scan_film_mtf.py

or save without opening a window:

    python proto/plot_scan_film_mtf.py --sample-count 8 --no-show --output mtf.png
"""

from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

from spektrafilm.runtime.params_builder import digest_params, init_params
from spektrafilm.runtime.process import Simulator


MIDGRAY_RGB = 0.184
DEFAULT_MIN_FREQUENCY = 1.0
DEFAULT_MAX_FREQUENCY = 200.0
DEFAULT_SAMPLE_COUNT = 24
DEFAULT_HEIGHT_PX = 16
DEFAULT_MEASURE_ROWS = 16
DEFAULT_MODULATION = 0.20
DEFAULT_SAMPLES_PER_CYCLE = 4.0
DEFAULT_PRINT_PROFILE = 'kodak_portra_endura'
DEFAULT_FILM_PROFILE = 'kodak_portra_400'
LUMA_WEIGHTS = np.array([0.2126, 0.7152, 0.0722], dtype=np.float64)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Plot scan-film MTF from a neutral sinusoidal target.')
    parser.add_argument('--film-profile', default=DEFAULT_FILM_PROFILE, help='Film profile stock name.')
    parser.add_argument('--print-profile', default=DEFAULT_PRINT_PROFILE, help='Placeholder print profile; ignored by scan_film route.')
    parser.add_argument('--film-format-mm', type=float, default=35.0, help='Film format used to map pixels to cycles/mm.')
    parser.add_argument('--min-frequency', type=float, default=DEFAULT_MIN_FREQUENCY, help='Minimum spatial frequency in cycles/mm.')
    parser.add_argument('--max-frequency', type=float, default=DEFAULT_MAX_FREQUENCY, help='Maximum spatial frequency in cycles/mm.')
    parser.add_argument('--sample-count', type=int, default=DEFAULT_SAMPLE_COUNT, help='Number of log-spaced frequency samples.')
    parser.add_argument('--height-px', type=int, default=DEFAULT_HEIGHT_PX, help='Target height in pixels.')
    parser.add_argument('--width-px', type=int, default=None, help='Target width in pixels. Defaults to a power of two large enough for the requested max frequency.')
    parser.add_argument('--measure-rows', type=int, default=DEFAULT_MEASURE_ROWS, help='Number of central rows averaged for modulation fitting.')
    parser.add_argument('--modulation', type=float, default=DEFAULT_MODULATION, help='Input sinusoid modulation depth around neutral midgray, in [0, 1).')
    parser.add_argument('--output', type=Path, default=None, help='Optional path to save the plot image.')
    parser.add_argument('--no-show', action='store_true', help='Do not open a matplotlib window.')
    return parser.parse_args()


def _next_power_of_two(value: float) -> int:
    return 1 << int(np.ceil(np.log2(max(2.0, float(value)))))


def _default_width_px(film_format_mm: float, max_frequency_cy_mm: float) -> int:
    min_width = film_format_mm * max_frequency_cy_mm * DEFAULT_SAMPLES_PER_CYCLE
    return _next_power_of_two(min_width)


def _build_target(
    frequency_cy_mm: float,
    *,
    width_px: int,
    height_px: int,
    film_format_mm: float,
    modulation: float,
) -> np.ndarray:
    x_mm = ((np.arange(width_px, dtype=np.float64) + 0.5) / width_px) * film_format_mm
    wave = np.sin(2.0 * np.pi * frequency_cy_mm * x_mm)
    line = MIDGRAY_RGB * (1.0 + modulation * wave)
    image = np.repeat(line[np.newaxis, :, np.newaxis], height_px, axis=0)
    image = np.repeat(image, 3, axis=2)
    return np.clip(image, 0.0, 1.0)


def _fit_modulation(signal: np.ndarray, frequency_cy_mm: float, film_format_mm: float) -> float:
    width_px = signal.size
    start = int(round(width_px * 0.15))
    stop = int(round(width_px * 0.85))
    cropped = signal[start:stop]
    x_mm = ((np.arange(start, stop, dtype=np.float64) + 0.5) / width_px) * film_format_mm
    phase = 2.0 * np.pi * frequency_cy_mm * x_mm
    design = np.column_stack((np.ones_like(phase), np.sin(phase), np.cos(phase)))
    dc, sin_coeff, cos_coeff = np.linalg.lstsq(design, cropped, rcond=None)[0]
    if dc <= 0.0:
        return float('nan')
    amplitude = float(np.hypot(sin_coeff, cos_coeff))
    return amplitude / float(dc)


def _measure_mtf(
    scan_rgb: np.ndarray,
    *,
    frequency_cy_mm: float,
    film_format_mm: float,
    measure_rows: int,
    input_modulation: float,
) -> dict[str, float]:
    centre = scan_rgb.shape[0] // 2
    half_rows = max(1, measure_rows // 2)
    row_slice = slice(max(0, centre - half_rows), min(scan_rgb.shape[0], centre + half_rows))
    strip = np.mean(scan_rgb[row_slice, :, :], axis=0)
    luminance = strip @ LUMA_WEIGHTS

    red_mod = _fit_modulation(strip[:, 0], frequency_cy_mm, film_format_mm)
    green_mod = _fit_modulation(strip[:, 1], frequency_cy_mm, film_format_mm)
    blue_mod = _fit_modulation(strip[:, 2], frequency_cy_mm, film_format_mm)
    luma_mod = _fit_modulation(luminance, frequency_cy_mm, film_format_mm)
    scale = max(float(input_modulation), 1e-12)
    return {
        'R': red_mod / scale,
        'G': green_mod / scale,
        'B': blue_mod / scale,
        'Y': luma_mod / scale,
    }


def _build_simulator(
    film_profile: str,
    print_profile: str,
    film_format_mm: float,
    *,
    dir_couplers_only: bool = False,
) -> Simulator:
    params = init_params(film_profile=film_profile, print_profile=print_profile)
    params.camera.auto_exposure = False
    params.camera.exposure_compensation_ev = 0.0
    params.camera.film_format_mm = film_format_mm
    params.camera.lens_blur_um = 0.0
    params.io.scan_film = True
    params.io.input_cctf_decoding = False
    params.io.output_cctf_encoding = False
    params.scanner.lens_blur = 0.0
    params.scanner.unsharp_mask = (0.0, 0.0)
    params.settings.neutral_print_filters_from_database = False
    params.settings.use_scanner_lut = True
    params.debug.deactivate_stochastic_effects = True
    if dir_couplers_only:
        params.film_render.halation.scatter_amount = 0.0
        params.film_render.halation.halation_amount = 0.0
        params.film_render.halation.scatter_core_um = (0.0, 0.0, 0.0)
        params.film_render.halation.scatter_tail_um = (0.0, 0.0, 0.0)
        params.film_render.halation.halation_first_sigma_um = (0.0, 0.0, 0.0)
        params.film_render.grain.active = True
        params.film_render.grain.blur = 0.0
        params.film_render.grain.blur_dye_clouds_um = 0.0
    digested = digest_params(params)
    return Simulator(digested)


def _normalize_mtf_curves(mtf: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
    normalized: dict[str, np.ndarray] = {}
    for key, values in mtf.items():
        curve = np.asarray(values, dtype=np.float64)
        valid = np.flatnonzero(np.isfinite(curve) & (curve > 0.0))
        if valid.size == 0:
            normalized[key] = curve.copy()
            continue
        reference = float(curve[valid[0]])
        normalized[key] = curve / reference if reference > 0.0 else curve.copy()
    return normalized


def _plot_results(
    frequencies: np.ndarray,
    mtf: dict[str, np.ndarray],
    film_profile: str,
    width_px: int,
    film_format_mm: float,
    *,
    mtf_dir_couplers_only: dict[str, np.ndarray] | None = None,
) -> plt.Figure:
    pixels_per_mm = width_px / film_format_mm
    mtf = _normalize_mtf_curves(mtf)
    mtf_percent = {
        key: np.maximum(np.asarray(values, dtype=np.float64) * 100.0, 1e-6)
        for key, values in mtf.items()
    }
    mtf_dir_couplers_percent = None
    if mtf_dir_couplers_only is not None:
        mtf_dir_couplers_only = _normalize_mtf_curves(mtf_dir_couplers_only)
        mtf_dir_couplers_percent = {
            key: np.maximum(np.asarray(values, dtype=np.float64) * 100.0, 1e-6)
            for key, values in mtf_dir_couplers_only.items()
        }
    fig, ax = plt.subplots(figsize=(6.6, 6.6), constrained_layout=True)
    ax.set_box_aspect(1)
    ax.loglog(frequencies, mtf_percent['Y'], color='k', linewidth=2.0, label='luma')
    ax.loglog(frequencies, mtf_percent['R'], color='tab:red', linewidth=1.2, label='R')
    ax.loglog(frequencies, mtf_percent['G'], color='tab:green', linewidth=1.2, label='G')
    ax.loglog(frequencies, mtf_percent['B'], color='tab:blue', linewidth=1.2, label='B')
    if mtf_dir_couplers_percent is not None:
        ax.loglog(frequencies, mtf_dir_couplers_percent['Y'], color='k', linewidth=1.6, linestyle='--', label='luma dir couplers only')
        ax.loglog(frequencies, mtf_dir_couplers_percent['R'], color='tab:red', linewidth=1.0, linestyle='--', alpha=0.8, label='R dir couplers only')
        ax.loglog(frequencies, mtf_dir_couplers_percent['G'], color='tab:green', linewidth=1.0, linestyle='--', alpha=0.8, label='G dir couplers only')
        ax.loglog(frequencies, mtf_dir_couplers_percent['B'], color='tab:blue', linewidth=1.0, linestyle='--', alpha=0.8, label='B dir couplers only')
    ax.set_xlim(DEFAULT_MIN_FREQUENCY, DEFAULT_MAX_FREQUENCY)
    ax.set_ylim(1.0, 200.0)
    ax.set_xlabel('spatial frequency (cycles/mm)')
    ax.set_ylabel('MTF (%)')
    ax.set_title(
        f'Scan-film MTF prototype: {film_profile}\n'
        f'neutral sine target, normalized at lowest sampled frequency, scanner blur/unsharp off, {pixels_per_mm:.1f} px/mm'
    )
    ax.grid(alpha=0.25, which='both')
    ax.legend(loc='upper right')
    return fig


def main() -> None:
    args = _parse_args()
    if not 0.0 <= args.modulation < 1.0:
        raise ValueError('--modulation must be in the range [0, 1).')
    if args.min_frequency <= 0.0 or args.max_frequency <= 0.0:
        raise ValueError('Frequencies must be positive.')
    if args.max_frequency <= args.min_frequency:
        raise ValueError('--max-frequency must be greater than --min-frequency.')
    if args.sample_count < 2:
        raise ValueError('--sample-count must be at least 2.')

    width_px = args.width_px or _default_width_px(args.film_format_mm, args.max_frequency)
    pixels_per_mm = width_px / args.film_format_mm
    nyquist_cy_mm = 0.5 * pixels_per_mm
    if args.max_frequency >= nyquist_cy_mm:
        raise ValueError(
            f'Max frequency {args.max_frequency:.1f} cy/mm exceeds Nyquist {nyquist_cy_mm:.1f} cy/mm. '
            f'Increase --width-px or reduce --max-frequency.'
        )

    frequencies = np.geomspace(args.min_frequency, args.max_frequency, args.sample_count)
    simulator = _build_simulator(args.film_profile, args.print_profile, args.film_format_mm)
    simulator_dir_couplers_only = _build_simulator(
        args.film_profile,
        args.print_profile,
        args.film_format_mm,
        dir_couplers_only=True,
    )
    mtf = {key: np.zeros_like(frequencies) for key in ('R', 'G', 'B', 'Y')}
    mtf_dir_couplers_only = {key: np.zeros_like(frequencies) for key in ('R', 'G', 'B', 'Y')}

    print(
        f'Running {frequencies.size} frequencies from {args.min_frequency:.2f} to {args.max_frequency:.2f} cy/mm '
        f'on a {args.height_px}x{width_px} target ({pixels_per_mm:.1f} px/mm, Nyquist {nyquist_cy_mm:.1f} cy/mm).'
    )
    for index, frequency in enumerate(frequencies):
        target = _build_target(
            frequency,
            width_px=width_px,
            height_px=args.height_px,
            film_format_mm=args.film_format_mm,
            modulation=args.modulation,
        )
        scan = simulator.process(target)
        measured = _measure_mtf(
            scan,
            frequency_cy_mm=float(frequency),
            film_format_mm=args.film_format_mm,
            measure_rows=args.measure_rows,
            input_modulation=args.modulation,
        )
        scan_dir_couplers_only = simulator_dir_couplers_only.process(target)
        measured_dir_couplers_only = _measure_mtf(
            scan_dir_couplers_only,
            frequency_cy_mm=float(frequency),
            film_format_mm=args.film_format_mm,
            measure_rows=args.measure_rows,
            input_modulation=args.modulation,
        )
        for key, value in measured.items():
            mtf[key][index] = value
        for key, value in measured_dir_couplers_only.items():
            mtf_dir_couplers_only[key][index] = value
        print(
            f'  {index + 1:02d}/{frequencies.size:02d}  {frequency:7.3f} cy/mm  '
            f'Y={measured["Y"]:.4f}  Y_dir={measured_dir_couplers_only["Y"]:.4f}'
        )

    fig = _plot_results(
        frequencies,
        mtf,
        args.film_profile,
        width_px,
        args.film_format_mm,
        mtf_dir_couplers_only=mtf_dir_couplers_only,
    )
    if args.output is not None:
        fig.savefig(args.output, dpi=150)
        print(f'Saved plot to {args.output}')
    if args.no_show:
        plt.close(fig)
    else:
        plt.show()


if __name__ == '__main__':
    main()