import numpy as np
from numba import njit, prange
from math import sqrt, exp

@njit(parallel=True, cache=True)
def fast_binomial(N_arr, p_arr):
    """
    Generate an array of binomial random variates.

    For each element with parameters n (from N_arr) and p (from p_arr),
    the function selects:
      - Direct simulation for small n (< 25),
      - For larger n:
          * If n*p*(1-p) > 10, uses a Normal approximation,
          * Otherwise uses the inversion method.

    Supports input arrays of any shape.

    Parameters
    ----------
    N_arr : numpy array of int64
        Number of trials for each element.
    p_arr : numpy array of float64
        Success probability for each element.

    Returns
    -------
    result : numpy array of int64
        Binomial random variates, same shape as N_arr.
    """
    result = np.empty(N_arr.shape, dtype=np.int64)
    flat_N = N_arr.ravel()
    flat_p = p_arr.ravel()
    flat_result = result.ravel()
    n_elements = flat_N.shape[0]
    n_threshold = 25

    for i in prange(n_elements):
        n_val = flat_N[i]
        p_val = flat_p[i]
        if p_val <= 0.0:
            flat_result[i] = 0
        elif p_val >= 1.0:
            flat_result[i] = n_val
        else:
            if n_val < n_threshold:
                count = 0
                for k in range(n_val):
                    if np.random.rand() < p_val:
                        count += 1
                flat_result[i] = count
            else:
                mean = n_val * p_val
                var = n_val * p_val * (1.0 - p_val)
                if var > 10:
                    z = np.random.randn()
                    approx = mean + sqrt(var) * z
                    approx_int = int(np.round(approx))
                    if approx_int < 0:
                        approx_int = 0
                    elif approx_int > n_val:
                        approx_int = n_val
                    flat_result[i] = approx_int
                else:
                    u = np.random.rand()
                    cdf = 0.0
                    prob = (1.0 - p_val) ** n_val
                    k = 0
                    while cdf < u and k <= n_val:
                        cdf += prob
                        if k < n_val:
                            prob = prob * ((n_val - k) / (k + 1)) * (p_val / (1.0 - p_val))
                        k += 1
                    flat_result[i] = k - 1
    return result

@njit(parallel=True, cache=True)
def fast_poisson(lam_arr):
    """
    Generate an array of Poisson random variates from an array of rate parameters.

    For each element with lambda (from lam_arr):
      - If lambda <= 0, returns 0.
      - For lambda below 30, uses Knuth's algorithm.
      - Otherwise, uses a Normal approximation.

    Supports input arrays of any shape.

    Parameters
    ----------
    lam_arr : numpy array of float64
        Rate parameters (λ).

    Returns
    -------
    result : numpy array of int64
        Poisson random variates, same shape as lam_arr.
    """
    result = np.empty(lam_arr.shape, dtype=np.int64)
    flat_lam = lam_arr.ravel()
    flat_result = result.ravel()
    n_elements = flat_lam.shape[0]
    lam_threshold = 30.0

    for i in prange(n_elements):
        lam = flat_lam[i]
        if lam <= 0.0:
            flat_result[i] = 0
        elif lam < lam_threshold:
            L = exp(-lam)
            p_val = 1.0
            k = 0
            while p_val > L:
                k += 1
                p_val *= np.random.rand()
            flat_result[i] = k - 1
        else:
            z = np.random.randn()
            sample = lam + sqrt(lam) * z
            sample_int = int(np.round(sample))
            if sample_int < 0:
                sample_int = 0
            flat_result[i] = sample_int
    return result

