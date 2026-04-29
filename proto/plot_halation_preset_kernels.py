"""Plot the 1D kernel shape of every halation preset.

For each (use, antihalation) combo in `_HALATION_PRESETS`, this script:
  1. Builds a `RuntimePhotoParams` on a carrier stock (Vision3 250D for cine,
     Portra 400 for still), overrides `info.antihalation`, and digests so the
     preset seeds `HalationParams.halation_first_sigma_um` and
     `HalationParams.halation_strength` via `_apply_halation_preset`.
  2. Runs `apply_halation_um` on a centred impulse to recover the full kernel
     (boost + scatter + halation, per channel). Also runs scatter-only and
     halation-only variants so the two passes can be inspected independently.
  3. Plots a radial cut through the centre per channel on log-y, with a zoomed
     linear subplot for the near-core region.

Intended as an eyeball check on shape, tail smoothness, and per-channel
balance across presets. Run directly:

    python proto/plot_halation_preset_kernels.py
"""
from __future__ import annotations

import copy

import matplotlib.pyplot as plt
import numpy as np

from spektrafilm.model.diffusion import apply_halation_um
from spektrafilm.runtime.params_builder import (
    _HALATION_PRESETS,
    digest_params,
    init_params,
)


PIXEL_SIZE_UM = 5.0
IMAGE_SIZE_PX = 1024
CHANNEL_LABELS = ('R', 'G', 'B')
CHANNEL_COLORS = ('tab:red', 'tab:green', 'tab:blue')


