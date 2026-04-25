"""Fit a normalized 2D exponential kernel with a normalized two-Gaussian surrogate.

This script explores the relationship between the exponential decay length
lambda and the best-fit two-Gaussian surrogate used by the scatter model:

    K_exp(r) = exp(-r / lambda) / (2 pi lambda^2)
    K_2g(r)  = (1 - w) G(r; sigma_c) + w G(r; sigma_t)

where each Gaussian is the unit-integral 2D isotropic kernel

    G(r; sigma) = exp(-r^2 / (2 sigma^2)) / (2 pi sigma^2).

The fit is done in radius space with positive constraints and a small amount
of logarithmic weighting so the tail matters in the objective. The output is:

1. An example shape comparison for a representative lambda.
2. Fitted sigma_c, sigma_t, and w versus lambda.
3. Dimensionless ratios sigma_c / lambda and sigma_t / lambda, plus w.

Run directly:

    python proto/fit_exponential_with_two_gaussians.py

or save without opening a window:

    python proto/fit_exponential_with_two_gaussians.py --no-show --output exp_fit.png
"""

from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from scipy.optimize import least_squares


DEFAULT_LAMBDA_MIN_UM = 5.0
DEFAULT_LAMBDA_MAX_UM = 120.0
DEFAULT_SAMPLE_COUNT = 18
DEFAULT_RADIUS_MULTIPLIER = 8.0
DEFAULT_RADIUS_SAMPLES = 4096
DEFAULT_EXAMPLE_LAMBDA_UM = 40.0


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Fit a 2D exponential tail with a two-Gaussian surrogate.')
    parser.add_argument('--lambda-min', type=float, default=DEFAULT_LAMBDA_MIN_UM, help='Minimum decay length lambda in um.')
    parser.add_argument('--lambda-max', type=float, default=DEFAULT_LAMBDA_MAX_UM, help='Maximum decay length lambda in um.')
    parser.add_argument('--sample-count', type=int, default=DEFAULT_SAMPLE_COUNT, help='Number of lambda samples to fit.')
    parser.add_argument('--radius-multiplier', type=float, default=DEFAULT_RADIUS_MULTIPLIER, help='Maximum fitted radius in multiples of lambda.')
    parser.add_argument('--radius-samples', type=int, default=DEFAULT_RADIUS_SAMPLES, help='Number of radius samples used in each fit.')
    parser.add_argument('--example-lambda', type=float, default=DEFAULT_EXAMPLE_LAMBDA_UM, help='Representative lambda shown in the shape comparison plot.')
    parser.add_argument('--output', type=Path, default=None, help='Optional output path for the plot image.')
    parser.add_argument('--no-show', action='store_true', help='Do not open a matplotlib window.')
    return parser.parse_args()


def _gaussian_kernel_2d(radius_um: np.ndarray, sigma_um: float) -> np.ndarray:
    sigma_um = max(float(sigma_um), 1e-12)
    return np.exp(-0.5 * (radius_um / sigma_um) ** 2) / (2.0 * np.pi * sigma_um ** 2)


def _exponential_kernel_2d(radius_um: np.ndarray, lambda_um: float) -> np.ndarray:
    lambda_um = max(float(lambda_um), 1e-12)
    return np.exp(-radius_um / lambda_um) / (2.0 * np.pi * lambda_um ** 2)


def _two_gaussian_kernel_2d(radius_um: np.ndarray, sigma_core_um: float, sigma_tail_um: float, tail_weight: float) -> np.ndarray:
    weight = float(np.clip(tail_weight, 0.0, 1.0))
    core = _gaussian_kernel_2d(radius_um, sigma_core_um)
    tail = _gaussian_kernel_2d(radius_um, sigma_tail_um)
    return (1.0 - weight) * core + weight * tail


def _make_radius_axis(lambda_um: float, radius_multiplier: float, radius_samples: int) -> np.ndarray:
    radius_max = max(float(lambda_um) * float(radius_multiplier), 1e-3)
    return np.linspace(0.0, radius_max, int(radius_samples), dtype=np.float64)