@njit(parallel=True, cache=True)
def fast_lognormal(mu_arr, sigma_arr):
    """
    Generate an array of lognormal random variates.

    Each element is computed as exp(mu + sigma * z), where z is a standard normal variate.
    If sigma is below 1e-6, returns exp(mu) to avoid numerical issues.

    Supports input arrays of any shape.

    Parameters
    ----------
    mu_arr : numpy array of float64
        Underlying normal mean parameters.
    sigma_arr : numpy array of float64
        Underlying normal standard deviation parameters.

    Returns
    -------
    result : numpy array of float64
        Lognormal random variates, same shape as mu_arr.
    """
    result = np.empty(mu_arr.shape, dtype=np.float64)
    flat_mu = mu_arr.ravel()
    flat_sigma = sigma_arr.ravel()
    flat_result = result.ravel()
    n_elements = flat_mu.shape[0]
    sigma_threshold = 1e-6

    for i in prange(n_elements):
        mu_val = flat_mu[i]
        sigma_val = flat_sigma[i]
        if sigma_val < sigma_threshold:
            flat_result[i] = exp(mu_val)
        else:
            z = np.random.randn()
            flat_result[i] = exp(mu_val + sigma_val * z)
    return result

@njit(parallel=True, cache=True)
def fast_lognormal_from_mean_std(mean_arr, std_arr):
    """
    Generate an array of lognormal random variates from linear-space parameters.

    For a lognormal distribution with underlying normal parameters μ and σ,
    the linear-space mean (m) and standard deviation (s) are related as:
    
         m = exp(μ + σ²/2)
         s² = (exp(σ²) - 1) * exp(2μ + σ²)
    
    These relations are inverted to compute:
         σ = sqrt( ln(1 + (s²/m²)) )
         μ = ln(m) - σ²/2

    Supports input arrays of any shape.

    Parameters
    ----------
    mean_arr : numpy array of float64
        Mean values (m) in linear space.
    std_arr : numpy array of float64
        Standard deviation values (s) in linear space.

    Returns
    -------
    result : numpy array of float64
        Lognormal random variates, same shape as mean_arr.
    """
    result_shape = mean_arr.shape
    mu_arr = np.empty(result_shape, dtype=np.float64)
    sigma_arr = np.empty(result_shape, dtype=np.float64)
    flat_mean = mean_arr.ravel()
    flat_std = std_arr.ravel()
    flat_mu = mu_arr.ravel()
    flat_sigma = sigma_arr.ravel()
    n_elements = flat_mean.shape[0]

    for i in prange(n_elements):
        m = flat_mean[i]
        s = flat_std[i]
        if m <= 0:
            flat_mu[i] = 0.0
            flat_sigma[i] = 0.0
        else:
            sigma2 = np.log(1.0 + (s * s) / (m * m))
            flat_sigma[i] = sqrt(sigma2)
            flat_mu[i] = np.log(m) - sigma2 / 2.0

    return fast_lognormal(mu_arr, sigma_arr)

def warmup_fast_stats():
    """
    Warm up the fast random variate functions using small dummy arrays.

    This triggers compilation of the njit functions before benchmarking.
    """
    fast_poisson(np.array([[1.0, 2.0], [3.0, 4.0]], dtype=np.float64))
    fast_binomial(
        np.array([[10, 20], [30, 40]], dtype=np.int64),
        np.array([[0.5, 0.5], [0.5, 0.5]], dtype=np.float64)
    )
    fast_lognormal(
        np.array([[0.0, 1.0], [0.5, -0.5]], dtype=np.float64),
        np.array([[0.1, 0.2], [0.3, 0.4]], dtype=np.float64)
    )
    fast_lognormal_from_mean_std(
        np.full((2, 2), 2.0, dtype=np.float64),
        np.full((2, 2), 0.5, dtype=np.float64)
    )

