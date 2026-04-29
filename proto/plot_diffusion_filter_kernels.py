"""Plot the radial PSF and 2D impulse response of every diffusion-filter family.

For each family in `_DIFFUSION_FILTER_SHAPES`, this script:
  1. Plots the analytic radial profile from `diffusion_filter_radial_profile`,
     decomposed into core / halo / bloom on log-y, so the long-reach Student-t
     bloom tail is visible.
  2. Sweeps strength {1/8, 1/4, 1/2, 1, 2} on a centred impulse, runs
     `apply_diffusion_filter_um`, and plots the resulting impulse-response
     radial cuts and the corresponding (p_s, p_a) photon fractions.
  3. Renders 2D log-RGB images of the impulse response so per-family shape and
     bloom geometry are eyeball-checkable.

Run directly:

    python proto/plot_diffusion_filter_kernels.py
"""
from __future__ import annotations

import matplotlib.pyplot as plt
import numpy as np

from spektrafilm.model.diffusion import (
    DIFFUSION_FILTER_FAMILIES,
    _strength_to_scatter,
    apply_diffusion_filter_um,
    diffusion_filter_radial_profile,
)
from spektrafilm.runtime.params_schema import DiffusionFilterParams


PIXEL_SIZE_UM = 10.0
IMAGE_SIZE_PX = 1024
STRENGTHS = (0.125, 0.25, 0.5, 1.0, 2.0)


def _impulse_image() -> np.ndarray:
    image = np.zeros((IMAGE_SIZE_PX, IMAGE_SIZE_PX, 3), dtype=np.float64)
    image[IMAGE_SIZE_PX // 2, IMAGE_SIZE_PX // 2, :] = 1.0
    return image


def _apply(family: str, strength: float, spatial_scale: float = 1.0) -> np.ndarray:
    diffusion = DiffusionFilterParams(
        active=True,
        filter_family=family,
        strength=strength,
        spatial_scale=spatial_scale,
    )
    return apply_diffusion_filter_um(_impulse_image(), diffusion, PIXEL_SIZE_UM)


def _radial_profile(image: np.ndarray, channel: int = 0) -> np.ndarray:
    centre = IMAGE_SIZE_PX // 2
    return image[centre, centre:, channel]


def _floor(values: np.ndarray, minimum: float = 1e-12) -> np.ndarray:
    return np.maximum(values, minimum)


def _log_rgb(image: np.ndarray, *, log_min: float = -8.0, log_max: float = -1.0) -> np.ndarray:
    clipped = np.maximum(image, 10.0 ** log_min)
    log = np.log10(clipped)
    return np.clip((log - log_min) / (log_max - log_min), 0.0, 1.0)


def _centre_crop(image: np.ndarray, half_width_px: int) -> np.ndarray:
    centre = IMAGE_SIZE_PX // 2
    return image[centre - half_width_px:centre + half_width_px,
                 centre - half_width_px:centre + half_width_px]


def _plot_analytic_profiles(ax, family: str) -> None:
    radius_um = np.geomspace(1.0, 5000.0, 800)
    profile = diffusion_filter_radial_profile(radius_um, family=family, spatial_scale=1.0)
    # Group totals are channel-independent for core / bloom; halo is per-channel.
    total_per_channel = profile['total_per_channel']
    ax.loglog(radius_um, _floor(total_per_channel[0]), color='tab:red', linewidth=1.5, label='total R')
    ax.loglog(radius_um, _floor(total_per_channel[1]), color='tab:green', linewidth=1.5, label='total G')
    ax.loglog(radius_um, _floor(total_per_channel[2]), color='tab:blue', linewidth=1.5, label='total B')
    ax.loglog(radius_um, _floor(profile['core']), color='black', linewidth=0.8, linestyle='--', alpha=0.5, label='core (Σ E)')
    ax.loglog(radius_um, _floor(profile['halo'][1]), color='black', linewidth=0.8, linestyle=':', alpha=0.5, label='halo G (Σ E)')
    ax.loglog(radius_um, _floor(profile['bloom']), color='black', linewidth=0.8, linestyle='-.', alpha=0.5, label='bloom (Σ E ≈ r^-α)')
    ax.set_xlim(1.0, 5000.0)
    ax.set_ylim(1e-12, 1e-2)
    ax.set_xlabel('radius on image plane (um)')
    ax.set_ylabel('K_s(r)  [1/um**2]')
    ax.set_title(f'{family} — analytic K_s', fontsize=10)
    ax.grid(alpha=0.2, which='both')
    ax.legend(fontsize=7, loc='upper right')


def _plot_strength_sweep(ax, family: str) -> None:
    radii_um = np.arange(IMAGE_SIZE_PX // 2) * PIXEL_SIZE_UM
    cmap = plt.cm.viridis
    for index, strength in enumerate(STRENGTHS):
        psf = _apply(family, strength)
        p_s = _strength_to_scatter(strength, family)
        color = cmap(index / max(len(STRENGTHS) - 1, 1))
        label = f's={strength:g}  p_s={p_s:.2f}'
        ax.semilogy(radii_um / 1000.0, _floor(_radial_profile(psf)), color=color, linewidth=1.3, label=label)
    ax.set_xlim(0.0, 4.0)
    ax.set_ylim(1e-8, 1.0)
    ax.set_xlabel('radius on image plane (mm)')
    ax.set_ylabel('impulse response (red channel)')
    ax.set_title(f'{family} — strength sweep', fontsize=10)
    ax.grid(alpha=0.2, which='both')
    ax.legend(fontsize=7, loc='upper right')


def _plot_psf_image(ax, family: str, strength: float, crop_um: float = 4000.0) -> None:
    half_px = int(round(crop_um / PIXEL_SIZE_UM))
    psf = _apply(family, strength)
    rgb = _log_rgb(_centre_crop(psf, half_px))
    extent_um = half_px * PIXEL_SIZE_UM
    ax.imshow(rgb, extent=(-extent_um, extent_um, -extent_um, extent_um), origin='lower', interpolation='nearest')
    ax.set_xlabel('x (um)')
    ax.set_ylabel('y (um)')
    ax.set_title(f'{family}  s={strength:g}', fontsize=9)


def main() -> None:
    families = list(DIFFUSION_FILTER_FAMILIES)
    n_families = len(families)

    fig_lines, axes_lines = plt.subplots(n_families, 2, figsize=(13, 3.0 * n_families), constrained_layout=True)
    for row, family in enumerate(families):
        _plot_analytic_profiles(axes_lines[row, 0], family)
        _plot_strength_sweep(axes_lines[row, 1], family)
    fig_lines.suptitle('Diffusion-filter PSFs (analytic and impulse-response sweep)', fontsize=11)

    sweep_strength = 0.5
    fig_images, axes_images = plt.subplots(1, n_families, figsize=(4 * n_families, 4), constrained_layout=True)
    if n_families == 1:
        axes_images = np.array([axes_images])
    for ax, family in zip(axes_images, families):
        _plot_psf_image(ax, family, sweep_strength)
    fig_images.suptitle(
        f'Diffusion-filter impulse response, strength={sweep_strength:g} '
        '(2D log-RGB, log10 mapping: -8 (black) to -1 (full channel))',
        fontsize=11,
    )

    plt.show()


if __name__ == '__main__':
    main()
