"""Fit and plot sum-of-Gaussians surrogates for a 2D exponential PSF.

The analytic PSF is the isotropic 2D exponential

    f_exp(r) = exp(-r / lambda) / (2*pi*lambda**2),

and the surrogate is

    f_sur(r) = sum_k a_k * exp(-r**2 / (2*sigma_k**2)) / (2*pi*sigma_k**2)

with sum_k a_k = 1 (energy preservation). All fitting happens in normalised
coordinates (lambda = 1), so the resulting (a_k, sigma_k/lambda) pairs can be
pasted verbatim into `_EXPONENTIAL_GAUSSIAN_FITS` in
`spektrafilm.utils.fast_gaussian_filter`.

The fit minimises mean-squared error in log PSF over a log-spaced radius grid,
which weights near-peak and deep-tail regions comparably and is the right
objective given the orders of magnitude the PSF spans. Amplitudes are
softmax-parametrised to keep them on the simplex, and sigmas are optimised in
log-space so they stay positive.

Run directly:

    python proto/plot_exponential_gaussian_fits.py
"""
from __future__ import annotations

import matplotlib.pyplot as plt
import numpy as np
from scipy.optimize import minimize

from spektrafilm.utils.fast_gaussian_filter import _EXPONENTIAL_GAUSSIAN_FITS


# Fit grid covers the range where the exponential is physically meaningful:
# from 0.05 lambda (well inside the core) out to 10 lambda (PSF already
# ~5e-6 of the peak). Pushing the grid further makes the optimiser waste
# weight trying to match a regime where the Gaussian mixture structurally
# cannot follow the exponential tail, and it collapses the fit onto a
# single intermediate-sigma Gaussian.
_R_GRID = np.geomspace(5e-2, 10.0, 300)


def _analytic_exponential(r_over_lambda: np.ndarray) -> np.ndarray:
    return np.exp(-r_over_lambda) / (2.0 * np.pi)


def _surrogate(fit: np.ndarray, r_over_lambda: np.ndarray) -> np.ndarray:
    total = np.zeros_like(r_over_lambda)
    for amplitude, sigma_ratio in fit:
        total += amplitude * np.exp(-0.5 * (r_over_lambda / sigma_ratio) ** 2) / (2.0 * np.pi * sigma_ratio ** 2)
    return total


def _unpack(params: np.ndarray, n_gaussians: int) -> tuple[np.ndarray, np.ndarray]:
    raw_amplitudes = params[:n_gaussians]
    log_sigmas = params[n_gaussians:]
    # softmax keeps amplitudes on the unit simplex (sum = 1, all >= 0).
    stabilised = raw_amplitudes - raw_amplitudes.max()
    exp_raw = np.exp(stabilised)
    amplitudes = exp_raw / exp_raw.sum()
    sigmas = np.exp(log_sigmas)
    return amplitudes, sigmas


def _log_loss(params: np.ndarray, n_gaussians: int, r_grid: np.ndarray, log_target: np.ndarray) -> float:
    amplitudes, sigmas = _unpack(params, n_gaussians)
    surrogate = np.zeros_like(r_grid)
    for amplitude, sigma in zip(amplitudes, sigmas):
        surrogate += amplitude * np.exp(-0.5 * (r_grid / sigma) ** 2) / (2.0 * np.pi * sigma ** 2)
    residual = np.log(surrogate) - log_target
    return float(np.mean(residual ** 2))