if __name__=='__main__':
    import time
    import matplotlib.pyplot as plt

    size = (6000, 4000)
    pixel_area = (35000 / size[0])**2
    particle_area = 0.2
    n = pixel_area / particle_area
    n_max = np.int64(np.ceil(n * 1.3))
    n_min = np.int64(n * 0.8)
    print('N particles per pixel:', n)

    lam_array = np.random.uniform(n_min, n_max, size)
    n_array = np.random.randint(n_min, n_max, size)
    p_array = np.random.uniform(0, 1, size)
    
    start = time.time()
    warmup_fast_stats()
    print("Warm-up time:", (time.time() - start))

    start = time.time()
    poisson_np = np.random.default_rng().poisson(lam_array)
    binomial_np = np.random.default_rng().binomial(poisson_np, p_array)
    _ = np.random.lognormal(lam_array, p_array)    
    print("NumPy Binomial+Poisson Time (1 run x 9):", (time.time() - start) * 9)

    start = time.time()
    for i in np.arange(9):
        poisson_fast_auto = fast_poisson(lam_array)
        binomial_fast_auto = fast_binomial(poisson_fast_auto, p_array)
    _ = fast_lognormal_from_mean_std(lam_array, p_array)
    print("Fast Poisson+Poisson Time (9 runs):", (time.time() - start))
    
    # ----------------------------
    # Comparison Plot Section
    # ----------------------------
    # For plotting we use a smaller array size.
    small_size = (100, 100)

    # --- Poisson Distribution Comparison ---
    lam_val = 10.0
    lam_array_small = np.full(small_size, lam_val)
    poisson_numpy = np.random.default_rng().poisson(lam_array_small)
    poisson_fast = fast_poisson(lam_array_small)
    poisson_numpy_flat = poisson_numpy.flatten()
    poisson_fast_flat = poisson_fast.flatten()

    plt.figure(figsize=(15, 5))
    plt.subplot(1, 3, 1)
    bins_poisson = np.arange(0, np.max(poisson_numpy_flat) + 2) - 0.5
    plt.hist(poisson_numpy_flat, bins=bins_poisson, density=True, alpha=0.5, label='NumPy Poisson')
    plt.hist(poisson_fast_flat, bins=bins_poisson, density=True, alpha=0.5, label='Fast Poisson')
    plt.title('Poisson Distribution (λ = 10)')
    plt.xlabel('Value')
    plt.ylabel('Probability')
    plt.legend()

    # --- Binomial Distribution Comparison ---
    n_val = 20
    p_val = 0.3
    n_array_small = np.full(small_size, n_val)
    p_array_small = np.full(small_size, p_val)
    binomial_numpy = np.random.default_rng().binomial(n_array_small, p_array_small)
    binomial_fast = fast_binomial(n_array_small, p_array_small)
    binomial_numpy_flat = binomial_numpy.flatten()
    binomial_fast_flat = binomial_fast.flatten()

    plt.subplot(1, 3, 2)
    bins_binom = np.arange(0, n_val + 2) - 0.5
    plt.hist(binomial_numpy_flat, bins=bins_binom, density=True, alpha=0.5, label='NumPy Binomial')
    plt.hist(binomial_fast_flat, bins=bins_binom, density=True, alpha=0.5, label='Fast Binomial')
    plt.title('Binomial Distribution (n = 20, p = 0.3)')
    plt.xlabel('Value')
    plt.ylabel('Probability')
    plt.legend()

    # --- Lognormal Distribution Comparison ---
    # Using both parameterizations: log-space and linear-space.
    mu_val = 1.0
    sigma_val = 0.4
    mu_array_small = np.full(small_size, mu_val)
    sigma_array_small = np.full(small_size, sigma_val)
    lognormal_numpy = np.random.lognormal(mu_val, sigma_val, size=small_size)
    lognormal_fast = fast_lognormal(mu_array_small, sigma_array_small)
    
    # Generate lognormal variates using linear-space parameters.
    mean_linear = np.full(small_size, np.exp(mu_val + sigma_val**2 / 2))
    std_linear = np.full(small_size, np.sqrt((np.exp(sigma_val**2) - 1) * np.exp(2 * mu_val + sigma_val**2)))
    lognormal_linear = fast_lognormal_from_mean_std(mean_linear, std_linear)

    lognormal_numpy_flat = lognormal_numpy.flatten()
    lognormal_fast_flat = lognormal_fast.flatten()
    lognormal_linear_flat = lognormal_linear.flatten()

    plt.subplot(1, 3, 3)
    plt.hist(lognormal_numpy_flat, bins=50, density=True, alpha=0.5, label='NumPy Lognormal')
    plt.hist(lognormal_fast_flat, bins=50, density=True, alpha=0.5, label='Fast Lognormal')
    plt.hist(lognormal_linear_flat, bins=50, density=True, alpha=0.5, label='Linear-space Params')
    plt.title('Lognormal Distribution (μ = 1, σ = 0.4)')
    plt.xlabel('Value')
    plt.ylabel('Probability')
    plt.legend()

    plt.tight_layout()
    plt.show()