def _fit_two_gaussian_surrogate(lambda_um: float, radius_multiplier: float, radius_samples: int) -> dict[str, float | np.ndarray]:
    radius_um = _make_radius_axis(lambda_um, radius_multiplier, radius_samples)
    target = _exponential_kernel_2d(radius_um, lambda_um)
    weights = np.sqrt(1.0 + radius_um / max(float(lambda_um), 1e-12))

    def residuals(parameters: np.ndarray) -> np.ndarray:
        sigma_core_um, sigma_tail_um, tail_weight = parameters
        sigma_small = min(sigma_core_um, sigma_tail_um)
        sigma_large = max(sigma_core_um, sigma_tail_um)
        model = _two_gaussian_kernel_2d(radius_um, sigma_small, sigma_large, tail_weight)
        return (model - target) * weights / np.maximum(target, 1e-18)

    initial = np.array([0.55 * lambda_um, 2.2 * lambda_um, 0.25], dtype=np.float64)
    lower = np.array([1e-4, 1e-4, 0.0], dtype=np.float64)
    upper = np.array([10.0 * lambda_um, 20.0 * lambda_um, 1.0], dtype=np.float64)
    fit = least_squares(residuals, initial, bounds=(lower, upper), method='trf', ftol=1e-10, xtol=1e-10, gtol=1e-10)

    sigma_core_um, sigma_tail_um, tail_weight = fit.x
    sigma_core_um, sigma_tail_um = sorted((float(sigma_core_um), float(sigma_tail_um)))
    model = _two_gaussian_kernel_2d(radius_um, sigma_core_um, sigma_tail_um, float(tail_weight))
    rms_relative_error = float(np.sqrt(np.mean(((model - target) / np.maximum(target, 1e-18)) ** 2)))
    return {
        'lambda_um': float(lambda_um),
        'sigma_core_um': sigma_core_um,
        'sigma_tail_um': sigma_tail_um,
        'tail_weight': float(tail_weight),
        'radius_um': radius_um,
        'target': target,
        'model': model,
        'rms_relative_error': rms_relative_error,
    }


def _fit_lambda_sweep(lambdas_um: np.ndarray, radius_multiplier: float, radius_samples: int) -> list[dict[str, float | np.ndarray]]:
    return [_fit_two_gaussian_surrogate(float(lambda_um), radius_multiplier, radius_samples) for lambda_um in lambdas_um]


def _select_example_fit(fits: list[dict[str, float | np.ndarray]], example_lambda_um: float) -> dict[str, float | np.ndarray]:
    return min(fits, key=lambda entry: abs(float(entry['lambda_um']) - float(example_lambda_um)))


def _plot_results(fits: list[dict[str, float | np.ndarray]], example_fit: dict[str, float | np.ndarray]) -> plt.Figure:
    lambdas_um = np.array([float(entry['lambda_um']) for entry in fits], dtype=np.float64)
    sigma_core_um = np.array([float(entry['sigma_core_um']) for entry in fits], dtype=np.float64)
    sigma_tail_um = np.array([float(entry['sigma_tail_um']) for entry in fits], dtype=np.float64)
    tail_weight = np.array([float(entry['tail_weight']) for entry in fits], dtype=np.float64)
    rms_relative_error = np.array([float(entry['rms_relative_error']) for entry in fits], dtype=np.float64)

    fig, axes = plt.subplots(2, 2, figsize=(11.0, 9.0), constrained_layout=True)

    radius_um = np.asarray(example_fit['radius_um'], dtype=np.float64)
    target = np.asarray(example_fit['target'], dtype=np.float64)
    model = np.asarray(example_fit['model'], dtype=np.float64)
    example_lambda_um = float(example_fit['lambda_um'])
    example_sigma_core = float(example_fit['sigma_core_um'])
    example_sigma_tail = float(example_fit['sigma_tail_um'])
    example_tail_weight = float(example_fit['tail_weight'])

    ax = axes[0, 0]
    ax.semilogy(radius_um, target, color='k', linewidth=2.0, label='2D exponential target')
    ax.semilogy(radius_um, model, color='tab:orange', linewidth=1.6, linestyle='--', label='two-Gaussian fit')
    ax.set_xlabel('radius (um)')
    ax.set_ylabel('kernel value')
    ax.set_title(
        f'Example fit at lambda={example_lambda_um:.1f} um\n'
        f'sigma_c={example_sigma_core:.2f}, sigma_t={example_sigma_tail:.2f}, w={example_tail_weight:.4f}'
    )
    ax.grid(alpha=0.25, which='both')
    ax.legend(loc='upper right')

    ax = axes[0, 1]
    ax.plot(lambdas_um, sigma_core_um, color='tab:blue', linewidth=1.6, label='sigma_c')
    ax.plot(lambdas_um, sigma_tail_um, color='tab:red', linewidth=1.6, label='sigma_t')
    ax.plot(lambdas_um, lambdas_um, color='0.4', linewidth=1.0, linestyle=':', label='lambda')
    ax.set_xlabel('exponential decay lambda (um)')
    ax.set_ylabel('fitted sigma (um)')
    ax.set_title('Absolute sigma relationship')
    ax.grid(alpha=0.25)
    ax.legend(loc='upper left')

    ax = axes[1, 0]
    ax.plot(lambdas_um, sigma_core_um / lambdas_um, color='tab:blue', linewidth=1.6, label='sigma_c / lambda')
    ax.plot(lambdas_um, sigma_tail_um / lambdas_um, color='tab:red', linewidth=1.6, label='sigma_t / lambda')
    ax.plot(lambdas_um, tail_weight, color='tab:green', linewidth=1.6, label='w')
    ax.set_xlabel('exponential decay lambda (um)')
    ax.set_ylabel('dimensionless parameter')
    ax.set_title('Dimensionless relationship')
    ax.grid(alpha=0.25)
    ax.legend(loc='best')

    ax = axes[1, 1]
    ax.plot(lambdas_um, 100.0 * rms_relative_error, color='tab:purple', linewidth=1.6)
    ax.set_xlabel('exponential decay lambda (um)')
    ax.set_ylabel('RMS relative error (%)')
    ax.set_title('Fit residual across lambda sweep')
    ax.grid(alpha=0.25)

    return fig