def _fit_exponential_gaussian_mixture(n_gaussians: int, r_grid: np.ndarray = _R_GRID) -> np.ndarray:
    log_target = np.log(_analytic_exponential(r_grid))
    rng = np.random.default_rng(0)

    best_loss = np.inf
    best_params: np.ndarray | None = None
    # Diverse random restarts: amplitudes drawn uniformly, sigmas drawn
    # log-uniform from a wide spread. Nelder-Mead locally polishes.
    n_restarts = 60
    for trial in range(n_restarts):
        raw_amplitudes = rng.uniform(-2.0, 2.0, size=n_gaussians)
        log_sigmas = np.sort(np.log(rng.uniform(0.3, 4.0, size=n_gaussians)))
        start = np.concatenate([raw_amplitudes, log_sigmas])
        result = minimize(
            _log_loss,
            start,
            args=(n_gaussians, r_grid, log_target),
            method='Nelder-Mead',
            options={'xatol': 1e-9, 'fatol': 1e-11, 'maxiter': 50000, 'adaptive': True},
        )
        if result.fun < best_loss:
            best_loss = float(result.fun)
            best_params = result.x

    assert best_params is not None
    amplitudes, sigmas = _unpack(best_params, n_gaussians)
    order = np.argsort(sigmas)
    sorted_fit = np.stack([amplitudes[order], sigmas[order]], axis=1)
    print(f'  N={n_gaussians}: log-MSE loss = {best_loss:.5f}')
    return sorted_fit


def _format_fit(fit: np.ndarray) -> str:
    lines = ['    ['] if False else []
    rows = [f'        [{a:.4f}, {s:.4f}],' for a, s in fit]
    return '\n'.join(rows)


def main() -> None:
    r_plot = np.geomspace(1e-2, 1e2, 1000)
    analytic = _analytic_exponential(r_plot)

    fig, axes = plt.subplots(1, 2, figsize=(12, 5), constrained_layout=True)
    ax_psf, ax_err = axes

    ax_psf.loglog(r_plot, analytic, color='black', linewidth=2.0, label='analytic exp(-r/lambda)')

    print('Fitting sum-of-Gaussians surrogates to the 2D exponential PSF...')
    fitted: dict[int, np.ndarray] = {}
    colors = ('tab:blue', 'tab:orange', 'tab:green')
    for (n_gaussians, _placeholder), color in zip(sorted(_EXPONENTIAL_GAUSSIAN_FITS.items()), colors):
        fit = _fit_exponential_gaussian_mixture(n_gaussians)
        fitted[n_gaussians] = fit

        surrogate = _surrogate(fit, r_plot)
        ax_psf.loglog(r_plot, surrogate, color=color, linewidth=1.4, label=f'N={n_gaussians} fitted')

        if n_gaussians == max(dict(_EXPONENTIAL_GAUSSIAN_FITS)):
            for amplitude, sigma_ratio in fit:
                component = amplitude * np.exp(-0.5 * (r_plot / sigma_ratio) ** 2) / (2.0 * np.pi * sigma_ratio ** 2)
                ax_psf.loglog(r_plot, component, color=color, linewidth=0.7, linestyle=':', alpha=0.5)

        relative_error = (surrogate - analytic) / analytic
        ax_err.semilogx(r_plot, relative_error, color=color, linewidth=1.3, label=f'N={n_gaussians} fitted')

    ax_psf.set_xlabel('r / lambda')
    ax_psf.set_ylabel('PSF * lambda**2')
    ax_psf.set_ylim(1e-10, 1.0)
    ax_psf.set_title('2D exponential PSF vs fitted Gaussian-mixture surrogate')
    ax_psf.grid(True, which='both', alpha=0.2)
    ax_psf.legend(fontsize=9)

    ax_err.axhline(0.0, color='black', linewidth=0.8)
    ax_err.set_xlabel('r / lambda')
    ax_err.set_ylabel('(surrogate - analytic) / analytic')
    ax_err.set_ylim(-1.0, 1.0)
    ax_err.set_title('Relative residual')
    ax_err.grid(True, which='both', alpha=0.2)
    ax_err.legend(fontsize=9)

    fig.suptitle('fast_exponential_filter: Gaussian-mixture approximation of a 2D exponential', fontsize=11)

    print('Fitted parameters — paste into `_EXPONENTIAL_GAUSSIAN_FITS`:')
    print()
    print('_EXPONENTIAL_GAUSSIAN_FITS: dict[int, np.ndarray] = {')
    for n_gaussians, fit in sorted(fitted.items()):
        print(f'    {n_gaussians}: np.array([')
        for amplitude, sigma_ratio in fit:
            print(f'        [{amplitude:.4f}, {sigma_ratio:.4f}],')
        print('    ], dtype=np.float64),')
    print('}')

    plt.show()


if __name__ == '__main__':
    main()