def _impulse_image() -> np.ndarray:
    image = np.zeros((IMAGE_SIZE_PX, IMAGE_SIZE_PX, 3), dtype=np.float64)
    image[IMAGE_SIZE_PX // 2, IMAGE_SIZE_PX // 2, :] = 1.0
    return image


def _halation_for_preset(use: str, antihalation: str):
    carrier_stock = 'kodak_vision3_250d' if use == 'cine' else 'kodak_portra_400'
    params = init_params(film_profile=carrier_stock)
    params.film.info.use = use
    params.film.info.antihalation = antihalation
    digest_params(params)
    halation = copy.deepcopy(params.film_render.halation)
    # Boost is irrelevant for impulses below mid-grey; zero it so we see the
    # pure spatial kernel without the boost shaping highlight amplitudes.
    halation.boost_ev = 0.0
    return halation


def _psf(halation, *, include_scatter: bool, include_halation: bool) -> np.ndarray:
    h = copy.deepcopy(halation)
    if not include_scatter:
        h.scatter_amount = 0.0
    if not include_halation:
        h.halation_amount = 0.0
    return apply_halation_um(_impulse_image(), h, PIXEL_SIZE_UM)


def _radial_profile(psf: np.ndarray, channel: int) -> np.ndarray:
    centre = IMAGE_SIZE_PX // 2
    return psf[centre, centre:, channel]


def _floor(values: np.ndarray, minimum: float = 1e-12) -> np.ndarray:
    return np.maximum(values, minimum)


def _log_rgb(psf: np.ndarray, *, log_min: float = -8.0, log_max: float = -1.0) -> np.ndarray:
    """Map a positive 3-channel PSF image into a displayable log-compressed RGB."""
    clipped = np.maximum(psf, 10.0 ** log_min)
    log = np.log10(clipped)
    return np.clip((log - log_min) / (log_max - log_min), 0.0, 1.0)


def _linear_rgb(psf: np.ndarray) -> np.ndarray:
    """Map a positive 3-channel PSF image into a displayable linear RGB."""
    clipped = np.maximum(psf, 0.0)
    scale = float(np.max(clipped))
    if scale <= 0.0:
        return np.zeros_like(clipped)
    return np.clip(clipped / scale, 0.0, 1.0)


def _centre_crop(image: np.ndarray, half_width_px: int) -> np.ndarray:
    centre = IMAGE_SIZE_PX // 2
    return image[centre - half_width_px:centre + half_width_px,
                 centre - half_width_px:centre + half_width_px]


def _plot_preset(ax_log, ax_lin, halation, title: str) -> None:
    radii_um = np.arange(IMAGE_SIZE_PX // 2) * PIXEL_SIZE_UM
    core_radius_um = 100.0
    core_radius_px = int(round(core_radius_um / PIXEL_SIZE_UM)) + 1

    full = _psf(halation, include_scatter=True, include_halation=True)
    scatter = _psf(halation, include_scatter=True, include_halation=False)
    halation_only = _psf(halation, include_scatter=False, include_halation=True)
    core_peak = 0.0

    for ch, (label, color) in enumerate(zip(CHANNEL_LABELS, CHANNEL_COLORS)):
        full_profile = _radial_profile(full, ch)
        scatter_profile = _radial_profile(scatter, ch)
        halation_profile = _radial_profile(halation_only, ch)
        core_peak = max(core_peak, float(np.max(full_profile[:core_radius_px])))

        ax_log.plot(radii_um, _floor(full_profile), color=color, linewidth=1.4, label=f'{label} full')
        ax_log.plot(radii_um, _floor(scatter_profile), color=color, linewidth=0.9, linestyle='--', alpha=0.6)
        ax_log.plot(radii_um, _floor(halation_profile), color=color, linewidth=0.9, linestyle=':', alpha=0.6)

        ax_lin.plot(radii_um, full_profile, color=color, linewidth=1.4, label=label)

    ax_log.set_yscale('log')
    ax_log.set_xlim(0, 400)
    ax_log.set_ylim(1e-10, 1.0)
    ax_log.set_title(title, fontsize=10)
    ax_log.set_xlabel('radius (um)')
    ax_log.set_ylabel('PSF (log)')
    ax_log.grid(alpha=0.2, which='both')
    ax_log.legend(fontsize=7, loc='upper right')

    ax_lin.set_xlim(0, core_radius_um)
    ax_lin.set_ylim(0.0, core_peak * 1.02 if core_peak > 0.0 else 1.0)
    ax_lin.set_xlabel('radius (um)')
    ax_lin.set_ylabel('PSF (core, linear)')
    ax_lin.grid(alpha=0.2, which='both')


def _plot_preset_images(axes_row, halation, *, rgb_mapper) -> None:
    crop_um = 500.0
    half_px = int(round(crop_um / PIXEL_SIZE_UM))
    extent_um = half_px * PIXEL_SIZE_UM

    full = _psf(halation, include_scatter=True, include_halation=True)
    scatter = _psf(halation, include_scatter=True, include_halation=False)
    halation_only = _psf(halation, include_scatter=False, include_halation=True)

    panels = (('full', full), ('scatter-only', scatter), ('halation-only', halation_only))
    for ax, (label, psf) in zip(axes_row, panels):
        rgb = rgb_mapper(_centre_crop(psf, half_px))
        ax.imshow(rgb, extent=(-extent_um, extent_um, -extent_um, extent_um), origin='lower', interpolation='nearest')
        ax.set_title(label, fontsize=9)
        ax.set_xlabel('x (um)')
        ax.set_ylabel('y (um)')


def main() -> None:
    presets = sorted(_HALATION_PRESETS.keys())
    n_presets = len(presets)

    fig_lines, axes_lines = plt.subplots(n_presets, 2, figsize=(12, 2.8 * n_presets), constrained_layout=True)
    fig_images_log, axes_images_log = plt.subplots(n_presets, 3, figsize=(10, 3.2 * n_presets), constrained_layout=True)
    fig_images_linear, axes_images_linear = plt.subplots(n_presets, 3, figsize=(10, 3.2 * n_presets), constrained_layout=True)

    for row, (use, antihalation) in enumerate(presets):
        halation = _halation_for_preset(use, antihalation)
        a_tot = tuple(float(value) for value in halation.halation_strength)
        sigma_h = halation.halation_first_sigma_um[0]
        sigma_c = tuple(float(value) for value in halation.scatter_core_um)
        sigma_t = tuple(float(value) for value in halation.scatter_tail_um)
        title = (
            f'{use}+{antihalation}  '
            f'sigma_h={sigma_h:.0f}um  a={a_tot}  '
            f'sigma_c={sigma_c}  sigma_t={sigma_t}'
        )
        _plot_preset(*axes_lines[row], halation, title)

        row_axes_log = axes_images_log[row]
        _plot_preset_images(row_axes_log, halation, rgb_mapper=_log_rgb)
        row_axes_log[0].set_ylabel(f'{use}+{antihalation}\ny (um)', fontsize=9)

        row_axes_linear = axes_images_linear[row]
        _plot_preset_images(row_axes_linear, halation, rgb_mapper=_linear_rgb)
        row_axes_linear[0].set_ylabel(f'{use}+{antihalation}\ny (um)', fontsize=9)

    fig_lines.suptitle('Halation preset kernels (impulse response, radial cut)\n'
                       'solid=full  dashed=scatter-only  dotted=halation-only', fontsize=11)
    fig_images_log.suptitle('Halation preset kernels (impulse response, 2D log-RGB)\n'
                            'log10 mapping: -8 (black) to -1 (full channel)', fontsize=11)
    fig_images_linear.suptitle('Halation preset kernels (impulse response, 2D linear RGB)\n'
                               'each panel normalized to its own peak', fontsize=11)
    plt.show()


if __name__ == '__main__':
    main()