def main() -> None:
    args = _parse_args()
    if args.lambda_min <= 0.0 or args.lambda_max <= 0.0:
        raise ValueError('Lambda bounds must be positive.')
    if args.lambda_max <= args.lambda_min:
        raise ValueError('--lambda-max must be greater than --lambda-min.')
    if args.sample_count < 2:
        raise ValueError('--sample-count must be at least 2.')

    lambdas_um = np.geomspace(args.lambda_min, args.lambda_max, args.sample_count)
    fits = _fit_lambda_sweep(lambdas_um, args.radius_multiplier, args.radius_samples)
    example_fit = _select_example_fit(fits, args.example_lambda)

    print('lambda_um  sigma_c_um  sigma_t_um  tail_weight  sigma_c/lambda  sigma_t/lambda  rms_rel_err_%')
    for entry in fits:
        lambda_um = float(entry['lambda_um'])
        sigma_core_um = float(entry['sigma_core_um'])
        sigma_tail_um = float(entry['sigma_tail_um'])
        tail_weight = float(entry['tail_weight'])
        rms_relative_error = float(entry['rms_relative_error'])
        print(
            f'{lambda_um:8.3f}  {sigma_core_um:10.4f}  {sigma_tail_um:10.4f}  {tail_weight:11.6f}  '
            f'{sigma_core_um / lambda_um:14.6f}  {sigma_tail_um / lambda_um:14.6f}  {100.0 * rms_relative_error:13.6f}'
        )

    sigma_core_ratio = np.array([float(entry['sigma_core_um']) / float(entry['lambda_um']) for entry in fits], dtype=np.float64)
    sigma_tail_ratio = np.array([float(entry['sigma_tail_um']) / float(entry['lambda_um']) for entry in fits], dtype=np.float64)
    tail_weight = np.array([float(entry['tail_weight']) for entry in fits], dtype=np.float64)
    print()
    print(
        'mean ratios: '
        f'sigma_c/lambda={np.mean(sigma_core_ratio):.6f}, '
        f'sigma_t/lambda={np.mean(sigma_tail_ratio):.6f}, '
        f'w={np.mean(tail_weight):.6f}'
    )

    fig = _plot_results(fits, example_fit)
    if args.output is not None:
        fig.savefig(args.output, dpi=150)
        print(f'Saved plot to {args.output}')
    if args.no_show:
        plt.close(fig)
    else:
        plt.show()


if __name__ == '__main__':
    main()